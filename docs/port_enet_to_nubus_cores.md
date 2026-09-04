# RESUME PROMPT — port the ethernet card to NuBus Mac cores (MacIIvi, Macintosh II)

Paste this whole file as the opening prompt of a session **in the target core's
repo** (e.g. `..\MacIIvi_MiSTer`). It carries everything that session needs from
the MacLC work; the reference implementation lives in
`C:\Temp\mistercore\MacLC_MiSTer` on branch `apple-pds-ethernet`, and the host
half in the user's Main_MiSTer fork (`C:\Temp\mistercore\Main_MiSTer`, branch
`mac-ethernet`, `support/mac/mac_eth*` + `mac_sonic*`).

(Rewritten 2026-08-21: v1 targeted the Asante MC3NB with a standalone daemon.
The MacLC feature has since become **Apple's own card** — Ethernet LC Twisted
Pair, SONIC — with the host half **inside Main_MiSTer**, and that changes this
port for the better.)

## Mission

Port the Mac Ethernet feature to this NuBus-based Mac core as the **Apple
Ethernet NB Twisted Pair card** (820-0511-A) — MAME
`src/devices/bus/nubus/enetnbtp.cpp`. Same SONIC family as the MacLC card,
which means the entire chip model, mailbox architecture, network bridge, and
Apple guest-driver stack are already built and validated; and this card is the
EASY member of the family:

**★ The NB TP card has 128 KiB of ON-CARD RAM and its SONIC masters only into
that local RAM** (MAME: "SONIC's bus mastering capability appears to be
unused outside of the on-card RAM"). So the hard part of the LC port — the
guest-RAM DMA-RPC engine into the SDRAM controller — is NOT needed here. The
card RAM is simply a DDR3-backed window (the v1 Asante "boardram" pattern,
still in git history at tag-time `1a73db4`), CPU accesses stretch for a DDR3
round trip, and the SONIC model's guest-memory accessor gets a trivial
"local buffer" backend instead of the DMA-RPC one.

## What already exists

| piece | where | reuse |
|---|---|---|
| SONIC model (DP83932/34) | Main fork `support/mac/mac_sonic.{h,cpp}` | as-is — the `sonic_host_ops` accessor struct was designed for exactly this split: give it a backend that reads/writes the card-RAM window instead of posting DMA-RPCs |
| host service pattern | Main fork `support/mac/mac_eth.cpp` | lifecycle, ring drain, shadow/INT publishing, MAC/PROM cooking all carry over; add this core's name to the (EXACT-match) gate and a per-core window/geometry |
| net bridge | Main fork `support/mac/mac_eth_iface.cpp` | as-is |
| model unit test | Main fork `support/mac/test/mac_sonic_test.cpp` (36 checks) | extend with a local-buffer backend case |
| FPGA mailbox core | MacLC `rtl/pds/pds_enet.sv` | doorbell ring / wptr-rptr / presence latch / poll walk / DDR3 FSM are card-agnostic; replace the LC decode layer with NuBus decode + this card's map; DROP the DMA engine + sdram.v eth port (not needed); ADD back a boardram window (v1 pattern) |
| unit TB | MacLC `verilator/tb_pds_enet.v` + `sim_ddr3.v` | 43 checks; port the addresses, drop the DMA cases, revive v1's boardram cases from git history |
| declROM tooling | MacLC `scripts/gen_enet_declrom.py` | re-point at the NB TP ROM (verify byteLanes — the LC TP ROM was $0F/flat; if this one differs, the window math changes) |
| architecture contract | MacLC `docs/pds_ethernet_scope.md` | READ FIRST |

## Port deltas (the actual work)

1. **Card facts from MAME `enetnbtp.cpp`** (do not assume the LC card's map):
   ROM_LOAD name/size/hashes (fetch + verify the dump), the card's slot map —
   RAM at card offsets `0x0-0x1FFFF` (with a mirror near `0xC20000`), SONIC
   regs at `+0xC0000`, RAM also visible in super-slot space — plus MAC PROM
   location/shape (the LC card's separate 8-byte PROM window with the $0028
   word-read magic may or may not carry over; MAME is the oracle).
2. **Slot decode.** Real NuBus slot (pick one this core doesn't populate;
   standard space `$Fs00_0000`, super slot `$s000_0000`). CRITICAL DIFFERENCE:
   NuBus Slot Managers expect **bus error on empty slots** — the card must
   claim its slot fully and everything else keeps the core's BERR behaviour
   (the MacLC's `$FFFF`-ack phantom-slot lore does NOT apply).
3. **Access timing.** DTACK-paced slot access: hold DTACK for the DDR3 round
   trip, watchdog → BERR fallback so a dead host can't wedge the machine.
4. **Interrupt.** /NMRQ → this core's VIA2 slot-interrupt register (not the
   LC pseudo-VIA bit). Same level semantics (INT word from the host).
5. **Window layout.** Give this card its own GEOMETRY version and a fresh
   MAGIC value (the MacLC v2 lesson: version-gate the pairing so a stale
   host/FPGA can never half-pair). If both cores may live on one box, the
   0x1FF00000 window is safe to share — only one core is ever loaded — but
   the MAGIC value must differ per layout, not per core.
6. **Main service.** In `mac_eth.cpp`: the core gate is an EXACT name match
   (prefix matching would collide MacLC/MacLCII — same trap here); add the
   new core name + a per-card personality (window layout, boardram backend,
   this card's PROM shape). Derived MACs already hash the hostname; add a
   per-core byte so two Macs on one box never collide.
7. **Both tops** if the target core has a Verilator top; port the TB.

## Gates

- Model unit test green (with the local-buffer backend case added).
- Unit TB green; full-boot sim of THIS core, card absent AND present
  (card-present evidence: heavy Slot Manager traffic in `$FsFFxxxx` and a
  normal desktop; the MacLC's 32K flat ROM logged ~460k window hits).
- Quartus fit: A&E clean, STA met, this repo's own per-seed video lore.
- HW: Apple's Network Software in the guest (same driver family as the LC
  card — one of the reasons the Apple card beats the Asante here), Network
  cpanel → EtherTalk, reboot once after the service is up (presence latches
  at guest reset).

## Bets carried from the MacLC implementation (watch on HW)

- Register-read shadows are host-poll-fresh (~0.7 ms round; hot-window
  bursts poll at ~32 µs). Fine for interrupt-driven drivers; revisit if a
  driver spin-polls CR/ISR with interrupts off (the MacLC scope doc's
  "CR command-bit visibility" watch item).
- Loopback self-test is a model-side TX→RX short-circuit (mac_sonic) — built
  because Mac drivers self-test at open; verified in the unit test, not yet
  against this card's driver.
