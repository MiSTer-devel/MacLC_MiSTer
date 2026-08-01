# Toolbox download: the last byte per 64 KB — CLOSED 2026-08-01 (client bug)

**Outcome: the server side is fixed and proven. The residual defect is a bug
in the guest client app. A working mitigation exists: `TB_CAPS=0x00` (build
`c9b3afd7`) makes the app fall back to small chunks in both directions and
the 2 MB round trip is byte-identical — at the cost of upload speed only
(192 → ~26 KiB/s; downloads stay ~120 KiB/s because they are guest-disk-bound
and large GETs never actually bought download speed).**

This doc originally claimed a one-line HPS change would finish the mission.
That change was necessary and landed (below), but the 32-wrong-byte round trip
persisted — and a both-ends instrumented session proved the remaining loss
happens INSIDE the guest app. Do not re-chase the last byte server-side; the
only server-side lever is the caps advert (§2a).

## 1. What was proven, with instruments on both ends

Setup: HPS field fix live (byte 4 carries length[16]) + core `914e07cc`
(17-bit `TBS_LATCH2` decode), one 2 MB download of `TBT.BIN`, HPS file-trace
build + core JTAG length-probe build (`e3c31edf`, working-tree only).

| stage | evidence | value |
|---|---|---|
| HPS stage | `/tmp/tb_status.log` (temp trace) | every chunk `GET want=65536 got=65536`, status wire `[00 B5 00 00 01]` |
| core latch | JTAG `scratch/tblen.tcl` (CDA3/CDA1) | `tb_len=0x10000`, raw byte4-as-read `=0x01` |
| core serve | JTAG CDA4 (data_cnt at serve-phase end) | **65536 bytes served and ACKed by the initiator** |
| guest file | round-trip md5 | still `65dd74f0` — zero at `offset%65536==65535`, byte-identical to the pre-fix artifact |

All 65536 bytes cross the SCSI bus; the app writes 65535 of them (16-bit arm;
the Mac SCSI Manager's phase cleanup reads and discards the extra byte) and
advances its file position by the full 16-block ask.

## 2. What is and is not fixable server-side

Disproven (do not retry):

- **Serve fewer, block-aligned bytes (e.g. 15 blocks) for a 16-block ask:**
  the app advances by its ASK, not by bytes received — proven by the 07-31
  capture where 4096-byte responses landed "spaced 16 apart". Under-serving
  turns 1 lost byte into a 4 KB hole per chunk.
- **Byte shuffling / overlap tricks:** the client writes the first 65535
  received bytes at `k*65536` and nothing else; the last position of each
  window is unreachable by construction.

### 2b. Second-client control: MacAtrium is byte-exact on the FAST core

The decisive independent test (2026-08-01). MacAtrium's own Toolbox client,
driven through **Toolbox Shared Files**, copied `TBT.BIN` SD → Mac
(MacAtrium/Incoming) and back Mac → SD on the **same fast core `914e07cc`
and same HPS `dda65f18`** that gives the SD Transfer app its 32 wrong bytes.
Result: **`c42818…` — byte-identical to the pristine fixture.** The SD file
was genuinely rewritten (watched growing 131072 → 2097152, mtime updated),
so this is a real round trip, not an untouched file.

Two clients, one unchanged server, opposite outcomes — the server is
exonerated by construction, and the defect is the SD Transfer app's.

MacAtrium is immune by design (`src/filebrowse.c`): `fb_copy_in` hardcodes
`CDB[6]=1` (4 KB per GET) and `fb_send_stream` caps chunks at 4 KB, so it
never presents a 65536-byte transfer; it reads the caps byte only for
`TB_CAP_WORKDIR`, never for transfer sizing. **MacAtrium is therefore
unaffected by whichever `TB_CAPS` we ship.** Measured on the fast core:
copy-in 2 MB in under 60 s, copy-out ~39 KiB/s.

### 2a. The caps lever WORKS (2026-08-01, user-prompted A/B)

The 07-31 note "the app issues CDB[6]=16 regardless of what we advertise" was
an **overclaim** — that capture only ever ran under `TB_CAPS=0x02`. A/B build
`c9b3afd7` (`TB_CAPS=0x00`, sole change) on the same HPS: the app falls back
to small chunks in BOTH directions and the 2 MB round trip is **byte-identical
(pristine md5 `c42818…`)**. Measured: upload ~26 KiB/s (512-byte v0 chunks),
download ~121 KiB/s app-reported — the SAME download rate as 64 K mode, i.e.
downloads are guest-disk-bound and large GETs never bought speed. The bits
cannot be split (GETs go large under 0x02-only), so the choice is:

| config | SD Transfer uploads | SD Transfer downloads | SD Transfer correctness | MacAtrium |
|---|---|---|---|---|
| `TB_CAPS=0x02` | ~192 KiB/s | ~120 KiB/s | >64 K downloads lose 1 byte/64 K | byte-exact, ~39 KiB/s out |
| `TB_CAPS=0x00` | ~26 KiB/s | ~120 KiB/s | **everything byte-exact** | identical (ignores caps) |

Since MacAtrium is unaffected either way (§2b), the choice is purely about
the third-party app: `0x00` = correct-but-slow for it, `0x02` = fast uploads
for it at the cost of its own >64 K download corruption.

Scope of the 0x02 defect: downloads of files **> 65535 bytes** lose the last
byte of each full 64 KB window (final short chunk intact; files ≤ 65535 bytes
round-trip exact). Uploads byte-exact in both configs.

## 3. The client bug itself (for an upstream report)

- App: **BlueSCSI SD Transfer 1.1.0b5** (repo `erichelgeson/BlueSCSI-Toolbox`
  ships binaries only, no source; newest public = 1.0.2 stable / 1.1.0b4 beta).
- Real BlueSCSI v2 hardware serves full 64 KB too (`onGetFile10` caps at
  `sizeof(scsiDev.data)` = `SCSI2SD_BUFFER_SIZE` = 8192×8 = 65536), so the
  same corruption should reproduce against genuine hardware — worth reporting
  with our bus-level evidence.
- Suspected mechanism: a 16-bit transfer arm (65535) in the app's read TIB,
  same clamp pattern our HPS had.

## 4. What shipped (keep all of it)

- **Main_MiSTer** branch `add-bluescsi-toolbox-for-MacLC`, commit `4510442`
  "report the response length as 17 bits (byte 4 bit 0)". Deployed binary
  `dda65f18` — bit-identical to a clean rebuild of that commit (determinism
  proof). Rollback chain on the box: `MiSTer.prev` = de49280e (pre-byte-4),
  `MiSTer.prev2` = cbd9db75.
- **Core**: `releases/MacLC_20260801.rbf` = `914e07cc`, unchanged this
  session, redeployed to `_Unstable/MacLC.rbf` and boot-gated (`94fedd19`).
  The 17-bit decode (`8a786ce`) is required — an old core would read length 0
  for a full 65536 response and serve nothing.
- Probe artifacts (never commit): `scratch/MacLC_TBLEN2_e3c31edf.rbf`,
  `scratch/tblen.tcl`, the CDA rewire pattern in
  `scratch/tbp_probe_diff_20260731.patch`.

## 5. Ops lore learned this session

- Box inittab is `::sysinit:/media/fat/MiSTer &` — `killall MiSTer` does NOT
  respawn. Relaunch manually (`nohup /media/fat/MiSTer >/dev/null 2>&1
  </dev/null &`) or reboot. Replacing the file takes effect only via a Main
  restart, whichever form.
- MacAtrium Quick-Launch auto-dismisses after a few seconds: pre-position the
  mouse on the target button FIRST, then Esc, then click immediately.
- The guest mouse BUTTON path can wedge mid-session (moves + keyboard stay
  live). Return presses the default button of a dialog; a core reload clears
  the wedge. `scratch/mouse.sh` clicks are otherwise reliable.
- Clean shutdown from the Finder: Cmd+Q the app, then Special-menu drag
  (`down` at (232,9), `walk 0 130`, `up`); shutdown screen md5 `73624ddc`.
- The SD fixture `/media/fat/games/MacLC/shared/TBT.BIN` is pristine
  (md5 `c42818124581bcf115c913eefcd12972`); local pristine copy =
  `scratch/TBT_full_rt.bin`.
