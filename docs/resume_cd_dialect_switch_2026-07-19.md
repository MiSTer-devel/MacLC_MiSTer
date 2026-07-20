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


## STATE ADDENDUM (written mid-lottery, ~09:30 2026-07-19)

**The implementation is DONE and pushed** — all four phases landed this
morning in one driving session:

| Commit | Content |
|---|---|
| 825876a | T43 table build (M_T43_* states + plane quartet, cap 60, +150 MSF hex) |
| fdd6ce7 | 0x43/0x42 serving + 0x47/0x48/0x4B/0x4E onto the engine; binary live regs (vendor BCD at serve); 0x1B LoEj eject; c_trk2 generalization; cdb8 latch |
| 202b07e | THE FLIP: INQUIRY CDU-8002/1.8g -> CDU-8004/1.9a + ANSI-2; CDA2 latches 0x43 asks {flags9, start6, alloc} |

Audits clean at every step (final: 34,470 regs / 3,930,474 bits = exactly
+8,192 for the T43 planes; no flips).

**Remaining: the fit lottery + the hardware verdict.**
- seed 5: +0.105 — REJECTED (thinner than the +0.177 that boot-wedged;
  per-fit marginality law). Never deployed.
- seed 6: building at time of writing (scratch/build_dialect_s6.log).
- Procedure: roll seeds until +0.24-class worst slack, stage hash-named,
  deploy, BOOT-PROBE first (cd_probes.tcl + psdt_read.tcl: CPU alive,
  no req_drop saturation, toc_ready=1/toc_valid=1/n_tracks=22 on the
  auto-mounted CHD), THEN the user test:
  1. AppleCD Audio Player -> expect ALL 22 TRACKS listed (the driver now
     speaks 0x43 to the 8004 identity; the table is byte-verified).
  2. PLAY (0x47 path) / pause+resume (0x4B) / skip / STOP (0x4E);
     position display live via 0x42 (binary, current-position format 1).
  3. If anything is off: read CDA2 (the exact 0x43 ask) + CDA0/1; the
     serving is fully determined by {ask, table}, so divergences are
     arithmetic again.
- Fallback rbf if the dialect misbehaves: 0170576s5 / b46d8bcs5 era
  (vendor dialect, music-works-2-track state) in scratch/.

**Watch-outs for the tester/next session:**
- The driver MAY probe additional standard commands we accept-noop or
  don't implement (e.g. 0x4A notifications, MODE SENSE pages). CDA1
  last_op + sense shows any rejection; extend the ok-set as evidence
  arrives.
- The 0x43 start-track filter (cdb[6]>1) serves the full table in v1 —
  fine for the known driver pattern (start 0/1); revisit if CDA2 shows
  bigger starts.
- LBA-form (cdb[1] MSF bit clear) serves MSF-form values in v1 — the
  known driver always asks MSF; revisit on evidence.
- Distortion investigation stays PARKED per the user until the TOC/read
  path is proven (it may simply vanish).

## Fit ledger + law refinement (2026-07-19 late morning)

| Seed | Netlist | Scalar | pll_hdmi setup | Boot-probe | Verdict |
|---|---|---|---|---|---|
| 5 | dialect | +0.105 | thin | not run | rejected (law) |
| 6 | dialect | +0.126 | thin | not run | rejected |
| 7 | dialect | +0.192 (HOLD-ltd) | **+0.42** | **CLEAN** (berr=0, CDA green, driver conversing) | ~~DEPLOYED~~ **FIELD-QUARANTINED 07-19 eve: BLACK SCREEN** |
| 8 | +filter | +0.158 | +0.158 | not run | rejected |
| 9 | +filter | +0.252 | **+0.64** | **FAILED: CDA hub gone, berr=36, 250ms stall peg** | QUARANTINED |

**LAW REFINEMENT (s9's lesson): STA slack — even fat, per-domain-read —
does NOT clear a fit. The BOOT-PROBE is the real gate** (instruments
enumerable + berr=0 + no stall peg + CPU alive). s9 had the mission's
best numbers and a sick boot; s7 has middling numbers and a clean one.
Also: the scalar mixes setup/hold — always read the per-domain summary.

**Standing state:** s7 (4125a2f, md5 468e811a) deployed = full dialect
minus the start-filter (leadout-length quirk visible as wrong disc
duration). The filter netlist (b3ec132+) still needs a healthy fit —
roll seeds ≥10, boot-probe each. The 22-track user verdict runs on s7.

## EVENING ADDENDUM (2026-07-19 ~21:00): s7 BLACK-SCREENED IN THE FIELD

User report: "not getting video anymore." Remote diagnosis confirmed:
- Box power-cycled fresh by the user, MACLC (s7 launchable, pushed
  10:56) running, CPU-side alive — but Main could not produce a
  screenshot (stale MacIIvi 07-18 file returned = **no core vsync
  reaching Main**). Main binary (07-17) and MiSTer.ini (06-16)
  untouched — not the framework, not the board.
- A/B: pushed fallback **0170576s5** (256bd46d) as the launchable,
  relaunched → fresh MACLC screenshot, **happy-Mac on grey pattern,
  video fine**. User's own power-cycle + s7 = black rules out the
  07-17 board-PLL condition. s7 = the never-root-caused
  **black-screen fit class** (seed-2 precedent, CD-ROM mission).
- The morning session ran s7's boot-probe but **skipped the per-seed
  display check** (MEMORY law) — the s9 lesson ("boot-probe is the
  real gate, not STA") over-corrected. s7 boot-probes clean AND
  black-screens: the two gates catch **disjoint** failure classes.

**LAW (final form): a fit clears only on the TRIPLE gate —
(1) fat per-domain STA, (2) boot-probe (berr=0, no stall peg,
instruments alive), (3) DISPLAY CHECK (fresh screenshot showing
video).** No single gate subsumes another: s9 passed (1) failed (2);
s7 passed (2) failed (3).

- Box restored: launchable = 0170576s5 (vendor dialect, music plays,
  2-track bug live). **The 22-track dialect test has NEVER run** — no
  dialect-netlist build has yet passed all three gates.
- Next: SEED 10 on the filter netlist (HEAD), triple gate, then the
  user verdict. s7 rbf kept in scratch/ for the black-screen
  root-cause pile.