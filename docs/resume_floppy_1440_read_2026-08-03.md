# Resume — 1.44MB MFM floppy READ **WORKS**; new blocker = screen corruption

**Authoritative handoff, 2026-08-03 (afternoon).** Supersedes
`docs/resume_floppy_ism_2026-08-03.md` (the morning handoff) and
`docs/resume_floppy_controller_2026-07-07.md`. Branch `fix-quicktime`,
commits `7e127ef`, `6c8438f`, `0280cfc`.

---

## 0. TL;DR — 1.44MB floppy READ WORKS; screen corruption is the open item

**The 1.44MB MFM/ISM floppy read works, confirmed by the user on build
`ccb82d32`.** `OS-6.0.8 disk 1 of 2.dsk` mounts as volume **"System Startup"**
and the Finder lists its 7 real items (System Folder, Installer, Installer
Script, Apple HD SC Setup, Disk First Aid, TeachText, Read Me — 1.1 MB used,
189K free), where every earlier build gave *"This disk is improperly formatted
for use in this drive."* Evidence: `scratch/hw_hidden.png`.

**Root cause was the missing INDEX pulse, not the data** (§1). The read datapath
was already byte-exact; the driver never saw the once-per-revolution index it
uses to bound its sector searches.

**One scare, already root-caused:** an intermediate report that the mount "did
not reproduce" turned out to be a **stale core pick** — `_Unstable` held 19
`MacLC_*.rbf` files and a manual OSD selection landed on a July build. Resolved
by the deploy discipline in §3a; not an RTL problem.

**★ THE OPEN ITEM: screen corruption from boot** (§4). Known state, present on
this core, **not diagnosed and not attributed**. This is the mission now.

---

## 1. What was actually wrong (and how it was proven)

| # | Bug | Evidence |
|---|---|---|
| 1 | **No index pulse.** During an MFM session the driver parks phases on RdData0/1 and polls sense via ISM Handshake **b3** — which on a SuperDrive with an MFM disk is `!index`. We returned `diskDataIn` (the GCR byte register), whose 6&2 alphabet is always MSB-set ⇒ a permanent "no index, ever". | MAME `mac_floppy::wpt_r`; Snow `drive.rs`: `RDDATA0 \| RDDATA1 if mfm && motor => !at_index()`; capture shows ~3.5M such polls per session |
| 2 | **VIA ORA reads returned the input register for output pins.** Every read-modify-write on Port A wrote the input pattern back over the output latch. PA5 = HDSEL = the drive SEL line. | MAME `6522via.cpp input_pa()` always ORs `(m_out_a & m_ddr_a)`; ROM disassembly at `A6D432` = `BSET #5,$1E00(A2)`, `A6D43A` = `BCLR #5` |
| 3 | **Verilator ioctl bus ended downloads one word short**, so the 1.44MB size check never fired — **no floppy image had ever actually been inserted in any Verilator run.** | `sim.v` flag trace: `dio_addr(words)=737279 → mfm=0 hd=0`, now `737280 → mfm=1 hd=1` |

**Fixed by `7e127ef`** (index + track preamble + two FIFO conformance fixes),
**`6c8438f`** (VIA ORA), **`0280cfc`** (tooling/sim/doc).

`mfm_track_encoder` now emits the track preamble it was missing (gap4a 80×4E,
sync 12×00, IAM `C2 C2 C2 FC`, gap1 50×4E) and derives `oindex` from gap4a.
Rotation is now 12422 B/track × 16 µs = 198.75 ms = **301.9 RPM** (was 305.5).
The IAM bytes are delivered **plain, not as marks** — SWIM1 syncs only on the
A1/`0x4489` pattern.

### Things now PROVEN — do not re-audit
- **Read datapath is byte-exact.** `verilator/tb_ism_read.v` + `expect_track.py`:
  **1400/1400 popped bytes match**, aligned at track offset 158, ID field
  `A1m A1m A1m FE 00 00 01 02 CA 6F` — the same CRC the MAME capture recorded.
  Covers ID field, gap2, sync, data address mark, the real 512-byte payload and
  its CRC.
- **Drive identity + sense table correct.** `verilator/tb_sense.v` sweeps all 16
  registers; identify nibble reads `0011` (SuperDrive + HD). Only mismatch is
  `NoWrProtect` = locked, which is *correct* for our read-only floppies.
- **July's "SDRAM region ≠ image" verdict is dead** — it was an artifact (see the
  morning handoff §4); the payload was never the problem.
- **The ISM motor gate (`586ed77`) was NOT the bug.** The capture shows MotorOn
  strobed via the IWM path before the ISM session, so `mfm_spinning` was already
  true. It shipped in this build and is harmless.

---

## 2. Build provenance

| build | md5 | SEED | STA | hardware |
|---|---|---|---|---|
| `ccb82d32` | `ccb82d3284a97d571fe2eb13584c32c3` | 7 | met **+0.246 ns** | boots to MacAtrium w/ colour icons (**per-fit gate PASS**); **1.44M disk mounts and reads** |

Local copy: `scratch/rbf/MacLC_ccb82d32.rbf`. On the box:
`/media/fat/_Unstable/MacLC_ccb82d32.rbf`.
Test image (bench and local are byte-identical, md5 `677648766bfc53d5b6178a2bee8fed47`,
1,474,560 B).

**Budget: 4 of 10 builds used** (3 in the morning session + this one).

---

## 3. ★ OPS — corrections to the morning handoff, and the user's standing rule

### ★★ THE MOUSE WORKS. Clean-shut-down the guest before ANY core load.
The morning handoff said `ws_send.py` is "keyboard only" and that there is "no
keyboard path to a clean shut down". **The first half was wrong** and made the
second half look unavoidable. The MiSTer Remote ws API supports the mouse; our
wrapper just didn't pass it through. `tools/misterdeploy/ws_send.py` now does:

```bash
python tools/misterdeploy/ws_send.py --host 192.168.99.143 \
  mouseMove:-2000,-2000 sleep:0.5 mouseMove:626,8 sleep:0.5 mouseBtn:left
```

- `mouseMove:<dx>,<dy>` is **RELATIVE** (the Mac tracks deltas). Park the cursor
  first by slamming to a corner with a large negative move, then step out.
- `mouseBtn:left` (also `right`, `middle`). HTTP equivalents exist at
  `/api/controls/mouse/{move,position,<button>}`.
- **USER REQUIREMENT (stated 2026-08-03):** always quit the guest via
  **Finder ▸ Special ▸ Shut Down** before loading a core, to avoid hard-disk
  corruption. Hard-reloading a running guest is not acceptable.
- **⚠ VERIFIED ONLY IN PART.** Mouse move + click is proven (it selected
  "Hide MacAtrium" successfully). A full Special ▸ Shut Down was **not**
  completed: after keyboard use the cursor stopped responding to moves and the
  screenshot API stopped producing new frames. Suspects, in order: the known
  ADB single-device autopoll limitation ([[adb-mouse-needs-wire-srq]] — the
  mouse needs wire-level SRQ to break in once the keyboard is the polled
  device), and HPS churn from heavy screenshot/ws polling
  ([[shared-mister-hps-exhaustion]]). **Next session: verify this path
  end-to-end on a freshly booted guest, mouse-only, before relying on it.**
  Classic Mac menus track mouse-DOWN, so use
  `POST /api/controls/mouse/left_down`, move onto the item, then `left_up` —
  a fast `mouseBtn:left` click will not hold a menu open. Mouse deltas are
  accelerated, so step in small increments (~8 px), not one big jump.

### ★ Do NOT Cmd-Q MacAtrium
Quitting it (`Cmd-Q` → Quit) bombed the Finder with **"error type 41"** and
forced a reboot. To see the desktop, use the **Application menu (top-right of
the menu bar) ▸ Hide MacAtrium** instead. That worked cleanly.

### Other ops facts (some correct the morning doc)
- **Mac-drawn menus and dialogs DO appear in screenshots.** Only the MiSTer OSD
  overlay does not. So you can navigate Mac menus visually — iterate
  click → screenshot → click.
- **Row 0 (no `kbd:down`) = Mount Pri Floppy = the INTERNAL drive**, which is the
  drive the ISM session selects (Mode bits 2:1 = `01`). The morning handoff's
  "row 1 is the only row the guest reacts to" was a symptom of the since-fixed
  ISM eject bug. Row 0 is the correct target and works:
  ```bash
  python tools/misterdeploy/ws_send.py --host 192.168.99.143 \
    kbd:osd sleep:1.5 kbd:confirm sleep:2.0 kbdRaw:24 sleep:1.2 kbd:confirm sleep:14
  ```
  (`kbdRaw:24` = 'O', jumping the browser to `OS-6.0.8…`. Codes are PS/2 set-1:
  Return = 28, Q = 16, LeftAlt/Command = 56.)
- **Screenshot filename = mount oracle** (`…-OS-6.0.8%20disk%201%20of%202.png`).
- **★ Do not write sim logs to `/tmp` in WSL.** `/tmp` was wiped mid-session and
  destroyed a completed 40-minute run. Use the repo `scratch/` (slower I/O, but
  durable).
- Verilator full-boot runs take ~40 min to reach a floppy mount and produce
  ~190 MB logs, dominated by EGRET/SCC spam. **Gating that spam is the single
  biggest speedup available** for future floppy work — worth doing first.
- CD is still detached from the boot config (`MACLC.s4` →
  `MACLC.s4.bak_floppy20260802`). **Restore it when convenient.**

---

## 3a. ★★ DEPLOY DISCIPLINE — one core name, prune first, commit per build

**Standing rules (user, 2026-08-03).** A "the fix doesn't reproduce" scare cost
part of a session and was purely a stale-core pick: `_Unstable` had accumulated
**19** `MacLC_*.rbf` files, and a manual OSD selection landed on a July build.

1. **ALWAYS deploy under the canonical name `MacLC.rbf`.** No hash-suffixed
   names on the box — that is what creates the off-by-one/mis-pick trap
   (`[[scsi-fit-stabilization-mission]]`). `scripts/local.env` already sets
   `RBF_NAME="MacLC.rbf"`, so the deploy tool's default is correct; just don't
   override it:
   ```bash
   python tools/misterdeploy/launch_unstable_core.py --host 192.168.99.143 \
     --ssh-key ~/.ssh/mister_only --push output_files/MacLC.rbf --core MacLC.rbf
   ```
2. **Clear out older MacLC cores before proceeding.** Done 2026-08-03: 19 old
   RBFs moved to `/media/fat/backups/maclc_rbf_20260803/`, leaving `_Unstable`
   with exactly `MacLC.rbf` (md5 `ccb82d3284a97d571fe2eb13584c32c3`) plus
   `MacLCii.rbf` / `MacLCii_0921_backup.rbf`, which are **a different machine —
   do not touch them.** Re-prune whenever strays reappear.
3. **Backups only periodically**, not per build. Real provenance lives in the
   repo (`releases/` for release-quality artifacts) and in git.
4. **★ Commit between every build**, so each fit maps to exactly one commit and
   rollback is a `git checkout` away. Record the RBF md5 in the commit or the
   handoff — Quartus is deterministic (same netlist + seed ⇒ same md5,
   `[[validate-the-gate-before-the-build]]`), so the hash is a free provenance
   proof tying a binary to a tree.

**Verify what actually booted** before trusting any hardware result: the deploy
tool prints `coreRunning`, and `md5sum /media/fat/_Unstable/MacLC.rbf` on the box
should match the local `output_files/MacLC.rbf`.

**Mount to row 0** (`kbd:confirm` with no `kbd:down`) = *Mount Pri Floppy* = the
**internal** drive, which is the one the ISM session selects (Mode bits 2:1 =
`01`). Row 1 is the secondary/external drive; ISM never reads it, so a row-1
mount produces exactly the "improperly formatted" dialog and looks like a
regression.

## 4. ★★ THE OPEN ISSUE — screen corruption (present from boot)

Observed on build `ccb82d32` after the floppy mounted
(`scratch/hw_corruption.png`): in the **background** BlueSCSI Toolbox window,
the icons for `g-cdchangercrash.txt` and `MacsBug` render as **coloured pixel
noise**, and `ChangeLog`/`README` look blank. The foreground "System Startup"
window's icons are clean.

**User reports it is present from boot** and persists across a core reload, so
it is a stable, reproducible state — not a one-off. It is still **not diagnosed
and not attributed**; do not assume it came from these commits until an A/B says
so.

Candidates, cheapest discriminator first:

1. **Pre-existing / recurring.** The user described it as happening "again".
   **Discriminator: load a known-good older core and compare the same window.**
   The July builds are archived at `/media/fat/backups/maclc_rbf_20260803/`, and
   `releases/MacLC_20260802.rbf` is in the repo — copy one back in as
   `MacLC.rbf` (or push it under that name), look, then restore. If the
   corruption is there too, these commits are exonerated and this becomes a
   separate, older bug.
2. **Damaged Desktop DB.** The guest bombed (Finder error 41) during this
   session; corrupted icon resources are the classic signature.
   **Discriminator: rebuild the Desktop (boot holding Cmd-Option) and re-look.**
   Free, and would explain garbage icons specifically.
3. **A regression from these commits.** Least likely on current evidence but not
   excluded. Note the obvious suspect has already been **eliminated**: the VIA
   ORA fix cannot corrupt video through `vid_alt` (PA6), because `vid_alt` is
   declared in `MacLC.sv:696`, wired out of `dataController_top`, and **consumed
   nowhere** — it is a dangling wire. If you still want to bisect, revert only
   `6c8438f` (kept as its own commit for exactly this reason) and rebuild.

Relevant prior art: `[[quickdraw-deficit-mission]]` records a *different*
corruption class (I-cache ON corrupts disk data), and `[[v8-renderer-matches-mame]]`
established the V8 scanout itself is not at fault.

---

## 5. Suggested next steps

1. **Run the §4 discriminators** (Desktop rebuild, then the known-good-build A/B)
   before touching any RTL.
2. **Regression-check the 800K GCR path** on this build — it shares
   `floppy.v`/`readData` and the VIA. Mount `Disk605.dsk`; it should still give
   the GCR dialog, not the MFM one, proving the is_2m routing still splits
   correctly.
3. **Try booting from the 1.44M disk** (it is a bootable System Startup disk) —
   reading the directory is proven, but a full boot exercises many more sectors
   and both heads.
4. **Write support** is still absent (floppies are read-only). The ISM write path
   in `swim.v` exists only as CPU-side FIFO pushes.
5. Gate the EGRET/SCC sim spam (§3) before the next Verilator campaign.
