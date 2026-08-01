# Resume — Toolbox GET ring race: the stale-sector serve (2026-08-01)

**✅ MISSION COMPLETE (2026-08-01 PM session). Do not re-run this prompt.**
Fix `7a6935a` (watchdog → bounded retry + `!tb_ack` issue gates), caps 0x03
`7e6d321`, build `5a181d40` = `releases/MacLC_20260801.rbf`, deployed + boot-
gated twice (`94fedd19`). 3× 2 MB MacAtrium round trips byte-exact
(`c42818…`), incl. one under a deliberate SD write storm (downloads dipped
56 KB/s = retries exercised live). Downloads 33 → ~91 KB/s. §3's suspicion
was verified on the bench first (`scsi_bench --mode toolboxget`, deferred-
latch HPS model, exact −16 signature) plus a second same-family defect
(status-ack-live fetch arm killing sector 0) found by the now-gating
`toolboxslow` probe. SEND-side ship watchdog hardening filed as a follow-up
chip. Historical content below.

---

Paste the block below as the opening message of the next session.

---

## THE PROMPT (paste this)

> Fix the BlueSCSI Toolbox multi-block GET stale-sector race on the MacLC
> core (`C:\Temp\mistercore\MacLC_MiSTer`, branch `toolbox-large-files`).
> Read `docs/resume_toolbox_ring_race_2026-08-01.md` first — it is the
> authoritative state.
>
> The defect is ALREADY DOCUMENTED in the RTL as a known gap
> (`rtl/scsi.v`, the `TBS_DATA` comment block) and was confirmed live on
> hardware 2026-08-01: a 2 MB download corrupted exactly ONE 512-byte
> sector, serving the ring slot's previous occupant from one full 8 KB
> ring cycle earlier. The suspected mechanism is named in §3 — verify it,
> do not assume it.
>
> A previous fix attempt ("positive fill evidence") was REVERTED. The RTL
> comment says why: do not retry it without HW-faithful bench coverage of
> the watchdog-primary path first. Build that bench case BEFORE the fix.
>
> Expected end state: a bench case that reproduces the stale serve fails
> before the fix and passes after; `TB_CAPS = 8'h03` then round-trips a
> 2 MB file byte-exactly through MacAtrium on hardware, unlocking ~91 KB/s
> downloads (from 33).

---

## 1. What is broken

Advertising `CAP_LARGE_TRANSFERS` (bit 0) lets clients issue multi-block
GETs. The serve then streams through the 8 KB ring — and can hand out a
sector the HPS never delivered.

Measured on hardware (build `020cd964`, `TB_CAPS = 8'h03`, MacAtrium
`ae7a051` doing 32 KB reads, 2 MB file):

| | |
|---|---|
| wrong bytes | 510, all inside ONE 512-byte sector |
| location | file offset `0x1AD800` (sector 3436; sector 44 of 32 KB chunk 53) |
| what was served | byte-identical to the sector **8192 bytes earlier** (−16 sectors) |
| ring geometry | `TB_ADDRW(12)` on the Toolbox target = 8 KB = **16 sectors** |
| everything else | byte-perfect |

−16 sectors is exactly one full ring cycle: slot `44 mod 16 = 12` still
held sector 28's bytes. The serve consumed a slot the HPS had not
refilled.

**This is our defect, not a client bug.** Do not confuse it with the
separate SD Transfer app defect (that one loses the last byte of every
64 KB chunk and is unfixable from our side) — see
`docs/resume_toolbox_download_byte_2026-08-01.md` §1/§2b.

## 2. It was already known — this is the first live confirmation

`rtl/scsi.v`, immediately above `TBS_DATA`:

> KNOWN GAP (2026-07-31): a data block carries no signature, so a stalled
> HPS here cannot be detected and this serves the previous sector's
> bytes — a silently corrupt GET. Only SEND (which has no data phase) and
> the status block are protected by the TBS_LATCH retry above. Fixing it
> needs positive fill evidence, which is exactly what the reverted attempt
> got wrong; do not retry that without HW-faithful bench coverage of the
> watchdog-primary path first.

"Serves the previous sector's bytes" is precisely what was measured. Treat
that paragraph as a design note from the author of the streaming path, and
honour its warning.

## 3. Suspected mechanism — VERIFY, don't assume

Both fetch states treat the read-ack watchdog as a successful completion:

- `TBS_DATA`: `if ((old_tb_ack & ~tb_ack) || (&tb_to)) begin tb_sec_done <= tb_sec_done + 9'd1; ... end`
- `TBS_STREAM`: same shape — on `(&tb_to)` it clears `tb_fetch_busy`,
  increments `tb_sec_done`, and moves on to the next sector.

`tb_to` is an 18-bit counter reset on each fetch issue. When it saturates,
the sector is counted **resident** although nothing arrived, and the
missing sector is never re-read. `tb_get_stall` — the serve's only
guard — is derived from `tb_sec_done`, so it then happily serves the
slot's stale contents.

Why the timeout plausibly fires in the field: the SD is mounted
`sync,dirsync`, and the RTL already notes elsewhere that "when the card
hits an erase cycle it stalls far past one watchdog period" (that is why
the status path got `TB_RETRY_MAX = 96` re-looks). The GET data path has
no equivalent protection.

Corroborating detail: the corruption appeared once in 2 MB — consistent
with a rare card stall, not a systematic addressing error. An addressing
bug would corrupt every chunk identically.

**Confirm before fixing.** Cheapest confirmation: make the bench HPS model
withhold one data block long enough to saturate `tb_to`, and check whether
the serve emits the previous occupant.

## 4. Fix directions (pick after confirming)

1. **Retry instead of complete** — on `(&tb_to)`, re-issue the read for the
   SAME `tb_fetch_sec` and do not advance `tb_sec_done`, bounded by a
   retry cap in the style of `TB_RETRY_MAX`. Smallest change, mirrors what
   already protects the status block.
2. **Fail loud** — after the retry cap, abort the transfer (CHECK / end the
   phase) instead of serving. Silent corruption becomes a visible error;
   worth having even alongside (1).
3. **Positive fill evidence** — what the reverted attempt tried. Only with
   the bench coverage the comment demands.

Precedent to copy: `082dcc4` "scsi: stall REQ until the full pseudo-DMA
look-ahead window is fetched" (the CD-read stale-word defect) with its
evidence write-up `aff82c0`. Same class, same repo, closed properly with
bench + HW proof.

## 5. Bench work — REQUIRED before the fix

`verilator/scsi_bench/scsi_bench.cpp`:

- HPS model at the top (`TbHps`, `op_get` handles 0xD1) — this is where a
  *delayed / withheld* data block must be modelled. Today the model always
  answers promptly, which is why the race is invisible.
- The `toolbox` test case is further down; today it covers a single
  65536-byte GET, which passes and does NOT reproduce this.

Two gaps to close:
1. A **stalled-HPS** case: withhold one data block past the watchdog and
   assert the served bytes are correct (fails today).
2. A **sustained streaming** case: many back-to-back multi-block GETs, the
   cadence a real client produces — one big GET is not equivalent.

Run `toolbox / toolboxslow / cdvol / gapcmds / --id 0` before any build.

## 6. Reproduce on hardware

1. Restore the pristine fixture:
   `scp scratch/TBT_full_rt.bin root@192.168.99.143:/media/fat/games/MacLC/shared/TBT.BIN`
   (2,097,152 bytes, md5 `c42818124581bcf115c913eefcd12972`).
2. Deploy `scratch/MacLC_CAPS03_020cd964.rbf` (already built: `TB_CAPS =
   8'h03`, STA met +0.246 ns, boot gate `94fedd19`).
3. Boot; Esc → **Toolbox Shared Files** (button at ~(320,220) in the
   Quick-Launch menu).
4. Arrow to `TBT.BIN`, Return → copies into MacAtrium/Incoming (~91 KB/s).
5. **From Mac to Shared...** (~(374,368)) → picker: Cmd+Up twice to the
   volume root, `M`, Return, down ×2 to Incoming, Return, select TBT.BIN,
   Return.
6. `md5sum` the SD file.

PASS = `c42818…`. The 08-01 failure was `75cabffc39427dfe53dde1ed50fff8a4`.

Block map of any failure:

```bash
python -c "
a=open('scratch/TBT_full_rt.bin','rb').read(); b=open('scratch/TBT_caps03_rt.bin','rb').read()
bad=[i for i in range(len(a)) if a[i]!=b[i]]; print(len(bad),'wrong')
off=bad[0]//512*512; got=b[off:off+512]
hits=[i for i in range(0,len(a),512) if a[i:i+512]==got]
print('served data came from sector deltas:',[(h-off)//512 for h in hits])"
```

A delta of **−16** is this bug. A run of single bytes at
`offset%65536==65535` is the unrelated client defect.

## 7. Traps

- **Never advertise `TB_CAPS` bit 0 in a release** until this is fixed —
  it silently corrupts downloads. Shipped value is `8'h02` (commit
  `9c96ae7`, comment block at the constant explains why).
- **MacAtrium is caps-dependent since `ae7a051`** — it sizes sends from
  bit 1 and reads from bit 0. An older claim that it ignores caps is
  obsolete.
- **A single big GET proves nothing here.** The bus-level proof that the
  core serves a full 65536-byte GET byte-exactly is real and still stands;
  it simply does not exercise this race. Do not use it as evidence again.
- **Clean-shutdown law.** Never reload the core over a running guest:
  Quick-Launch → **Shut Down** (cursor must be on Shut Down, NOT the
  broken Restart above it), verify screen md5 `7d1e525a`, then deploy.
- **Detach the CD before gating** (`mv /media/fat/config/MACLC.s4 …bak`)
  and restore after — the CUE/CHD-at-boot-attach hang fakes build
  failures on ANY rbf.
- **One boot is never a verdict** (`validate-the-gate-before-the-build`).

## 8. State

Branch `toolbox-large-files` (nothing pushed):

```
9c96ae7  toolbox: ship caps 0x02; bit 0 exposes a stale-sector race in the GET path
54f9e21  docs: second-client control — MacAtrium is byte-exact on the fast core
2c34785  toolbox: advertise no caps (0x00) — small chunks both ways, byte-exact
5cb53a8  docs: close the 64K download-byte hunt — client bug, server chain proven
```

- Deployed + gated: **914e07cc** = `releases/MacLC_20260801.rbf`
  (`TB_CAPS = 0x02`), boot gate `94fedd19`. HPS `dda65f18` (Main
  `4510442`, 17-bit length field). Both correct — leave them.
- Repro build: `scratch/MacLC_CAPS03_020cd964.rbf`.
- Artifacts: `scratch/TBT_full_rt.bin` (pristine),
  `scratch/TBT_caps03_rt.bin` (the corrupt round trip).
- Guest disk: `games/MACLC/Mac68KColorGames_v1.hda` (md5 `514ad4a2`,
  MacAtrium `ae7a051` with 32 KB transfers + live KB/s readout). Previous
  image kept as `Mac68KColorGames_v1_prev20260801.hda`.

## 9. What the fix is worth

| | `0x02` (today) | `0x03` (after the fix) |
|---|---|---|
| MacAtrium upload | ~120 KB/s | ~120 KB/s |
| MacAtrium download | 33 KB/s | **~91 KB/s** |

Downloads are the last slow leg. The ~230 KiB/s guest data-phase ceiling
is still above 91, so there may be more after this.
