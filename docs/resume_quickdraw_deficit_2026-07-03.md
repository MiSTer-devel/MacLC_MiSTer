# Resume — QuickDraw deficit hunt + pixel clock + floppy (2026-07-03 PM)

You are picking up MacLC_MiSTer after the **System-Tick root-cause session**. The
in-game slowdown mission is RESOLVED at the correctness level; what remains is a
quantified performance-fidelity gap, the queued pixel-clock fix, and the untouched
floppy investigation. **Read this whole doc first.** Predecessor doc (floppy
details + hardware crib): `docs/resume_floppy_and_video_2026-07-03.md` — its
Investigation A section is still the floppy source of truth; its Investigation B
is SUPERSEDED by this doc.

- **Branch:** `new-disk-features` @ `094ae86`. Nothing pushed; the user pushes.
  Today's commits: `41b97f0` (PBL bus-latency meter probes + buslat.tcl),
  `a937c4c` (★ the System Tick fix), `a48c5ea` (PBH latency histogram +
  bushist.tcl), `094ae86` (buslat.tcl signature fallback).
- Build/gate flow unchanged: A&E gate (`quartus_map --analysis_and_elaboration
  MacLC`, ~1 min, 0 err/64 warn baseline) → `bash scripts/build_only.sh`
  (~21 min) → SCSI gate (`quartus_sta -t scripts/check_scsi_timing.tcl`, PASS
  ≥ +0.5 ns; running ~+27.6 ns). `MacLC.qsf` shows modified — leave it.

## ★ WHAT WAS FIXED (validated on HW — do not re-derive)

**The System Tick ran at HALF rate.** `dataController_top.sv` toggled VIA1 CA1
once per full 60.15 Hz period; CA1 interrupts on one edge polarity → the ROM's
tick ISR (Ticks++) ran at 30.075 Hz. POP paces frames via a `_TickCount` compare
loop (caught live: PC $26A8, opcode A975, PIFD sampling) → games ran ~half-ish
speed with tick-quantization effects. Fix `a937c4c`: half-period toggle (67,539
clk8 enables) + `onesec`/CA2 re-derived from the same fixed tick (was counting 60
mode-dependent video vblanks = 1.55 s "seconds" in VGA). **HW-validated:** POP
near-proper speed, caret blink matches the user's physical LC, core snappier.

**Corollary (memorize):** Speedometer/TattleTech time themselves WITH Ticks —
every pre-fix benchmark comparison was inflated 2×. "Core 1.5× faster than a
real LC" was fiction. Sanity-check any guest-timed benchmark against the
menu-bar clock vs wall time first.

## INVESTIGATION B′ — QuickDraw deficit (~23%) — ACTIVE, mid-measurement

**True fidelity, matched conditions** (same 7.1 image, 512×384/256c, honest
tick; user's PHYSICAL Mac LC vs core):

| Test | Real LC | Core | Core speed |
|---|---|---|---|
| Mono | 28.750 s | 37.750 s | 0.76× |
| 2-bit | 31.783 s | 41.633 s | 0.76× |
| 4-bit | 35.133 s | 45.067 s | 0.78× |
| 8-bit | 42.300 s | 53.600 s | 0.79× |

Core ≈ 0.97× a Mac II; real LC ≈ 1.25×. Deficit narrows slightly with depth
(our scanout is BRAM-fed/free; real LC's VRAM arbitration worsens with depth).
POP's residual "spike-moment" hitches (3rd screen, spikes appearing while
jumping) are this same deficit surfacing in bursts.

**Measured facts (PBL meter + PBH histogram, this session):**
- Idle Finder: bus occupancy 65%, fetches = 78% of accesses / 82% of bus time.
  POP gameplay (pre-tick-fix): occupancy 65%, latencies normal → was wait-bound.
- **DTACK-cycle histogram (idle):** mode = **5 clk_sys (153.8 ns) at 82%**,
  0% at ≤4 and 6, ~5.5% at 7, ~11-12% at ≥9. Same shape for fetch and data.
- ⇒ **Per-access floor (5 clk = 153.8 ns) BEATS a real '020 3-clock bus cycle
  (187.5 ns).** The memory path per-access is NOT the deficit.
- ⇒ **No fat wait tail:** everything above mode ≈ 12% of bus time ≈ 4-5% of
  wall. **DTACK wait-trimming is a DEAD END — do not spend RTL there.**

**The decisive pending capture (user was away):** Speedometer Color Benchmarks
running (~3 iterations) while sampling `bushist.tcl 15` + `buslat.tcl 15`
mid-draw. Decision rule:
- Occupancy ~95-100% while drawing → bus-bound → **instruction prefetch/cache
  in front of TG68K** is the fix with a real ceiling (fetch volume is the tax;
  a real '020 runs hot loops from its 256 B I-cache, freeing the bus for data).
- Occupancy ~70% while drawing → limiter is TG68K's internal per-instruction
  timing vs the '020 pipeline → different conversation (kernel-level work;
  check TG68K 020-mode cycle counts vs real '020 before designing anything).

**Next candidate after measurement:** the ≥9-clk tail (~12% of bus time) is
worth ONE look (suspects: 4th-slot exclusion during SCSI/dio windows, refresh
collisions) but its ceiling is small; the fetch-volume path is the main event.

## Queued — pixel-clock fix (display correctness, NOT game speed anymore)

VGA mode still scans out at 16.25 MHz → 38.7 Hz refresh (12" RGB ≈ 62.4 Hz,
close to correct). Game TIME BASE no longer depends on it (tick fix), but
motion smoothness and anything truly VBL-synced still do. Design notes: add a
true 25.175 MHz (VGA) / 15.667 MHz (12") pixel domain; CPU/SDRAM stay on
clk_sys; only scanout+sync cross (the BRAM line buffer makes the CDC
tractable). `maclc_v8_video.sv` timing tables are per-mode correct (640×407 @
12", 800×525 @ VGA). LC II repo has NOTHING portable for this (checked).
`onesec`/ticks must NOT be re-tied to vblank when this lands.

## INVESTIGATION A — Floppy 800K GCR (untouched today)

Source of truth: predecessor doc §Investigation A + 
`docs/findings_mame_floppy_groundtruth_2026-07-02.md`. NOTE: the expected
`docs/findings_gcr_encoder_diff_2026-07-03.md` from a "background agent" NEVER
LANDED (no such agent survives sessions — treat that as a to-do, not a
deliverable). Prime suspect stands: track→image-offset math ignoring 800K
zoned recording (12/11/10/9/8 sectors/track). Build 2 (ISM 1.44MB engine) spec
lives in the predecessor doc.

## HARDWARE STATE (as of handoff)

- **`.143`** (JTAG box): running `MacLC_Unstable_20260703_a48c5ea.rbf` — tick
  fix + full probe deck (PBL0-6, PBH0, PADR/PSTA/PIFA/PIFD/PDRD, PRC0 trail,
  SCSI deck). 7.5.5 desktop up. `s0=MacLC_7-5-5.hda`, `s1=MacLC_6-0-8-POP.hda`.
  Older RBFs renamed `*.disabled`. s0 backups: `MACLC.s0.bak_755_20260703`,
  `MACLC.s0.bak_71_20260702`. The user remounts images via OSD (updates s0) —
  verify current mount at resume. **Fit caution: worst slack +0.043 ns** (gates
  green, boot clean; if HW gets flaky → seed-bump rebuild FIRST, see
  `[[scsi-fit-stabilization-mission]]` playbook).
- **`.188`**: STILL on pre-fix `MacLC_Unstable_20260702_3a46a80.rbf` (halved
  tick!) with `MacLC_7-0-1.hda`. Deploy the tick-fix build there when its turn
  comes, and RESTORE its color s0 (`MACLC.s0.bak_fullcolor_0702`) when testing
  concludes.
- **★ `MacLC_6-0-8-POP.hda` is SOURED as a boot disk** (mounted through 2 HPS
  crashes; boots → happy-mac reboot loop, boot_inits=208 on a KNOWN-GOOD build
  was the tell). Use as s1 DATA volume only. NO .zip fixture exists — ask the
  user to zip a good POP disk for refresh_disks.sh.
- **`.143` HPS died twice this session** (ssh+HTTP dead, JTAG alive; guest
  SCSI wedges when HPS dies mid-mount). Physical power-cycle only (user). Go
  LIGHT: batch ssh, minimal screenshot polling; JTAG is free (bypasses HPS).

## TOOLING CRIB (new this session)

- `quartus_stp_tcl -t scripts/buslat.tcl [secs]` — avg fetch/data/VPA latency,
  rates, occupancy, fetch share. `scripts/bushist.tcl [secs]` — the 12-bucket
  latency histogram (PBH0 = ONE probe instance, 4-bit source selects bucket).
- **ISSP quirks:** ~39-node hub → instance NAME table often reads corrupted;
  buslat/bushist auto-locate PBL0 by clk-rate signature (32.5M ticks/s). PBH0's
  "+7 from PBL0" fallback proved WRONG (hub indexed PBH0 BEFORE PBL0 this fit)
  — trust names when present, else harden the fallback (verify via bucket-sum ≈
  ΔPBL1 cross-check, printed as "histogram/PBL match %"). Counter reads can
  TEAR (~1 in 5): sanity-check (occupancy ≤ 100%, match % ≈ 100) and resample.
  **"No ISSP instances" / all-FFFFFFFF reads = the MENU core (or a foreign
  core) is loaded, not ours** — check before debugging "hub corruption".
- 16-bit `bl_vpa_cnt` wraps in long windows → apparent avg-vpa > 255 clk is
  the wrap artifact, not a stall (255 = bl_cur saturation bound).
- Launcher: `--push FILE --core BASENAME --delay 0.3 --max-tries 3`; on a
  fresh menu boot keys can be eaten (it launched AO486 once — it self-reports
  MISS via coreRunning). ONE launchable MacLC rbf per box, hash-named, always.
- Guest keyboard over ws: `ws://<ip>:8182/api/ws`, send `kbd:confirm` (Return)
  — used to dismiss the 6.0.8 disk's MacPPP "Insufficient memory!" alert.

## IMMEDIATE NEXT ACTION

User runs Speedometer Color Benchmarks (~3 iterations) on `.143`; capture
mid-draw: `bushist.tcl 15` then `buslat.tcl 15` (occupancy is the verdict
number). Then pick the deficit path per the decision rule above. After that:
pixel-clock fix, then floppy A (or per user priority).

Memory: `[[system-tick-halved-rootcause]]` (this session's core findings),
`[[scsi-fit-stabilization-mission]]`, `[[shared-mister-hps-exhaustion]]`,
`[[second-mister-188]]`, `[[quartus-cli-rtl-validation]]`.
