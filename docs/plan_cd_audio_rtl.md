# CD Audio — RTL engine plan (branch `add-cd-audio`)

Status 2026-07-16: HPS side DONE and deployed (Main fork `f38b189`): full-TOC
track tables for cue/chd/raw, plus two out-of-band block windows the RTL
consumes — the contract (window addresses, MCDA blob format, byte order,
silence rules) lives in `Main_MiSTer/support/maclc/maclc_cd.h` and is the
authoritative reference. This doc covers the core side.

## Oracle (byte truth)

MAME `nscsi_cdrom_apple_device` (`../mame/src/devices/bus/nscsi/cd.cpp`),
the same oracle our INQUIRY/TOC/sense already match. Command set:

| op | name | semantics (v1 scope) |
|---|---|---|
| 0xC8 | AUDIO TRK SEARCH | seek; CDB[9]: 00=LBA, 40=MSF(BCD, bytes 5-7), 80=track(BCD, byte 5; track 0 = stop). CDB[1] bit4: 1=play after seek, 0=hold paused. Track mode also sets stop=next track start |
| 0xC9 | AUDIO PLAY | CDB[9] modes as above but MSF in bytes 3-5; track 0 = stop. CDB[1] bit4: 0=addr is START (stop from prior 0xCB), 1=addr is END (start = current pos) |
| 0xCA | AUDIO PAUSE | CDB[1]==0x10 pause; else unpause (+cancel scan) |
| 0xCB | AUDIO STOP | sets stop_position (modes as 0xC8); halts only if already past it |
| 0xCC | AUDIO STATUS | 6B in: status(0=play,1=paused,2=muted,3=end,4=err,5=idle), 0, adr_ctrl, BCD M/S/F absolute (NO +150 — matches our TOC convention) |
| 0xCD | AUDIO SCAN | v1: seek only (no fast-scan rate); ends on PAUSE-off |
| 0xCE | AUDIO CONTROL | DataOut, discarded (already implemented) |
| 0xC2 | READ Q SUBCODE | 9B in: ctrl, BCD track, index=1, BCD rel M/S/F, BCD abs M/S/F |

Interactions: READ(6/10/12) while playing STOPS audio (oracle-mandated);
eject stops audio; no-disc → existing NOT-READY/0xB0 sense path.

## Architecture

New `rtl/cd_audio.sv`, instantiated INSIDE `scsi.v` under `CDROM != 0`
(zero cross-hierarchy plumbing except sound out). Owns:

1. **TOC blob**: fetched at mount from block `0x7FFF_0000` (2 blocks) via the
   existing io channel; magic "MCDA" → multi-track TOC RAM (1KB dpram);
   invalid magic (stock Main, sim, flat image) → fall back to today's
   synthesized single-track TOC. Mount-time FSM precomputes the full 0xC1
   READ TOC response bytes (per-track BCD MSF via the existing iterative
   divider) into a response RAM; `cd_toc_byte` serves from it.
2. **Playback state**: cur_lba, stop_position (init leadout at mount),
   playing/paused/stopped/ended; track lookup by LBA (sequential scan FSM
   over TOC RAM) for STATUS/SUBQ; MSF conversions on demand (divider FSM,
   these are command-time rare).
3. **Audio fetch**: when playing and the data path is idle, drives the io
   channel with audio-window addresses (`0x4000_0000 + lba*5 + k`), 5 blocks
   per frame into a 2-frame ping-pong buffer (2×2560B dpram). Data commands
   preempt (and stop playback anyway, per oracle).
4. **Sample engine**: fractional accumulator clk_sys→44.1kHz; 16-bit LE
   stereo from the frame buffer; playhead +1 sector per 588 samples; stop at
   stop_position → REACHED_END. Outputs signed cd_l/cd_r.
5. **Mixing**: scsi.v(cdrom) → ncr5380 → dataController_top → MacLC.sv,
   summed into the existing audio output at half gain, saturating.

## Budgets / gates

M10K: +1KB TOC + ~0.5KB response + 5KB frames ≈ 7KB (~7 M10K) — fits the
budget that capped the CD ring at RING_LOG=3. Gates: A&E → verilator parse →
sim boot regression (audio idle = inert; blob magic fails in sim → fallback
path exercised) → full build → STA + display check → HW with a mixed-mode
cue/chd + AppleCD Audio Player / CD Remote on the guest. Wedge watch: audio
adds background slot-4 traffic — retest "play audio while copying from HDD"
(the #2/#3 interleaving surface).

## v1 non-goals

Fast-scan audible rates (SCAN seeks only), CDDA de-emphasis, volume via
AUDIO CONTROL page (full volume; page accepted and discarded), subcode R-W.
