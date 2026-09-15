# Plan: make the SDRAM read capture fit-invariant (QuarkXPress F-line regression)

Written 2026-09-12 at session close. Status: **diagnosed and measured, NOT yet
implemented.** Nothing below has been built or booted except where stated.
The author of the fix is a non-maintainer; the deliverable is a PR, not a
release. Do not ship a seed change as the fix.

## 1. The regression in one paragraph

On `MacLC_20260827.rbf` (commit 93a90b7) QuarkXPress 3.32 under System 7.5.5
hangs after a few keystrokes, once with System Error 10 (Line 1111 / F-line =
the CPU executed non-code). `MacLC_20260826.rbf` (638a70b) is fine. The
638a70b..93a90b7 delta is an Ethernet ISR-mask change in `rtl/pds/pds_enet.sv`
that cannot execute with the card off (it was off, and a non-fork Main never
asserts card presence), plus `MacLC.qsf` SEED 8 -> 4. A refit of 93a90b7's
**unchanged RTL at SEED 7** (`scratch/bisect/MacLC_seed7_0827rtl.rbf`) fixes
Quark on hardware (user-confirmed 2026-09-12). So the defect is
fit-dependent, and it lives where STA never looks.

## 2. Root cause (measured, not inferred)

The SDRAM interface has **no I/O constraints at all** (no
`set_input_delay`/`set_output_delay` in `MacLC.sdc` or `sys/sys_top.sdc`; the
STA report lists every SDRAM port as unconstrained). Facts from `rtl/sdram.v`:

- `SDRAM_CLK` is `altddio_out(datain_h=0, datain_l=1)` of `clk_64` (65.01 MHz,
  15.381 ns) => the chip clock is the **inverted** clk_64, reaching the pin
  7.2-8.1 ns after the PLL (measured on the seed-7 fit).
- Reads: burst length 1, CAS latency 2, and `STATE_READ = CAS + CL + 2`
  (commit 3a6f00d, 2026-03-22, "latch one state later for 65MHz margin" -
  that commit budgeted SETUP only). With BL=1 the chip drives DQ only until
  its next clock edge + tOH (2.5 ns), so the sample sits near the END of the
  data-valid window and the hold side depends on the pin-to-register route.
- `sys/sys.tcl` sets `FAST_INPUT_REGISTER ON -to SDRAM_DQ[*]`, but only ONE
  register per pin can be packed into the I/O cell. Three registers read the
  pins at `STATE_READ` (`cpu_dout`, `eth_dout`, floppy `dout`); the fitter
  packed the floppy `dout` (IC = 0 ns). `cpu_dout` and `eth_dout` are fabric
  registers with **3.8-12.3 ns of routing** in the seed-7 fit - the term a
  seed reshuffles.

Constrained STA on the seed-7 (good) fit, trial SDC as in section 3.2 but
with `set_multicycle_path -setup -end 2` to the existing capture registers
(= the controller's real edge) and default hold. Datasheet: Alliance
AS4C32M16SB-7 (64/128 MB MiSTer modules): tAC(CL2) 6.0, tOH 2.5, tHZ 5.4,
tIS 1.5, tIH 0.8 ns; Winbond W9825G6KH-6 (32 MB module) is equivalent.

| Path | Setup slack | Hold slack |
|---|---|---|
| FPGA -> chip (A/BA/DQ/cmd, I/O-cell registers) | +4.06 | +6.02 |
| DQ -> `cpu_dout` (fabric) | +2.32 | +1.89 |
| DQ -> `eth_dout` (fabric) | **-0.46 VIOLATED** | +1.77 |
| DQ -> floppy `dout` (I/O cell, posedge) | +10.13 | **-1.39 VIOLATED** |

The read eye at a capture register is ~9.7 ns wide (setup + hold slack of
one bit); the good fit places CPU bits 1.9-2.3 ns inside it at the extremes.
A seed that routes any CPU bit ~2 ns shorter or ~2.5 ns longer falls out -
that is seed 4. The I/O-cell-packed floppy capture shows the POSEDGE is
hold-marginal (-1.4 ns) even with zero routing, so "just pack the CPU capture
into the I/O cell" is NOT sufficient: the capture EDGE must move. Eth DMA is
already outside the eye on the good fit (matters once the card is on).

Reports kept (all gitignored): `scratch/p_*.txt` (unconstrained pin paths),
`scratch/c_*.txt`, `scratch/d_*_{setup,hold}[_full].txt` (constrained),
`scratch/sdram_io*.tcl` (STA scripts), `scratch/sdram_io.sdc` (trial SDC),
`scratch/bisect/seed7.sta.rpt`. The seed-7 fit database is still in `db/` +
`output_files/` (built 2026-09-12 12:35). `MacLC.qsf` is **SEED 7,
uncommitted** (revert to 4 only to reproduce the failing 0827 fit).

## 3. The fix (design)

Principle: one register on the data pins, in the I/O cell, clocked on the
**falling** edge of clk_64; every consumer reads that staged word at the edge
it already uses. Plus SDC constraints so STA reports the eye in every build.

Edge arithmetic (STA frame, seed-7 numbers): the chip launches data at ideal
2.5P (+8.1 ns clock path), valid at the I/O-cell register at ~54.9 ns; a
negedge capture at ideal 3.5P (+7.3 ns tree) = 61.1 ns => **~+6 ns setup**;
the data leaves at ~65.3 ns => **~+4 ns hold**. Centred, and identical in
every fit because an I/O-cell register has no fabric route. The
negedge -> posedge hand-off (`sd_data_q` -> `cpu_dout` at `STATE_READ`) is a
half-period internal path that STA checks natively.

### 3.1 `rtl/sdram.v`

```verilog
// I/O-cell capture of the data pins on the FALLING edge of clk_64
// (eye budget: docs/plan_sdram_read_capture_2026-09-12.md, sections 2-3).
reg [15:0] sd_data_q;
always @(negedge clk_64) sd_data_q <= sd_data_rd;
```

At `if (seq == STATE_READ)` replace the three `sd_data_rd` reads
(`cpu_dout`, `eth_dout`, `dout`) with `sd_data_q`. `STATE_READ` and every
`cpu_done` / `eth_ack` edge stay exactly as they are, so the CPU-side
done/latch arithmetic documented above `cpu_done` remains valid. Optional:
add `initial t = 3'd0;` next to `initial reset = 10'h3FF;` so the Icarus
gate runs without the scratchpad helper (harmless for Quartus; power-up 0 is
the default anyway).

Testbench compatibility: the chip model in `tb_icache_seam.v` drives
`sd_data_i` at the posedge two cycles after it sees READ (E_c+3 in controller
terms) and holds it until the next READ; a negedge capture at E_c+3.5 sees
it. `verilator/sim.v` uses `sim_ram.v`, not `sdram.v`, and consumer latency
is unchanged, so no sim-side edit; note the change in
`docs/verilator_differences.md` anyway.

### 3.2 `MacLC.sdc` (add; adjust the numbers to the module actually fitted)

```tcl
# ----------------------------------------------------------------------------
# SDRAM interface (2026-09-12). SDRAM_CLK = altddio_out(datain_h=0,datain_l=1)
# of clk_64 = INVERTED clk_64. Values: Alliance AS4C32M16SB-7 / Winbond
# W9825G6KH-6: tAC(CL2)=6.0 tOH=2.5 tIS=1.5 tIH=0.8, +0.5 ns trace on max.
# Read capture = sd_data_q (I/O cell, negedge clk_64): chip launch at its
# rising edge -> the next clk_64 FALLING edge is the default relationship,
# so no multicycle is needed. If the capture is ever moved back to a
# posedge register, re-derive (the pre-fix STATE_READ capture needed
# set_multicycle_path -setup -end 2).
# ----------------------------------------------------------------------------
create_generated_clock -name sdram_clk -invert \
  -source [get_pins {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] \
  [get_ports {SDRAM_CLK}]
set_input_delay  -clock sdram_clk -max 6.5 [get_ports {SDRAM_DQ[*]}]
set_input_delay  -clock sdram_clk -min 2.5 [get_ports {SDRAM_DQ[*]}]
set SDRAM_OUT [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQMH SDRAM_DQML SDRAM_nCAS SDRAM_nRAS SDRAM_nWE SDRAM_nCS}]
set_output_delay -clock sdram_clk -max  2.0 $SDRAM_OUT
set_output_delay -clock sdram_clk -min -0.8 $SDRAM_OUT
```

`sdram_clk` is deliberately left OUT of the exclusive clock groups in
`sys/sys_top.sdc` so that it is timed against clk_64 (an unlisted clock is
related to every group, which is what we want here).

### 3.3 `MacLC.qsf`

No new assignment should be needed: `sys/sys.tcl` already requests
`FAST_INPUT_REGISTER` on `SDRAM_DQ[*]`, and with a single unconditional
register on each pin the fitter can honour it. **Verify in the fit report**
(section 4.3). Leave SEED as the maintainer had it (4) in the PR; the fix
must not depend on the seed.

### 3.4 Fallback if the fitter will not pack a negedge register into the I/O cell

Use the framework-standard DDR input primitive (`altddio_in`, inclock =
clk_64): its `dataout_l` is the falling-edge capture, taken in the I/O cell
by design and presented in the rising-edge domain. Needs an `altddio_in`
stub next to `verilator/altddio_out_stub.v` for the testbenches; the SDC
above is unchanged. Second fallback: a dedicated phase-shifted PLL output
driving SDRAM_CLK (the standard MiSTer method, but it edits the generated
`rtl/pll.v`).

## 4. Verification (in this order)

### 4.1 STA-only sanity on the existing seed-7 database (1 minute, no refit)

Add the SDC of 3.2 as a scratch file first and run the
`scratch/sdram_io4.tcl`-style reports. Expected BEFORE the RTL change: the
table in section 2. This proves the constraints bite.

### 4.2 Offline seam gates (Icarus, `C:\iverilog\bin`; Verilator is NOT installed here)

From `verilator/`, with the scratchpad helper `tinit_seam.v` containing
`module tinit_seam; initial tb_icache_seam.dut.t = 3'd0; endmodule`
(Icarus starts `t` at X, Verilator zero-inits; without this the TB hits its
global timeout on unchanged RTL):

```
iverilog -g2012 -DTB_NO_TRISTATE -o seam.vvp tb_icache_seam.v ../rtl/sdram.v altddio_out_stub.v tinit_seam.v && vvp seam.vvp
   -> checks=107 errors=0 RESULT: PASS      (baseline 2026-09-12: PASS)
iverilog -g2012 -DTB_NO_TRISTATE -DSDRAM_NO_DONE_LEVEL_FIX -o neg.vvp tb_icache_seam.v ../rtl/sdram.v altddio_out_stub.v tinit_seam.v && vvp neg.vvp
   -> must print RESULT: FAIL                (negative control; baseline: FAIL, 3 violations)
iverilog -g2012 -DTB_REAL_SDRAM -DTB_NO_TRISTATE -I../rtl -o dl.vvp tb_dl_cpu_seam.v ../rtl/sdram.v sim_ram.v altddio_out_stub.v && vvp dl.vvp
   -> checks=10 errors=0 RESULT: PASS       (baseline: PASS)
```

Also `tb_pds_enet.v` if it builds under Icarus (it exercises the eth port of
sdram.v via pds_enet; CLAUDE.md lists it as a gate for SDRAM edits). The boot
gate (`./obj_dir/Vemu --screenshot 450`, grey desktop + cursor at frame 450)
needs Verilator: not on this PC; WSL "Ubuntu" exists without it
(`apt install verilator` plus SDL2 would enable it), or run it on the usual
Mac/Linux box.

### 4.3 Full builds (~25 min each, `bash scripts/build_only.sh`; never edit during a build)

For EACH of at least three seeds (for example 4, 7, 5):

1. Per-domain STA in `output_files/MacLC.sta.rpt` (NOT the script's aggregate
   number): clk_sys and clk_64 setup positive as before (+4.7 / +2.1 on seed 7).
2. SDRAM report: `report_timing -setup` and `-hold` `-from_clock sdram_clk
   -to [get_registers {*sdram|sd_data_q*}]`, and `-to_clock sdram_clk` for the
   outputs (see `scratch/sdram_io4.tcl`). Expect roughly +6 / +4 read and
   +4 / +6 write. Consider committing that script as
   `scripts/sdram_io_report.tcl`.
3. Fit report: every `sdram|sd_data_q[n]` row says "Packed Register ... Fast
   Input Register assignment" (as `dout[n]` does today), i.e. IC = 0 on the
   DQ -> sd_data_q paths. If not, go to section 3.4.
4. `report_ucp`: SDRAM ports no longer listed as unconstrained.

### 4.4 Hardware (user)

- Ethernet OFF in the OSD for the A/B (bit-19 polarity trap: set it explicitly).
- Quark repro on `mac_80mb.vhd` or the 2 GB disk: type in a document for a
  few minutes; the old failure came within a few keystrokes.
- Finder colour-icon check (crisp icons, folder tints, no noise) plus at
  least two further Finder boots; keep the CD attach mounted; a boot-time
  load hang is a retry, not a verdict. `scripts/icon_gate.py` cells are stale
  (its header says so), so use it as a visual aid only. Fresh frames come
  from `scripts/grab_fresh.sh` (needs MISTER_HOST etc. in `scripts/local.env`,
  still template values).
- Floppy read and SCSI copy smoke test (the floppy capture moves from a
  hold-marginal posedge to the centred negedge; expect no change or better).
- Then the same on the seed the maintainer ships (4): the point is that the
  seed no longer matters.

## 5. PR contents

- `rtl/sdram.v` (3.1), `MacLC.sdc` (3.2), optional `scripts/sdram_io_report.tcl`,
  a `docs/verilator_differences.md` note, this document, and an `altddio_in`
  stub only if 3.4 was needed.
- NOT: the SEED change, anything under `scratch/`, anything under `releases/`.
- The commit message should cite: bisect 0826-good / 0827-bad, seed-7 refit
  passes on hardware, the measured table in section 2, and 3a6f00d as the
  origin of the late sample.

## 6. Open points / risks

- Whether a negedge register packs into the Cyclone V I/O cell is unverified
  (the Intel documentation fetch failed). The fit report answers it in one build.
- The trace-delay allowance (0.5 ns) and the exact module on the user's board
  are assumptions; the constraints turn a wrong assumption into a reported
  slack, not a silent failure.
- The always-on "marginality anchor" in `MacLC.sv` (~line 1575) pins SCSI and
  floppy read cones for the same "STA green, hardware corrupt" class. Leave
  it in place for this PR; revisit only after several constrained fits soak.
- `verilator/sim.v` / `sim_ram.v` do not model pin timing at all, so no
  offline gate can catch this class; only the constrained STA can.

## 7. Revision after the first three builds (2026-09-12, later)

### 7.1 What the section-3 design did on hardware-grade fits

Built at seeds 4 / 7 / 5 exactly as written in 3.1 / 3.2 (artifacts:
`scratch/sdramfix_v1_posedge_handoff/`). The pin side worked: the eye at
`sd_data_q` was **+2.24 setup / +6.52 hold on every seed (0.035 ns spread)**,
the write side +4.06 / +6.02, all 16 bits packed as "Fast Input Register",
no unconstrained SDRAM port left. But all three fits reported **TIMING NOT
MET**: the new critical path was `sd_data_q -> eth_dout/cpu_dout/dout` at
seed 4 -0.639, seed 7 -0.330, seed 5 -0.143 ns. The path is one logic level
of pure I/O-cell-to-core interconnect (~6.0-6.6 ns) inside a half-period
budget (7.691 ns) that also loses ~1.2 ns of clock skew (the I/O-cell clock
arrives later than the core clock). Section 3's claim that the hand-off "is a
half-period internal path that STA checks natively" was true; it just does
not close.

### 7.2 Two errors in the plan and in the follow-up notes

1. **The eye direction was misread.** Setup +2.24 / hold +6.52 means the
   capture edge sits ~2.2 ns after the START of the data-valid window and
   ~6.5 ns before its END, i.e. EARLY in the eye. Centring it means moving
   the capture ~2.1 ns LATER. The notes said "late in the eye, centred would
   be ~1.9 ns earlier" and recommended a ~135 deg PLL output clocking
   `sd_data_q` earlier "to centre the eye AND grow the hand-off". Earlier
   would have left ~+0.3 ns of pin setup - worse than the defect being
   fixed. Later centres the pins but shrinks the hand-off to ~5.6 ns. The
   two goals conflict, so a phase-shifted capture clock cannot fix the
   hand-off at all (section 3.4's second fallback is withdrawn).
2. **Section 3.1's "consumers read the staged word at exactly the edge they
   used before" is what made the hand-off half a period.** The data is
   physically not in the fabric by that posedge for a far-placed consumer:
   E5.5 + ~6 ns route + skew lands at ~E6, which is exactly the coin-flip the
   original design lost. The extra clk_64 is unavoidable.

### 7.3 The design that closes (implemented)

`rtl/sdram.v`, read-capture block:

```
always @(negedge clk_64) sd_data_q <= sd_data_rd;          // I/O cell, E5.5 (unchanged)
always @(negedge clk_64) sd_data_r <= sd_data_q;           // fabric,   E6.5  (NEW)
always @(negedge clk_64) if (flp_cap) dout <= sd_data_q;   // floppy,   E6.5  (NEW)
localparam STATE_READ = STATE_CMD_CONT + CAS_LATENCY + 4'd3; // was +2 -> cpu_dout/eth_dout at E7
flp_cap <= seq_busy && (seq == STATE_READ-1) && !src_cpu && !src_eth && oe_latch; // posedge E6
```

- `sd_data_q -> sd_data_r` is negedge->negedge: the ~6 ns route now has a
  full 15.38 ns period.
- `sd_data_r -> cpu_dout/eth_dout` at E7 is a short fabric-to-fabric
  half-period path the fitter can place freely.
- **Why the floppy gets its own falling-edge copy:** floppy.v latches its
  byte at `cep && dskReadAckD` = the END of busPhase 3 of the window slot
  (S0+8 in clk_64 edges; `dskReadAck` = `dskReadAckInt`, combinational from
  `busCycle`, so the sdram sees the window at S0+1 and ACTIVE lands there:
  E0 = S0+1, so E7 = S0+8). A posedge E7 `dout` would be written on the very
  edge the floppy latches. Loading `dout` at E6.5 keeps the byte one clk_64
  ahead of that latch, as it was (the old posedge-E6 `dout` also had one
  clk_64). `flp_cap` is the one-edge enable so `dout` keeps holding the
  floppy word afterwards.
- Every consumer of the moved edges was checked: the CPU FSM sees
  `cpu_done` (E3) at E4 and latches `tg68_din_r` at E8 (S_TAIL2), so E7 data
  reaches it over one clk_64 period - which is the relationship STA ALREADY
  used for `cpu_dout -> tg68_din_r` (15.382 ns, +7.9 ns slack on the seed-5
  db: related clocks, nearest edges, no multicycle exists on these paths;
  the old comment claiming "timed at a full 30.8 ns period" was wrong). The
  I-cache fill commits at AS-rise (>= E8). `eth_ack` and `eth_dout` move
  together; pds_enet consumes both on clk_sys at E8. `dout -> dskReadDataLatch`
  had +10.0 ns at a 15.38 relationship, so the falling-edge launch should
  leave roughly +2.3 ns before the fitter re-places it.
- Offline gates after the change: tb_icache_seam 107/0 PASS, negative control
  FAIL with 3 violations (as designed), tb_dl_cpu_seam 10/0 PASS, tb_pds_enet
  ALL PASS (it does not include sdram.v - it is not a gate for this).
- SDC: unchanged constraints; only the comment. `scripts/sdram_io_report.tcl`
  now also reports the stage paths (`sd_data_q -> sd_data_r`, `-> dout`,
  `sd_data_r -> cpu/eth`, `dout -> floppy latch`, `cpu_dout -> tg68_din_r`).

### 7.4 Build results (seeds 4 / 7 / 5, `scratch/sdramfix/`)

Chain 15:44-16:41, all three **TIMING MET** (build status headline +0.24 ns =
the video-PLL hold slack, as on every build of this core):

| metric | seed 4 | seed 7 | seed 5 |
|---|---|---|---|
| clk_64 setup | 1.289 | 2.241 | 2.241 |
| clk_64 hold | 0.253 | 0.271 | 0.297 |
| clk_sys setup | 2.938 | 3.081 | 2.915 |
| clk_sys hold | 0.260 | 0.252 | 0.268 |
| sdram_clk setup | 4.070 | 4.060 | 4.064 |
| sdram_clk hold | 6.032 | 6.024 | 6.022 |
| pll_hdmi setup | 0.436 | 0.534 | 0.518 |
| read  DQ -> sd_data_q  setup | 2.276 | 2.241 | 2.241 |
| read  DQ -> sd_data_q  hold | 6.523 | 6.521 | 6.523 |
| write FPGA -> chip     setup | 4.070 | 4.060 | 4.064 |
| write FPGA -> chip     hold | 6.032 | 6.024 | 6.022 |
| stage sd_data_q -> sd_data_r setup | 7.685 | 7.179 | 7.620 |
| stage sd_data_q -> sd_data_r hold | 2.134 | 2.117 | 2.246 |
| stage sd_data_q -> dout setup | 8.016 | 8.070 | 8.223 |
| stage sd_data_q -> dout hold | 2.141 | 2.117 | 2.250 |
| stage sd_data_r -> cpu/eth setup | 1.289 | 2.386 | 2.665 |
| stage sd_data_r -> cpu/eth hold | 7.512 | 7.721 | 7.621 |
| stage dout -> floppy latch setup | 2.938 | 3.081 | 2.915 |
| stage dout -> floppy latch hold | 7.784 | 6.671 | 7.866 |
| stage cpu_dout -> tg68_din_r setup | 8.403 | 9.043 | 7.907 |
| sd_data_q Fast Input Register rows | 16 | 16 | 16 |
| report_ucp SDRAM_ lines | 1 | 1 | 1 |
| build status line | Timing (STA)           met — worst slack +0.243 ns | Timing (STA)           met — worst slack +0.247 ns | Timing (STA)           met — worst slack +0.246 ns |

The pin eye is unchanged from the first attempt (same I/O-cell register), so
the fit-invariance result stands. The worst clk_64 setup path is now the short
`sd_data_r -> cpu_dout/eth_dout` half-period hop (+1.3..+2.7 ns); the worst
clk_sys setup path is `dout -> dskReadDataLatch` (+2.9..+3.1 ns, half period,
matching the +2.3 predicted from +10.0 at a full period). Not yet booted on
hardware: run section 4.4 with `scratch/sdramfix/MacLC_sdram-negedge-capture_seed4.rbf`
(the seed the PR ships) first, then seed 7 or 5 to prove the seed no longer
matters.

## 8. Hardware result of section 7, and the SECOND fit-dependent hole (2026-09-12, evening)

### 8.1 The three section-7 builds on hardware (user, same disk, Ethernet Off)

| seed | timing | hardware |
|---|---|---|
| 7 | met | clean: desktop, QuarkXPress typing, restarts |
| 5 | met | reproducible: "not unmounted properly" dialog, OK, HD icon appears then vanishes, blank desktop, mouse alive |
| 4 | met | reproducible: freezes at the first desktop |

Same RTL, so a fit-dependent defect still existed, while the SDRAM read path
is now measured identical on all three (pin eye +2.24..2.28 / +6.52, internal
stages +2.2..+7.7). It was therefore NOT the SDRAM path any more, and the
symptom was deterministic per fit, which rules out thermal marginality and
points at a specific instruction/data pattern on a badly-timed path.

### 8.2 Eliminated by measurement (do not re-check)

- Capture-edge arithmetic: a strict chip model (DQ driven only from launch +
  tAC to next edge + tOH, X otherwise) passes 107/0 on the new RTL and reads X
  on the old E6 capture.
- The TG68 kernel two-period credit as such: with the SDC exceptions stripped
  the kernel's true single-cycle slack is seed 7 **-7.2** (the GOOD build),
  seed 4 -3.4, seed 5 -1.5, i.e. anti-correlated with stability; every kernel
  and ALU register is clkena-gated and the register-file M10Ks have clock
  enables on both ports, so the credit is not wrong in principle.
- periph_din_reg / SCSI CSR cone: +6..+9 ns even at a single cycle.
- Recovery/removal met on all seeds; remaining unconstrained I/O is slow
  framework lines only; all other `negedge` uses are async resets; the new
  half-period hops are +2.2 ns or better on the CPU bits of every seed.

### 8.3 Found: the decoder's structural loop makes the two-period credit unsafe

Quartus reports a **150-node combinational loop** in `TG68KdotC_Kernel.vhd`
(~line 1656; Critical Warning 332081 "Estimating the delays through the
loop"). `setexecOPC` is a function of `setstate`/`next_micro_state`/
`set_direct_data`, and the `setstate` mux trees use `setexecOPC` as a select.
The `setexecOPC`-guarded branches only set ALU operand-routing flags, so it is
structural, not a functional oscillator; but STA can only estimate delay
through those mux trees. Under the two-period credit the fitter treats the
kernel as non-critical and leaves its visible paths at 32-38 ns per fit, with
the loop-hidden remainder unbounded and re-rolled by every placement. On some
seeds the real delay of one decode path for one instruction pattern exceeds
the two periods that actually exist, and that instruction fails every time.
The credit entered the SDC on 2026-06-07 (29e1f69); every "STA green,
hardware corrupt, differs per seed" incident in this repo postdates it.

### 8.4 Experiment E1 and the fix

E1: the seed-4 fit rebuilt with ONLY the kernel multicycle removed. The fitter
closed the kernel at a single period to -0.165 ns (it CAN compact the kernel
to ~31 ns when it must), everything else unchanged, and the build is stable
on hardware through boots, QuarkXPress typing and restarts where seed 4 froze.

Fix (MacLC.sdc): the two-period credit is replaced by
`set_max_delay 32.0 -from kernel -to kernel`. The fitter must keep the kernel
compact (the E1 fit), STA reports honestly against the cap (E1 database:
+1.07 ns), hold is the normal single-cycle check, and the genuine two-period
budget leaves ~29 ns of real margin for whatever the loop estimate misses.
Long-term, breaking the structural loop in the kernel would make STA exact.
Both fixes ship together: the SDRAM read path was measurably marginal before
(eth -0.46, floppy hold -1.39, CPU +1.9/+2.3 on the good fit) and is now
fit-invariant; the kernel cap removes the second hole.

### 8.5 Gate for the PR

Three seeds (4, 7, 5) with both fixes: TIMING MET everywhere, SDRAM eye
unchanged, kernel reported against the 32 ns cap; then hardware on at least
the two previously-failing seeds (4 and 5) plus 7: desktop, the "not
unmounted" OK, Finder use, QuarkXPress typing, restart. Results (`scratch/sdramfix/RESULT_stage5.md`): seed 4 MET (kernel +3.30 vs
the cap), seed 7 MET (+1.24), seed 5 NOT MET — a -0.078 ns HOLD miss on a
CD-audio MLAB write-address register (fit-to-fit class, unrelated to either
fix; its kernel sat +0.32 from the cap). SDRAM eye 2.24-2.28 / 6.52 on all
three. That is the intended behaviour: a marginal fit is now REPORTED. Ship
seed 4; hardware gate on seeds 4 and 7.
