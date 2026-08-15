/*
 * maclc_eth — HPS-side daemon for the MacLC core's PDS Ethernet card
 * (Asante MacCON i LC front-end in rtl/pds/pds_enet.sv).
 *
 * Standalone port of the Minimig A2065 host-half architecture
 * (Main_MiSTer support/minimig/minimig_a2065*, GPL) — runs OUTSIDE Main so
 * the core needs no Main changes. See docs/pds_ethernet_scope.md.
 */
#ifndef MACLC_ETH_H
#define MACLC_ETH_H

#include <stdint.h>

/* ── DDR3 shared window (must mirror rtl/pds/pds_enet.sv) ─────────────── */
#define DDR_BASE     0x1FF00000UL
#define WIN_SIZE     0x21000UL

#define OFF_BRAM     0x00000UL   /* 64K boardram (guest byte A = win[A]) */
#define OFF_ROM      0x10000UL   /* 64K declROM window (lane-expanded)   */
#define OFF_MAGIC    0x20000UL
#define OFF_WPTR     0x20008UL   /* FPGA->ARM doorbell write index       */
#define OFF_SHAD     0x20010UL   /* 6 x u64 register shadows (read view) */
#define OFF_INT      0x20040UL
#define OFF_RPC      0x20048UL
#define OFF_GEO      0x20050UL
#define OFF_RPTR     0x20058UL   /* ARM->debug: daemon's ring read index */
#define OFF_RING     0x20800UL   /* 256 x u64 */

#define MAGIC_V      0x4D634C4345544831ULL

#define TAG_REG_WR       0
#define TAG_DATAPORT_WR  1
#define TAG_DATAPORT_RD  2
#define TAG_READ_NOTIFY  3
#define TAG_RESET        4

/* ── DP8390 model (dp8390.c) ──────────────────────────────────────────── */
void dp8390_reset(void);
void dp8390_reg_write(uint8_t addr, uint8_t data);
void dp8390_read_notify(uint8_t addr);
void dp8390_dataport_write(uint16_t data);
uint16_t dp8390_dataport_read(void);
void dp8390_rx_frame(const uint8_t *frame, int len);   /* from the wire */
int  dp8390_running(void);
void dp8390_fill_shadows(uint8_t shad[48]);
int  dp8390_int_line(void);
/* board glue provided by maclc_eth.c: */
uint8_t  bram_read(uint32_t addr);
void     bram_write(uint32_t addr, uint8_t v);
void     wire_send(const uint8_t *frame, int len);

/* ── network iface (enet_iface.c) ─────────────────────────────────────── */
int  iface_open(const char *name);      /* "tapN" or raw iface name */
void iface_close(void);
int  iface_send(const uint8_t *frame, int len);
int  iface_recv(uint8_t *buf, int maxlen);   /* non-blocking, -1 if none */
int  iface_fd(void);
int  iface_get_mac(uint8_t mac[6]);

extern int verbose;
#define LOG(...)  do { if (verbose) { printf(__VA_ARGS__); fflush(stdout); } } while (0)

#endif
