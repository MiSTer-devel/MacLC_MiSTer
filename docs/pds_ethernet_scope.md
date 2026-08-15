# LC PDS Ethernet — scope & design (2026-08-15)

Goal: a Macintosh LC PDS Ethernet card in the core, bridged to real networking
on the HPS, **without modifying Main_MiSTer** ("don't touch Main" — user
ruling). EtherTalk (AppleShare/Chooser) and MacTCP should both work in the
guest, which means real Ethernet frames end-to-end, not an IP-level tunnel
(SCC PPP already covers IP-only).

## Where the "existing plumbing" actually lives (recon result)

The Amiga Ethernet card on MiSTer is the **Minimig A2065** (Zorro II, Am7990
LANCE). Its split, from the shipped sources (Minimig `rtl/A2065/`, Main
`support/minimig/minimig_a2065*`):

- **FPGA side is deliberately dumb**: Zorro autoconfig + LANCE RAP/RDP
  register front-end + the card's buffer RAM ("boardram") — all backed by a
  **DDR3 shared-memory mailbox** on the core's DDRAM port:
  - Register **writes** post `{reg, data}` entries into a DDR3 **CMD ring**
    and stretch DTACK only until the entry lands in DDR3 (never waits on
    host software — that would deadlock against single-threaded Main).
  - Register **reads** are answered instantly from a **CSR shadow** the host
    keeps current in DDR3 (FPGA re-polls it every ~64 idle cycles).
  - **Boardram** accesses are DTACK-stretched DDR3 reads/writes (RMW for
    byte lanes) into a flat window both sides share.
  - An **INT word** in DDR3, host-written, FPGA-polled, drives the card IRQ.
- **Host side owns the chip**: the whole Am7990 model (descriptor rings, CRC,
  MAC filter) plus the network bridge runs on the ARM, fed by `a2065_poll()`.
  Bridge modes: `eth0` (promiscuous + BPF filter), `eth1` (dedicated second
  NIC), `macvlan` (own MAC on the LAN without a second NIC), `tap0` (private
  subnet / NAT; the only mode that works over WiFi). AF_PACKET raw sockets /
  TUNSETIFF — all portable code.
- DDR3 window: ARM physical `0x1FF00000` (Avalon/DDRAM word `0x03FE0000`).
  Proven safe against Linux/Main on shipping MiSTers.

**The catch:** `a2065_start()`/`a2065_poll()` run only under
`if (is_minimig())` in Main's `user_io.cpp`. There is no NE2000 anywhere in
Main (checked the user's fork, which is what the bench runs). So "reuse the
plumbing" cannot mean "Main will serve our card" — the Main half is
minimig-keyed.

**Resolution that honors "don't touch Main":** reuse the *architecture and
code* wholesale, but run the host half as a **standalone HPS daemon**
(`maclc_eth`, cross-compiled `arm-linux-gnueabihf` — toolchain present in
WSL), shipped in `releases/` like the validated Main binary is today. It mmaps
`/dev/mem` at the same reserved DDR3 window, bridges to tap/macvlan/eth
exactly like `minimig_a2065_ethernet.cpp` (ported), and idles unless
`/tmp/CORENAME` says `MacLC`. If the user later prefers it inside their Main
fork, the daemon ports nearly 1:1 into `support/mac/` next to `mac_cdrom` —
explicitly out of scope now.

## Guest-visible card: Asante MacCON i LC (`pdslc_macconilc`)

MAME (local `~/repos/mame`, 0.287-era) emulates **three** LC PDS ethernet
cards: `macconilc` (Asante MacCON i LC, **DP8390**, 64 KiB on-card RAM),
`enetlc`/`enetlctp` (Apple Ethernet LC, **DP83932C SONIC**, no card RAM —
**bus-masters into host RAM**). The SONIC cards are disqualified for us: the
daemon can't reach guest RAM (it's FPGA-side SDRAM, not DDR3), so a SONIC
would drag the whole chip model into RTL plus a bus-master port into the
memory controller. The **MacCON i LC is the target**: self-contained
(registers + its own 64 KiB buffer + declROM), DP8390/NE2000-shaped, and its
entire state machine can live in the daemon exactly like the A2065's LANCE
does.

Reference: `mame/src/devices/bus/nubus/nubus_asntmc3b.cpp`
(`pdslc_macconilc_device`, hardwired slot $E), `cards.cpp:84-98` (valid on
`maclc`, `maclc2`, `maccclas`). declROM: `asante_maccon_lc_mcilc_1.1.bin`,
16 KiB, CRC `b95940be` SHA1 `317255bc…` (MAME romset `pdslc_macconlc`; not in
the local romset — must be sourced; see Phase 1).

### Address decode (MAME ground truth)

The LC's V8 decodes with mask `0x80ffffff` (A30-A24 don't-care): the entire
**A31=1** half is PDS space. The Slot Manager and drivers use the canonical
`$FExx'xxxx` forms (slot $E standard space); our core already models the
probe behavior there ($F1-$FE = `slot_space`, open-bus `$FFFF` ack — keep for
everything the card doesn't claim). MAME also installs a **24-bit window**
(slot $E view, `$00E0'0000-$00EF'FFFF`), and installs the card's RAM/regs in
both — the Asante driver evidently uses 24-bit addressing at runtime.

| Region | 32-bit form | 24-bit form | Notes |
|---|---|---|---|
| Card buffer RAM 64 KiB | `$FE0D'0000-$FE0D'FFFF` | `$00ED'0000-$00ED'FFFF` | 8-bit device on real HW (020 dynamic sizing); we serve 16-bit words with UDS/LDS — same data, fewer cycles |
| DP8390 registers | `$FE0E'0000-$FE0E'003F` | `$00EE'0000-$00EE'003F` | 16 regs × 4-byte stride, byte on **D[15:8]** (even address, UDS); **register index = `0xF − addr[5:2]`** (A5..A2 wired inverted) |
| Remote-DMA data port | word access (UDS+LDS) anywhere in the reg window | same | 16-bit; see risk #2 |
| Declaration ROM | top of slot space, ends `$FEFF'FFFF` | not needed (MAME omits it; `maclc` Slot Manager scans in 32-bit mode) | lane-expansion per the ROM's byteLanes byte done **by the daemon** when it stages the image |

IRQ path (MAME `maclc.cpp:408-414`, `pseudovia.cpp:113,190`): card INT
(active high) → slot $E → V8 `slot2_irq_w` → pseudo-VIA slot-IFR reg `$02`
bit `$20` **active low**, IER `$12` bit `$20`, "any slot" bit `$02` of IFR
`$03` → **IPL 2**. Our `pseudovia.sv` already models exactly this and
`MacLC.sv:900` has the `pds_slot_irq` stub on the right bit. Nothing to
change but the wire.

## Our split (A2065 pattern, 8390 flavor)

FPGA (new `rtl/pds/pds_enet.sv`, **single clock domain**: mailbox runs in
clk_sys and `DDRAM_CLK = clk_sys`, so the A2065's CDC machinery collapses;
the DDRAM port is currently tied off = wholly ours):

- Slot decode carved out of `slot_space`/unmapped-I/O in **both tops**
  (MacLC.sv + verilator/sim.v — `verilator_differences.md` discipline), for
  the four regions above. Card regions get stretched DTACK (and are excluded
  from the VPA path in the 24-bit window); unclaimed slot space keeps the
  hardware-validated `$FFFF` open-bus ack.
- **Register front-end**: writes → CMD ring doorbell entries
  `{tag, addr[3:0], data[7:0]}`, order-preserving (page switches via CR
  interleave with per-page writes; the daemon resolves paging like
  `dp8390.cpp` does: `(addr & 0x0f) | (cr & 0xc0)`). Reads ← shadow block
  (daemon-maintained; ISR/CURR/BNRY/TSR/RSR/CR + friends). Clear-on-read
  counters (CNTR0-2) get a non-blocking READ_NOTIFY doorbell entry so the
  daemon can clear its copies.
- **Buffer RAM / declROM**: DTACK-stretched DDR3 reads/writes (RMW for byte
  lanes), A2065-style. Slot Manager's boot scan of the ROM window costs tens
  of ms — fine. No M10K anywhere.
- **Presence gate**: card decodes only when the daemon's MAGIC/heartbeat word
  is valid in DDR3 **and** the OSD "Ethernet" option is On. No daemon ⇒
  slot $E stays open-bus ⇒ today's boot exactly (sim boot gate unaffected).
- IRQ: DDR3 INT word → `pds_slot_irq`. Daemon orders shadow updates before
  raising INT, so the ISR the guest's handler reads is always current.
- Guest reset (warm restart) posts a RESET doorbell entry; regfile resets.

Daemon (`hps/maclc_eth/`, C):

- Port of `minimig_a2065_ethernet.cpp` (iface modes incl. BPF/macvlan/tap) +
  a full DP8390 model written against MAME `dp8390.cpp` semantics — but with
  the two things MAME skips done properly: **loopback modes** (Mac drivers
  self-test at open; TCR b2:1 route TX back to the RX path) and the **MAC
  PROM** (see risk #1).
- TX: CR.TXP → read TBCR bytes at TPSR<<8 from boardram → iface. RX: frame →
  ring write PSTART..PSTOP with 4-byte header, CURR/BNRY/overflow, PAR/MAR
  filtering. ISR/IMR → INT word.
- Stages the declROM into DDR3 at start (lane-expanded exactly as
  `nubus.cpp:399-535` does, from the image's trailing byteLanes byte) and
  patches the per-unit MAC wherever the dissected ROM expects it.
- Config: args/INI (iface mode; default `tap0`). Idles unless
  `/tmp/CORENAME == MacLC`; withdraws MAGIC when idle.

DDR3 window (ours, v1 — same reserved area as A2065; cores are mutually
exclusive so no conflict):

```
ARM 0x1FF00000 + :                      (DDRAM word addr 0x03FE0000 + off>>3)
0x00000-0x0FFFF  boardram 64 KiB  (8390 local-DMA space)
0x10000-0x1FFFF  declROM window 64 KiB (lane-expanded image, ARM-staged)
0x20000-0x207FF  control words: MAGIC/heartbeat, geometry/version,
                 CMD_WPTR (FPGA→ARM), reg shadows, INT, dataport RPC slots
0x20800-0x20FFF  CMD ring (256 × 64-bit)
```

## Risks / open questions

1. **MAC PROM location is genuinely unknown.** MAME fills `m_prom[16]` but
   never maps it into guest space — a modelling gap flagged in the source
   sweep; the local romset also lacks the declROM, so MAME can't be run as an
   oracle until the ROM is sourced. Plan: source the ROM, dissect the
   declaration ROM (sResource tree + driver code) to find where the driver
   reads the MAC (declROM sResource data vs an NE2000-style PROM shadow at
   local-DMA 0x0000 via the data port). The daemon patches the MAC bytes (+
   checksum) wherever that turns out to be.
2. **Remote-DMA data port reads** are destructive/sequential — not
   shadow-servable. Bet (to verify in the driver dissection): the driver
   copies frames via the directly-mapped RAM and touches the data port
   rarely or never. v1: data-port writes ride the doorbell; data-port reads
   are a stall-until-daemon RPC with a watchdog fallback (~50 ms → `$FFFF`,
   never hang the guest — the SCSI pseudo-DMA timeout lesson). If the driver
   turns out to bulk-copy through the port, revisit (FPGA-side CRDA walker).
3. **Shadow freshness** for polled ISR: bounded by the daemon poll cadence
   (aim ≤1 ms; A2065 proves the pattern under AmigaOS interrupt handlers).
4. **declROM provenance**: ships like the other ROMs in `releases/`
   (16 KiB, MAME romset `pdslc_macconlc`). Guest driver: Asante's archived
   installers; possibly the declROM driver alone suffices (Slot Manager
   loads drivers from card ROM) — determined during dissection/HW test.
5. **Daemon lifecycle**: `/tmp/CORENAME` gating; survive core reloads (FPGA
   republishes CMD_WPTR=0 on reset per the A2065 ring design; MAGIC
   handshake re-establishes).
6. **Fit cost**: est. ~500-900 ALMs, 0 M10K. Per-seed video gate law applies
   to any new fit; seed lore in memory (7 good recently).
7. **16 MHz CPU mode**: stretched-DTACK card access is speed-independent.

## Phases (commit per phase)

1. **Scope doc** (this file) + **source the declROM** + dissect it (MAC
   location, data-port usage, loopback self-test) — the three risk-killers.
2. **RTL card front-end + mailbox** (`rtl/pds/`): decode, regfile, doorbell
   ring, shadows, DDR3 FSM; wired in both tops; presence-gated; OSD option.
3. **Verilator**: behavioral DDR3 model + TB playing the daemon role
   (register echo, boardram RW, declROM serve, IRQ); boot gate green with
   daemon absent AND with a staged declROM (Slot Manager scan exercised).
4. **Daemon**: iface layer port, 8390 model, ROM stage/patch; WSL cross
   build; bench smoke against the FPGA build.
5. **Quartus fit** + resource/timing check + deploy candidate; user does the
   guest-driver install + HW validation (deploy discipline: one canonical
   RBF, no interim rollbacks).
