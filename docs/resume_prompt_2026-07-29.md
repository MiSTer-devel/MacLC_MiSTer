# Resume prompt — write-corruption fix, then the probes-off build (2026-07-29)

Paste the block below as the opening message of the next session. Everything
after it is the supporting dossier.

---

## THE PROMPT (paste this)

> Resume the MacLC mission on branch `more-audio` (repo
> `C:\Temp\mistercore\MacLC_MiSTer`).
>
> Read `docs/resume_prompt_2026-07-29.md` first — it is the authoritative
> state. Two missions, in order:
>
> 1. **Fix the SCSI write corruption** (`rtl/scsi.v` word-pairing lane slip).
>    The mechanism is PROVEN, the reproduction is DETERMINISTIC, and the
>    verification tooling exists. Fix the WRFB probe mux first (it can't
>    catch per-command evidence yet), then the pairing itself, then verify
>    with the TIM installer + `extract2.py` diff.
> 2. **Root-cause the probes-off release marginality.** Three probes-off
>    fits failed the hardware boot gate in two distinct ways while every
>    probe-bearing fit is clean. Attributes-only hunt (PRESERVE/syn_keep
>    anchors) — NO behavioral RTL changes mixed in.
>
> Hard rules: never hard-reload a RUNNING guest (clean Shut Down first —
> flows below); `sys/` is off-limits; `MacLC.qsf` probe-macro flips are
> working-tree-only (the tree is CLEAN right now — re-flip
> `USE_DBG_PROBES=1` before building any probe core, re-comment before any
> release build); ALWAYS check `grab.sh`'s returned filename timestamp
> (stale-screenshot trap); two DE10s on the bench — probe scripts select the
> chain by CONTENT.

---

## Where everything stands (2026-07-29 ~00:30)

**SHIPPED (commit `45c5851`, branch `more-audio`, PUSHED — user PRs/merges):**
- `releases/MacLC_20260728.rbf` = `releases/MacLC_CDFIX_20260728_95e4e8e0s5.rbf`
  (md5 `95e4e8e0`, SEED 5, STA +0.219, RTL commit `f896389`). **Ships WITH
  the JTAG probe decks** (user-approved deviation — see mission 2).
- `releases/MiSTer` = `b124447c` (Main fork branch
  `add-bluescsi-toolbox-for-MacLC`, commits `c6e5506` + `b3fb2f7`, PUSHED to
  `danifunker/Main_MiSTer`). **Pairing law: this core's CD audio requires
  this Main** (whole-frame serving is LBA-window-keyed; an older core on
  this Main gets garbled CD audio; data/TOC paths unaffected either way).
- **No further HPS-side changes are needed.** Writes ride the generic sd
  path (never modified); the corruption is core-side. The Main PR is
  complete as pushed.

**CD audio is DONE and measured**: the ping-pong freed the wrong half at
every frame wrap (`f896389` fixed it) — CDUR went 71 starves/s → 0/s live.
Also in: whole-frame 2352 B CD-DA fetches, the 8-clk interpolated output
hold (sys stability-filter CDC law: core audio outputs must hold ≥8
clk_sys), full-gain mix, ASC byte-lane fix.

**On the box (.143):** running `_Unstable/MacLC_CDFIX_20260728.rbf`
(= the release bits, probes IN — WRFB/CDUR/CDA/PSC decks live) on Main
`b124447c`. MacAtrium disk was REFRESHED from `c:\temp\macatrium-build`
(`Mac68KColorGames_v1.hda`, md5 `d57c4521` — patched MacAtrium, intact 7.1
whose CD extension detects at boot). The old damaged-catalog disk is
preserved as `games/MACLC/Mac68KColorGames_v1.hda.damaged728` on the SD and
locally as `scratch/tim3/hda_damaged728.hda`. `_Unstable` also holds the
three FAILED probes-off fits (`MacLC_REL_` 35601be6, `MacLC_REL2_`
764d1703, `MacLC_REL3_` 3129a134) — keep for the mission-2 A/B, then clean.
OSD master volume is still ~2 notches down globally (`Volume.dat`=0x02) —
suggest the user raise it.

---

## Mission 1 — the write-corruption fix

### The proven mechanism
- **Signature (reproduced byte-identically TWICE, deterministic):**
  installer's "Machine Data" comes out **+78 bytes with first divergence at
  `0x1f5d`**; "TIM Audio" corrupts **unit 0 (benign header scratch) + every
  ODD 64 KB unit** — one byte INSERTED near each span start (odd offsets =
  LDS lane), rest of the span shifted by one. A plain Finder copy shows the
  rare variant: one wrong first-WORD of a 512-byte block (~1 in 28k blocks).
- **WRFB measured the trigger live** (during the user's failing copy):
  write data phases start in BYTE mode and flip to WORD mode mid-phase
  (`first_word=0, modeflips=1, first_parity=0`) — the Mac driver's classic
  "first bytes by hand, rest by pseudo-DMA".
- **The slip:** `rtl/scsi.v` ~249-276: `odd_byte_r` (buffer1's word-mode
  data) is captured ONLY at `stb_ack && PHASE_DATA_IN && ~data_cnt[0] &&
  dbg_dma_word`. If the byte-mode prefix has ODD length, the first
  word-mode beat lands at odd `data_cnt` → no fresh capture → a STALE byte
  gets stored and the even/odd pairing is shifted for the rest of the
  command. Whether the prefix is odd alternates per command → the
  every-other-64KB-unit pattern.

### Fix order (do the probe first — evidence before RTL)
1. **WRFB mux fix** (`rtl/ncr5380.sv` ~`wrfb_mux`): the current mux routes
   only while a target is LIVE in a data phase; JTAG reads between commands
   return `target_wrfb[DEVS-1]`'s stale latch, so per-command sampling never
   sees target 0. Change to LATCH the index of the last target seen in a
   data phase (a small clocked register) and route the probe through that.
   Consider also widening WRFB or adding a second word (WRF2) with: count of
   write phases whose FIRST word-mode beat had odd parity (the direct
   smoking-gun counter — expect ~half the installer's large writes).
2. **The pairing fix** (`rtl/scsi.v`): re-read the beat/count semantics at
   lines ~1260-1268 (`buffer0_wr <= ~data_cnt[0]` etc.) and ~2280-2295
   before designing. Candidate: replace the `~data_cnt[0]` capture/pairing
   condition with a PHASE-LOCAL byte-position toggle that resets at
   DATA_IN entry and tracks byte-vs-word beats as they actually arrive, so
   a mode flip at odd offset re-syncs instead of slipping. Do NOT touch
   buffer0 (proven correct). Respect the existing race/timing comments
   (dbg_dma_lowbyte is only stable at the beat's stb_ack).
3. Gates: `bash scripts/build_only.sh --check` (~4.5 min), then full build
   with `USE_DBG_PROBES=1` re-flipped in the qsf (WT-only!). Triple gate on
   deploy (STA + boot screenshot + probes).

### Verification recipe — REWRITTEN 2026-07-29 (the old one was unsound)

**The old criterion was wrong and must not be reused.** It said: extract
the installer's `Machine Data` and PASS = byte-identical to
`scratch/tim3/machine_data_ref.dat`, treating the `+78` bytes as
corruption. Three facts kill it:
- The CD's OWN `Machine Data` data fork is **7,487,823** bytes — i.e.
  `machine_data_ref.dat` IS THE CD SOURCE, not expected install output.
  The installer legitimately writes a transformed, 78-byte-longer file, so
  `+78` is normal and every run would "fail" regardless of hardware.
- The two supposed references disagree with each other:
  `machine_data_ref.dat` vs `machine_data_installed.dat` differ at byte
  41,473.
- Installer output is not a stable oracle at all (it transforms content).

**Use length-preserving copies instead, against a verified source.**
- `scratch/tim3/TIM3-data.iso` is VERIFIED byte-perfect: `reiso.py`
  re-extracts the data track from `TIM_3-mac.BIN` (mode-1 user data at
  sector byte 16, len 2048) and 0 of 68,677 sectors differ. Fork
  references pulled from it with `extract2.py` are authoritative;
  `forkmap.py` maps a fork offset to a raw image offset with NO extent
  stitching when a byte needs checking independently.
- **Write-path test (the definitive one, no CD in the loop):** in the
  guest, select a large file already on a volume and File > Duplicate
  (a 14.5 MB file takes ~4 min). Then extract BOTH from the pulled image
  and compare with `difflist.py`. Self-contained — needs no external
  reference. PASS = every 512 B data block identical; only block 0 may
  differ (the resource-fork reserved header holds the file NAME, so the
  duplicate legitimately contains the literal string " copy" there).
- **CD-path test:** Finder-drag `TIM Voices 1` (14.5 MB) from the CD to a
  volume, then compare the extracted copy against the ISO-derived
  reference. Block 0 header scratch is expected; anything else is real.
- Sample WRFB during any write workload
  (`quartus_stp_tcl -t scratch/wrfb_read.tcl`). ODDW ([7:2]) counts the
  lane-slip trigger. The installer path saturates it; Finder/disk copies
  never trigger it (ODDW stays 0) — so the installer is the workload that
  exercises the pairing fix.
- Tools written 2026-07-29, all in `scratch/tim3/` (gitignored):
  `difflist.py` (equal-length offset diff + block/parity histogram),
  `align.py` (reference-free indel/substitution counter),
  `cmp3.py` (shift-hypothesis divergence classifier), `reiso.py`,
  `forkmap.py`.

### Outcome 2026-07-29 — write path VALIDATED CLEAN
- Disk-to-disk duplicate of a 14.5 MB fork on build `24592e25` (RTL
  `ceaec45`): **28,348 of 28,349 data blocks byte-identical, zero
  corruption**; the only differing block is block 0's resource header,
  whose diff literally contains `20636f7079` (" copy") = the new filename.
- The pairing fix is measurable on the installer path: today's output is
  byte-identical to the pre-fix run for the first 65,539 bytes and then
  re-syncs at shift −1 with 99.3% match — exactly one inserted byte
  removed at the 64 KB boundary, the documented signature.
- WRFB proves the trigger is real and common: ~29% of installer write
  phases have their first word-mode beat at odd parity (ODDW 9 → 51 →
  saturated 63 during one install).

### Still OPEN — a SEPARATE, deterministic CD-read defect
The "rare variant" (previously believed to be a random write fault) is
**deterministic and is NOT the write path**: CD-sourced copies contain
`0x8080` where the CD holds `0x3840`, at fork offset `0x18200`. Identical
bytes in two runs across two different core builds, and faithfully
preserved by a disk-to-disk copy — so it enters on the READ side.
- Location: CD data-track sector **49,385 + 512 bytes** — a 512 B
  sub-boundary inside a 2048 B sector.
- `0x8080` is the neutral/silence value for unsigned 8-bit audio and
  replaces a smooth waveform ramp (`2c 33 38 40 45 4a…`), which reads as
  unfilled buffer content rather than a lane swap.
- The sector is a clean Mode-1 sector (`00 ff*10 00`, header `11 00 35 01`)
  with no false sync pattern in its user data.
- Only 1 occurrence in 7,088 CD sectors, so it is not a periodic
  serving-boundary bug. Next step: instrument the CD read/serve path
  around the 512 B sub-boundary handling.

### Also OPEN (pre-existing, user-confirmed "for a while") — colour-icon
### display corruption
Seen on the probes-off boot 3 in the Finder: custom COLOUR icons render
as multicolour noise (volume icons, System Folder icons, Trash, the TIM
Voices doc icon) while plain 1-bit folder icons, all window chrome,
menus and text render perfectly. The selectivity — colour icons only —
points at the 4/8bpp colour path rather than the scaler or a fit
problem, which lines up with the known 4/8bpp colour issue that the
DDR3-video-channel work is meant to fix (video fetch off SDRAM onto
cached DDR3). NOT caused by the write fix or by dropping the probe deck:
the user confirms it predates both. Do not score it against a boot gate;
score the gate on boot + main-loop responsiveness.

## Mission 2 — the probes-off marginality

### The facts
- Probes-off fits of the SAME `f896389` netlist, all STA-met, all FAIL the
  hardware boot gate: SEED 5 (`35601be6`, +0.230) = Finder wedge with live
  cursor (VBL alive, main loop blocked); SEED 3 (`764d1703`, +0.245) =
  boots then lands on the "safe to switch off" screen; SEED 1 (`3129a134`,
  +0.241) = Finder wedge again. TWO distinct failure modes = possibly two
  marginal cones.
- Every probe-bearing fit boots and validates (91927d4f, f692039a,
  95e4e8e0 — hours of validation).
- Theory: the ~20 altsource_probe instances anchor observed nets
  (keep/no-retime side effects) across the SCSI/CD/CPU decks; without them
  the aggressive qsf physical synthesis (retiming, duplication, gated-clock
  conversion) re-optimizes a cone that is STA-met but HW-marginal — the
  historical `#3` class (SCSI CSR reads) is the prime suspect and the
  Finder-wedge symptom (blocked on disk I/O) matches.

### RESOLVED 2026-07-29 — probes-off now PASSES, no anchors needed

A probes-off fit of the POST-write-fix netlist (`ceaec45`, SEED 5, md5
`cc57535d`, STA +0.248) **passes the boot gate 3/3** with a responsive
main loop (menus open on demand — the historical failure was a live
cursor over a blocked main loop). The attribute hunt below was never
needed and should NOT be started unless the symptom returns.

Most likely cause of the earlier failures: the write fix changed the SCSI
cone structurally (new `wm_beat2`/`store_low` registers; the data-source
mux moved off the `data_cnt[0]` parity path), which relieved the marginal
path the probe instances had been accidentally anchoring. The A/B backs
this up — the probes-off build has MORE margin in the core domains than
the probe build, not less:

| domain | probes ON | probes OFF |
|---|---|---|
| worst setup (pll_hdmi) | +0.464 | +0.317 |
| `emu\|pll` general[0] | +1.942 | **+2.310** |
| `emu\|pll` general[1] | +2.003 | **+2.406** |
| worst hold | +0.242 | +0.248 |

Registers 35,346 (on) vs 32,928 (off) = 2,418 for the deck + its JTAG
`sld_hub`; block memory bits identical at 3,975,530 (no RAM migration).
Report pair archived at `scratch/m2/probes_{on,off}.{map,fit,sta}.rpt`.

**Consequence: releases no longer need to ship the probe decks.** The
07-28 user-approved deviation is retired.

### The hunt (attributes only — no behavioral RTL) — ONLY IF IT RETURNS
1. Diff `map.rpt`/`fit.rpt` between the probe build and a probes-off build
   for the SCSI cones (register duplication/retiming reports name nets).
2. Add targeted anchors on OUR side: `(* preserve *)`/`(* syn_keep *)` RTL
   attributes or qsf `set_instance_assignment -name PRESERVE_REGISTER ON
   -to <net>` on the nets the decks observe (start with scsi.v phase/csr
   state, ncr5380 target_* muxes, the pseudo-DMA engine state — the PSCS/
   PSNC/PSCW/PSDS observed sets are the shopping list, they're exactly what
   the probes anchor today).
3. Rebuild probes-off, full triple gate per fit. Iterate the anchor set
   until a probes-off fit passes; then a future release can drop the decks.
4. If anchors don't converge: the fallback is permanent — ship releases
   with the decks in (tonight's precedent, user-approved).

## Ops crib (hard-won, use it)

- **Guest driving**: `scratch/mouse.sh` verbs slam/walk/down/up/click/dclick
  (≤3 px/25 ms = 1:1; slams for corner sync; button state persists).
  Finder Shut Down: `slam -1 1`, `click` (desktop), `slam -1 -1`,
  `walk 231 8`, `down`, `walk 0 131`, `up`. MacAtrium QL: ONE ESC (it
  TOGGLES — double-ESC race made it look broken; wait 3.5 s), Shut Down
  button at (320,370), Show Finder (320,250), CD Library (320,190).
- **AppleCD player transport** (window at default spot): Stop(266,122)
  Play(314,122) **Eject(357,122) — the trap that ejected the disc**;
  Prev(260,148) Next(291,148) Rew(325,148) FFwd(357,148). Player numbers
  AUDIO tracks only (player-01 = disc track 2). Verify UI state via ffmpeg
  crop+5x neighbor zoom of screenshots — pixel-exact digit reads.
- **Screenshots**: `bash scripts/grab.sh scratch/x.png` — ALWAYS check the
  returned filename timestamp; the service DIES under heavy HPS churn and
  grab returns the stale previous file. HPS reboot cures it.
- **Deploys**: MiSTer binary swap = scp to `.new` + `mv` (ETXTBSY blocks
  cp); hda swaps ONLY after `load_core /media/fat/menu.rbf` (releases the
  fds); guest reload law = clean Shut Down + `load_core` (warm Restart =
  known-broken grey hang, separate OPEN bug).
- **JTAG**: select by probe CONTENT (two DE10s; `scripts/cd_probes.tcl` is
  the pattern). Readers: `scripts/cd_meters.tcl` (CDUR starvation + CDS),
  `scratch/wrfb_read.tcl` (WRFB), `scratch/wr_watch.tcl`,
  `scratch/vid_delta.tcl`. Keep sessions SHORT (HPS exhaustion law).
- **Main fork build**: WSL,
  `PATH=/opt/gcc-arm-10.2-2020.11-x86_64-arm-none-linux-gnueabihf/bin:$PATH
  make` in `/mnt/c/Temp/mistercore/Main_MiSTer` (the docker image lacks the
  cross-gcc on PATH). Push over HTTPS (`gh` auth as danifunker; ssh keys
  don't cover GitHub).
- **HFS forensics**: `scratch/tim3/extract2.py` (whole-image leaf scan,
  newest-cnid wins on duplicate names; `hfs_walk.py` is superseded — it
  silently misses records past the MDB's 3 extents).

## Superseded / closed this session (don't re-chase)

- "CD not detected" = the OLD disk's 7.1 System was the casualty (damaged
  catalog ate the AppleCD extension's INIT) — fresh disk detects at boot.
  NOT the core, NOT Main, NOT the HPS reboot, NOT PRAM.
- The "2.8 ms/txn, 104% utilization" serving model was WRONG (real per-txn
  ~0.1 ms, Main serves back-to-back in one poll pass); the starvation was
  the half-clear bug. The multi-block serving stays (real headroom + it
  made the smoking-gun measurement possible).
- The boot repulse (`b3fb2f7`) is necessary only for true cold-attach
  cases; keep it (harmless, guarded by the data-read count).
