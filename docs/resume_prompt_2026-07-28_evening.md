# Resume prompt — MacLC audio + write-corruption mission (2026-07-28 evening)

Paste the block below as the opening message of the next session. Everything
after it is supporting detail for whoever is reading rather than pasting.

---

## THE PROMPT (paste this)

> Resume the MacLC mission on branch `more-audio` (repo
> `C:\Temp\mistercore\MacLC_MiSTer`).
>
> Read `docs/resume_audio_write_triage_2026-07-28.md` first — it is the
> authoritative state, including the 07-28 pm sections at the top and the
> "WRITE CORRUPTION REPRODUCED" section. Then read this file
> (`docs/resume_prompt_2026-07-28_evening.md`).
>
> Status in one breath: the 2x-fast game audio is FIXED and validated by ear.
> The CD-audio digital path is exonerated by measurement, and a downstream fix
> (full-gain mix + interpolation) is BUILT AND DEPLOYED but NOT yet judged by
> ear. The SCSI write corruption is REPRODUCED on a clean volume with an exact,
> characterized signature and a named-but-unproven suspect.
>
> Running on the MiSTer at 192.168.99.143 right now:
> `_Unstable/MacLC.rbf` = md5 `39d51fdda3e4eae74100f72e2fdc18e9`
> (commit `6ffe854` = ASC lane fix + SCSI wr_pending fix + CD-audio gain/
> interpolation + BOTH JTAG probe decks). STA met +0.201 ns.
>
> Priorities, in order:
> 1. Get the user's ears on CD audio (AppleCD Audio Player, TIM3 CUE is
>    mounted, play track 2+ — track 1 is data and is SUPPOSED to sound like
>    static). If still wrong, see "If CD audio is still wrong" below.
> 2. Hunt the write corruption with the probe experiment described below.
>    Do NOT blind-patch `odd_byte_r`.
>
> Hard rules: never hard-reload a RUNNING guest (clean Shut Down first);
> guest warm Restart is a KNOWN-BROKEN separate bug (grey hang) — reboot is
> always "Shut Down, then `load_core`"; `sys/` is off-limits; the
> `MacLC.qsf` probe-macro flips are working-tree-only and must be
> re-commented before any release build.

---

## Where each report stands

| # | Report | State |
|---|--------|-------|
| 1 | CD audio "not CD quality / sounds half" | Digital path EXONERATED on HW (41.8k sample-changes/s both channels during playback = full-rate). Downstream fix built + deployed, **awaiting the user's ears** |
| 2 | Some games play audio 2x fast | **CLOSED.** `ebf605e`; user confirmed Reader Rabbit 2 normal speed |
| 3 | TIM3 install "files may be damaged" | **REPRODUCED on a clean volume with `17f5a85` applied.** Signature fully characterized; suspect named, unproven |
| 4 | TIM3 general slowness | Untouched. Data point: a 14.5 MB Finder copy took ~4 min wall clock (read phase then write phase, roughly 60 KB/s) |

## Commits this session (all on `more-audio`, none merged)

- `7b88002` docs: RR2 validation, CD exoneration, wedge forensics, guest-driving crib
- `6ffe854` **cd-audio: full-gain mix + continuous linear interpolation** (the deployed RTL change)
- `225efb9` docs: guest warm-restart is a known-broken path
- `8d60e83` docs: write corruption reproduced — exact signature

Uncommitted and intentional: `MacLC.qsf` probe-macro flips.

## The write-corruption signature (the actionable core)

Reproduced with a pristine volume: `TIM3TEST_755.hda` is a byte-copy of the
validated `MacLC_7-5-5.hda`, mounted on SCSI-1 (volume `Mac7-5-5`), TIM3
installed into a new folder on it. Damaged-catalog and stale-install theories
are both dead.

Two signatures, both surviving `17f5a85`:

1. **Rare, in a plain Finder copy (no installer at all):** copying
   "TIM Voices 1" (14.5 MB) from CD to disk corrupted 2 of 28,350 blocks —
   one is benign resource-header scratch, the other has **exactly its first
   16-bit word wrong** (`8080` vs `3840`) with the remaining 510 bytes
   perfect. Same class as the 07-28 am "first word of a 512-byte block".
   **This is the clean, installer-independent reproduction.**

2. **Frequent, in the installer's large sequential writes:** in "TIM Audio",
   **every OTHER 64 KB unit** is corrupt — spans at 0x10000, 0x30000,
   0x50000 …, each exactly 0xFE00 (65,024 B = 127 sectors), 24 spans total.
   Inside a span, **one byte is inserted within the first 4 bytes** (observed
   at +1 and +3 — odd offsets, i.e. the LDS/low lane) and the rest of the span
   is the reference shifted by one byte. Visible in ASCII: the file contains
   `org@an` where the CD has `organ`. Fork header/layout is unchanged; the
   +4 bytes of file length are trailing allocation only.

During the failing install the JTAG probes were **clean**: bus resets stayed
at 1 (the boot one), no stalls, WRITE(10)/0x2A on target 1 and READ(10)/0x28
on target 0. This is silent data corruption, not an error/retry path.

### Leading hypothesis (UNPROVEN — do not patch blind)

The alternation implies a **residue carried between write commands**: command
N leaves a stray byte, N+1 consumes it and shifts, N+2 repeats. Prime suspect
is the word-write byte packing in `rtl/scsi.v` ~226-276: `odd_byte_r` is a
module-scope latch, reset ONLY on `rst`, captured at
`stb_ack && (phase == PHASE_DATA_IN) && ~data_cnt[0] && dbg_dma_word`, and
consumed as buffer1's `data_b`. If the even/odd pairing ever slips at a
command boundary — or the driver's classic "first byte by hand, rest by DMA"
flips byte/word mode mid-command — the lanes shift by one byte for the rest
of that command.

This bug family has burned this project with plausible-but-wrong fixes
before (see the `#3` marginality history). Prove it before changing RTL.

### The experiment to run next

Add a probe that latches, per WRITE(10) data phase: `data_cnt[0]` at the
first beat, `dbg_dma_word`, the first 4 bytes actually stored, and a counter
of byte-mode↔word-mode transitions within the command. Then run the same
install and correlate a known-corrupt span (they are at predictable 64 KB
offsets) against a mode transition or a parity slip. If the first beat of
alternate commands starts on the wrong `data_cnt` parity, that is the bug.

A cheaper first cut: the Finder-copy repro (signature 1) is much faster than
a full install — a single 14.5 MB drag reproduces one bad block in ~4 min.

## Reproducing and measuring (exact recipe)

```bash
bash scripts/grab.sh scratch/shot.png          # ALWAYS check returned name+size
```

- Pull the test image and diff:
  `scp root@192.168.99.143:/media/fat/games/MACLC/TIM3TEST_755.hda scratch/tim3/`
  then in WSL: `python3 extract2.py TIM3TEST_755.hda list` and
  `python3 extract2.py TIM3TEST_755.hda extract "TIM Audio" rsrc out.rsrc`
- **`hfs_walk.py` silently misses records** once the catalog outgrows the
  MDB's 3 extents (it only prints a WARN). Use `scratch/tim3/extract2.py`,
  which whole-image-scans for 0xFF leaf nodes and follows extents overflow.
- References in `scratch/tim3/` (gitignored, still valid):
  `tim_audio_ref.rsrc` (2,912,330), `machine_data_ref.dat` (7,487,823),
  `tim_voices1.bin` (MacBinary: 128-byte header, then the 14,514,992-byte
  resource fork), plus this session's `new_*` extracts and the post-install
  `TIM3TEST_755.hda` (md5 `5f2e5e9e`).
- Probe readers: `scratch/wr_watch.tcl` (write path), `scratch/aud_rate.tcl`
  (ASC + CD cadence), `scratch/wedge_dump.tcl` (CPU/bus forensics),
  `scripts/cd_meters.tcl` (CD cadence; NOTE its 44100-vs-22050 verdict table
  is now retired — CDS probes the interpolated stream after `6ffe854`).
  All select the JTAG chain by probe CONTENT, never by cable order (two
  DE10s on this bench).

## If CD audio is still wrong

The digital path is measured clean, and gain + resampling are now addressed
core-side, so the next suspects in order:
1. **Listen to track 2+, not track 1** — track 1 is the data track and the
   TIM3 installer's own readme says it "will sound like static".
2. Guest-side mixing: System 7's Sound control panel "Sound In / Internal CD
   / Playthrough" settings (the TIM3 readme documents this) — a guest-side
   playthrough setting could dominate.
3. `AUDIO_MIX = 0` in `MacLC.sv` (no stereo blending) and `AUDIO_S = 1`.
4. Re-measure with `scratch/aud_rate.tcl` while playing to confirm the
   engine is still delivering ~44.1k after `6ffe854`.

## Guest-driving crib (this is hard-won — read before touching the guest)

- **Remote ws/HTTP mouse BUTTONS never reach the guest** (moves do; even the
  Remote web UI's own clicks don't land). Keyboard works:
  `POST /api/controls/keyboard-raw/{code}` and ws `kbdRawDown/kbdRawUp`
  (chords: 56 = LAlt = Cmd; 28 Enter, 1 ESC, 108 down, 88 F12).
- **Working click/drag: inject raw `input_event` structs into the PHYSICAL
  mouse node** `/dev/input/event3` over ssh with busybox printf octal
  escapes. 16 B per event `{8B zero time, u16 type, u16 code, s32 value}`;
  EV_REL=2 (REL_X=0, REL_Y=1), EV_KEY=1 with BTN_LEFT=0x110, SYN = 16 zero
  bytes. Writes must be a multiple of 16 bytes, and **avoid 0x0A in any value
  byte** (busybox printf splits the write → EINVAL).
- **The core clamps accumulated mouse delta per poll**: use **≤2-3 px per
  event spaced ~25 ms for exact 1:1**; ≥5 px steps hit Mac acceleration
  (~2x). Corner-slam to re-sync absolute position, then walk.
- **Button state persists across ssh commands** — press, drag, screenshot to
  verify the menu highlight, then release. System 7 menus are fully drivable.
- **The OSD is NOT composited into screenshots.** Never drive it blind;
  ask the user for OSD actions, or use `load_core`.
- MacAtrium Quick-Launch = ESC; entries: Settings / Status / CD Library /
  Toolbox Shared Files / Show Finder / Exit to Finder / System Folder
  Chooser / Restart / Shut Down. "Show Finder" keeps MacAtrium resident.
- The 7.1 Apple-menu "AppleCD Audio Player" alias is BROKEN (opens a 7.6.1
  desktop-printing readme in SimpleText). The real app is
  `Apple Extras/AppleCD Audio Player/AppleCD Audio Player`.
- Standard File dialogs: Cmd-D = Desktop level; typing goes into the
  destination NAME field, it is not type-select; navigate with the mouse.
- Screenshot service dies under heavy HPS traffic and `grab.sh` then
  silently returns a STALE image — always check the returned filename and
  byte size against the host clock.

## Bench state

- `.143`: booted on `39d51fdd`, CD3 `TIM_3-mac.CUE` mounted, SCSI-0 =
  `Mac68KColorGames_v1.hda` (volume `MacAtrium_Sys`, the user's disk — has a
  damaged catalog B-tree, wants Disk First Aid some day), SCSI-1 =
  `TIM3TEST_755.hda` (the clean test volume, now holding the corrupt TIM3
  install — keep it, it is evidence).
- Staged on the box: `_Unstable/MacLC_CDAUD_20260728_39d51fdds5.rbf` and the
  previous `_Unstable/MacLC_WRFIX_20260728_91bfb2fas5.rbf`.
- The user merges PRs themselves; never `gh pr merge`.
