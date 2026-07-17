# RESUME: CD Audio RTL — fit saga state & continuation (2026-07-16 night)

Branch: `add-cd-audio` @ `7266985` (pushed). Working tree clean except
possibly `MacLC.qsf` line-ending noise (`git diff` empty = ignore/checkout).

## Where this stands

The CD-audio engine is **code-complete, gates-green, and committed**:
`rtl/cd_audio.sv` (AppleCD audio ops byte-matched to MAME `nscsi_cdrom_apple`,
TOC-blob consumption, frame streaming, 44.1 kHz mixer feed), integrated inside
`scsi.v`'s CDROM target; sound plumbed scsi→ncr5380→dataController→MacLC.sv
mixer (cd/2 saturating). Sim boot regression PASS; A&E and Verilator parse
clean at every commit. HPS side (TOC blob + audio windows) has been deployed
on .143 since afternoon (Main fork `f38b189`, binary md5 aa81f386).

**The fit saga (all committed, each message has the details):**
1. First fits: LAB overflow (4833/4191) — root cause = Quartus 17's silent
   small-RAM register-fabric fallback. THREE victims found & fixed with
   vram_bram's forced-M10K recipe (`(* ramstyle = "M10K,no_rw_check" *)` +
   split write/read always blocks):
   - `cd_audio` 0xC1 response planes (eadc802..8f29c6d)
   - June's Toolbox `tb_buf0/1` — 2.6K LUTs of debt (eadc802)
   - **ASC FIFO A — ~8K regs + 3.8K LUTs** (76abb57; timing-safe, 1460-clk slack)
   Net: design comb 55.0K → 48.6K, BELOW the pre-audio baseline.
2. Resource fit then passed but ROUTING failed (16618) at seed 4; seed 1 ran
   95 min without concluding (not hung — 2.4 cores busy; capped/killed).
3. **Decisive attempt (7266985): 20-bit disc addressing (cuts real wire
   demand; CD ≤ ~360k frames) + FITTER_AGGRESSIVE_ROUTABILITY_OPTIMIZATION
   ALWAYS + SEED 5 → THE FITTER ROUTED, "Successful - Thu Jul 16 21:15:27".**
   The session teardown killed the flow after fitting, before STA/ASM.

## Final state of 2026-07-16 night (VERIFIED)

STA + ASM completed on the surviving seed-5 fit at 21:31:

- **Routing: SOLVED.** The 7266985 recipe (20-bit narrowing + aggressive
  routability + seed) routes. Ignored-Assignments checked: only the two
  perennial framework items (HDMI fast-out reg, PLL merge) — the aggressive
  flag IS honored.
- **Per-clock setup slack:** `clk_sys` **+1.053** (the entire Mac core incl.
  cd_audio closes with real margin — the engine is timing-clean);
  **pll_hdmi −1.521, TNS −75.5** ← the ONLY violation, the historical
  scaler-noise domain. The routability trade was paid entirely by ascal.
- `output_files/MacLC.rbf` @21:31 (4,616,656 B) = seed-5 artifact:
  **DO NOT DEPLOY** (violated domain drives HDMI pixels; July-12 law).
- **SEED 6 sweep with identical config launched ~21:45**
  (`scratch/build_cdaudio_seed6.log`). Interpretation: routing should
  repeat; only the pll_hdmi slack is rolling. MET → stage
  `scratch/MacLC_CDAUDIO_20260716_<hash>s6a.rbf`, deploy, display check,
  audio test below. Still violated → seeds 7/8; if three seeds all land
  ≥ −1 ns on pll_hdmi only, next lever is scaler-side: reduce ascal load
  (OSD scaler options) is user-visible — prefer instead trying
  aggressive-routability=AUTOMATICALLY (less brutal than ALWAYS) which may
  rebalance the trade, or constrain-relax analysis of the exact failing
  ascal paths (they historically include margin-y multicycle candidates).

## HW audio test protocol (once display-checked)

Guest needs: a mixed-mode disc (cue/bin or chd WITH audio tracks) in
`games/MacLC/`, AppleCD Audio Player or CD Remote on the System. Then:
1. Data regression first: mount the known-good CHD; volume mounts, files copy.
2. Insert the mixed-mode disc; launch the audio player: TOC shows the track
   list (proves blob path); PLAY → **music from the MiSTer audio out**;
   pitch correct (verifies CLK_HZ=32.5MHz cadence constant); pause/resume,
   track skip (SEARCH), stop.
3. Position display advances ≈1 s/s (STATUS/SUBQ live registers).
4. Stress: play audio WHILE copying files CD→HDD and HDD-heavy I/O
   (the #2/#3 wedge interleaving surface; watch for stalls).
5. Boot chime + POP audio still fine (ASC FIFO conversion regression).

## Environment gotchas rediscovered tonight

- Process probes: `tasklist //FI` from git-bash and `tasklist.exe` from WSL
  both FALSE-NEGATIVE on quartus processes. Use
  `powershell Get-Process quartus* | Select Name,Id,CPU,StartTime`.
  CPU accumulating = working, not hung (seed-1 burned 120 CPU-min honestly).
- build_only.sh writes its BUILD STATUS block only at flow end; mid-flow the
  scratch log lags MINUTES behind (Quartus buffering). fit.rpt/sta logs are
  the truth.
- Long fits under aggressive routability are NORMAL here now (~40 min).
  The background-task 90-min timeout is the backstop.

## Context pointers

- Plan/architecture: `docs/plan_cd_audio_rtl.md`; HPS contract in
  `Main_MiSTer/support/maclc/maclc_cd.h` (branch add-bluescsi-toolbox-for-MacLC).
- Memory: `cdrom-scsi3-mission` (CD state incl. INQUIRY law),
  `quartus-cli-rtl-validation` (the BRAM-inference recipe + map-before-fit
  workflow — READ THIS before touching any RAM in this repo).
- The fabric elephants deliberately NOT touched (async-read, subsystem-sacred):
  egret_wrapper rom (~2-3K, HC05 timing), ariel palette (pixel path),
  adb kbdFifo (tiny). Future capacity, each its own careful mission.
- Everything else of 2026-07-16 is merged to master and HW-validated:
  CD-ROM full format matrix, PRAM boot fix, path law, real .nvr seed.
