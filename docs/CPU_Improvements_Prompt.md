# RESUME PROMPT — CPU performance: the 68020 bus cycle and the rest of the ladder

Paste this whole file as the opening prompt of a session in this repo
(`C:\Temp\mistercore\MacLC_MiSTer`). It carries the 2026-08-17 measurement, the
root-cause derivation, and every candidate fix with its file anchors, cost, and
gate. **Read `docs/Speedometer_3-23_Benchmarks.md` first** — it is the scoreboard
this mission is judged against.

## Mission

Close the ~1.33x gap between the MacLC core and a physical Mac LC. The evidence
says one structural cause dominates: **the core runs a 68000-style 4-clock bus
cycle where the real machine's 68020 runs a 3-clock cycle.** Everything else on
the ladder is second-order, and two popular theories (memory bandwidth, video)
are ruled out below.

## The measurement (2026-08-17, Speedometer 3.23, 640x480, 10 MB)

| Suite | Core | Physical Mac LC | Core / real LC |
|---|---:|---:|---:|
| Benchmark Mix (Classic=1.0) | 2.771 | 3.702 | 74.8% |
| Color Benchmarks (Mac II=1.0) | 0.937 | 1.249 | 75.0% |

Both suites land within 0.003 of the same ratio. The color suite is QuickDraw
blit loops — CPU code — so this is **one cause, not a CPU problem plus a video
problem**. Full per-test table in `docs/Speedometer_3-23_Benchmarks.md`.

Worst tests (core ÷ real LC time): **Sieve 2.25x**, Queens 1.51x, Bubble Sort
1.49x — the three whose inner loops fit in a real 68020's 256-byte on-chip
I-cache. At parity: Dhrystones 1.02x, Towers 1.02x. QuickDraw is a flat
1.30–1.35x across all four depths (8-bit is the *best* of the four, which is
evidence against a per-pixel or per-byte video cost).

## Root cause, derived from the RTL

| fact | anchor |
|---|---|
| `clk_sys` = 32.5 MHz | `rtl/pll.v:80` (output 1; output 0 = 65 MHz clk_mem) |
| CPU `phi1`/`phi2` = `clk16_en_p`/`clk16_en_n`, alternating every clk_sys | `MacLC.sv:1120-1121`, instance at `MacLC.sv:1221-1225` |
| ⇒ `s_state` advances once per clk_sys | `rtl/tg68k/tg68k.v:82` (phi1), `:107` (phi2) |
| The wrapper is the classic 68000 8-state sequence | `rtl/tg68k/tg68k.v:2` — *"68000 compatible bus-wrapper"* |
| AS asserts at s1 | `tg68k.v:87-94` |
| DTACK sampled at s4 (holds there until `!dtack_n`) | `tg68k.v:107` |
| Data latched + AS/DS released at s6-phi2 | `tg68k.v:114-119` |
| Kernel clocked at s7-phi1 | `tg68k.v:43` |

**No-wait cycle = 8–9 clk_sys** (s4 only clears on a phi2 edge) = **246–277 ns**.
AS-low = s1..s6 = 5 clk_sys — the "5-clk floor" from the 2026-07-07 session.

A physical Mac LC's 68020 does a **3-clock** bus cycle at 15.6672 MHz =
**191 ns**. Ratio **1.29–1.45x**, which brackets the measured **1.336x**.

★ **We are not clock-starved.** The core's CPU rate is 16.25 MHz — about 3.7%
*faster* than the real 15.67 MHz (`MacLC.sv:167`; same +3.7% that makes E
812.5 kHz). It is still 1.33x slower because each access costs 4 clock periods
instead of 3. **The gap is bus-cycle structure, in RTL we own.**

Corroboration from hardware: the 2026-07-07 probe session measured AS-low at
**avg 6.15 clk_sys** with instruction fetches at 43% of wall time — the 5-clk
floor plus ~1.15 clk of DTACK wait. Model and measurement agree.

**Second cost, stacked on top:** DTACK for RAM/ROM/VRAM is granted only at a CPU
slot's `memoryLatch` (`MacLC.sv:958`), and 1 of every 4 bus slots is reserved for
floppy (`rtl/addrController_top.v:126-127`) — idle whenever no floppy read is
pending. When the s4 wait lands on that slot the cycle stretches 8 → 12 clk_sys.

## Step 0 — measure before touching anything (offline, no fit)

Instrument `s_state` in Verilator and histogram **clk_sys per bus cycle**, split
by `tg68_busstate` (00 fetch / 10 read / 11 write) and by target
(RAM / ROM / VRAM / VPA-peripheral). This converts the 8–9 / 12 bracket above
into a number and gives a before/after metric for every item below that costs
nothing to re-run. Boot to the desktop, then a QuickDraw-heavy stretch.

WSL Verilator runs are sanctioned (2026-08-08). Build per `CLAUDE.md`
(`cd verilator && make`), and remember the top is `verilator/sim.v`, not
`MacLC.sv`.

## The ladder

### 1. Shorten the bus FSM to a 68020-shaped cycle — the main event

**Where:** `rtl/tg68k/tg68k.v:70-125` (the `s_state` machine), plus the DTACK glue
`MacLC.sv:937-958` and `MacLC.sv:1094`. **`verilator/sim.v` has its own copy of
the glue — both tops change together or sim and FPGA silently diverge**
(`docs/verilator_differences.md`).

**Target:** 6 clk_sys = 185 ns, which is *faster* than a real LC's 191 ns. The
win applies to every memory access in the machine.

**Contract that must survive** (this is what makes it a wrapper change and not a
kernel change — do NOT touch `TG68KdotC_Kernel`):
- data must be stable into `tg68_din_r` at the latch edge (`tg68k.v:115`);
- `tg68_clkena` pulses once per cycle at s7-phi1 (`tg68k.v:43`);
- `berr_hold` must still span the cycle and clear at s0 (`tg68k.v:216-225`);
- the VPA/E path is paced by `xVma`, not DTACK (`tg68k.v:107`, `:135`) — E-paced
  peripheral accesses (~1.23 us) are unaffected and must stay that way;
- bus arbitration freezes `s_state` (`tg68k.v:83`, `:109`).

**Approach:** the states between AS-fall and the DTACK sample are dead time for
any target that can answer early (SDRAM RAM/ROM, VRAM BRAM). Collapse those, or
let s4 advance the moment DTACK is known rather than at the next phi2. Keep the
full-length path available for anything that needs the current AS width.

**★ Risk — AS width is load-bearing elsewhere.** The 800K GCR fix (`2804d02`)
turned on the IWM read-data latch clearing at the *end* of an access; the SWIM /
IWM / floppy paths are calibrated against the current AS timing. Any change to
AS width re-runs the floppy TBs, no exceptions.

**Gates:** `tb_gcr_read` (`+acclen=40 +pollgap=40`), `tb_mfm_idcensus`,
`tb_ism_sony`, `tb_disk_swap`, `tb_scsi_pf`, `tb_scc_midi`, `check_boot.sh --run`,
then `quartus_map` A&E, then the per-seed HW video+boot gate.

### 2. Reclaim the 4th bus slot

**Where:** `rtl/addrController_top.v:126-127` (`cpuBusControl` / `extraBusControl`),
`:232-234` (`dskReadAckInt/Ext`), `MacLC.sv:958` (dtack glue).

Give the CPU the extra slot when no floppy fetch is pending; removes the
8 → 12 clk_sys stretch.

**★ Trap documented in the file itself (`addrController_top.v:120-125`):** the
three CPU slots are *contiguous*, so a rising-edge detector sees one edge per
rotation and HALVES throughput. Assert per-slot, not per-edge.

**Also worth checking while in there:** on the MacIIvi the equivalent
`dskReadAck*` asserts on `extraBusControl` alone regardless of floppy activity,
issuing a real SDRAM read every rotation that clobbers `dout`. Confirm whether
the LC's extra slot does the same — if so it is a free spurious read to remove.

### 3. I-cache revival — now clearly second-order

Everything already exists on branch **`i-cache`, commit `b393eaf`**:
`rtl/fetch_cache.sv` (1 KB direct-mapped word cache, write snoop + generation
flush, OSD-gated but always filling so one build gives a live A/B), plus
`docs/resume_icache_corruption_2026-07-07.md` on that branch. Shadow-measured on
the live fetch stream at **87.7% (256 B) / 96.0% (1 KB)**. Cost ~2–3 M10K.

**Parked on:** disk corruption with the cache ON, plus a mono regression.
Suspects, in the parked doc's order: (1) the combinational DTACK join being
STA-met-but-HW-marginal, (2) an unfound coherency case.

**What has changed since the park:**
- The doc's OPEN DECISION — un-ban Verilator sim runs to diff cache-on vs
  cache-off boots — was resolved in favour of running them (2026-08-08). The
  deterministic catch (first divergent instruction in `cpu_trace.log`) is
  available offline now.
- The MacIIvi's 2026-08-16 fix is a **fill-capture qualification** discipline:
  capture the fill word only at an edge where the address compare is valid AND
  `din` is live, with a sticky served flag. The LC has the same AS-gated decode
  and the same `cpu_data` passthrough latch (`rtl/dataController_top.sv:329`,
  `:359`), so the same hazard class exists here. Audit `fetch_cache`'s fill point
  against it.

**★ Re-measure after item 1 before spending effort here.** A hit still answers
through the same DTACK path, which is why the parked build only reached mode-5
instead of its 3-clk design target. Shortening the cycle changes what the cache
is worth.

### 4. CPU VRAM reads still come from SDRAM

`vram_bram`'s port-A read output is unused — *"reserved for a later phase (CPU
VRAM reads still come from SDRAM today)"* (`rtl/vram_bram.sv:33-36`) — and
`rtl/addrController_top.v:200-222` routes `selectVRAM` reads to the SDRAM shadow
copy at word `0x580000`. QuickDraw read-modify-write ops therefore pay an SDRAM
round trip on the read half while the write half is single-cycle BRAM.

Zero M10K (the port already exists). The one genuinely video-side item left.

### 5. Disk read ring 16 KB → 32 KB — measure first

**The blocker comment is stale.** `rtl/scsi.v:134` says RING_LOG=6 needs 600 M10K
> 553 avail, counting *"3 mirror RAMs x 2 buffers x 2 disks"* — but `ram_c`/`ram_d`
were deleted in the 2026-07-17 pdma-prefetch redesign (`rtl/scsi.v:3051`), which
freed ~48 blocks. The same comment predicts the outcome: *"drop the look-ahead
mirror RAMs -> ~1/3 the M10K -> room for 48KB+."*

Current shape: `RING_LOG = 5` (`scsi.v:129`) = 32 sectors / 16 KB per disk;
`DEVS = 2` disk targets (`ncr5380.sv:165`); CD target runs `CD_RING_LOG = 3`
(`ncr5380.sv:170`).

| | blocks |
|---|---:|
| one ring buffer, 2^13 x 8b | 8 M10K |
| x 2 buffers x 2 disk targets — today | 32 |
| same at RING_LOG=6 | 64 |
| **delta** | **+32** → 503 → ~535 of 553 |

It fits, with ~18 spare — but it spends nearly all remaining headroom, and a
deeper ring buys **burst absorption, not bandwidth**.

**Measure first:** `dbg_ring` (`rtl/scsi.v:480`, out as `dbg_ring0/1`) already
carries `rd_ahead_unfilled` / `rd_cur_unfilled` / both block pointers per target.
Watch it through a cold extension load or a large copy. Pinned-unfilled ⇒ depth
helps. Mostly-full ⇒ the cost is the per-block HPS round trip or the pseudo-DMA
handshake rate, and 32 KB buys nothing.

## Ruled out — do not spend time here

- **More framebuffer BRAM.** `vram_bram` is 384 KB (`DEPTH = 196608` x 2 byte
  lanes, `rtl/vram_bram.sv:27-49`), already the largest supported mode
  (16bpp @ 512x384); 640x480 @ 8bpp is only 300 KB. Video reads are single-cycle
  on port B with zero contention. Adding BRAM moves no benchmark number.
- **DDR3 video channel** (`docs/plan_ddr3_video_channel.md`). Superseded by the
  on-chip framebuffer, and DDR3 does not work properly on this core anyway.
- **Porting the MacIIvi 68030 cache subsystem.** `TG68K_Cache_030.vhd` +
  `TG68K_CacheCtrl_030.vhd` are bolted to the 030 kernel and its cache-control
  registers; this core runs the 68020-class kernel (1.6 MB generated vs 4.9 MB).
  Bringing it means bringing the 030 kernel — a different mission, emulating a
  cache the real LC does not have.
- **"Video is slow."** The two suites give the same ratio to three decimals; the
  framebuffer is already on-chip. Item 4 is the only real video-side cost left.

## Budget and standing laws

Latest fit (`output_files/MacLC.fit.summary`, 2026-08-15): **ALMs 29,563/41,910
(71%)**, **RAM blocks 503/553 (91%)**, registers 25,295. Of those RAM blocks,
~384 are the framebuffer (2 x 196,608 x 8b at 1024 words/M10K — derived from
`DEPTH`, not read off the fit report; confirm in the RAM summary before relying
on it). Items 1, 2 and 4 cost ~0 M10K; item 3 ~2–3; item 5 +32.

- `sys/` is **OFF-LIMITS** — reconcile from our side only.
- Both tops in sync: `MacLC.sv` and `verilator/sim.v`
  (`docs/verilator_differences.md`).
- Per-seed HW video + boot gate is **law** — STA-met is not enough; seed history
  lives in `MacLC.qsf`.
- `USE_DBG_HUD` OFF in release fits.
- The CD boot-attach (`MACLC.s4`) stays ATTACHED during gates; on a load hang,
  retry the boot rather than blaming the build. One boot is never a verdict.
- Scratch goes in `scratch/` (gitignored), never the repo root.

## Recording results

Every build that moves a number gets a new row in
`docs/Speedometer_3-23_Benchmarks.md` — label it with the change and the build
hash, keep the physical-hardware rows untouched as the reference.
