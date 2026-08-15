/*
 * maclc_eth.c — main: /dev/mem window, declROM staging, doorbell ring drain,
 * poll loop, core-name gating.
 *
 * Runs standalone on the MiSTer HPS (no Main_MiSTer changes): start it from
 * /media/fat/linux/user-startup.sh. It idles until /tmp/CORENAME says the
 * MacLC core is loaded, then stages the declaration ROM into the DDR3 window,
 * raises MAGIC, and serves the DP8390 doorbell + the network bridge.
 *
 *   maclc_eth [-i iface] [-r rompath] [-m aa:bb:cc:dd:ee:ff] [-f] [-v]
 *     -i  tap0 (default) | eth0 | a macvlan child | any interface
 *     -r  declaration ROM (default /media/fat/games/MacLC/maccon.rom)
 *     -m  guest MAC override (default: Asante OUI + hostname hash)
 *     -f  stay in foreground (default daemonizes)
 *     -v  verbose
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include "maclc_eth.h"

int verbose = 0;

static volatile uint8_t *win;      /* the mmap'd DDR3 window */
static volatile uint64_t *w64(uint32_t off) { return (volatile uint64_t *)(win + off); }

uint8_t bram_read(uint32_t a)          { return win[OFF_BRAM + (a & 0xFFFF)]; }
void    bram_write(uint32_t a, uint8_t v) { win[OFF_BRAM + (a & 0xFFFF)] = v; }
void    wire_send(const uint8_t *f, int l) { iface_send(f, l); }

static uint8_t guest_mac[6];
static char    rompath[512] = "/media/fat/games/MacLC/maccon.rom";
static char    ifname[64]   = "tap0";
static int     card_up = 0;
static uint32_t rptr = 0;

/* ── declROM staging ──────────────────────────────────────────────────── */
/* Apple declaration ROM CRC: rotate-left-1 then add, the 4 CRC bytes
 * themselves count as zero. Verified against the MacCON dump. */
static void fix_declrom_crc(uint8_t *rom, int n)
{
    uint32_t length = (rom[n-16] << 24) | (rom[n-15] << 16) | (rom[n-14] << 8) | rom[n-13];
    int crc_pos = n - 12;
    uint32_t c = 0;
    for (int i = n - (int)length; i < n; i++) {
        c = (c << 1) | (c >> 31);
        if (i < crc_pos || i >= crc_pos + 4) c += rom[i];
    }
    rom[crc_pos]   = c >> 24;
    rom[crc_pos+1] = c >> 16;
    rom[crc_pos+2] = c >> 8;
    rom[crc_pos+3] = c;
    LOG("[rom] length=0x%x crc=%08x\n", length, c);
}

static int stage_declrom(void)
{
    uint8_t rom[0x4000];
    FILE *f = fopen(rompath, "rb");
    if (!f) { printf("[rom] cannot open %s\n", rompath); return 0; }
    int n = fread(rom, 1, sizeof rom, f);
    fclose(f);
    if (n != sizeof rom) { printf("[rom] %s: bad size %d\n", rompath, n); return 0; }

    /* the functional sResource's MAC entry (id $80) points at ROM offset 0 —
     * patch the per-unit address in and re-fix the CRC */
    memcpy(rom, guest_mac, 6);
    fix_declrom_crc(rom, n);

    /* byteLanes $A5 (lanes 0,2): ROM byte i -> window byte 0x8000 + 2*i,
     * skipped lanes read $FF; bottom 32K of the 64K window is $FF filler */
    for (uint32_t i = 0; i < 0x8000; i++) win[OFF_ROM + i] = 0xFF;
    for (uint32_t i = 0; i < (uint32_t)n; i++) {
        win[OFF_ROM + 0x8000 + 2*i]     = rom[i];
        win[OFF_ROM + 0x8000 + 2*i + 1] = 0xFF;
    }
    LOG("[rom] staged %s, MAC %02X:%02X:%02X:%02X:%02X:%02X\n", rompath,
        guest_mac[0], guest_mac[1], guest_mac[2], guest_mac[3], guest_mac[4], guest_mac[5]);
    return 1;
}

/* ── shadows / INT ────────────────────────────────────────────────────── */
static void push_state(void)
{
    uint8_t s[48];
    dp8390_fill_shadows(s);
    for (int i = 0; i < 6; i++) {
        uint64_t v = 0;
        for (int k = 0; k < 8; k++) v |= (uint64_t)s[i*8 + k] << (8*k);
        *w64(OFF_SHAD + 8*i) = v;
    }
    __sync_synchronize();
    *w64(OFF_INT) = dp8390_int_line() ? 1 : 0;
}

/* ── doorbell ring ────────────────────────────────────────────────────── */
static void drain_ring(void)
{
    uint32_t wp = (uint32_t)*w64(OFF_WPTR);
    if (wp < rptr) {
        LOG("[ring] wptr regressed (%u < %u) — FPGA reset, resync\n", wp, rptr);
        rptr = 0;
    }
    int guard = 512;
    while (rptr != wp && guard--) {
        uint64_t e = *w64(OFF_RING + 8 * (rptr & 0xFF));
        rptr++;
        if (!(e & 1)) continue;
        int tag  = (e >> 1) & 7;
        int addr = (e >> 4) & 0xF;
        int data = (e >> 8) & 0xFFFF;
        int seq  = (e >> 24) & 0xFF;
        switch (tag) {
        case TAG_REG_WR:      dp8390_reg_write(addr, data & 0xFF); break;
        case TAG_DATAPORT_WR: dp8390_dataport_write(data); break;
        case TAG_DATAPORT_RD: {
            uint16_t v = dp8390_dataport_read();
            *w64(OFF_RPC) = 1ULL | ((uint64_t)seq << 8) | ((uint64_t)v << 16);
            break;
        }
        case TAG_READ_NOTIFY: dp8390_read_notify(addr); break;
        case TAG_RESET:       dp8390_reset(); break;
        }
    }
    *w64(OFF_RPTR) = rptr;
}

/* ── card lifecycle ───────────────────────────────────────────────────── */
static void card_start(void)
{
    dp8390_reset();
    rptr = (uint32_t)*w64(OFF_WPTR);   /* skip anything stale */
    *w64(OFF_RPTR) = rptr;             /* release the FPGA's ring backpressure */
    if (!stage_declrom()) return;
    if (!iface_open(ifname)) return;
    push_state();
    *w64(OFF_GEO) = 1;                 /* layout version */
    __sync_synchronize();
    *w64(OFF_MAGIC) = MAGIC_V;
    card_up = 1;
    printf("[maclc_eth] card up (iface %s)\n", ifname);
}

static void card_stop(void)
{
    if (!card_up) return;
    *w64(OFF_MAGIC) = 0;
    iface_close();
    card_up = 0;
    printf("[maclc_eth] card down\n");
}

static int core_is_maclc(void)
{
    char buf[64] = {0};
    FILE *f = fopen("/tmp/CORENAME", "r");
    if (!f) return 0;
    if (!fgets(buf, sizeof buf - 1, f)) buf[0] = 0;
    fclose(f);
    buf[strcspn(buf, "\r\n")] = 0;
    return !strncasecmp(buf, "MACLC", 5);
}

static void default_mac(void)
{
    /* Asante OUI + FNV hash of the hostname: stable per box, unique enough */
    char hn[128] = "mister";
    FILE *f = fopen("/etc/hostname", "r");
    if (f) { if (fgets(hn, sizeof hn - 1, f)) hn[strcspn(hn, "\r\n")] = 0; fclose(f); }
    uint32_t h = 2166136261u;
    for (char *p = hn; *p; p++) h = (h ^ (uint8_t)*p) * 16777619u;
    guest_mac[0] = 0x00; guest_mac[1] = 0x00; guest_mac[2] = 0x94;
    guest_mac[3] = h >> 16; guest_mac[4] = h >> 8; guest_mac[5] = h;
}

int main(int argc, char **argv)
{
    int foreground = 0, opt;
    default_mac();
    while ((opt = getopt(argc, argv, "i:r:m:fv")) != -1) {
        switch (opt) {
        case 'i': snprintf(ifname, sizeof ifname, "%s", optarg); break;
        case 'r': snprintf(rompath, sizeof rompath, "%s", optarg); break;
        case 'm': {
            unsigned m[6];
            if (sscanf(optarg, "%x:%x:%x:%x:%x:%x", &m[0],&m[1],&m[2],&m[3],&m[4],&m[5]) == 6)
                for (int i = 0; i < 6; i++) guest_mac[i] = m[i];
            break;
        }
        case 'f': foreground = 1; break;
        case 'v': verbose = 1; break;
        default:
            printf("usage: %s [-i iface] [-r rompath] [-m mac] [-f] [-v]\n", argv[0]);
            return 1;
        }
    }

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("/dev/mem"); return 1; }
    win = (volatile uint8_t *)mmap(NULL, WIN_SIZE, PROT_READ | PROT_WRITE,
                                   MAP_SHARED, fd, DDR_BASE);
    if (win == MAP_FAILED) { perror("mmap"); return 1; }

    if (!foreground && daemon(0, verbose ? 1 : 0)) { perror("daemon"); return 1; }
    signal(SIGPIPE, SIG_IGN);
    printf("[maclc_eth] window @0x%lX, iface %s, rom %s\n", DDR_BASE, ifname, rompath);

    int corename_div = 0;
    while (1) {
        if (++corename_div >= (card_up ? 1000 : 50)) {   /* ~1s / ~50ms-ish */
            corename_div = 0;
            int want = core_is_maclc();
            if (want && !card_up) card_start();
            else if (!want && card_up) card_stop();
        }

        if (!card_up) { usleep(20000); continue; }

        drain_ring();

        uint8_t frame[2048];
        for (int i = 0; i < 16; i++) {
            int n = iface_recv(frame, sizeof frame);
            if (n <= 0) break;
            dp8390_rx_frame(frame, n);
        }

        push_state();

        struct pollfd p = { .fd = iface_fd(), .events = POLLIN };
        poll(&p, 1, 1);                /* 1 ms pace, wake early on rx */
    }
    return 0;
}
