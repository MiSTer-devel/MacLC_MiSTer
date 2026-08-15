/*
 * dp8390.c — National DP8390 NIC model for the maclc_eth daemon.
 *
 * Written against MAME src/devices/machine/dp8390.cpp semantics (page-mapped
 * registers, remote DMA, receive ring with 4-byte headers), with the two
 * things MAME leaves out done properly because Mac drivers may rely on them:
 * loopback modes (TCR b2:1 — TX loops into the receive path / FIFO) and
 * clear-on-read tally counters (via the FPGA's READ_NOTIFY doorbell).
 *
 * The local-DMA address space (the card's 64K buffer RAM) is the DDR3
 * boardram, accessed through bram_read()/bram_write() from maclc_eth.c.
 */
#include <stdio.h>
#include <string.h>
#include "maclc_eth.h"

/* ISR bits */
#define ISR_PRX 0x01
#define ISR_PTX 0x02
#define ISR_RXE 0x04
#define ISR_TXE 0x08
#define ISR_OVW 0x10
#define ISR_CNT 0x20
#define ISR_RDC 0x40
#define ISR_RST 0x80

static struct {
    uint8_t cr;
    uint8_t pstart, pstop, bnry, tpsr, curr;
    uint8_t isr, imr, dcr, tcr, rcr, tsr, rsr, ncr;
    uint16_t tbcr, rsar, rbcr, crda, clda;
    uint8_t par[6], mar[8];
    uint8_t cntr[3];
    uint8_t fifo[8];
    int fifo_pos;
} r;

void dp8390_reset(void)
{
    memset(&r, 0, sizeof r);
    r.cr  = 0x21;          /* STP | page 0 */
    r.isr = ISR_RST;
    r.dcr = 0x04;
    LOG("[8390] reset\n");
}

int dp8390_running(void) { return (r.cr & 0x02) && !(r.cr & 0x01); }
int dp8390_int_line(void) { return (r.isr & r.imr & 0x7f) ? 1 : 0; }

/* ── CRC32 (FCS), bit-reversed poly, standard ethernet ────────────────── */
static uint32_t crc32_fcs(const uint8_t *p, int len)
{
    uint32_t crc = 0xFFFFFFFF;
    for (int i = 0; i < len; i++) {
        crc ^= p[i];
        for (int b = 0; b < 8; b++)
            crc = (crc >> 1) ^ (0xEDB88320 & (-(int)(crc & 1)));
    }
    return ~crc;
}

/* multicast hash: top 6 bits of the FCS CRC of the destination address */
static int mar_match(const uint8_t *dst)
{
    uint32_t crc = crc32_fcs(dst, 6);
    int bit = crc >> 26;
    return (r.mar[bit >> 3] >> (bit & 7)) & 1;
}

/* ── transmit ─────────────────────────────────────────────────────────── */
static void do_tx(void)
{
    static uint8_t frame[2048];
    int len = r.tbcr;
    if (len > (int)sizeof frame) len = sizeof frame;
    for (int i = 0; i < len; i++)
        frame[i] = bram_read(((uint32_t)r.tpsr << 8) + i);

    int loopback = !(r.dcr & 0x08) && (r.tcr & 0x06);
    if (loopback) {
        /* TX loops into the receive machinery. The real chip does not do
         * ring DMA in loopback — the tail of the frame lands in the FIFO
         * and the driver checks status/FIFO. Model: fill the FIFO with the
         * last bytes, flag a good receive, and complete the transmit. */
        int n = len < 8 ? len : 8;
        for (int i = 0; i < n; i++) r.fifo[i] = frame[len - n + i];
        r.fifo_pos = 0;
        r.rsr = 0x01;                   /* PRX: received intact */
        r.tsr = 0x01;                   /* PTX */
        r.isr |= ISR_PTX;
        LOG("[8390] loopback tx len=%d tcr=%02x\n", len, r.tcr);
    } else {
        wire_send(frame, len);
        r.tsr = 0x01;
        r.isr |= ISR_PTX;
        LOG("[8390] tx len=%d\n", len);
    }
    r.cr &= ~0x04;                      /* TXP self-clears */
}

/* ── receive (wire -> ring) ───────────────────────────────────────────── */
void dp8390_rx_frame(const uint8_t *frame, int len)
{
    if (!dp8390_running()) return;
    if (len < 14 || len > 1518) return;

    const uint8_t *dst = frame;
    int accept = 0;
    if (r.rcr & 0x10) accept = 1;                            /* PRO */
    else if (!memcmp(dst, r.par, 6)) accept = 1;
    else if (!memcmp(dst, "\xff\xff\xff\xff\xff\xff", 6)) accept = (r.rcr & 0x04) != 0; /* AB */
    else if (dst[0] & 1) accept = (r.rcr & 0x08) && mar_match(dst);                     /* AM */
    if (!accept) return;

    /* stored frame = payload + 4-byte FCS; the ring entry prepends a 4-byte
     * header {status, next_page, count_lo, count_hi}, count includes the
     * header (Linux 8390.c convention: pkt_len = count - 4). Data flows
     * continuously across pages — headers exist only at packet start. */
    uint32_t fcs = crc32_fcs(frame, len);
    int total = len + 4 + 4;
    int pages = (total + 255) >> 8;

    /* free pages between the write head (CURR) and the read tail (BNRY);
     * drivers keep CURR = BNRY+1 when empty, so free==0 means FULL */
    int ring = r.pstop - r.pstart;
    int free_pages = (r.bnry >= r.curr) ? (r.bnry - r.curr)
                                        : (ring - (r.curr - r.bnry));
    if (ring <= 0 || pages >= free_pages) {
        r.isr |= ISR_OVW;
        LOG("[8390] rx overflow len=%d\n", len);
        return;
    }

    uint8_t first = r.curr;
    uint32_t wr = ((uint32_t)first << 8) + 4;
    for (int i = 0; i < len + 4; i++) {
        uint8_t v = (i < len) ? frame[i] : (uint8_t)(fcs >> (8 * (i - len)));
        bram_write(wr, v);
        wr++;
        if ((wr >> 8) >= r.pstop) wr = (uint32_t)r.pstart << 8;
    }
    uint8_t next = first + (uint8_t)pages;
    if (next >= r.pstop) next = r.pstart + (next - r.pstop);

    r.rsr = 0x01;
    bram_write((uint32_t)first << 8,     r.rsr);
    bram_write(((uint32_t)first << 8)+1, next);
    bram_write(((uint32_t)first << 8)+2, (uint8_t)total);
    bram_write(((uint32_t)first << 8)+3, (uint8_t)(total >> 8));

    r.curr = next;
    r.isr |= ISR_PRX;
    LOG("[8390] rx len=%d pages=%d curr=%02x bnry=%02x\n", len, pages, r.curr, r.bnry);
}

/* ── remote DMA ───────────────────────────────────────────────────────── */
static void rdma_complete_check(void)
{
    if (r.rbcr == 0) r.isr |= ISR_RDC;
}

uint16_t dp8390_dataport_read(void)
{
    uint16_t v;
    if (r.dcr & 0x01) {                 /* word-wide */
        uint8_t b0 = bram_read(r.crda), b1 = bram_read(r.crda + 1);
        /* big-endian bus order when BOS+WTS (DCR b1:0 = 11) */
        v = ((r.dcr & 0x03) == 0x03) ? (uint16_t)((b0 << 8) | b1)
                                     : (uint16_t)((b1 << 8) | b0);
        r.crda += 2;
        r.rbcr = (r.rbcr > 2) ? r.rbcr - 2 : 0;
    } else {
        v = bram_read(r.crda);
        v |= v << 8;                    /* serve the byte on both lanes */
        r.crda += 1;
        r.rbcr = (r.rbcr > 1) ? r.rbcr - 1 : 0;
    }
    rdma_complete_check();
    return v;
}

void dp8390_dataport_write(uint16_t data)
{
    if (r.dcr & 0x01) {
        if ((r.dcr & 0x03) == 0x03) { bram_write(r.crda, data >> 8); bram_write(r.crda + 1, data & 0xff); }
        else                        { bram_write(r.crda, data & 0xff); bram_write(r.crda + 1, data >> 8); }
        r.crda += 2;
        r.rbcr = (r.rbcr > 2) ? r.rbcr - 2 : 0;
    } else {
        bram_write(r.crda, data & 0xff);  /* MAME remote_write: low byte */
        r.crda += 1;
        r.rbcr = (r.rbcr > 1) ? r.rbcr - 1 : 0;
    }
    rdma_complete_check();
}

/* ── register writes (doorbell) ───────────────────────────────────────── */
void dp8390_reg_write(uint8_t a, uint8_t d)
{
    int page = (r.cr >> 6) & 3;
    if (a == 0) {                       /* CR, common to all pages */
        uint8_t rd = (d >> 3) & 7;
        r.cr = d;
        if (d & 0x01) {                 /* STP */
            r.isr |= ISR_RST;
        }
        if (d & 0x02) r.isr &= ~ISR_RST;
        if (rd == 1 || rd == 2) {       /* remote read / write */
            r.crda = r.rsar;
            rdma_complete_check();
        } else if (rd == 3) {           /* send packet */
            r.crda = ((uint32_t)r.bnry << 8);
            r.rbcr = 0;                 /* minimal: drivers here don't use it */
        }
        if ((d & 0x04) && (d & 0x02)) do_tx();
        return;
    }
    switch (page) {
    case 0:
        switch (a) {
        case 0x1: r.pstart = d; break;
        case 0x2: r.pstop = d; break;
        case 0x3: r.bnry = d; break;
        case 0x4: r.tpsr = d; break;
        case 0x5: r.tbcr = (r.tbcr & 0xff00) | d; break;
        case 0x6: r.tbcr = (r.tbcr & 0x00ff) | (d << 8); break;
        case 0x7: r.isr &= ~d; break;   /* write-1-to-clear */
        case 0x8: r.rsar = (r.rsar & 0xff00) | d; break;
        case 0x9: r.rsar = (r.rsar & 0x00ff) | (d << 8); break;
        case 0xA: r.rbcr = (r.rbcr & 0xff00) | d; break;
        case 0xB: r.rbcr = (r.rbcr & 0x00ff) | (d << 8); break;
        case 0xC: r.rcr = d; break;
        case 0xD: r.tcr = d; break;
        case 0xE: r.dcr = d; break;
        case 0xF: r.imr = d; break;
        }
        break;
    case 1:
        if (a >= 1 && a <= 6) r.par[a - 1] = d;
        else if (a == 7) r.curr = d;
        else r.mar[a - 8] = d;
        break;
    case 2:
        switch (a) {                    /* page 2 writes mirror page 0 config */
        case 0x1: r.clda = (r.clda & 0xff00) | d; break;
        case 0x2: r.clda = (r.clda & 0x00ff) | (d << 8); break;
        case 0xC: r.rcr = d; break;
        case 0xD: r.tcr = d; break;
        case 0xE: r.dcr = d; break;
        case 0xF: r.imr = d; break;
        }
        break;
    }
}

void dp8390_read_notify(uint8_t a)
{
    /* FPGA served a clear-on-read register from the shadow — mirror the
     * clear here. Page 0 regs $0D-$0F are the tally counters. */
    if (((r.cr >> 6) & 3) == 0 && a >= 0xD)
        r.cntr[a - 0xD] = 0;
}

/* ── shadows: the READ view of all 3 pages ────────────────────────────── */
void dp8390_fill_shadows(uint8_t s[48])
{
    memset(s, 0, 48);
    /* page 0 read map */
    s[0x0] = r.cr;
    s[0x1] = r.clda & 0xff;
    s[0x2] = r.clda >> 8;
    s[0x3] = r.bnry;
    s[0x4] = r.tsr;
    s[0x5] = r.ncr;
    s[0x6] = r.fifo[r.fifo_pos & 7];
    s[0x7] = r.isr;
    s[0x8] = r.crda & 0xff;
    s[0x9] = r.crda >> 8;
    s[0xC] = r.rsr;
    s[0xD] = r.cntr[0];
    s[0xE] = r.cntr[1];
    s[0xF] = r.cntr[2];
    /* page 1 read map */
    s[0x10] = r.cr;
    memcpy(&s[0x11], r.par, 6);
    s[0x17] = r.curr;
    memcpy(&s[0x18], r.mar, 8);
    /* page 2 read map */
    s[0x20] = r.cr;
    s[0x21] = r.pstart;
    s[0x22] = r.pstop;
    s[0x24] = r.tpsr;
    s[0x2C] = r.rcr;
    s[0x2D] = r.tcr;
    s[0x2E] = r.dcr;
    s[0x2F] = r.imr;
}
