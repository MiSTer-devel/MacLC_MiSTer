# RESUME PROMPT — CPU perf mission: Phase C validated offline, HW gate + Speedometer next

Paste this file as the opening prompt of a session in this repo
(`C:\Temp\mistercore\MacLC_MiSTer`, branch **`cpu-enhancements`**). It is the
continuation of `docs/CPU_Improvements_Prompt.md` (the original mission brief)
after the 2026-08-17/18 session. **Read `docs/CPU_Perf_Log.md` first** — it is
the complete engineering log (mechanisms, laws, Pocket-port notes) and the
scoreboard lives in `docs/Speedometer_3-23_Benchmarks.md`.

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

## ★★★ HW GATE RESULT: PHASE C **FAILS** ON HARDWARE — START HERE

Deployed md5 `4fede16981c5b57d515cc2c4560698a3` (commit `4f24246`, STA
+0.573) boots MUCH further than before — POST passes, the Mac OS splash and
"Starting up…" progress bar render correctly, extensions begin loading — then
**bombs: "System Update" / error type 10** (= line-1111 / F-line exception,
i.e. the CPU executed a word that decoded as an F-line opcode). Reproduced
identically after a guest Restart, so it is deterministic, not a dice-roll.
Screenshots: `scratch/phaseC_fixed_hw_boot.png`, `scratch/phaseC_boot_retry.png`.

**An F-line bomb means executed garbage ⇒ memory-content corruption**, not a
hang: some read returned wrong data, or some write landed wrong, and the OS
eventually jumped into it. Crucially, **the same tree boots perfectly in
Verilator** and passes every offline TB — so the defect is HARDWARE-ONLY,
which means TIMING or REFRESH in the demand engine, not logic.

The bisect is already narrow: Phase B (`2791e6a`) is HW-validated and boots
clean to the Finder; everything between it and `4f24246` is the demand
engine. **Do not chase the CLUT/Ariel again — that path is settled.**

### Suspects, ranked, with the test for each

★ The user's read (2026-08-18) is that **the demand engine's interaction
with the MiSTer SDRAM is simply wrong**, which is the classic cause of
F-line-class corruption after an SDRAM change. The analysis below supports
that directly — suspect 1 is a genuine CDC unsoundness, not just tight
timing, and it also explains cleanly why Phase B is fine.

1. **★★★ PRIME: the clk_sys→clk_mem request capture is unsound, and the
   SDC multicycle `b48b60c` hides it.** Derivation: `clk_mem` (65 MHz) is
   exactly 2× `clk_sys` (32.5 MHz) off the same PLL, so every other clk_64
   edge coincides with a clk_sys edge. The ladder counter `t` counts 0..7
   per `clk_8` period and — because 8 clk_64 == 1 clk_8 exactly — never
   stalls in steady state, so `t[0]` selects *alternate* clk_64 edges: EITHER
   all the clk_sys-coincident ones OR all the half-period ones, fixed at
   runtime by where the clk_8 sync landed. Therefore a request launched from
   a clk_sys flop (AS/addr/din/ds/oe/we) is captured by the ACTIVE branch
   either **~0 ns later (coincident case = a straight race)** or **15.4 ns
   later (half-period case)** — never the "≥1 full clk_sys = 30.8 ns" the
   multicycle comment claims. The V8 address translation cone (SIMM
   compare, mirror subtract, mux) into `sd_addr`/`col_q` plausibly exceeds
   15.4 ns on its own. So STA was told to ignore paths that are real.
   **This also explains why Phase B is clean**: it never touched `sdram.v`,
   where the old slot machine sampled at `t == STATE_CMD_START` with the CPU
   holding address/data stable for the WHOLE 4-clk_sys slot (~123 ns of
   margin). Phase C threw that margin away.
   **Fix (structural, not a constraint):** gate `req_cpu` on a clk_sys-domain
   "request has been stable for ≥1 full tick" qualifier — the same shape as
   Phase B's `as_low_q` — so addr/din/ds are provably ≥30.8 ns old before any
   clk_64 edge can capture them; only THEN is the 2-period multicycle honest
   (standard data+valid CDC: data multicycled, valid single-cycle). Costs
   ~1 tick of start latency; the 7-tick read may become 8, still far better
   than the 8–14 baseline. **Test first: delete the two SDC lines and refit
   as-is** — if STA now reports a violation on these paths, the diagnosis is
   confirmed outright.
2. **Write-data capture at ACTIVE is too early.** `din_q <= din` samples the
   kernel's `data_write` through the top-level mux, and Phase B moved the
   write strobes to assert WITH AS (old walker: two ticks later at s3), so
   the engine can now latch write data earlier than any prior design ever
   did. Sim has zero propagation delay and cannot see this. **Test: hold CPU
   write starts one extra clk_sys tick (or capture `din` at CAS from a
   clk_sys-registered copy) and refit.**
3. **Refresh starvation.** Old design: AUTO_REFRESH on every idle slot
   (massively over-provisioned). New: lowest-priority `else if`, blocked by
   `!flp_guard && !flp_win`, with CPU back-off only at `ref_due >= REF_FORCE`
   (480 clk_64 ≈ 7.38 µs) vs the chip's ~7.8 µs tREF average — **thin**, and
   the floppy keep-out can push it later. ★ The GCR encoder FREE-RUNS with no
   disk mounted (CLAUDE.md: "byte_cnt churns on garbage"), so floppy windows
   and their guard fire continuously during a normal SCSI boot — exactly the
   workload that bombed. **Test: drop REF_FORCE to ~380 and REF_OPP to ~200,
   and/or give refresh priority over `req_flp` when `ref_due` is high.**
   Corruption-after-seconds-of-heavy-IO is the signature of marginal refresh.

Bisect cheaply by reverting one thing at a time — each fit is ~20 min. A
faster discriminator for #3 alone: boot with the floppy encoder quiesced
(no floppy image mounted AND `flp_pend_*` forced 0 in a probe fit); if the
bomb disappears, it is refresh/guard interaction.

### On trying other SEEDS for Phase C

**Not tried — both Phase-C fits were seed 7 only.** Worth running as a
DIAGNOSTIC, not as a fix:
- If another seed (5, 6, 3) bombs *identically* at "System Update" error 10,
  that is strong evidence of a **systematic** protocol/CDC error (suspect 1),
  because placement luck would not reproduce the same failure point.
- If different seeds fail differently or one boots, that says **marginal
  timing** — which points at the same unsound-constraint root cause anyway.

★ **Do not accept a passing seed as the fix.** With the multicycle in place
STA is not even checking the suspect paths, so a "good" seed would be a
placement that happens to meet a path nobody is verifying — latent
corruption shipped, and exactly the trap this repo's per-seed gating law
exists to catch. Fix the constraint/structure first, THEN gate seeds.

## What happens next (in order)

0. **Fix the F-line bomb above.** Nothing below is meaningful until Phase C
   boots clean on hardware. If you need a shippable core in the meantime,
   Phase B (`2791e6a`) is HW-validated and already carries a real win.
1. **HW boot gate on the fixed build**: guest boots from SCSI to the Finder.
   One boot is never a verdict; CD `MACLC.s4` stays ATTACHED (retry, don't
   detach).
2. **★ THE CLOCK CHECK — do not skip.** On the booted Finder, screenshot
   (`bash scripts/grab_fresh.sh scratch/clk1.png`), wait ≥3 min, screenshot
   again: the menubar clock MUST advance. A frozen clock was observed once on
   the Phase-B HW boot (cursor alive, clock stuck) and is still UNEXPLAINED —
   it may be pre-existing (verify against the 08-15 release build
   `releases/MacLC_20260815.rbf`) or a Phase-B/C regression. Timer-class
   breakage skews every self-timed benchmark (see the system-tick-halved
   lore), so this must be settled before trusting Speedometer numbers.
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
