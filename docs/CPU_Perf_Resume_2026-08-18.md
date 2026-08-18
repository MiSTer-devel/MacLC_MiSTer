# RESUME PROMPT — CPU perf mission: Phase B+C SHIPPED (+10.7%), I-cache is next

Paste this file as the opening prompt of a session in this repo
(`C:\Temp\mistercore\MacLC_MiSTer`, branch **`cpu-phase-c-fix`**). It is the
continuation of `docs/CPU_Improvements_Prompt.md` (the original mission brief)
after the 2026-08-17/18 session. **Read `docs/CPU_Perf_Log.md` first** — it is
the complete engineering log (mechanisms, laws, Pocket-port notes) and the
scoreboard lives in `docs/Speedometer_3-23_Benchmarks.md`.

Jump to **"STATUS: PHASE C SHIPPED"** and **"THE REMAINING LADDER"** below;
the sections before them are the historical record of how the bug was found
(kept because the METHOD — STA-probing a post-fit netlist instead of trusting
a constraint — is the transferable lesson).

## Where the mission stands

The ~1.33x gap's root cause was confirmed and FIXED: the core ran a
68000-style slot-quantized bus cycle (locked ≥8 clk_sys per memory access).
Three commits rebuilt the memory path:

| landed | commit | what |
|---|---|---|
| Phase B | `2791e6a` | collapsed bus FSM (S_IDLE/WAIT/TAIL1/TAIL2/ENDC), every-tick DTACK sampling, VPA/E tail identical. HW-booted to Finder, STA +0.216. |
| Phase C | `f13d936` | demand-start SDRAM engine: reads **7.00 ticks flat** (100.0% at len 7), posted writes **6.00**, **+25.4% CPU cycles/sec**, VPA cycles 62→36 avg (the 8-tick grid was resonant with the 40-tick E period — free peripheral speedup). Floppy windows keep exact old slot timing, pending-gated; explicit refresh. |
| fix 1 | `c7291b3` | oe = pure CPU intent (floppy windows held cpu_done across AS gaps → stale-read instant-acks + lost vram_we strobes) |
| SDC | `b48b60c` | clk_sys→sequencer request multicycle (t[0]-parity-justified), STA **+0.521** |
| fix 2 | `4f24246` | **terminate ROM-region WRITES** (ack-and-discard via dtack_en) — the magenta boot stall: the ROM's device probe byte-writes into ROM space behind a temp vector-$8 handler; the demand engine never served it (no oe/we) and nothing else terminated the cycle |

**Offline gates: ALL GREEN** on the final tree: tb_scsi_pf, tb_scc_midi,
tb_mfm_idcensus, tb_gcr_read (+acclen=40 at pollgap=40 AND tightened
pollgap=28 modeling the faster CPU), tb_ism_sony, tb_disk_swap,
check_boot.sh, and the full-boot sim gate — frame 450 on the deterministic
?-icon path = grey dither desktop + cursor + flashing-? icon in correct B/W.

**Final fit** (commit `4f24246`, seed 7): fill in from
`output_files/MacLC.fit.summary` / this session's close-out — deployed to the
bench MiSTer as canonical `MacLC.rbf`; md5 in the session close-out below.

## MAME verification status (read this before trusting the fixes)

Per CLAUDE.md the standing rule is to diff misbehaviour against MAME's
`maclc`. What was actually checked, precisely:

**Checked against MAME source (`~/repos/mame` in WSL):**
- **Ariel RAMDAC semantics** — `src/devices/video/ariel.cpp`: `address_r()`
  (resets `m_address_rgb`), `palette_r()` (advances the RGB phase mod 3 and
  bumps `m_address` on wrap), `palette_w()`, `control_r/w`, `key_color_r/w`.
  Our `rtl/ariel_ramdac.sv` matches exactly — ONE shared address + RGB-phase
  counter, reads auto-advance. This is what ruled the CLUT model OUT as the
  magenta cause and reframed the RD/WR pairs as legitimate RMW instruction
  halves.
- **ROM-region writes (fix 2's premise)** — `src/mame/apple/maclc.cpp`:
  `map(0xa00000, 0xffffff).m(m_v8, v8_device::map)`; `src/mame/apple/v8.cpp`:
  `map(0x000000, 0x0fffff).r(FUNC(v8_device::rom_switch_r))` — a **`.r()`
  read-only handler with NO write handler**. The hang address $A6C3D5 maps to
  V8 internal $06C3D5, inside that range. In MAME an unmapped write is logged
  and DISCARDED with no bus error ⇒ **ack-and-discard is MAME-correct**, which
  is exactly what the fix implements. ★ Caveat on process: this check was run
  AFTER the fix was written and committed, prompted by the user asking. The
  fix's original justification was "restore what the old slot glue did, which
  was HW-validated for months" — sound, but not ground truth. It happened to
  be right; check the map FIRST next time.

**Not MAME-checkable / verified other ways:**
- **Fix 1 (oe-bridge stale `cpu_done`)** — a defect in RTL written this
  session; the memory controller is ours, MAME has no counterpart.
- **Bus-cycle timing (7-tick reads / 6-tick writes)** — MAME is not
  cycle-accurate here; measured with the `bus_hist` rig instead.
- **"The shredded 2-entry CLUT patch is transient/normal"** — verified
  DIFFERENTIALLY against our own Phase-B known-good build (worktree
  `../maclc-pb`): byte-identical RD/WR interleave, then recovery ~32 frames
  later. For this question the same-RTL/same-ROM known-good build is a
  stronger oracle than MAME.

**Never run:** MAME itself was not executed this session (no `run_mame.sh`,
no tap.lua/trace.dbg captures) — all MAME work was source reading.

**MAME checks worth running next session:**
1. The frozen-clock question (item 2 below): boot MAME `maclc` to the desktop
   and watch VIA1 CA1/CA2 tick delivery vs ours (`verilator/mame/` rig,
   `docs/mame_compare.md`). Cheaper first step is the build A/B in item 2.
2. If Speedometer still trails after Phase C: MAME won't arbitrate cycle
   counts, but `tap`-style memory traces can confirm access PATTERNS
   (e.g. whether the guest issues the RMW traffic we think it does).

## ★ STATUS: PHASE C SHIPPED AND MEASURED (2026-08-18)

**Released as `releases/MacLC_20260817.rbf`** (md5
`b9ed35136d5ef2994589d6a77bb64088`, seed 4, STA met +0.149 ns, branch
`cpu-phase-c-fix`, not pushed — the user pushes unstables themselves).

| Suite | Baseline | Phase B | **Phase B+C** | vs baseline | share of a real Mac LC |
|:--|--:|--:|--:|--:|--:|
| Benchmark Mix | 2.771 | 2.756 | **3.067** | **+10.7%** | 74.9% → **82.8%** |
| Color Benchmarks | 0.937 | 0.935 | **1.030** | **+9.9%** | 75.0% → **82.5%** |

Every test improved (+6.6% to +17.5%); predicted +12% from the histogram,
measured +11.3%. Dhrystones (109.5%) and Towers (106.8%) now beat a physical
Mac LC. The F-line bomb was root-caused by STA (a -6.710 ns half-settled SDRAM
address) and fixed structurally — full forensics in `docs/CPU_Perf_Log.md`
entry 4. **Do not re-add a multicycle on the SDRAM request paths.**

## ★ THE REMAINING LADDER, RE-PRIORITISED BY THE MEASURED DATA

The residual gap is no longer uniform — the per-test shares say exactly where
it lives:

| where the core still trails | share of a real LC | the cause |
|:--|--:|:--|
| Sieve / Queens / Bubble / Puzzle | 54-77% | **no I-cache** (tight loops fit a 68020's 256 B cache) |
| QuickDraw colour suite | ~82% | VRAM reads still round-trip SDRAM |
| Floating point (Whet/FFT/FPM) | ~95% | essentially parity — nothing to win |
| Dhrystones / Towers | 107-110% | already faster than the real machine |

**1. I-CACHE — now the single dominant item.** Branch `i-cache` @ `b393eaf`
already has `rtl/fetch_cache.sv` (1 KB direct-mapped, write snoop + generation
flush, OSD-gated but always filling so one build gives a live A/B) plus
`docs/resume_icache_corruption_2026-07-07.md`. Shadow-measured 87.7% hit at
256 B / 96.0% at 1 KB. Parked on disk corruption with the cache ON + a mono
regression. ★ Two things changed that make it far more tractable now:
  - The parked doc's prime suspect was "the combinational DTACK join being
    STA-met-but-HW-marginal". After what Phase C just taught us, that suspicion
    is much more credible — and `scratch/sta_sdram_probe.tcl` is the ready-made
    tool to check it (point it at the cache's keepers instead).
  - It must be re-evaluated against the NEW 8-tick-flat path, not the old 8-14
    tick one: a hit is worth less than it was, so re-measure before assuming
    the old projections hold.

**2. Phase D — CPU VRAM reads from `vram_bram` port A.** `a_dout` is still
unused (`rtl/vram_bram.sv:31-32` says "reserved for a later phase"), and
`addrController_top.v:200-222` routes `selectVRAM` reads to the SDRAM shadow at
word `0x580000`. The histogram shows VRAM reads are **20-38% of desktop bus
traffic**, all currently paying the full 8-tick SDRAM path when they could be
served from on-chip BRAM in ~5-6. Zero M10K cost (the port exists). This is the
cheap, well-scoped win and it targets the colour suite directly.

**3. Phase C2 — recover the lost tick (8 → 7).** The pipeline stage that fixed
the timing costs one clk_sys per access. Recovering it means translating the
address speculatively from the kernel's combinational `tg68_addr` and
registering THAT, so the translated address is valid at the same edge AS
asserts. Worth roughly another +10% (the broken 7-tick build ran 4.44 M
cycles/s vs 3.59 M at 8 ticks). Risk: the kernel's own output cone is long, so
prove it with STA before believing it — and never with a multicycle.

**4. SCSI read ring 16 KB → 32 KB — still "measure first", still low
priority.** `RING_LOG = 5` (`rtl/scsi.v:129`). Buys burst absorption, not
bandwidth, so it will not move Speedometer. The blocker comment's M10K maths is
stale (the mirror RAMs were deleted in the 2026-07-17 redesign); re-derive
before trusting it, and watch `dbg_ring` first to see if the ring is even
starved.

**5. Refresh margin (a latent risk this mission introduced).** `REF_FORCE` =
480 clk_64 ≈ 7.38 µs against the chip's ~7.8 µs tREF average, with refresh as
the lowest-priority branch and blocked inside the floppy guard zone. It is
inside spec today and the hardware is stable, but the margin is thin by design.
Consider lowering `REF_OPP`/`REF_FORCE` or letting refresh pre-empt `req_flp`
when `ref_due` is high.

**Explicitly ruled out — do not revisit:** more framebuffer BRAM (already
384 KB, video reads are single-cycle on port B), the DDR3 video channel
(superseded, and DDR3 is broken on this core), porting the MacIIvi 68030 cache
subsystem (bolted to the 030 kernel), and "video is slow" theories (both suites
track each other to within 0.3 points).

## Validation debt on the shipped build

Passed: clean boot to the 7.5.5 Finder with colour icons, full Speedometer run,
all offline TBs (tb_gcr_read at standard AND tightened pollgap, tb_mfm_idcensus,
tb_ism_sony, tb_disk_swap, tb_scsi_pf, tb_scc_midi, check_boot, full-boot sim
gate), STA clean with no masking constraints.
**Still owed:** multi-boot Finder soak (one boot is never a verdict),
floppy/SCSI/CD hardware regression pass.

## What happens next (in order)

0. **Fix the F-line bomb above.** Nothing below is meaningful until Phase C
   boots clean on hardware. If you need a shippable core in the meantime,
   Phase B (`2791e6a`) is HW-validated and already carries a real win.
1. **HW boot gate on the fixed build**: guest boots from SCSI to the Finder.
   One boot is never a verdict; CD `MACLC.s4` stays ATTACHED (retry, don't
   detach).
2. **★ THE CLOCK CHECK — MEASURED 2026-08-18, IT IS FROZEN.** On the
   redeployed Phase-B build (boots clean to the 7.5.5 desktop, colour icons
   fine, cursor alive) the menubar clock read **6:37 AM in two screenshots
   taken ~4 minutes apart** (`scratch/phaseB_redeploy_boot.png`,
   `scratch/phaseB_clock_t2.png`; captures verified fresh by filename
   timestamp). So the freeze is NOT Phase-C-specific and is reproducible.

   **What it probably is — and why it probably does NOT invalidate
   Speedometer:** the Mac's time-of-day advances off the **1 Hz** path
   (`onesec = (tickCount == 59)` → VIA1 **CA2**, `rtl/dataController_top.sv`
   ~line 707), while `TickCount`/Time Manager — what Speedometer and every
   self-timed benchmark use — runs off the **60 Hz** path (`tick_60hz` →
   VIA1 **CA1**, same block). Those are separate signals off the same
   counter, so a dead 1 Hz clock with a healthy 60 Hz tick is entirely
   possible (and the boot completing at sane speed argues the 60 Hz tick is
   alive). Note `onesec` is a LEVEL that is high for one whole 60 Hz tick
   period (~16.7 ms) once per second, not a pulse — check how VIA CA2 edge
   detection and the PCR mode the OS programs interact with that.

   **Do these, in order:**
   a. A/B against the shipped release: deploy `releases/MacLC_20260815.rbf`
      and repeat the two-screenshot check. Frozen there too ⇒ **pre-existing**,
      unrelated to this mission (log it and move on). Advancing there ⇒ a
      **Phase-B regression**, and the suspect is the FSM's changed AS/VMA
      timing feeding the VIA's E-paced register access.
   b. Either way, confirm the 60 Hz tick independently before trusting
      benchmark numbers — e.g. time a known-duration operation in the guest
      against a wall clock, or compare a Speedometer run's absolute times
      against the 2026-08-17 baseline row (which was captured on the 08-15
      release, i.e. under whatever clock behaviour that build has).
3. **Speedometer 3.23 run** (the user runs it; bench guest 7.5.5 at 640x480,
   10 MB — same config as the scoreboard's core row). Add a new row to
   `docs/Speedometer_3-23_Benchmarks.md` labeled with commit `4f24246` and
   the RBF md5. Projection from the sim histograms: CPU mix ~3.4-3.5
   (from 2.771; real LC = 3.702), QuickDraw suite proportionally better
   (VRAM writes −41%, reads −26% vs Phase B).
4. **Regression sweep on HW while it's up**: floppy read (the GCR/MFM paths
   ride changed CPU pacing — offline TBs passed incl. tighter pollgap, but
   the HW law stands), SCSI copy, CD mount, serial if convenient.
5. **Phase C2 (optional, if Speedometer still trails)**: speculative ACTIVE
   start from the kernel's registered address the tick before AS (read
   period 7 → 6). Design sketch in the 08-17 session notes; the demand
   engine + t[0] parity make it a contained change in rtl/sdram.v.
6. **Phase D**: CPU VRAM *reads* from vram_bram port A (immediate-DTACK
   class, ~7 → ~5-6 ticks on 30-38% of desktop traffic). Ladder item 4.
7. **Release**: when HW-validated + Speedometer recorded, stamp
   `releases/MacLC_YYYYMMDD.rbf` per repo convention (USE_DBG_HUD stays OFF).
8. **Pocket port**: `docs/CPU_Perf_Log.md` is written as the port document —
   every entry marks core-RTL vs top-glue and carries the two hard-won laws:
   (a) a request-done handshake must key on the requester's OWN level, never
   a shared mux; (b) every access class the engine does NOT serve must still
   be terminated (ack-and-discard or BERR) — ROM writes are the classic.

## Standing laws (unchanged)

- `sys/` OFF-LIMITS. Both tops in sync (`MacLC.sv` ⇄ `verilator/sim.v`).
- Per-seed HW video+boot gate is law; STA-met is not enough. Seed 7 current.
- Deploy canonical `MacLC.rbf` only; verify coreRunning + md5 before verdicts.
- Never hard-reload a running guest — Special ▸ Shut Down choreography first
  (proven recipe in memory `mister-guest-clean-shutdown-mouse`).
- Scratch in `scratch/`, never repo root. Commit per build.
- SDC invariants: kernel clkena ≥2 clk_sys apart; tg68_din_r register
  boundary; the new sdram request multicycle is justified ONLY while CPU
  starts stay t[0]-parity-gated — re-verify if that gate ever changes.

## Sim environment notes (this session's hard lessons)

- `verilator/sim_ram.v` mem[] is deterministically FFFF-filled: Verilator's
  `--x-initial fast` gives per-BUILD patterns, and the ROM's video/boot probe
  reads unwritten memory — a mere added $display used to flip which boot
  branch ran. FFFF pins the ?-icon probe branch (the harder one; boot gate =
  dither + cursor + ?-icon at 450).
- The Ariel/PVIA register traces are behind `+define+ARIEL_TRACE`; the
  tg68k bus-hang watchdog (S_WAIT > 20000 ticks names the address) and the
  bus_hist instrumentation stay on under SIMULATION.
- `verilator/bus_hist.log` + `scripts/bus_hist_report.py` = the cycle-length
  measurement rig; baselines archived in `scratch/bus_hist_{baseline,phaseB,
  phaseC}.log`.
- WSL runs sanctioned; screenshots DO fire headless (drvfs mtime/content
  caching lies — verify freshness by content, not ls). Never `pkill -f` with
  a substring of your own command chain.
- A `git worktree` of Phase B lives at `../maclc-pb` (delete with
  `git worktree remove ../maclc-pb --force` when no longer needed for A/B).

## Session close-out (2026-08-18)

- **Final fit** (commit `4f24246`, seed 7): Fitter **Successful**, STA **met,
  worst slack +0.573 ns**, RBF md5 **`4fede16981c5b57d515cc2c4560698a3`**.
  ★ Quartus 17.0 threw a mid-fit **Access Violation** on the first attempt and
  left the PREVIOUS fit's RBF on disk with hung `quartus_fit.exe` processes —
  always check `output_files/MacLC.rbf` mtime against the build log before
  deploying, and `taskkill` the strays before relaunching.
- **Deployed** to the bench as canonical `MacLC.rbf` — see the deploy log for
  md5-verified push + `coreRunning='MACLC'`.
- **HW boot gate: recorded below by the deploying session.** If it is blank,
  the gate did NOT complete — re-run it first thing (boot, screenshot via
  `scripts/grab_fresh.sh`, then the clock check in item 2).
- Pre-deploy box state was the hung pre-fix Phase-C build (equal-count colour
  bars = Ariel init palette, no OS running), so the reboot-based deploy was
  safe without a guest shutdown.
