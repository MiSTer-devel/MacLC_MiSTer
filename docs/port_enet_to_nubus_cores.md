# RESUME PROMPT — port the ethernet card to NuBus Mac cores (MacIIvi, Macintosh II)

Paste this whole file as the opening prompt of a session **in the target core's
repo** (e.g. `..\MacIIvi_MiSTer`). It carries everything that session needs from
the MacLC work; the reference implementation lives in
`C:\Temp\mistercore\MacLC_MiSTer` on branch `add-pds-ethernet`.

## Mission

Port the MacLC PDS ethernet feature to this NuBus-based Mac core as an
**Asante MC3NB** (NuBus, same DP8390 chip as the MacCON i LC). Reuse the DDR3
mailbox architecture and the `maclc_eth` HPS daemon essentially unchanged;
replace the LC-specific slot front-end with NuBus slot decode and this card's
declaration ROM. MiSTer Main is NOT modified — the daemon is standalone.

## What already exists (MacLC repo, branch add-pds-ethernet)

| piece | file | notes |
|---|---|---|
| FPGA front-end | `rtl/pds/pds_enet.sv` (521 L) | slot decode, DDR3 mailbox client, reg-RPC, stretched ROM/RAM reads, IRQ shadow |
| top-level glue | `MacLC.sv` + `rtl/addrController_top.v` diffs in commit `1a73db4` | DDRAM wiring, slot carve-out, pseudo-VIA IRQ bit |
| HPS daemon | `hps/maclc_eth/` (`maclc_eth.c`, `dp8390.c`, `enet_iface.c`, `maclc_eth.h`, Makefile) | DP8390 model, declROM stage + MAC patch + Apple-CRC refix, bridge: eth0 (AF_PACKET) / tap0 / macvlan / eth1 |
| declROM (LC card) | `releases/maccon.rom` (16 KB) | NOT the ROM for this port — see below |
| unit TB | `verilator/tb_pds_enet.v` + `verilator/sim_ddr3.v` | 22 checks: mailbox, RPC, stretch, IRQ, watchdog |
| architecture doc | `docs/pds_ethernet_scope.md` | READ FIRST — mailbox contract, register quirks, design bets |

Architecture in one line: the FPGA side is a dumb slave that maps slot space
onto a DDR3 window (ARM phys `0x1FF00000`: 64 KB packet buffer + 16 KB declROM
+ control page) and turns register accesses into doorbell RPCs; the daemon
mmaps the same window via `/dev/mem`, runs the DP8390 model + network bridge,
and pre-stages ROM + register shadows so guest READS never wait on the ARM.

**Measured cost on the MacLC (Cyclone V 5CSEBA6):** ~441 ALMs, 732 registers,
**0 M10K, 0 DSP** (buffer + ROM live in DDR3, staging is MLAB/regs). STA closed
first try. Budget the same here, plus a DDR3 arbiter if this core already uses
its DDRAM port (MacLC's was free — check this early; Minimig's
`rtl/A2065/a2065_ddram_arbiter.v` is the pattern to copy if not).

## Port deltas (the actual work)

1. **Card identity.** Target the Asante **MC3NB** — MAME emulates it in
   `src/devices/bus/nubus/nubus_asntmc3b.cpp` (MAME ≥ 0.287 recommended; the
   same file also has Apple Ethernet NB `appleenet` as an alternative if the
   Apple driver stack is preferred). From that file + its ROM def, extract and
   verify — do NOT assume the LC card's quirks carry over:
   - declROM size, load offset, byteLanes pattern, and where in slot space it
     surfaces (NuBus cards: top of standard slot space `$FsFF_FFFF` downward);
   - DP8390 register window address + whether the index is inverted like the
     MacCON's `~addr[5:2]`;
   - data-port location and width; where the MAC address lives (LC card: ROM
     offset 0, sRsrc $80 — verify for MC3NB, then keep the daemon's
     patch-MAC-then-refix-CRC flow; CRC algorithm already in `maclc_eth.c`).
   Fetch the ROM dump (mdk.cab hosts MAME romsets; verify CRC/SHA1 against the
   MAME source's ROM_LOAD line) into this repo's `releases/`.
2. **Slot decode.** Replace the LC pseudo-slot-$E carve-out with a real NuBus
   slot (pick one this core doesn't populate; $9–$E standard space
   `$Fs00_0000`, 24-bit alias `$s0_0000`). CRITICAL DIFFERENCE from MacLC: on
   NuBus machines the Slot Manager expects **bus error on empty slots**, and
   this core already implements that — the card must claim/ack its slot's
   space so it stops BERRing, and everything it does NOT decode inside the
   slot should keep the core's existing empty-space behaviour. (The MacLC's
   `$FFFF`-ack phantom-slot lore does not apply to NuBus cores.)
3. **Access timing.** MacLC served slow first-touch reads by stretching the
   E-clock VPA ack with a watchdog (BERR past ~200 µs is fine — the LC ROM
   probes behind a BERR handler). On this core, slot space is normal
   DTACK-paced access: hold DTACK until the mailbox answers, keep a watchdog
   → BERR fallback so a dead daemon can't wedge the machine (the Slot Manager
   handles BERR from a sick card gracefully).
4. **Interrupt.** Card asserts /NMRQ for its slot → this core's existing NuBus
   slot-IRQ path (VIA2 slot-interrupt register on II-class machines), NOT the
   MacLC pseudo-VIA bit. Keep the level-held-until-ISR-cleared semantics from
   `pds_enet.sv` (ISR shadow AND'ed with IMR shadow drives the line).
5. **Daemon.** Reuse `hps/maclc_eth/` nearly as-is. Required edits:
   - CORENAME gate is an **exact match** on `MACLC` (commit `0de9974`
     explains why prefix matching is dangerous — MacLCII). Add this core's
     name (check `/tmp/CORENAME` on the box for the real string, e.g.
     `MacIIvi`), ideally as a `-c NAME` flag + per-core ROM path map so ONE
     binary can serve all Mac cores; keep MacLC in the list.
   - MAC generation is hostname-hash based — add a per-core byte so an LC and
     a IIvi on the same box never collide.
   - declROM staging: adjust size/byte-lane expansion to what step 1 found.
   Deployment: binary at `/media/fat/linux/maclc_eth`, ROM under
   `/media/fat/games/<CORE>/`, transient start via ssh, persistence =
   one line in `/media/fat/linux/user-startup.sh` (user's call — never edit it
   unasked). Box busybox has no `pgrep`; use `ps | grep`.
6. **Both tops.** If this core has a separate Verilator top like MacLC's
   `sim.v`, wire the card + `sim_ddr3.v` mailbox model there too, and port
   `tb_pds_enet.v` (update addresses/acks for NuBus).

## Gates (all must pass before deploy)

- Unit TB green (mailbox RPC, stretch/watchdog, IRQ, staged-read paths).
- Full-boot sim gate of THIS core, card absent AND card present. Card-present
  evidence: the trace shows heavy Slot Manager traffic in the card's
  `$FsFFxxxx` declROM window and boot still reaches the normal desktop.
  (MacLC's run showed ~230k declROM accesses — same order expected.)
- Quartus fit: A&E clean, STA met, and this repo's own per-seed video lore.
- Deploy files-only; NEVER reload a core over a running guest. HW validation
  (user): Asante EtherTalk installer in the guest (macintoshgarden
  "asanté-installer-512" covers the whole Asante line incl. MC3NB), Network
  cpanel → EtherTalk, reboot guest once after the daemon is up (card presence
  latches at reset).

## Known bets carried from the MacLC implementation (watch on HW)

- Guest driver is assumed to move packet data via the mapped buffer window;
  data-port remote-DMA reads work but ride the RPC path (slow-but-safe). If
  the MC3NB driver turns out to bulk-copy through the data port, add an
  FPGA-side auto-increment walker.
- ISR shadow freshness is daemon-poll-bound (~1 ms) — fine for EtherTalk,
  revisit if a driver spin-polls ISR with interrupts off.
- 8390 loopback self-test is modeled as FIFO-fill (enough for the LC driver's
  probe; the Asante NuBus driver may probe differently — MAME comparison is
  the oracle if it fails).
