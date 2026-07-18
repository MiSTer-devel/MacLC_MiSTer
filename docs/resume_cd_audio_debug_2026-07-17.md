# RESUME: CD-audio HW debug day — 7 fixes probe-proven; OPEN no-CD hang on the tip (2026-07-17 ~21:30)

Branch: `add-cd-audio` @ `bd6b2be`-era (see `git log`; last deployed tip build
= `f5a3dec`, eject-guard build compiled from the commit after it — staged,
NOT yet deployed). Supersedes `resume_cd_audio_fit_2026-07-17.md` (that doc's
black-screen mystery RESOLVED: it was the wrong-board JTAG read + the fit-era
builds; timing has been stable +0.24-ish on every build since the defrag).

## The day in one table

| # | Fix (commit) | Found by | Status |
|---|---|---|---|
| 1 | Blob parser read latency — header coded 2-cycle vs 1-cycle RAM (`e17c448`, superseded by 6) | desk | in |
| 2 | PRAM auto-restart orphaned TOC acquisition → need-driven trigger (`cedf8c9`) | CDA probe | in |
| 3 | SCSI bus reset wiped engine mid-acquisition → split rst/bus_rst (`a788b4f`) | instrumented Main log | in |
| 4 | CD slot HPS capture gated by SCSI bus-busy → starved blob writes (`b04df9f`) | probe + log | in |
| 5 | (part of 4) io_ack un-masking | — | in |
| 6 | Mixed blob read contracts — unified 1-cycle, header shifted (`96b061d`) | CDA probe (mst=8 divider grind) | in |
| 7 | CA-channel acks leaked into data accounting → `~ca_io_active` scopes (`f5a3dec`) | user bisect (icons) | in |
| 8 | Guest eject mid-session wedges engine + grinds OS → unmount escapes + `io_busy && mounted` | probes (mounted=0, 8ms stalls) | **committed + compiled, NOT deployed** |

TOC chain fully verified on HW at `f5a3dec`: chd 22 tracks → blob "MCDA" →
fetch → capture → parse → `toc_valid=1, n_tracks=22, toc_ready=1` by probe,
auto-mount, zero intervention. PLAY streamed frames (`frame_fetches>0`).
**Music has still never been heard** — every attempt died on the next bug.

## OPEN: the tip hangs even with NO CD mounted

End-of-evening bisect matrix (user-run, power-cycled bench for the last row):

| Build | Contents | CD icons | Stability |
|---|---|---|---|
| `9c5d47f` | master + tier-1 repack | clean | **STABLE (no-CD soak, post-power-cycle)** |
| `a2ae04d` | master + pdma-prefetch | clean | stable |
| `f5a3dec` tip | everything | clean (post fix 7) | **hangs, incl. NO-CD; one black screen** |

So the no-CD hang lives in the tip's remaining delta: probe trim + CD-audio
stack (engine + target changes) + the CD fixes. Suspects, with tomorrow's
discriminators:

1. **OSD "CD-ROM Drive" = Disabled on the tip build** — the A/B lever
   (cd_enable off = target never answers selection = bus looks pre-CD).
   Hangs stop → the CD target/engine logic is active-and-guilty even
   unmounted (look at the no-media poll path, cd_no_media sense serving,
   the engine's idle behavior). Hangs persist → suspect 2/3.
2. **Fit-class marginality (seed-2 class)** — the eject-guard build is a
   fresh fit; test it first anyway since fix 8 must deploy regardless.
   Also worth one seed roll if hangs persist with CD disabled.
3. **The probe trim's deck interaction** (the tip's deck differs from both
   clean controls) — least likely; discriminate last.

NOTE the evening's confound: bench churn (dozens of reloads + force
restarts) is the documented hang-forger on this box. The user power-cycled
before the final control soak (clean), but the TIP has NOT yet been tested
on a fresh power-cycle. **Tomorrow step 0: power-cycle, then the
eject-guard build, no-CD soak FIRST, then CD data, then audio.**

## Guest-eject behavior (design fact, not a bug)

The CD game's startup app EJECTS the disc (0xC0 disc-check dance; probes
showed mounted=0/no_media=1 with the user nowhere near the OSD). After fix
8 the system survives it; the game then sees an empty drive until the user
re-mounts in the OSD ("reinsert"). If this proves common, consider a
Main-side auto-reinsert option later.

## Bench state right now

- .143: power-cycled ~21:05, running `9c5d47f` control (STABLE), s4
  auto-mount config restored (points at the 22-track TIM_3-mac.chd).
- `/media/fat/MiSTer` = the INSTRUMENTED fork Main (fork f38b189 + 4
  stderr DIAG lines in maclc_cd; functionally identical otherwise).
  Cleanup when hunting ends: rebuild without the DIAG block or redeploy
  the pristine fork build. Local: ../Main_MiSTer has the instrumentation
  UNCOMMITTED (plus unrelated pre-existing toolbox WIP — don't touch).
- Staged rbf ledger (scratch/): every build of the day, hash-named.
  Deploy candidates tomorrow: the eject-guard build (commit after
  f5a3dec) first.
- JTAG: TWO USB-Blasters on this box (MacLC + LBMacTwo DE10s) — readers
  MUST select the chain by content (cd_probes.tcl pattern; cpu_state.tcl
  and clkrate.tcl still have the naive first-match bug).

## Tooling built today (reusable)

- `scripts/cd_probes.tcl` — CDA0/CDA1 decoded readout, content-based
  chain selection, double-sample with deltas.
- `scratch/psdt_read.tcl` — stall meter + CPU liveness (same selection).
- Instrumented Main: mount parse + TOC-window serve bytes on stderr.
- CDA0/CDA1 probe pair in the tip builds (layouts in MacLC.sv comments).

## Branch/merge state

- `m10k-repack` (+14 blk) and `pdma-prefetch` (+64 blk): both HW-validated
  on master baselines, pushed, awaiting the user's merge-to-master call.
- `add-cd-audio`: all 8 fixes committed + pushed; fit stable at ~495-500/553
  blocks, +0.24 ns, default fitter, ~15 min flows.
- Framework law (sys/ off-limits) in CLAUDE.md on this branch.
