# CPU performance mission — change log (branch `cpu-enhancements`)

Running log of every change made to close the ~1.33x gap to a physical Mac LC
(scoreboard: `docs/Speedometer_3-23_Benchmarks.md`, mission brief:
`docs/CPU_Improvements_Prompt.md`). **Kept deliberately precise because these
changes will be ported to the Pocket core** — each entry names the files, the
exact mechanism, and whether the change is core RTL (ports) or MiSTer-top glue
(re-derive per platform).

## The timing model (derived 2026-08-17, before any change)

Worth recording once, since every fix argues against it. All counts in
`clk_sys` (32.5 MHz) ticks; the CPU sees phi1/phi2 on alternating ticks
(16.25 MHz), and `addrController_top.v` rotates 4-tick bus slots
(`busCycle` 0..3; slots 3,0,1 = CPU, slot 2 = floppy; `busPhase` 0..3 within a
slot; `memoryLatch` = busPhase 3).

**CPU FSM** (`rtl/tg68k/tg68k.v` `s_state`, one step per tick): after the
kernel-clock edge (clkena, s7@phi1) the sequence runs s0, s1@phi1 (AS+RW
assert), s2, s3@phi1 (write strobes), s4@phi2 (DTACK/VPA/BERR sample — holds
here, re-checks every phi2), s5, s6@phi2 (din latch + AS/strobe release),
s7@phi1 (clkena). Zero-wait period = **8 ticks**.

**DTACK** (`MacLC.sv` / `verilator/sim.v` `dtack_en`): RAM/ROM/VRAM get DTACK
only at the busPhase-0 tick of a CPU slot (`cpuBusControl & mem_latch_d`)
while AS is low; peripherals/unmapped get it the tick after AS falls.

**SDRAM** (`rtl/sdram.v`): 8-state machine at clk_64 (65 MHz) hard-locked to
the slot (t wraps at the clk8 edge). Requests sampled ONLY at t==0 (= slot
start, busPhase 0); CAS at t==2; `dout` registered at t==6 → data is stable
during busPhase 3, and `dataController_top.sv` registers it into `cpu_data`
at `memoryLatch` (passthrough on that tick). Idle slots issue AUTO_REFRESH.
`sdram_oe` also fires for `dskReadAckInt/Ext` — the floppy slot reads SDRAM
every rotation whether or not a fetch is pending, and overwrites `dout`
(harmless today only because `cpu_data` snapshots at the granting slot).

**Consequence — the mod-4 floor.** A memory access can only *start* at a
slot-start tick and only *complete* 3 ticks later, so in a locked stream the
clkena-to-clkena period is forced to a multiple of 4 ticks; the loop latency
(clkena → addr → AS → strobe ≥ 3 ticks, data +3, consume +1) makes 4
impossible, so the floor is **8 ticks = 4 CPU clocks per access — exactly the
68000-style cycle we measured**, independent of how short the CPU FSM is.
Misalignment (clkena landing on busPhase 2) gives 10; the floppy slot in the
strobe position gives +4 (12). Internal kernel steps (busstate==01) clock at
phi1 only = 2 ticks each, and shift the alignment parity.
A real LC's 68020 does 3 clocks = 6 of our ticks (185 ns vs our 246+ ns).
⇒ **FSM-only shortening cannot beat 8 on SDRAM targets. Reaching 6 requires
starting the SDRAM access on demand (any tick) instead of at slot starts.**
Bus arbitration (`br_n`/`bgack_n`) is tied off in both tops — dead logic, no
interaction to preserve.

**Hard constraints discovered against the FPGA timing closure
(`MacLC.sdc`):**
1. The TG68 kernel carries a 2-cycle multicycle justified by "clkena can
   never pulse on two consecutive clk_sys cycles" — kernel reg→reg paths are
   ~33 ns, they do NOT close single-cycle at 32.5 MHz. Any wrapper rewrite
   must preserve **≥2 clk_sys between consecutive clkena pulses** (so 1-tick
   internal steps are off the table), and the SDC comment must be updated if
   the gating mechanism changes.
2. `tg68_din_r` is load-bearing for timing: it gives the kernel's deep
   data_in→decode cone a register boundary one tick before clkena. Feeding
   `tg68_din` combinationally into the kernel at the clkena edge would put
   SDRAM-mux→kernel-datapath in one 30.8 ns period — don't. Tail stays
   "din_r one tick before clkena".
3. `periph_din_reg`'s 2x multicycle assumes VPA reads settle ≥5 clk_sys
   before the sample — preserved as long as the VPA path keeps its current
   pacing (it must anyway).

## Plan of record

- **Phase A** — measure (sim-only instrumentation, this page's entry 1).
- **Phase B** — collapse the CPU FSM (short front/tail, 1-tick internal
  steps), reclaim the idle floppy slot for the CPU. Bounded gain (harvests
  the 10/12-tick cases + halves internal steps); prerequisite for C.
- **Phase C** — demand-start SDRAM service for CPU accesses (+ floppy request
  arbiter + refresh scheduling). This is where 8 → 6 lives.
- **Phase D** — CPU VRAM *reads* from `vram_bram` port A (writes already go
  to BRAM; reads still round-trip SDRAM today).

Gates for any phase: tb_gcr_read (+acclen=40 +pollgap=40, and a reduced
pollgap to model the faster CPU), tb_mfm_idcensus, tb_ism_sony, tb_disk_swap,
tb_scsi_pf, tb_scc_midi, check_boot.sh --run, quartus_map A&E, per-seed HW
video+boot gate. Floppy TB re-runs are non-negotiable for anything that
changes AS width or CPU pacing (the GCR latch-clear and Sony driver timing
are calibrated against current pacing).

---

## Entries

### 6 — 2026-08-18: I-cache ported and HW-tested — WORKS IN SIM, HANGS ON HARDWARE

**Ported** `rtl/fetch_cache.sv` (branch `i-cache` @`b393eaf`) onto the Phase B+C
tree, branch `cpu-icache`. One correction was mandatory:

★ **The hit path needs an address valid one clk BEFORE AS falls.** The
pre-Phase-B walker gave that free (addr at s0, AS at s1); the Phase-B FSM
registers `addr` and asserts `as_n_r` on the SAME edge, so on the registered
address the module's correspondence guard (`rd_idx_d == idx`) rejects every
fetch — a 100% miss, silently. `tg68k.v` now exposes `addr_early` (the kernel's
combinational output) and the cache is fed from it.

**Everything offline says it is good:**
- Hit rate **99.96%** (3,998,471 / 4,000,000; 1,529 cold misses).
- Fetch cycle **8.00 → 6.00 ticks flat**; data reads unchanged at 8.00.
- `verilator/tb_fetch_cache.v` (NEW): coherency torture — self-modifying code,
  zero-gap write/fetch, index aliasing, generation flush, 256-iteration
  interleave. **958 hit-data checks, zero violations.**
- `scripts/icache_trace_diff.py` (NEW): cache-ON vs cache-OFF PC→opcode
  identity. PASS — but weak: the diskless sim runs 5.2M instructions across only
  ~1,000 distinct PCs.
- Sim BOOTS with the cache enabled (5.3M instructions, no hang).
- Fit clean: setup +0.330 / hold +0.242 design-wide; RAM 503 → 506 blocks.
- STA probe on the cache's own paths: worst **+3.326 ns** in, +20 ns out,
  +0.424 ns hold. Nothing like the −6.710 ns Phase C was hiding.

**★★★ AND YET: enabling it on hardware HANGS the machine.** Deployed
(md5 5331d64e), booted with the switch off — Speedometer matched the release
within noise (mix 3.048 vs 3.067, colour 1.029 vs 1.030), confirming the gate
isolates the answer path. Flipping **CPU I-Cache → Enabled** mid-session froze
the guest: screen pixel-identical after cursor movement (the definitive liveness
oracle here, since the menubar clock is frozen anyway). No Sad Mac, no bomb — a
HANG, which reads as the CPU spinning on garbage rather than faulting. Recovered
by reloading the core; the volume booted fine and the pre-flip backup
(`MacLC_7-5-5.PRE-ICACHE-BACKUP.hda`) is intact and byte-verified.

**★ LEADING HYPOTHESIS — the July audit's margin was consumed by Phase B+C.**
The module header states the fill's M10K read-during-write garbage *"is provably
never consumed (next AS-fall ≥2 clk)"*. That guarantee came from the OLD 8-tick
cycle and its longer tail. Phase B+C compressed the cycle to 6 ticks with a
single-tick S_IDLE, so the distance from the fill (at AS-rise) to the next
fetch's AS-fall has SHRUNK. Supporting detail: `tag_ram`/`data_ram` are declared
`(* ramstyle = "M10K" *)` **without** `no_rw_check`, so their real
read-during-write behaviour need not match Verilog's non-blocking semantics —
exactly the class of thing simulation models ideally and silicon does not, which
is why every offline test passes.

**★ Fix direction (do this before trying hardware again):** stop relying on a
timing margin and make the cache RDW-immune by construction — detect
`write_index == read_index` in the same cycle and either force a miss or
bypass-forward the written data. Then extend `tb_fetch_cache.v` with an explicit
same-cycle fill-vs-lookup case (it does NOT currently cover that) and re-run
before refitting.

**Status: the cache ships OSD-gated OFF and is safe to deploy; do not enable it
on an image you care about until the above is done.**


### 2 — 2026-08-17: Phase B — collapsed bus FSM (tg68k wrapper) + DTACK-grant qualifier

**Core RTL (ports to Pocket): `rtl/tg68k/tg68k.v`.** The 8-state per-tick
walker (AS at s1-phi1, DTACK sampled only at s4-phi2, latch s6, clkena s7)
is replaced by S_IDLE/S_WAIT/S_TAIL1/S_TAIL2/S_ENDC:

- AS+RW+UDS/LDS assert at the first edge after the kernel presents the
  access (any phi phase) — one tick earlier than before, and write strobes
  now assert WITH AS (was: two ticks later at s3; safe because SDRAM samples
  ds two clk_64 into the granting slot and VPA targets are E-paced).
- S_WAIT samples exit EVERY tick: `berr_held | !dtack_n | (phi2 && xVma)`.
  The VPA exit keeps its phi2 qualification = E-pacing identical.
- Tail is tick-identical to the old walker: exit +2 = din_r latch +
  AS/strobe release (old s6), +3 = clkena (old s7). Slot-granted SDRAM data
  lands at the granting slot's busPhase-3 tick = exit+2 exactly.
- clkena = S_ENDC, plus internal (busstate==01) steps in S_IDLE gated by
  `!clkena_d` — preserves the ≥2-clk_sys kernel-update spacing the SDC
  multicycle needs (internal steps stay 2 ticks; they now phase-drift
  instead of phi1-locking, which breaks the 8-tick parity lock more often).
- berr_hold clears in S_IDLE (after the kernel's S_ENDC berr sample).
- E/VMA block untouched (its `s_state != 0` guard still works: S_IDLE==0).
- Instrumentation start/end conditions updated to the new states; target
  classifier fixed (32-bit $50Fxxxxx I/O aliases were landing in "other";
  only slot space $F1-$FE is genuinely non-24-bit).

**Top glue (re-derive per platform): `MacLC.sv` + `verilator/sim.v`** — the
mem-slot DTACK grant gains an `as_low_q` qualifier (AS low through the
whole previous tick). The SDRAM controller samples oe/we at the slot's
first clk_64 edge; the old FSM could never present AS at a slot boundary
(phi1-only assert), the new one can, and granting such a slot would serve
stale dout (the fill-capture hazard class from the MacIIvi 2026-08-16
lesson). No cost against old-FSM-timing cases.

**`MacLC.sdc`**: kernel-multicycle + periph_din_reg comment justifications
rewritten for the new gating (constraints themselves unchanged). Pocket
port: whatever the Pocket's timing constraints are, the same two invariants
must hold there — ≥2-cycle kernel spacing, and din_r/periph settle windows.

Expected effect (model): locked fetch streams stay at the 8-tick slot
floor; the 10/12-tick misalignment and transient cases compress toward
6-9; DTACK-immediate targets (slot space, SCSI-DMA when DREQ pending)
complete in 5-6 ticks vs 8. Measured effect: see entry 3.

**MEASURED (sim A/B, archived `scratch/bus_hist_phaseB.log`):** window-0
boot workload executed cycle-for-cycle identically to baseline (2,944,491
vs 2,944,483 cycles — functional transparency proven); ROM fetch stays
8.93 (the slot lock, as modeled), while the new fast paths appear exactly
where designed (IO-DTACK 5.0, RAM writes 6.0, len-5/6 buckets populated).
Desktop windows: fetch 8.60, VRAM read 9.50, VRAM write 10.10.

**HW gate 2026-08-17: PASS.** Fit seed 7: Fitter Successful, STA met
(worst slack +0.216 ns). Deployed md5 63982eb3b61e476e1259f14b15331bd3 as
canonical MacLC.rbf; coreRunning=MACLC; booted System 7.5 to the Finder
desktop with clean video and colour icons (scratch/phaseB_hw_boot1.png).

### 4 — 2026-08-18: Phase C FIX — pipeline the request bundle (branch `cpu-phase-c-fix`)

**The F-line bomb was a genuine timing failure, and STA proved it.** With the
`b48b60c` multicycle disabled, timing analysis on the post-fit netlist
reported:

```
slack -6.710 ns   WINDOW 15.381 ns   tg68k|addr[16] -> sdram|sd_addr[12]
```

The capture window is ONE clk_64 period (15.381 ns) — so the `t[0]` start gate
selects the half-period edges, not the coincident ones — while the V8
address-translation cone (SIMM compare, mirror subtract, mux) needs ~22 ns.
The demand sequencer was latching a **half-settled row/column address**, so
reads and writes landed at the wrong locations. That is the RAM corruption
behind the "System Update" error-type-10 (F-line) bomb: the guest eventually
executed garbage. The multicycle had been granting 2 destination periods
(30.76 ns) that the silicon never had — the textbook STA-met-but-HW-fails trap.

**Why Phase B never had this problem:** it did not touch `sdram.v`. The old
slot machine sampled at a fixed slot phase with the CPU holding address and
data stable across the WHOLE 4-clk_sys slot — about 123 ns of settling. Phase C
discarded that margin and replaced it with a promise in a constraint file.

**Fix (core RTL + both tops):** register the entire SDRAM request bundle in
clk_sys before it reaches the controller — `addr`, `din`, `ds`, `oe`, `we`,
`flp_win`, `flp_guard`, plus the floppy byte-parity select so it stays coherent
with the address it was issued with. The deep cone now terminates at a clk_sys
flop with a full 30.76 ns period (22 ns needed → genuine positive slack), and
the sequencer captures from an adjacent register over a short route. Both legs
are honest single-cycle paths STA actually checks. **The multicycle is deleted**
with a DO-NOT-RE-ADD note in `MacLC.sdc`.

**Verified:** SDRAM paths **−6.710 → +3.817 ns**; design-wide worst setup back
to the framework ascal at +0.424 ns. Sim boots clean (frame 450 = dither
desktop + cursor + flashing-? icon).

**Cost and result — one clk_sys tick of request latency:**

| | baseline | Phase B | Phase C (broken) | Phase C + fix |
|---|--:|--:|--:|--:|
| ROM fetch | 8.96 avg (75% at len 8) | 8.93 | 7.00 | **8.00 flat (100%)** |
| VRAM read | ~11.6 | 9.50 | 7.00 | **8.00** |
| VRAM write | ~10.1 | 10.10 | 6.00 | **7.00** |
| desktop cycles/sec | — | 3.20 M | 4.44 M | **3.59 M (+12% over Phase B)** |

The win is smaller than the broken build advertised (+12% vs +38%) but it is
real. **Everything is now FLAT** — 100% of fetches at exactly 8 ticks, versus a
baseline where only 75% hit the floor and the rest paid 10/12/14 for slot
misalignment. That flatness is the demand engine working as designed.

**Idea for Phase C2 (recovering the lost tick, 8 → 7):** translate the address
speculatively from the kernel's combinational `tg68_addr` and register THAT, so
the translated address is valid at the same edge AS asserts instead of one tick
later. Needs a timing check on the kernel-output cone, which is already long.

**★ HW GATE: PASS (2026-08-18 09:53).** Seed-4 fit (STA met, +0.149 ns, no
violations) deployed as canonical MacLC.rbf: the guest boots straight to the
System 7.5.5 Finder desktop with colour icons intact and NO bomb. The
"System Update" error-type-10 crash is gone. This closes the loop opened by
the 2026-08-17 failure: sim-clean + STA-clean + HW-clean, with the timing
proven rather than asserted. Speedometer re-run is the remaining step (expect
~+12% on the mix per the histogram; Phase B alone measured as noise).

**Seed note:** the seed-7 placement of this fix left an unrelated 19 ps HOLD
violation in the CD-audio MLAB write-address path (`cd_audio|t43_wa[5]` →
`cd_sdp_mlab` LUT-RAM address regs) — a module this change never touched,
exposed because any netlist edit re-rolls the unpinned RAMs. Refit on seed 4.
★ That is the LEGITIMATE use of a reseed (placement marginality on an unrelated
module); using one to make the address-path violation "pass" would have been
the illegitimate use, and is exactly what the deleted multicycle was doing.

### 3 — 2026-08-17: Phase C — demand-start SDRAM service (the slot-floor break)

**Core RTL (ports to Pocket): `rtl/sdram.v`** — the operational branch of
the command engine is a demand sequencer: an access starts at any idle
clk_64 edge (same 8-clk_64 ACTIVE/CAS/capture schedule as before,
including the +2 capture margin), instead of only at bus-slot boundaries.
New ports: `flp_win` (floppy window, priority, runs slot-aligned by
construction so floppy.v sees identical timing), `flp_guard` (hold CPU
starts while a pending floppy window approaches), `cpu_done` (early-done:
reads at ACTIVE+3 clk_64 — data lands in `cpu_dout` at ACTIVE+6, a full
tick before the FSM's exit+2 din_r latch; writes POSTED at ACTIVE),
`cpu_dout` (private held CPU read register — floppy windows can no longer
clobber CPU data). Request values (din/ds/column) freeze at ACTIVE
(din_q/ds_q/col_q) so mid-access mux flips (download windows) can't
corrupt a delayed access. CPU starts gated to t[0] parity (integer
clk_sys edges) so cpu_dout launches on full-period STA paths — no
cross-clock multicycle needed. Explicit refresh: opportunistic when idle
past REF_OPP (300 clk_64), forced past REF_FORCE (480) — tREF needs one
per ~508. Read period: 7 clk_sys; write period: 6 (vs 8/10/12 before).

**`rtl/addrController_top.v`**: `_ramOE/_romOE/_ramWE/_memoryUDS/LDS`
drop their `cpuBusControl` slot gating (they are now level requests;
floppy windows force read-both-bytes). `dskReadAckInt/Ext` are
PENDING-GATED (fire only when the encoder's fetch address changed since
last served — kills the every-rotation spurious SDRAM read; served state
marked at the window's memoryLatch). New outputs `flp_guard` (covers the
full slot before a pending window + the window), input `cpu_wr_ack`. The
VRAM BRAM write-mirror strobe (`vram_we`) fires on the RISING EDGE of
`cpu_wr_ack` instead of at cpuBusControl&&memoryLatch — under demand
serving an AS-low window need not contain a cpu-slot latch tick (silent
BRAM-write drop = stale pixels), while the ack rises mid-cycle when AS,
the live a_be strobes, address and data are all still held.

**Top glue (re-derive per platform): `MacLC.sv` + `verilator/sim.v`** —
`_cpuDTACK` mem leg = `~cpu_done` (dtack_en shrinks to the immediate
peripheral/unmapped path; the as_low_q slot qualifier from entry 2 is
gone with the slot grant itself). `sdram_do`'s CPU leg serves the held
`cpu_dout` (warm-boot ROM patch applied there); `sdram_out` remains the
floppy demux source. `rtl/dataController_top.sv`: the memory leg of
cpuDataOut passes `memoryDataIn` straight through (retired the
slot-sampled `cpu_data` register — upstream data is now held).

**`verilator/sim_ram.v`**: same handshake, latency-matched (reads done at
+2 edges, writes posted at +1) — plus the write path is `!flp_win`-gated:
with un-slotted `_ramWE`, a pending CPU write's `we` is high during
floppy windows while `addr` is the floppy image's (the FPGA controller is
safe by construction; the sim model needed the explicit gate).

**Bug found and fixed during bring-up (the magenta screen, 2026-08-17,
identical on HW and sim):** first Phase-C builds booted to a uniform
magenta instead of the desktop. Diagnosis chain: CPU healthy (check_boot
PASS, desktop workload executing), VRAM BRAM strobes healthy through
frame 240 (109,364 strobes = exactly the visible-column fraction, 0
missed), frame 200 healthy grey, frame 450 magenta — the break follows
the Sony driver install, whose drive polling churns the floppy fetch
address and fires pending windows continuously. Root cause: `sdram_oe`
still included `dskReadAckInt/Ext` (a slot-machine leftover), while
`cpu_done` clears on `!(oe||we)` — a floppy window bridging the 2-3 tick
AS-high gap between CPU cycles held oe high, so done never cleared: the
next READ instant-acked on the held done and latched the PREVIOUS
access's cpu_dout without touching SDRAM (stale-read class), and the
next WRITE lost its done-RISE, silently dropping the vram_we BRAM
strobe. Fix: `oe` is pure CPU/download read intent in both tops (floppy
intent travels only via flp_win; sim_ram's window serve drops its oe
qualifier). The magenta itself was the Ariel's reset-time diagnostic
palette (bin 5 = magenta) showing through — a deliberately loud init
pattern that made the failure visible and diagnosable; uniform color =
the System's post-mode-switch redraw lost to dropped strobes and stale
RMW reads. **Pocket port note: this is THE trap class for any port of
the demand engine — every request-done handshake must key on the
requester's OWN level, never on a mux shared with another master.**

**Magenta, act 2 (open at this writing):** the oe fix was real but not
sufficient — the screen persisted on the next build. Precision so far:
the visible "magenta" is the 1bpp B/W desktop dither rendered through
two mis-programmed CLUT entries — 0x7F = (7F,FF,7F) light green, 0xFF =
(7F,00,7F) dark magenta (pixel-counted from the HW screenshot: exactly
307,200 pixels split 50/50) — produced when the guest's final 2-entry
CLUT program is phase-shifted by ONE extra READ-decoded ariel access
after each of its writes (REG_PALETTE reads auto-advance the shared RGB
counter — semantics verified identical in MAME ariel.cpp, the model's
ground truth). The failing boot branch is selected by what the ROM's
video probe reads from UNWRITTEN memory, so Verilator's per-build
--x-initial fast pattern made instrumented rebuilds dodge the path;
sim_ram now deterministically fills mem[] (zeros → clean path; trying
FFFF). Next discriminator: the instruction stream between consecutive
DAC writes in a magenta run's cpu_trace.log — real guest reads of
$F24xxx (⇒ our readback DATA is wrong) vs none (⇒ fabricated bus
cycles). MAME reference sequence via the run_mame.sh rig if needed.

**Magenta RESOLVED — root cause: unanswered ROM-region WRITES.** The
trail in full: the shredded CLUT was a red herring — the Phase-B
baseline executes the IDENTICAL RMW-based B/W patch with the identical
transient shred (the RD/WR pairs are the read halves of BSET #7 /
NOT.B-class instructions on the DAC data port; the "reads" were real),
and then ~32 frames later the boot's next stage reprograms the full CLUT
correctly. Phase C never reached that stage: a bus-hang watchdog named
the stall — a byte WRITE to $A6C3D5, ROM space, issued by the ROM's
device-probe code behind a temporary vector-$8 handler. A ROM write
asserts neither oe (read-gated) nor we (RAM/VRAM-gated), so the demand
engine never serves it; the old slot glue acked every mem-region access
at the slot start REGARDLESS of oe/we — ack-and-discard, 68000/V8
style — which is what the ROM requires (ack or BERR; hang is the one
illegal outcome). Fix: ROM-region writes take the immediate dtack_en
path (ack-and-discard) in both tops; the demand leg serves
RAM/VRAM/ROM-reads only. The pre-oe-fix builds sometimes LOOKED alive
under magenta because the stale-done bug phantom-acked these writes —
two bugs stacked on one symptom. **Pocket port law #2: every access
class the memory engine does NOT serve must still be terminated
(ack-and-discard or BERR) — enumerate them (ROM writes are the classic)
before first boot.** Repro determinism: sim_ram mem[] init value picks
the ROM's probe branch; 16'hFFFF reproduces the failing (?-icon) path.

### 1 — 2026-08-17: Step-0 measurement instrumentation (sim-only) + BASELINE

- `rtl/tg68k/tg68k.v`: `ifdef SIMULATION` block — histograms every completed
  bus cycle's clkena-to-clkena tick count, binned by busstate
  (fetch/read/write) × target class (RAM/ROM/VRAM/VPA/IO-DTACK/other), plus
  internal-step counts; dumps `bus_hist.log` once per simulated second.
- `scripts/bus_hist_report.py`: aggregates/reports the log.
- **Pocket port: not needed** (measurement scaffolding only). The timing
  model above, however, applies wherever the same addrController/sdram slot
  scheme is used.

**BASELINE (pre-Phase-B commit `3568a1e`, 9 sim-seconds boot→desktop,
archived `scratch/bus_hist_baseline.log`):**

| phase | bus-cycle share | avg cycle | notes |
|---|---|---|---|
| whole run (w0-6) | 86.6% of ticks | ~9.2 | ROM fetch 44.4% @ 8.96; RAM rd 17.5% @ 9.50; RAM wr 13.9% @ 10.03 |
| desktop (w6-8) | 86.5% of ticks | ~8.4 | ROM fetch 46.6% @ 8.41 (89.6% at len 8); VRAM/periph via $50Fxxxxx aliases: rd 26.5% @ 11.60, wr 17.3% @ 10.10 |

Memory-cycle length mix (whole run): only 57% (RAM) / 75% (ROM) of cycles
hit the 8-tick floor; the rest sit at 10/12/14 (slot misalignment + the
idle floppy slot). Internal steps are just 3-4% of ticks — the CPU's time
is essentially all bus cycles. Confirms: cut ticks-per-access or nothing.
(Caveat for A/B: this run predates the classifier fix, so 32-bit
$50Fxxxxx I/O/VRAM aliases count as "other" here.)
