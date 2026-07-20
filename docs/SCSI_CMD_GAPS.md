# SCSI CD-ROM Command Gaps — audit 2026-07-20 (DEFERRED, not scheduled)

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

1. **0x42 READ SUB-CHANNEL serves format-1 (position) regardless of the
   requested format.** MCN (fmt 2) / ISRC (fmt 3) / full-subQ (fmt 0) asks
   get position-layout garbage. Oracle: Snow `0x42` format switch
   (~line 1168/1208); BlueSCSI 2486. Risk: disc-identification features.
2. **MODE SENSE/SELECT page 0x0E (CD Audio Control) unimplemented — the
   player's VOLUME SLIDER is a no-op.** We serve pages 0x30/0x31 + a
   12-byte default and DISCARD all MODE SELECT data. Snow implements 0x0E
   read+write with 4 audio ports {channel, volume} (~lines 991/1041);
   volume should feed the engine's PCM scale. Also Snow serves pages
   0x01/0x03/0x2A we don't (no observed asks).
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
| MED | 0x45 / 0xA5 | PLAY AUDIO(10)/(12), LBA form | 2379/2393 | Alternate play path; length in blocks; 0xFFFFFFFF LBA = from-current (2551). |
| MED | 0x44 | READ HEADER | 2327 | Track-type probing by utilities. |
| LOW | 0xBE / 0xB9 | READ CD / READ CD MSF (MMC raw) | 2457/2475 | Later ripping software; sector-type filters. |
| LOW | 0xA8 | READ(12) | 2523 | Trivial once wanted. |
| LOW | 0x51 / 0x52 | READ DISC INFO / TRACK INFO | 2353/2360 | MMC-era. |
| LOW | 0x4A / 0xBB / 0xBD | EVENT STATUS / SET CD SPEED / MECHANISM STATUS | 2373/2451/2445 | MMC-era; SET SPEED could be accept-noop. |
| LOW | 0xD8 (non-quirks) | Plextor READ CD-DA | 2540 | Same engine as apple 0xD8 if ever done. |

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
