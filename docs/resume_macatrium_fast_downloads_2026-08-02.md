# Resume — fast MacAtrium downloads via a vendor capability bit (2026-08-02)

Paste the block below as the opening message of the next session. It spans TWO
repos: this core and MacAtrium (`~/repos/MacAtrium` in WSL — see
[[macatrium-wsl-env]]).

---

## THE PROMPT (paste this)

> Unlock fast MacAtrium downloads on the MacLC core without breaking the
> official BlueSCSI SD Transfer app. Read
> `docs/resume_macatrium_fast_downloads_2026-08-02.md` first — it is the
> authoritative state.
>
> MacAtrium downloads run at 33 KB/s because it sizes its GETs from Toolbox
> capability bit 0, and the core cannot advertise bit 0: doing so crashes the
> official app with a 68020 "bad F-Line instruction" bomb (measured, 3 of 4
> runs — §2). The fix is a VENDOR bit the official app ignores: the core
> advertises it, MacAtrium reads it, bit 0 stays clear.
>
> Two one-line-ish changes (§3), then hardware validation of BOTH clients
> (§4). The first test is the gating one: confirm the official app tolerates
> the new bit at all. If it bombs on the vendor bit too, STOP — the idea is
> dead and the core must stay at 0x02.
>
> Expected end state: MacAtrium downloads ~91 KB/s byte-exact, official app
> unchanged (~123 down / ~174 up, no bomb), core shipped with the new caps
> value.

---

## 1. Why downloads are slow

MacAtrium asks for 4 KB GETs instead of 32 KB because the core advertises
`TB_CAPS = 0x02` (large SEND only). Uploads are therefore fast (~90 KB/s) and
downloads are not (33 KB/s). The core's fast multi-block GET path is proven —
it ran 4× 2 MB byte-exact at `TB_CAPS = 0x03`, one under a deliberate SD write
storm, at ~91 KB/s.

## 2. Why bit 0 cannot simply be set

`CAP_LARGE_TRANSFERS` (bit 0) makes the official **BlueSCSI SD Transfer**
(1.1.0b5) bomb the guest with **"bad F-Line instruction"** at 0% — before any
data moves, usually before its own overwrite prompt. So the fault is in that
app's capability-dependent setup path, not our serve.

HW A/B, same app / file / procedure, each on a fresh boot:

| build | caps | GET race fix | official app |
|---|---|---|---|
| `5a181d40` | 0x03 | yes | **3 of 4 bombed**; survivor 99 KB/s then hung |
| `914e07cc` | 0x02 | no  | 2 of 2 clean, 122-123 KB/s |
| `3aaf1ed1` | 0x02 | yes | 2 of 2 clean, 121-123 KB/s ← **discriminator** |

The third row pins it on the caps byte and exonerates the RTL. Full write-up:
`docs/resume_toolbox_ring_race_2026-08-01.md` (addendum).

**Likely mechanism (hypothesis, not proven):** MacAtrium's own
`fb_xfer_begin()` does `NewPtr(TB_XFER_MAX)` and falls back gracefully when the
allocation fails. The official app plausibly does the same large allocation on
seeing bit 0 *without* the null check and jumps into garbage — which would also
explain why 1 run in 4 survived. Worth 10 minutes with MacsBug if anyone wants
certainty; it changes nothing about the fix.

## 3. The change

**Core** — `rtl/scsi.v`, the `TB_CAPS` constant (currently `8'h02`, with a long
comment block explaining why bit 0 is off; keep and extend it):

```verilog
localparam [7:0] TB_CAPS = 8'h82;   // bit 7 = vendor "multi-block GET is safe"
                                    // bit 1 = CAP_LARGE_SEND. Bit 0 stays CLEAR.
```

**MacAtrium** — `~/repos/MacAtrium/src`:

- `toolbox.h` (bits are defined near line 45):
  ```c
  #define TB_CAP_MISTER_XFER 0x80   /* MiSTer core: multi-block GET is safe.
                                       Vendor bit -- the official BlueSCSI app
                                       crashes on bit 0, so the core cannot use
                                       CAP_LARGE_XFER to say the same thing. */
  ```
- `filebrowse.c` line ~415, the read path:
  ```c
  fb_xfer_begin(TB_CAP_LARGE_XFER | TB_CAP_MISTER_XFER);
  ```
  `fb_xfer_begin()` already does `gCaps & capBit`, so passing a MASK works with
  no change to that function. **Use the mask, not the vendor bit alone** — on
  real BlueSCSI hardware (which sets 0x01, not 0x80) MacAtrium must keep its
  fast reads.
- Leave the SEND path (line ~350, `TB_CAP_LARGE_SEND`) alone; uploads already
  work.

## 4. Validation — in this order

1. **GATE: official app tolerates 0x82.** Build the core, boot, launch
   BlueSCSI SD Transfer, download a 2 MB file. It must NOT bomb. *If it bombs,
   stop and revert to `0x02`* — the vendor bit is not ignored and the idea is
   dead. (Bit 7 is unallocated in the BlueSCSI caps byte as far as we know, but
   that is an assumption, not a documented guarantee.)
2. Official app: download + upload, byte-exact, speeds unchanged (~123 / ~174).
3. MacAtrium **rebuilt with the new bit**: 2 MB round trip byte-exact, download
   now ~91 KB/s (from 33).
4. MacAtrium *old* build against the new core: must still work at 33 KB/s
   (it sees 0x82, matches neither bit... actually it checks 0x01, so it falls
   back to 4 KB GETs — confirm it degrades rather than misbehaves).
5. Two boots minimum. One boot is never a verdict.

Fixture: `scratch/TBT_full_rt.bin` (2 MB, md5
`c42818124581bcf115c913eefcd12972`) at
`/media/fat/games/MacLC/shared/TBT.BIN`.

## 5. Traps

- **Never screenshot or md5 an SD file DURING a transfer you are timing.** It
  blocks Main's poll loop and induces a real host stall; it cost two false
  "the build aborts uploads" readings on 2026-08-02. Measure clean, then stress
  deliberately as a separate test.
- **Clean-shutdown law**: Finder → Special → Shut Down (menu drag: down at
  (232,9), walk 0,130, up), screen md5 `73624ddc`. Never reload over a running
  guest.
- **Injected Cmd chords do not reach the guest** — `kbd.sh chord 125 <key>`
  silently fails. Use click routes (Desktop button, menu drags).
- The official app's own defect is unrelated and stays: downloads >64 KB lose
  one byte per 64 KiB chunk. Do not chase it; it is client-side and proven.
- MacAtrium is built in WSL; the core is built on Windows. See
  `docs/BLUESCSI_*.md` and BUILD.md.

## 6. State

- Core ships **`7e898172`** = `releases/MacLC_20260801.rbf` (commit `86b542b`),
  `TB_CAPS = 0x02`, GET + SEND watchdog fixes, unified
  `TB_STALL_RETRY_MAX` (4.2 s). Boot gate `94fedd19`, STA +0.246 ns.
- HPS: Main_MiSTer PR #1255 **merged** upstream (`035b86f`); no MiSTer release
  carries it yet, so `releases/MiSTer` (md5 `dda65f18`) is still installed by
  hand.
- Speeds today: official app ~123 down / ~174 up; MacAtrium 33 down / ~90 up.
- Bench gates: `scsi_bench --mode toolbox / toolboxget / toolboxsend /
  toolboxslow / cdvol / gapcmds` (all green).

## 7. If the gate fails

If the official app bombs on 0x82, the remaining options are, in order:

1. Try a different vendor bit (0x40, 0x20) — cheap, same test.
2. Ship 0x02 and make MacAtrium issue large GETs **unconditionally** on this
   core, detecting the MiSTer core by its INQUIRY string rather than by caps.
   No core change at all; MacAtrium already knows how to identify the target.
3. Accept 33 KB/s downloads.

Option 2 is the strongest fallback and arguably the cleaner design — the
capability byte is a BlueSCSI-protocol contract, and overloading it with vendor
meaning is what created this whole mess.
