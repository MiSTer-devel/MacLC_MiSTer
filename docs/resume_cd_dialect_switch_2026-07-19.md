# RESUME: CD dialect switch — AppleCD-150 vendor set → standard SCSI-2 (CDU-8004 identity)

Branch: `add-cd-audio`. Mission started 2026-07-19 morning; user directive:
drive the TRACK LISTING first via the dialect switch; STOP chasing audio
distortion (plausibly downstream of TOC/read issues).

## Why (the evidence trail, 2026-07-18/19)

- CD audio PLAYS (engine + transport proven; see
  `resume_cd_audio_debug_2026-07-17.md` addenda). But the AppleCD Audio
  Player shows 2 tracks for a 22-track disc, displays "Track 0" while
  playing, and CDA2 probe capture proved its launch walk asked ONE op-0x80
  descriptor (start=01, alloc=4) then quit — it believes the disc is tiny.
  Every stage of our 0xC1 serving desk-checks byte-correct vs MAME; the
  lying byte was never found. The 150/Sony vendor dialect is undocumented
  black-box territory.
- **Snow** (WSL `~/repos/snow`, the house oracle that solved the Welcome
  wedge) presents `SNOW    ` / `CD-ROM CDU-8004 ` (rev 1.9a) — the
  AppleCD **300** mechanism — and the same Apple driver+player then speaks
  the STANDARD dialect: 0x43 READ TOC (format = cdb[9]>>6), 0x47 PLAY
  AUDIO MSF, 0x42 READ SUB-CHANNEL, 0x4B PAUSE. Fully working player.
  **BlueSCSI-v2** (`C:\Temp\BlueSCSI-v2\src\BlueSCSI_cdrom.cpp`,
  S2S_CFG_QUIRKS_APPLE) implements the same standard set for real Macs.
  Two local, field-proven reference implementations.
- The driver gates on the PRODUCT string `CD-ROM CDU-8*` (the "generic
  identity refused" law was about non-CDU identities). 8003A → vendor
  dialect; 8004 → standard dialect. We switch to 8004.

## The plan (order matters — identity switch goes LAST)

1. **0x43 READ TOC, format 0** (MMC): header {u16be data-len, first=1,
   last=N (BINARY, not BCD)} + 8-byte descriptors {00, adr_ctrl, track#
   (binary), 00, addr[4]} + lead-out row (track 0xAA). addr = {00,M,S,F}
   hex (NOT BCD) with the +150 offset when cdb[1]&2 (MSF=1), else u32be
   LBA. Reference: Snow `read_toc()` (~line 422) — mirror its behavior
   incl. start-track filter (cdb[6]) and truncate-to-alloc.
   Implementation: NEW cd_sdp plane pair (512B, 2 M10K of the 58 free) so
   the 0xC1 planes stay untouched; extend cd_audio's emit chain after
   M_BUILT with states that build the 0x43 table from the SAME blob +
   divider (div_m/div_s/div_v are BINARY before bin2bcd — use directly;
   cap 60 tracks, 4+61*8=492 ≤ 512). Serving: new cmd decode + base/len
   (min(alloc, table_len)) + a 4-lane readback mirroring ca_toc_q*.
2. **Standard audio commands mapped onto the EXISTING engine** (the
   engine/ops don't change; only decodes):
   - 0x47 PLAY AUDIO MSF {start M,S,F @ cdb3-5, end @ cdb6-8, hex,
     -150} → engine play(start_lba, end_lba). Snow: `0x47`.
   - 0x48 PLAY AUDIO TRACK/INDEX (start trk cdb4, end trk cdb7) →
     resolve via blob table like the 0xC8 path.
   - 0x4B PAUSE/RESUME (cdb8 bit0: 0=pause 1=resume).
   - 0x4E STOP PLAY.
   - 0x42 READ SUB-CHANNEL: standard layout (Snow ~line 1200 area,
     'sub-channel format' handling; format 1 = current position:
     {00, audio-status, u16be len, 01, adr_ctrl, track BINARY, index,
     abs u32 (MSF or LBA), rel u32}) — served from the SAME live
     registers (ast_code map: our 0/1/3/5 → standard 0x11 playing /
     0x12 paused / 0x13 done / 0x15 stopped... VERIFY against Snow's
     status codes).
   - 0x1B START STOP UNIT (eject bit) → existing eject hook.
   - 0x25 READ CD-ROM CAPACITY: exists (standard) ✓ verify block size
     2048 reporting.
   - 0xCD (AppleCD player FF/RW, per BlueSCSI): accept-no-op initially.
3. **INQUIRY switch**: product bytes 16..31 → `CD-ROM CDU-8004 ` , rev
   `1.9a`-style; vendor field keep current (product is the gate; law
   `no-competitor-names-in-source` — parameterized vendor stays).
   THIS COMMIT LAST — it atomically flips the driver's dialect.
4. Keep the whole 0xC1/0xC2/0xCC/0xC8.. vendor set answering as today
   (legacy; harmless dual-dialect).
5. Gates per house law: A&E + map audit per commit; fat-slack build
   (per-fit marginality law! +0.24-class or roll seed); deploy; user
   verdict: player lists 22 tracks, PLAY/pause/skip work, position
   advances. THEN revisit distortion (may vanish with correct TOC-driven
   addressing).

## State snapshot at mission start

- Deployed: 0170576s5 (+0.247, md5 256bd46d) — vendor dialect, music
  plays, 2-track listing bug live.
- Probes: CDA0/1 as before; CDA2 latches op-0x80 0xC1 asks only (repoint
  to 0x43 asks when the dialect flips: same latch, condition swap —
  worth doing IN the dialect commit).
- All repos clean/pushed at `0170576`. MiSTer .143; instrumented Main
  (fork + stderr DIAG) resident and healthy.
- Per-fit marginality law in force: STA-met ≠ stable; +0.24-class slack
  + boot-probe (CPU alive, no req_drop saturation) before user soak.
