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

### 1 — 2026-08-17: Step-0 measurement instrumentation (sim-only)

- `rtl/tg68k/tg68k.v`: `ifdef SIMULATION` block — histograms every completed
  bus cycle's clkena-to-clkena tick count, binned by busstate
  (fetch/read/write) × target class (RAM/ROM/VRAM/VPA/IO-DTACK/other), plus
  internal-step counts; dumps `bus_hist.log` once per simulated second.
- `scripts/bus_hist_report.py`: aggregates/reports the log.
- **Pocket port: not needed** (measurement scaffolding only). The timing
  model above, however, applies wherever the same addrController/sdram slot
  scheme is used.
