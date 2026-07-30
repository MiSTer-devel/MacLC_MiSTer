# SCSI CD-ROM Command Gaps — audit 2026-07-20 (largely CLOSED 2026-07-29)

> **STATUS 2026-07-29 (night):** most of this list is now implemented on
> branch `cd-volume-v2`. Closed: Ring-1 partial 2 (page 0x0E volume —
> the AppleCD slider works, confirmed by ear on hardware), Ring-1
> partial 1 (0x42 formats 2/3), Ring-2 MED rows 0x44 and 0x45/0xA5, and
> Ring-2 LOW 0xBB. Also fixed: 12-byte (group-5) CDBs never completed,
> which hung the target on ANY such command — a latent bus wedge.
> Still open, with reasons, in the new §"Deliberately not implemented".
>
> **A methodological warning worth more than the command list:** the
> 2026-07-29 daytime session concluded these commands "fail the hardware
> gate" and built a whole fit-marginality theory (serve-mux depth pushing
> a shared cone marginal) on top of that. It was wrong. The failures were
> the project's known **CUE/CHD-attached-at-boot hang**, which fires
> intermittently on ANY build — it was reproduced on a KNOWN-GOOD RBF,
> producing a screenshot byte-identical to the one used as proof of the
> "failure". Gate CD work with the CD image DETACHED from boot config
> (`config/MACLC.s4` moved aside), and mount via the OSD after the
> desktop is up.

Audit of our CD target (`rtl/scsi.v` CDROM path + `rtl/cd_audio.sv` engine,
as of `185645c`) against both oracles:

- **BlueSCSI-v2** `C:\Temp\BlueSCSI-v2\src\BlueSCSI_cdrom.cpp` (field-proven
  with real Macs; line numbers below from the 2026-07 checkout)
- **Snow** WSL `~/repos/snow/core/src/mac/scsi/cdrom/mod.rs` (working AppleCD
  player against the CDU-8004 identity; its dispatch ≈ the driver's ACTUAL
  working set)

Context: audited the day the AppleCD Audio Player transport went green
(22-track listing, play/pause/resume/Next/Prev/Stop all working on
`185645c` s13). **Per user direction these gaps are LOGGED, not being
resolved now.**

## Ring 1 — the driver/player working set: state

| Op | Command | Status |
|---|---|---|
| 0x00/0x03/0x12 | TUR / REQUEST SENSE / INQUIRY | ✅ proven |
| 0x08 (0x28) | READ + pure-audio rejection 5/0x64 | ✅ proven (Finder-bomb fix) |
| 0x1B / 0x1E | START-STOP (eject bit) / PREVENT | ✅ proven |
| 0x43 | READ TOC fmt 0 + apple ctrl-byte 0x80 (full TOC, BCD) / 0x40 (session) | ✅ proven |
| 0x47 / 0x4B | PLAY MSF (incl. FF:FF:FF=from-current, start==end=seek-only) / PAUSE-RESUME | ✅ proven |
| 0x48 / 0x4E | PLAY TRACK-INDEX / STOP | ✅ (0x48 desk-checked; 0x4E accepted) |
| 0x01, 0x0B, 0x2B | REZERO (= player STOP) + SEEK(6/10), all stop-audio | ✅ proven (REZERO = the Stop button) |
| 0xC0..0xCE vendor set | EJECT/TOC/SUBQ/ASTAT/ACTL/SEARCH/PLAY/PAUSE/STOP/SCAN | ✅ legacy dual-dialect, HW-proven pre-switch |

### Ring-1 PARTIALS (user-visible, small, well-oracled)

1. **✅ CLOSED 2026-07-29 (`783573a`) — 0x42 READ SUB-CHANNEL formats.**
   Was: format-1 (position) served regardless of the requested format, so
   MCN (fmt 2) / ISRC (fmt 3) asks got position-layout garbage. Now serves
   the BlueSCSI-style fmt 2/3 layouts (header + format echo + ISRC track
   echo, VALID=0 with zeroed digits — the truthful answer, since our image
   containers carry no MCN/ISRC metadata). Format 0 and unknown formats
   keep the position fallback. Oracle: BlueSCSI 2486. Note Snow instead
   CHECKs every non-1 format, which is the weaker behaviour.
2. **✅ CLOSED 2026-07-29 (`24ac11a`) — MODE SENSE/SELECT page 0x0E, the
   AppleCD volume slider.** MODE SELECT page 0x0E is parsed (block-
   descriptor-aware) into four {channel, volume} audio ports; MODE SENSE
   serves them back so the slider holds position; ports 0/1 scale the
   CD-DA PCM in `cd_audio.sv`. **Confirmed working on hardware by ear**
   (volume swept down and back up on a playing track, 2026-07-29 night).
   Pages 0x01/0x03/0x2A remain unserved by choice — see "Deliberately
   not implemented".
3. **0xCD AUDIO SCAN (FF/RW) — OPEN, dynamics unproven.** See section
   below. Status at audit time: implemented as ±8-sectors-per-frame scan
   (`185645c`), user reports "still not working correctly", symptom +
   watch capture pending. NEITHER oracle implements it (BlueSCSI rejects
   `commandHandled=0` @2599 with the format documented in comments;
   Snow decodes fully then logs "not implemented" and keeps playing at
   1×) — so FF/RW is degraded on both references too; we are the first
   real attempt. Field-proven facts: cdb1 0x00=FF (BlueSCSI comment
   right, Snow's bit reading inverted vs our capture), MSF in cdb3-5
   with cdb9=0. Conservative fallback if the player fights a true scan:
   Snow-exact behavior (accept, no state change, keep playing 1×).

## Ring 2 — BlueSCSI surface we don't cover (by priority)

| Pri | Op(s) | Command | BlueSCSI | Notes |
|---|---|---|---|---|
| HIGH | 0xD8 / 0xD9 | Apple "CD-DA over SCSI bus" (LBA / MSF forms, 2352-byte raw audio reads, 12-byte CDBs) | 2614/2636 `doAppleD8` | Digital audio extraction (QuickTime-era ripping, AppleCD 300 features). 0xD9 collides with Toolbox DEVICE INFO **on the primary target only** — the CD target is free to implement. Data path = new 2352-byte serving plane or HPS raw-read leg. |
| ✅ | 0x45 / 0xA5 | PLAY AUDIO(10)/(12), LBA form | 2379/2393 | **CLOSED `789179f`** (+ `4938734` for the 12-byte form). 0xFFFFFFFF = from-current; length 0 = seek-only. |
| ✅ | 0x44 | READ HEADER | 2327 | **CLOSED `dfc3505`**, LBA form; MSF form CHECKs 5/0x24 (needs an LBA→MSF divide the serve path lacks). Mode byte is disc-level (audio vs data), not per-LBA. |
| LOW | 0xBE / 0xB9 | READ CD / READ CD MSF (MMC raw) | 2457/2475 | Later ripping software; sector-type filters. |
| LOW | 0xA8 | READ(12) | 2523 | Trivial once wanted. |
| LOW | 0x51 / 0x52 | READ DISC INFO / TRACK INFO | 2353/2360 | MMC-era. |
| LOW | 0x4A / 0xBD | EVENT STATUS / MECHANISM STATUS | 2373/2445 | MMC-era, no askers. |
| ✅ | 0xBB | SET CD SPEED | 2451 | **CLOSED `77e8295`**, accept-noop (speeds are advisory; our rate is the HPS ring's). |
| LOW | 0xD8 (non-quirks) | Plextor READ CD-DA | 2540 | Same engine as apple 0xD8 if ever done. |

## Deliberately not implemented (2026-07-29 decisions)

| Op(s) | Why not |
|---|---|
| 0xA8 READ(12) | Now *reachable* (12-byte CDBs complete), but wiring it means touching the LBA/tlen latch on the most proven path in the design — `tlen` is 16-bit while READ(12) carries a 32-bit block count. Zero observed askers. Do it only with a real asker and a full read regression. |
| Mode pages 0x01 / 0x03 | Snow serves them as all-zero payloads; our default MODE SENSE already returns a valid generic response, so the only difference is cosmetic. No information content. |
| 0x51 / 0x52 / 0x4A / 0xBD | MMC-era; neither oracle implements them for this drive identity and no classic-Mac software asks. |
| 0xBE / 0xB9 READ CD, 0xD8 Apple CD-DA | Need a 2352-byte raw serving plane (and Main-side work for the raw leg). Real project, not a command gap. |
| SOTC (stop-on-track-crossing) in page 0x0E | Parsed and ignored, exactly as Snow does — no software is known to set it. |

## Pointers for whoever picks these up

- Our decode inventory: `rtl/scsi.v` ~1400-1485 (`cmd_*` wires),
  `cmd_ok_cd` ~1517, `data_len` mux ~1206, sense chain ~1560.
- Engine command surface: `rtl/cd_audio.sv` M_CMD (~870) / M_APPLY /
  M_SCAN_GO; playhead advance ~441.
- Serving law (MANDATORY for any new DataIn command): transfer EXACTLY
  what the initiator arms — tlen = alloc (capped), zero-fill past the
  real payload, true length in headers. Both violation directions are
  HW-witnessed wedges (2026-06-10 over-serve, 2026-07-19 under-serve).
- Probe visibility: add any new op to `cmd_play_class` (CDA3/4 latch) or
  it will be invisible under the 0x42 poll flood.
