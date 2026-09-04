# LC PDS Ethernet v2 — Apple Ethernet LC Twisted Pair, 820-0532 (2026-08-20)

> **STATUS 2026-08-23 — COMPLETE, shipped and HW-validated.**
> `releases/MacLC_20260822.rbf` + `releases/MiSTer` (the REQUIRED host —
> two of the three card-ON-hang fixes are host-side, so an old Main hangs
> even with a current core). Everything below is the as-built contract,
> except the phase plan at the end which is kept as the build record.
> `hps/maclc_eth/` is long gone (7a607a2): where the text below says it
> *will be* removed, it already was. Landed since: OSD-selected interface
> and MAC suffix (core 187f9fe + Main 9f53b8b) — see CLAUDE.md.

Goal: replace the v1 **Asante MacCON i LC** card (2026-08-15, commits 2b76225 /
1a73db4 / 51e5012) with **Apple's own Ethernet LC Twisted Pair card**
(board 820-0532-B, DP83934 SONIC-T), and move the host half out of the
standalone `hps/maclc_eth` daemon into the user's **Main_MiSTer fork**
(`danifunker/Main_MiSTer`, branch `mac-ethernet`, placed per the merged
PR #1255 pattern). User rulings 2026-08-20:

- Twisted-Pair variant **only** (the AAUI card 820-0443 is out of scope).
- declROM served from **DDR3, zero M10K** (M10K bake rejected; the ROM bytes
  are compiled into the modified Main instead — no SD-card ROM file).
- `hps/maclc_eth/` was **removed entirely** when the Main port landed; the
  feature requires the modified Main.
- Guest driver = Apple's Network Software (user handles guest-side install;
  the ROM carries no driver — verified below).

The v1 implementation is the plumbing donor: its mailbox, doorbell ring,
presence latch, `pds_claim` aliasing guard, DTACK glue and TB harness carry
over; everything DP8390/Asante-specific is replaced. v1 was sim-proven
(TB 22/22, boot gate green with the Slot Manager scanning the declROM) but
never HW-validated — v2 supersedes it before that ever happened.

## Card ground truth

Sources: MAME mame0288 `src/devices/bus/nubus/enetlc.cpp` (card, in MAME
since 0.278), `src/devices/machine/dp83932c.cpp` (chip), NetBSD
`if_sn_nubus.c` + `sn(4)` (real-hardware driver), and our verified dump of
the declROM (`releases/341-0740_AppleLCTwistedPair.BIN`, 32768 bytes,
CRC32 9d47245c, SHA1 447ce683…, Apple FHeader CRC 185CEAA3 recomputes clean).

- **Chip**: DP83934 SONIC-T (SONIC + integrated 10Base-T PHY); register-
  compatible with the DP83932C MAME models. 64 × 16-bit registers.
- **No card RAM.** The SONIC **bus-masters into guest RAM**: CAM load
  descriptors, RRA (receive resources), RDA (receive descriptors), TDA
  (transmit descriptors) and every packet buffer live at guest physical
  addresses; the chip fetches and stores them itself. On LC-class machines
  the driver runs it in **16-bit mode, block-mode DMA**
  (NetBSD: `DCR = BMS|PO1|RFT1|TFT0`, `sc_32bit = 0` → descriptor stride 2).
- **declROM**: 32 KiB, `byteLanes $0F` (all four lanes) → **flat** window,
  top of slot $E standard space: `$FEFF'8000-$FEFF'FFFF`. Content is ~331
  real bytes (board sRsrc + `Network_EtherNet_none_AppleLCTwistedPair`
  functional sRsrc; **no driver**), 99.3 % zeros.
- **MAC address is NOT in the declROM** (unlike the MacCON's offset-0 word):
  a separate 8-byte PROM window. Bytes 0-5 = MAC **bit-swizzled**
  (`bitswap<8>(b, 0,1,2,3, 7,6,5,4)` per MAME — LSB-first transmission
  order), byte 6 = `$00`, byte 7 = XOR of bytes 0-5, complemented. Any
  **word-wide** read of the window returns the magic **`$0028`** (driver
  presence probe). No checksum interplay with the declROM ⇒ no CRC re-fix.
- **IRQ**: SONIC INT (level, `ISR & IMR ≠ 0`) → slot $E → pseudo-VIA slot
  IFR `$02` bit `$20` active-low → IPL 2. Identical wire to v1
  (`pds_slot_irq`), nothing changes.

### Address decode (32-bit forms; V8 mask `0x80ffffff`)

| Region | Address | Shape |
|---|---|---|
| SONIC registers | `$FE00'0000-$FE00'01FF` | reg index = **A[7:2]** (no inversion), 16-bit value as the **word at longword+0** (MAME `umask32 ffff0000`); `+2` half unmapped (serve `$FFFF`); `$100`-byte bank mirrors once in the `$200` window |
| MAC PROM | `$FE04'0000-$FE04'01FF` **and** `$FE40'0000-$FE40'01FF` | byte reads: PROM byte = `addr[2:0]` (mirrors through the window); word reads: `$0028` |
| declROM | `$FEFF'8000-$FEFF'FFFF` | flat 32 KiB, byte/word readable |

Everything else in `$F1-$FE` keeps the hardware-validated open-bus `$FFFF`
ack. The 24-bit slot-$E window (`$00Exx'xxx`): MAME's LC/LC II card map only
decodes the `$8000'0000`-based forms, and the Slot Manager accesses slot
space in 32-bit mode (SwapMMUMode), which the v1 sim confirmed (230 k scans
of the `$FEFF` window). **v2 starts 32-bit-only**; if the MAME runtime trace
(Phase 5) shows the Apple driver touching 24-bit forms, add them then.

`pds_claim` stays load-bearing: `$FE00'xxxx` truncates to guest-RAM
`$00'0000` (page zero!) and `$FE40'xxxx` to `$40'0000` in the 24-bit
addrDecoder, so every claimed region must keep masking `selectRAM`.

## Architecture: what moved, what stayed

Same philosophy as v1 — **dumb, fast FPGA; chip model on the ARM; the guest
never waits on host software** — with one addition (the DMA engine) and two
simplifications (no data port, no paging):

**FPGA answers locally (never stalls beyond DDR3):**
- Register reads ← 64-entry shadow block (ARM-maintained).
- Register writes → doorbell ring entries (DTACK held only until the entry
  lands in DDR3).
- MAC PROM ← control-block PROM word (8 cooked bytes from Main). Local, instant.
- declROM ← DDR3 window read, Main-staged (flat copy — the lane-expansion C
  code dies with byteLanes $0F).
- IRQ ← INT word.
- There is **no data-port RPC and no clear-on-read notify** — SONIC has no
  CPU data port (packets move by chip DMA) and no read-destructive registers
  the driver polls. The only guest-visible waits left are DDR3-bounded.
  A dead Main can still never wedge the guest.

**ARM (Main) owns the chip**: a C SONIC model ported from MAME
`dp83932c.cpp` flows — register write masks, CR command semantics (incl. the
TXP-while-TXP-ignored quirk), CAM load via `URRA:CDP`, RRA read/refill rules
(`RRP/RWP/RSA/REA` wrap, `RBE` on empty, the read-RRA-on-`ISR_RBE`-clear
quirk), RX descriptor flow (CRBA advance, `RBWC` decrement, `LPKT` at
`EOBC`, 5-word status writeback, link-LSB `RDE`, in-use clear), TX gather
(`TSA` fragments, CRC append unless `CRCI`, status writeback to `TTDA`,
`PINT`), tally counters stored inverted, 16-bit descriptor stride. Loopback
modes (RCR b9-b8) get a real TX→RX short-circuit like v1's dp8390 did —
Mac drivers self-test at open and MAME skips this; carry the v1 lesson.

**The new piece — guest-memory DMA-RPC**: the model reaches guest RAM
through a small FPGA engine. ARM posts `{seq, dir, guest_addr[23:0] (even),
byte_count (even), }` in a control word; the engine moves bytes between
guest SDRAM and the 64 KiB DDR3 **bounce buffer** (v1's boardram window,
repurposed); ARM polls the DONE word for the seq echo. One RPC per
descriptor group / packet buffer, sequenced by the model — which also gives
the ordering the driver depends on for free (packet bytes land before the
status word that publishes them).

**★ ORDERING LAW (2026-08-23, learned from a guest hard-freeze).** The two
directions are NOT symmetric:
- *driver→model* is safe for free: guest RAM writes land in ~µs while the
  register doorbell that announces them arrives ~ms later — RAM always
  beats the register.
- *model→driver* RAM sequences are the dangerous direction. Each host op is
  a ~100 µs DMA-RPC, and the Apple driver's ISR consumes a descriptor the
  instant its status word goes nonzero — then RECYCLES it, rewriting its
  link. So **the publish word must be the LAST access of the sequence, and
  nothing may read or write the structure after it.** The RX writeback once
  published status first and read the link last; the driver rewrote the link
  under the pending read, CRDA left the ring, and the guest hard-froze in a
  link=0 self-orbit (root-caused from a frozen-guest RAM dump via
  `tools/guestdump/`; fix + 7-check publish-order gate in Main `b3b0ed1`).
  Audit any new model-side descriptor writeback against this law.

Bandwidth/latency: 10BASE-T needs ≤ 1 word / 1.6 µs sustained; a full-size
frame occupies the wire ~1.2 ms and costs ~4-8 RPCs. With the v1 adaptive
poll (fast cadence while a command is armed or recently completed), pickup
is ~32 µs and SDRAM service µs-scale — total per-frame overhead ≈ 0.2 ms.
The SDRAM side steals only idle slots (the I-cache's hit-silent bus leaves
plenty); with Ethernet disabled the engine is dormant and the netlist path
must be provably inert. Exact arbitration insertion (addrController/sdram.v
slot schedule vs CPU-port idle mux) is decided in Phase 3 after reading the
slot structure — **gated by a Speedometer re-run** (the 97 % CPU-perf result
must hold) plus the standard boot gates.

## DDR3 window v2 (contract; both sides implement from THIS table)

Same reserved area as v1/A2065 — ARM phys `0x1FF00000`, 0x21000 bytes,
DDRAM word `0x03FE0000`, `DDRAM_CLK = clk_sys` single-domain. Layout
version 2; **MAGIC changes to `"McLCETH2"`** (`64'h4D634C43_45544832`) so a
stale daemon/Main and a v2 FPGA (or vice versa) can never half-pair.

```
+0x00000  64 KiB  XFER   bounce buffer for guest-RAM DMA (was: boardram)
+0x10000  64 KiB  ROM    declROM window, flat: win byte i = guest $FEFF0000+i
                         (ROM occupies +0x8000..+0xFFFF; lower half unused)
+0x20000  u64[]   control block, FPGA-polled:
   w0   MAGIC     ARM→FPGA  "McLCETH2"; presence gate (sampled at guest reset)
   w1   CMD_WPTR  FPGA→ARM  32-bit monotonic doorbell write index
   w2..w17 SHAD   ARM→FPGA  64 regs × 16-bit: word n = regs 4n..4n+3,
                            reg (4n+k) at bits [16k+15:16k]
   w18  INT       ARM→FPGA  bit0 = SONIC INT line
   w19  MACPROM   ARM→FPGA  8 cooked PROM bytes (byte k = PROM byte k:
                            swizzled MAC[0..5], $00, XOR-complement checksum)
   w20  GEOMETRY  ARM only  layout version = 2
   w21  RPTR      ARM→FPGA  daemon ring read index (backpressure)
   w22  DMA_CMD   ARM→FPGA  [7:0] seq | [8] dir (0 = guest→XFER read,
                            1 = XFER→guest write) | [39:16] guest_addr[23:0],
                            even | [55:40] byte_count, even, ≤ 0x8000;
                            XFER offset is always 0
   w23  DMA_STAT  FPGA→ARM  [7:0] done seq echo | [8] error (align/range/
                            timeout); ARM polls for seq == its DMA_CMD seq
+0x20800  2 KiB   CMD RING  256 × u64: [0] valid | [3:1] tag (0 = REG_WR,
                            1 = RESET) | [9:4] reg[5:0] | [31:16] data[15:0]
                            | [39:32] seq
```

Kept verbatim from v1: monotonic-wptr reset detection (FPGA republishes
`wptr = 0` after reset), rptr backpressure (stall at 200 ahead, ~2 ms
saturating timeout), sticky presence latch during guest reset AND'd with the
OSD "Ethernet" bit (`status[19]`, 0 = On), RESET doorbell on warm restart,
adaptive poll cadence (idle ~2 ms MAGIC-only / live ~1 k-clk steps / hot
32-clk steps while a DMA command is armed, backpressure holds, or within a
~200 µs post-completion window so descriptor-walk chains stay fast).

## Main_MiSTer side (fork `danifunker/Main_MiSTer`, branch `mac-ethernet`)

Placement per the merged PR #1255 pattern — everything in `support/mac/`,
auto-built by the `support/*/*.cpp` glob, **zero new common-code lines**:
arm/teardown/poll all hang off the existing unconditional `mac_poll()` hook.

- `mac_eth.cpp/.h` — lifecycle (modeled on `minimig_a2065.cpp`: stop on
  core change, lazy-arm, bounded work per pass), `shmem_map(0x1FF00000)`,
  ring drain, `push_state()` (shadows → barrier → INT, v1 ordering), DMA-RPC
  client, declROM staging from the **embedded ROM** (generated header:
  ~331 literal bytes + zero-fill — no SD file), MAC policy: Apple OUI
  `08:00:07` + 3 derived bytes (a2065-style NIC/hostname derivation, never
  all-zero), PROM word cooking (swizzle + checksum).
- `mac_sonic.cpp` — the SONIC model (above). Testable off-target: keep it
  ANSI-C-ish with the guest-memory accessor injected
  (`guest_read(addr,len,buf)` / `guest_write` function pointers → DMA-RPC
  backend here; a boardram backend later serves the NuBus card).
- `mac_eth_iface.cpp` — port of `hps/maclc_eth/enet_iface.c` (tap0 default,
  AF_PACKET+promisc for macvlan/eth). The a2065 four-mode set landed
  2026-08-23 as an OSD option (`o45`); availability probing did not —
  an interface this box cannot open reports itself once and stays down.
- **Core gate: exact match.** Main's `is_core_named()` is a strncasecmp
  *prefix* test — `"maclc"` would fire on MacLCII. Re-apply the daemon's
  0de9974 lesson (exact `strcasecmp` on the core name) inside `mac_eth`.
- `hps/maclc_eth/` was deleted in the mission phase that landed the Main
  port (its logic moved there; git history keeps the rest).

## Sharing with the NuBus port (docs/port_enet_to_nubus_cores.md refresh)

The Apple family makes the planned MacIIvi/MacII port *easier*: the NuBus
sibling is the **Apple Ethernet NB Twisted Pair** (820-0511-A, MAME
`enetnbtp.cpp`) — same SONIC core but **128 KiB on-card RAM**, DMA confined
to it (MAME: "essentially the same as the DP8390x cards"). Shared across
cores: `mac_sonic.cpp` (via the guest-memory accessor: RPC backend on LC,
plain XFER/boardram backend on NB — no SDRAM engine needed there), the
mailbox RTL core, the iface layer, MAC/PROM policy. Per-card: slot
front-end (NuBus wants BERR on empty slots, not the LC's `$FFFF` lore),
declROM, PROM window shape. The RTL refactor keeps
`rtl/pds/pds_enet.sv`'s mailbox/handshake generic under the card layer with
that split in mind.

## HW bring-up 2026-08-22 — boot hang RESOLVED

The card-ON "guest hangs at boot, one extension icon" bug was **NOT** the
declROM/DTACK enumeration theory: the guest driver enumerated and ran its full
open sequence every time (the mailbox doorbell ring proved it). Three defects,
all the **same class — the guest-RAM DMA engine only moves 16-bit WORDS at EVEN
addresses, but the SONIC legitimately uses ODD addresses, and the backend
REJECTED odd** (`if (ga & 1) return -1`):

1. `mac_sonic.cpp` — after a completed TX, `CTDA` holds an odd end-of-list link
   (LSB = EOL flag, not an address bit). The next TXP dereferenced the odd
   descriptor → backend rejected → `transmit_chain` aborted with `CR.TXP` still
   set → the driver spin-polled TXP forever. Fix: `DA()` word-aligns descriptor
   addresses (mirrors MAME `read_word`); `TX_ABORT()` guarantees TXP always
   clears on any host-op failure.
2. `mac_eth.cpp` — a 101-byte loopback frame leaves the RX buffer pointer ODD
   (`0xA530+101 = 0xA595`); the odd byte-write failed → `PKTRX` never raised →
   the driver hung in its open-time loopback self-test. Fix: `rpc_read`/
   `rpc_write` word-align + read-modify-write (the byte/word impedance match
   belongs in the backend). Both fixes are host-side; **no RTL change**, and the
   Mac now boots to the Finder desktop with Ethernet On (HW-confirmed).
   The offline gate had missed this because `mac_sonic_test`'s fake RAM tolerated
   odd addresses — now hardened (rejects odd word addrs) + an odd-EOL regression.

3. **Interrupt-ack livelock (Risk #2 below, realised): FIXED in RTL.** Measured
   ~120x doorbells per real interrupt on HW — the guest re-enters its handler
   ~120x because the INT line it sees lags its own ISR clear by ~1.6 ms. Fix =
   the **local ISR-clear overlay** in `pds_enet.sv`: `isr_eff = shadow_isr &
   ~isr_pend_clr` drives `irq` and the guest's ISR reads; a guest ISR write ORs
   its clear into `isr_pend_clr` immediately; the poll reconciles by ANDing the
   mask with the fresh shadow ISR (drops confirmed bits, no deadlock). `irq` no
   longer comes from Main's stale INT word. `tb_pds_enet` 53/53.

## Risks / watch items

1. **CR command-bit visibility**: CR reads come from the ~ms-fresh shadow;
   a driver that spin-polls CR.TXP (instead of the TXDN interrupt) would see
   TX at ~1 kHz. MAME's TXP guard suggests drivers append TDAs live instead.
   If the Phase-5 MAME trace shows CR polling, add a local pending-command
   overlay (set on doorbell write, cleared on post-consumption shadow
   refresh) — designed but not built until proven needed.
2. **ISR/shadow freshness** under interrupt load: same ~1 ms class v1
   accepted; the hot-cadence window bounds it during bursts. Watch on HW.
3. **SDRAM arbitration** is the only path that can touch CPU performance:
   idle-slot-only stealing, Speedometer gate, and an "Ethernet Off ⇒
   provably inert" requirement (netlist-level: engine held in reset).
4. **DMA/CPU interleave semantics**: the driver polls descriptor words the
   engine writes. RPC-granular sequencing by the model gives write ordering;
   SDRAM is the single point of coherency (no caches on the data side —
   the I-cache is fetch-only). Descriptor writes are word-atomic in SDRAM.
5. **Register +2 half-word fill** (`$FFFF` assumed) and any 24-bit-window
   usage: both settled by the Phase-5 MAME register trace before HW.
6. **MAME as oracle needs a build**: WSL system MAME is 0.264 (predates the
   card); `~/repos/mame` is at 0.288 but unbuilt. Building it (one-time,
   hours) is a Phase-5 prerequisite. Romset `enetlctp.zip` = our verified
   341-0740 dump.
7. **Fit**: v1 measured 441 ALMs / 732 regs / 0 M10K / 0 DSP; v2 adds the
   DMA engine + wider shadows, still 0 M10K. Per-seed video gate law and
   one-canonical-RBF deploy discipline apply to every fit.

## Phases (commit per phase; both tops in lockstep + verilator_differences.md)

1. **This doc + ROM import** (done: `releases/341-0740_AppleLCTwistedPair.BIN`).
2. **RTL front-end swap** (`rtl/pds/pds_enet.sv`): SONIC decode (regs, MAC
   PROM, flat declROM), shadow/ring v2, MAGIC v2; Asante artifacts deleted
   (`releases/maccon.rom`, `verilator/pds_declrom.hex` → regenerated);
   new generator script emits the sim hex + the Main ROM header from the
   BIN. TB rewritten for SONIC semantics; boot gate green card-absent and
   card-present (Slot Manager scans the new ROM). A&E clean.
3. **DMA-RPC engine**: mailbox command service + SDRAM idle-slot port
   (insertion point chosen after reading sdram.v/addrController); own TB
   against real sdram.v; boot + Speedometer gates.
4. **Main port**: `support/mac/mac_eth*` + `mac_sonic` (host-side unit test
   against pcap fixtures), WSL build, bench deploy; delete `hps/maclc_eth/`.
5. **Ground truth + HW bring-up**: build mame0288, trace the Apple driver
   (register/DMA traffic) under `maclc -lcpds enetlctp`, replay key
   sequences in the TB; then HW: card in Slots → driver opens → EtherTalk
   zones in Chooser → MacTCP/OT ping → transfer soak. Fit gates per law.
