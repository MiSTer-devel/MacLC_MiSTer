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


## ADDENDUM 2026-07-18 evening — the wedge is captured and the suspect list inverted

**Deterministic reproduction on 22d43c4 (full tip):** boot → launch MacAtrium
(HDD app) → hard wedge. Probe signature (snap + live, decoded):
- Target 0 mid-READ(10) (PSC6 t0 op=0x28), then BOTH targets phase-IDLE,
  zero io in flight — while the HOST pseudo-DMA stays ARMED (PSNC dma_en
  set, dack creeping via watchdog beats). CPU pinned at $F06408 (DACK),
  berr_fires SATURATED (255), max_stall = 8,125,000 clk = the 250ms
  watchdog ceiling. ONE bus reset (driver recovery) — cleared the target,
  NOT the host arm. Mouse/kbd dead = 250ms interrupt latency.
- CD engine idle and innocent at wedge time (toc_valid=1/22trk, no cmds).
- CD-Disabled A/B NOT conclusively run (OSD wedged before it applied).

**The suspect inversion:** desk-audit of the hang ladder shows the RTL
delta from the HW-clean controls (9c5d47f tier-1, a2ae04d prefetch) to the
wedging tips is HDD-BEHAVIOR-NEUTRAL: the f5a3dec ack-scoping terms are
per-instance with ca_io_active tied 0 on disk targets; 6685589's io_busy
guard adds `&& mounted` (constant 1 on disks); the pin is attribute-only.
Yet HDD reads wedge deterministically on the tip and never on the
controls. With the logic provably equivalent, the leading theory becomes
**fit-class marginality on the SCSI peripheral-read path** — the
documented #3 bug class ("STA-met-but-HW-fails", cold-boot handoff
2026-06-15): fit-sensitive marginal reads of SCSI status/data registers,
prescribed fix never implemented. Every ~15-min fit re-rolls placement;
the cd-era lineage keeps rolling marginal. (Caveat kept honest: ~6 bad
fits vs 3 good ones could still hide a real logic interaction — the
hardening below helps either way.)

**Next mission (fresh eyes):**
1. Implement the #3-prescribed hardening on the SCSI peripheral read path
   (register/multicycle the CSR+DACK read cone — periph_din_reg from the
   07-02 stabilization exists; the remaining items are the read-mux
   shortening / multicycle constraint).
2. **Disarm the host pseudo-DMA engine on SCSI bus reset** (ncr5380: bus
   reset should clear MR_DMA/arm state, as real hardware does) — today's
   signature shows the driver's recovery reset leaving the host armed is
   what turns a transient into an eternal wedge. Concrete, defensible fix
   regardless of root cause.
3. Then the A/B ladder properly: CD-Disabled from a FRESH boot on the
   tip; seed-roll of the identical netlist; bisect f5a3dec → 6685589 →
   22d43c4 only if still ambiguous.

**Bench state:** control 9c5d47f restored 20:17 (user unblocked; note
their stuck-OSD attempt may have half-saved the CD-Disabled option —
re-check in OSD if CD data is wanted on the control). Tip rbf
22d43c4s4 stays staged, KNOWN-BAD-ON-HW for MacAtrium launch. Main =
instrumented fork (state R, healthy — stderr-block theory disproven:
fd2→/dev/console, writes complete).

## ADDENDUM 2026-07-18 late — MUSIC PLAYED; underrun fixed; the marginality lottery named

**CD AUDIO WAS HEARD** (user, ~22:30): game soundtrack from the MiSTer out,
on build 35251e5 (reset-disarm). The eternal-wedge fix held under real
load (berr=0 through a full gameplay session with music).

Fixes/instruments landed tonight (all committed+pushed):
- 35251e5: MR DMA MODE cleared on SCSI bus reset (5380 datasheet + MAME +
  BlueSCSI's resilience model; converts eternal wedges into driver-
  recoverable transients). THE fix that let music happen.
- 471a83d: audio frame fetches interleave with read-command serving.
  Live capture had playback at ~42 of the needed 75 frames/s (sample-hold
  crackle = the reported distortion) because ca_grant demanded total
  bus-idle while the game streamed from the same disc. Mutual exclusion
  verified complete in BOTH directions post-change.
- 34d5dbb: CDA2 probe = last 0xC1 CDB {op,start,alloc}. First capture:
  the AppleCD player's last ask = op40 (leadout), alloc 4 — the
  enumeration sequence will need a small CDB history ring if the 2-track
  display persists after the next verdict.

**OPEN #1 — the 2-track display (AppleCD Audio Player) with a 22-track
disc**: core table holds 22 (probe), serving desk-matched to MAME's
three-op contract (op00 {01,last_bcd,00,00} / op40 leadout MSF / op80
descriptors from CDB[5], repeat-last). Next datum = CDA2 during a fresh
player launch; if the asks look sane, capture a 4-deep CDB history +
compare served bytes.

**OPEN #2 — per-fit marginality is now the dominant stability variable**:
34d5dbb (seed 4, +0.177) wedges BOOT (HDD READ(10), host re-armed after
its recovery reset, PSWL req_drop SATURATED 65535+ = REQ cycling with
zero ACKs, CPU polling PseudoVIA for the completion IRQ; CD unmounted and
answering no-disc correctly) while 35251e5 (+0.251) ran a full evening.
Functional delta ~nil. The dreq/ack-busy cone (dma_ack_holdoff/dma_settle
/ dreq gating) is the suspected marginal net family; the 21-node JTAG hub
routing may be aggravating pressure. Short-term: seed lottery with
PER-BUILD HW SOAK law (STA-met ≠ stable; slack magnitude correlates).
**Queued mission (the cure): register/multicycle-harden the SCSI periph
read + dreq/ack-busy cone** per the 06-15 #3 handoff prescription — ends
the lottery permanently. Consider probe-deck slimming (drop PBH-era
leftovers if any, keep CDA/PSDT) if hub pressure proves real.

Artifact ledger tonight: 35251e5s4 (md5 03fd764b) = the MUSIC build,
stable evening driver; 34d5dbbs4 (b3615c5d) = boot-wedges, quarantine;
seed-5 build in flight at time of writing.