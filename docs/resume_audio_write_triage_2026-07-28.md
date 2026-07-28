# Resume: audio speed / CD audio quality / install corruption — 2026-07-28

Branch `more-audio`. Three user reports opened this session; two are
root-caused and fixed (HW-unvalidated), one is instrumented but unmeasured.

## Reports and status

| # | Report | Status |
|---|---|---|
| 1 | CD audio "not 44.1 kHz quality, distorted, sounds ~half" | **Digital path EXONERATED on HW 07-28 pm**: CDS meter ~41.8k changes/s sustained both channels during playback (full-rate class; 22.05k = halved would have been the defect). Remaining suspects downstream: half-gain CD mix (`MacLC.sv` ~597) + sys 48 kHz ZOH resample (fix = core-side gain + interpolating resampler; `sys/` untouchable) |
| 2 | Some games play audio ~2x fast (Reader Rabbit 2; TIM3 "MIDI"; POP fine) | **VALIDATED on HW 07-28 pm** — user ears: RR2 music normal speed on build 91bfb2fa (`ebf605e`) |
| 3 | TIM3 (The Incredible Machine 3) loads extremely slowly; install reports "files may be damaged" | **Corruption root-caused + fixed** `17f5a85` (HW-unvalidated — needs fresh install test after volume repair). General slowness NOT explained |

## 07-28 pm validation session addenda

- **TIM3-launch wedge captured live** (pre-reset): CPU spinning forever in the
  ROM's AuxWin-list walk ($A18A3A-46, `cmpa.l 4(a0),a3` vs AuxWinHead $CD0.w,
  i.e. DisposeWindow on a circularized/corrupt aux-window list). SCSI fully
  idle, video timing alive, vram_wr frozen. Verdict: guest heap/list
  corruption from launching the KNOWN-DAMAGED pre-fix TIM3 install — not a
  core hang. Full dump: `scratch/wedge_dump1.log`, reader
  `scratch/wedge_dump.tcl` (content-selects the chain by PIFA).
- **CUE-at-boot-attach did NOT hang this boot**: 13:51 reload came up with
  `CD3/TIM_3-mac.CUE` attached from config and booted clean to MacAtrium.
  The open "CUE/CHD-at-boot-attach hang" issue did not reproduce under
  91bfb2fa (one data point, not closure).
- **Volume layout correction**: there is ONE hda (`Mac68KColorGames_v1.hda` =
  volume "MacAtrium_Sys", 690 MB, 60 MB free) carrying System Folders 6.0.8 /
  7.1 (MacAtrium boot) / 7.5.5 / 7.6.1 + System Picker + all games. The
  damaged-catalog findings apply to THIS (boot) volume — Disk First Aid before
  the reinstall test.
- The 7.1 Apple-menu "AppleCD Audio Player" alias is broken (opens a 7.6.1
  desktop-printing readme via SimpleText). Real app:
  `Apple Extras/AppleCD Audio Player/AppleCD Audio Player`.

## Guest-driving crib (07-28 pm, supersedes mouse notes)

- **Remote ws/HTTP mouse buttons never reach the guest** (moves do; verb is
  `mouseBtn:click`, and even that dies in Main's input path for buttons —
  clicks via the Remote web UI don't land either). Keyboard: HTTP
  `keyboard-raw/{code}` and ws `kbdRawDown/kbdRawUp` (chords: 56=LAlt=Cmd)
  both reach the guest.
- **Working click/drag path: inject raw `input_event` structs into the
  PHYSICAL mouse node** (`/dev/input/event3`, XING WEI) over ssh via
  busybox printf octal escapes. 16 B/event {8B zero time, u16 type, u16
  code, s32 value}; EV_REL=2 (REL_X=0/REL_Y=1), EV_KEY=1 BTN_LEFT=0x110,
  SYN=16 zero bytes. Writes must be 16-byte multiples; **avoid value bytes
  = 0x0A** (busybox printf line-buffers and splits the write -> EINVAL).
- **Core mouse path clamps accumulated delta per poll** — burst moves
  collapse (this was the whole ws-mouse attenuation mystery). Rule:
  **<=2-3 px per event spaced ~25-30 ms = exact 1:1**; >=5 px steps hit Mac
  acceleration (~2x). Button hold persists across ssh commands — press,
  drag, screenshot-verify the menu highlight at leisure, then release.
  System 7 menus fully drivable this way.
- MacAtrium Quick-Launch (ESC): Settings / Status / CD Library / Toolbox
  Shared Files / Show Finder / Exit to Finder / System Folder Chooser /
  Restart / Shut Down. "Show Finder" keeps MacAtrium resident. RR2 quit
  dialog answers to the `y` key.
- OSD is NOT composited into screenshots (drove blind-OSD attempts astray;
  use `load_core` via `/dev/MiSTer_cmd` for a deterministic guest reset —
  config re-attaches mounts).
- **Guest WARM RESTART is broken (user, 07-28): Finder Special→Restart hangs
  the next boot at uniform grey — a separate known core bug, still OPEN.**
  The only supported reboot is clean Shut Down (or dead guest) + core
  re-launch via `load_core`. Newly OSD-mounted SCSI volumes therefore get
  picked up by a core re-launch, not a guest restart.

## What is on the hardware right now (.143)

`/media/fat/_Unstable/MacLC.rbf` = md5 `91bfb2fa2c092cfa4648c5f9ef61ce56`,
also staged as `_Unstable/MacLC_WRFIX_20260728_91bfb2fas5.rbf`.
= `ebf605e` + `17f5a85` + BOTH probe decks (USE_AUDIO_ISSP + USE_DBG_PROBES).
STA met +0.247 ns, SEED 5. Boot gate PASSED (MacAtrium desktop,
screenshot-verified); probes clean: `berr_fires=0`, SCSI idle, 1 bus reset,
vbl advancing ~61/s. Guest left at the MacAtrium shelf with Reader Rabbit 2
selected. CD slot holds `Open Transport 1.3.1.iso` (a data disc — no audio
tracks).

**The `MacLC.qsf` probe-macro flips are UNCOMMITTED working-tree state and
MUST be re-commented before any release build.**

## Fix 1 — ASC FIFO dropped a byte lane (`ebf605e`)

`rtl/asc.sv` pushed exactly one byte per bus cycle taken from
`cpuDataOut[7:0]`. A `MOVE.W`/`MOVE.L` FIFO fill drives two byte lanes in one
cycle, so the UDS-lane byte of every pair was lost -> playback at exactly 2x
with aliasing. Byte fills were unaffected (the TG68 kernel mirrors a byte
write onto both lanes), which is why the chime, the Sound Manager path and
Prince of Persia always sounded right, and why per-register MAME oracling
never caught it: MAME's bus layer calls 8-bit device handlers once per lane,
so the divergence is invisible at the register level. **Lesson: byte-exact
register oracles do not catch access-SIZE bugs.**

Fix: `asc.sv` takes the full 16-bit write bus, pushes the UDS lane in the
strobe cycle and the latched LDS lane one clock later (`fifo_pend_*`, single
write port; the next CPU access is several clocks out so the pend slot never
collides). Both tops rewired (`MacLC.sv`, `verilator/sim.v`).
Gates: Quartus A&S clean; Verilator `check_boot.sh` PASS; frame-450
screenshot identical to the July-12 reference.

Acceptance test (PENDING USER): Reader Rabbit 2 and TIM3 music at normal
speed. TIM3's "MIDI" music is the same class — the LC has no MIDI hardware,
so game "MIDI" is a software synth writing PCM into this same FIFO.

Known remaining divergence, NOT changed: our FIFOSTAT read clears the ASC IRQ
unconditionally; MAME's V8 clears it only when the FIFO is not half-empty.
Candidate follow-up if a game still misbehaves.

## Fix 2 — SCSI write flow-control hole (`17f5a85`)

`rtl/scsi.v` `io_busy` used `(io_wr | io_ack)` for the DATA_IN term, but
between a block's `req_wr` edge and the flush actually issuing (`io_wr` rise)
neither is high — one cycle normally, longer while a previous flush is in
flight. REQ could assert in that window and one extra pseudo-DMA word landed
in the slot the pending flush had not read yet. Fix: hoist `wr_pending` to
module scope and include it in both `io_busy` clauses.

### How that was proven (repeatable recipe)

1. Pulled `Mac68KColorGames_v1.hda` and the CD's `TIM_3-mac.BIN` to
   `scratch/tim3/` (gitignored).
2. De-headered the CUE's MODE1/2352 data track to a flat ISO, mounted it with
   `hfsutils` (WSL), extracted the reference files as MacBinary.
3. `hfsutils` REFUSED the games HDA ("malformed b*-tree map node"), so
   `scratch/tim3/hfs_walk.py` (tolerant HFS walker: MDB + catalog leaf scan +
   fork extraction by CNID) got the installed copies out.
4. Compared forks (`diff3.py`).

Findings:
- Installed "TIM Audio" is byte-identical to the CD original except one
  header block the installer legitimately rewrites -> **CD read path
  exonerated**; failures are intermittent and on the write side.
- "Machine Data" (7.5 MB) is perfect except **the first 16-bit word of one
  512-byte block** (`f202` where `7500` belongs) -> damage at exactly HPS
  block granularity = the flow-control window above.
- The user's renamed failed copy ("TIM Audio badcopy") is **4 bytes longer**
  and contains alternating ~64 KB bands that were never written (they still
  hold StuffIt fragments of deleted files). **NOT explained by this fix.**
- The volume's catalog B-tree is damaged (hence hfsutils refusing it).
  Recommend Disk First Aid on that HDA before drawing conclusions from any
  future install test.

Installer note: TIM3 uses a StuffIt InstallerMaker installer (it extracts
from an archive; it is not a Finder copy).

## Open threads

1. **CD audio quality — unmeasured.** Engine is a correct 44.1 kHz fractional
   cadence; HPS serving byte-exact incl. CHD CD-DA byteswap. Remaining
   suspects: the CD stream is mixed at HALF GAIN (`MacLC.sv` ~597) and
   `sys/audio_out.sv` resamples 44.1k -> fixed 48k by zero-order hold.
   **Next step:** mount `CD3/TIM_3-mac.CUE` at RUNTIME (never at boot-attach —
   see traps), play a track, run
   `quartus_stp_tcl -t scripts/cd_meters.tcl`. Verdict table: ~44100
   changes/s = digital path clean (fix downstream: full-gain mix +
   interpolating upsampler); ~22050 = halved content (engine/serving defect);
   far lower with stutter = frame-fetch underruns.
2. **badcopy +4 bytes and the never-written 64 KB bands.** Needs a live
   capture during a failing install (PSWL / PSCW / PSD3 `dbg_wrstall` deck is
   compiled into the deployed build).
3. **TIM3 general slowness.** User retracted the "CUE loads faster than CHD"
   impression — everything is slow either way. Hypothesis worth testing
   first: driver error/retry cycles dominate (which would make container
   format irrelevant), i.e. same root as the corruption. Capture the SCSI
   command stream during a load: steady READs that are individually slow =
   serving; retry bursts + REQUEST SENSE storms = errored transfers; sparse
   commands = guest/CPU bound.
4. The write path is still a 2-slot double buffer; it never got the read
   path's ring treatment (`RING_LOG=5`). A write ring is a future throughput
   lever, counters-only (reuses the existing BUF_AW RAM).

## Ops crib (learned/confirmed this session)

- **The MiSTer screenshot service dies under heavy HPS traffic.** After a
  ~800 MB scp plus ssh/API churn, `POST /api/screenshots` returned empty JSON
  and `/dev/MiSTer_cmd` produced no file — and `scripts/grab.sh` then
  silently returns the STALE previous shot. **Always compare the returned
  filename and byte size.** A reboot cures it. Do not read "no new
  screenshot" as dead video (it cost ~15 min here).
- **PVID field order** is `[31:24]=vbl_cnt [23:16]=clut_wr [15:8]=vram_wr
  [7:0]=config` (see `rtl/dbg_probes.sv` ~313). Decoding it reversed made a
  healthy core look like dead video. `scratch/vid_delta.tcl` samples it 3x in
  one session: vbl ~61/s = timing alive; vram_wr frozen = static screen
  (a usable blind proxy for "the shutdown screen was reached").
- **Guest keystrokes:** the Remote ws `kbd:esc` does NOT reach the guest;
  RAW keycodes do — `POST /api/controls/keyboard-raw/{N}` with 1=ESC,
  108=down, 28=Enter. MacAtrium: ESC opens Quick-Launch; **Shut Down is 8
  downs below the default Settings highlight**; verified screenshot by
  screenshot, then repeatable blind.
- **Two DE10s on this bench.** `scripts/cpu_state.tcl` takes the first
  5CSE cable and hit the WRONG board (all-FF probes). `scripts/cd_probes.tcl`
  picks by probe-deck CONTENT — copy that pattern. MacLC was USB-1 today,
  but enumeration order is not stable, so always select by content.
- The running core's RBF path comes from `/proc/$(pidof MiSTer)/cmdline`
  (`/tmp/STARTPATH` is empty on this Main fork); mounted images from
  `/proc/$PID/fd`.
- `verilator/check_boot.sh` has CRLF line endings: in WSL run
  `tr -d '\r' < check_boot.sh > /tmp/cb.sh` and copy `cpu_trace.log` to
  `/tmp/` first (it looks for `/tmp/cpu_trace.log`).

## Commits / artifacts

- `ebf605e` asc byte-lane fix + CDS cadence probe + `scripts/cd_meters.tcl`
- `17f5a85` scsi `io_busy` `wr_pending` hole
- Uncommitted (intentional): `MacLC.qsf` probe-macro flips
- `scratch/tim3/` (gitignored): `TIM_3-mac.BIN`, `TIM3-data.iso`,
  `Mac68KColorGames_v1.hda`, MacBinary refs, extracted forks
  (`tim_audio_ref.rsrc` `193891db`, `tim_audio_installed.rsrc` `e1411dac`,
  `tim_audio_badcopy.rsrc`, `machine_data_ref.dat` `11cac512`,
  `machine_data_installed.dat` `6ddf8f75`), plus `hfs_walk.py`,
  `analyze_fork.py`, `diff3.py`
- `scratch/`: `vid_delta.tcl`, `send_keys.py`, `cpu_state_usb1.tcl`,
  boot/shutdown screenshots
