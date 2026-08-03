# Resume — 1.44MB MFM floppy READ **WORKS**; new blocker = screen corruption

**Authoritative handoff, 2026-08-03 (afternoon).** Supersedes
`docs/resume_floppy_ism_2026-08-03.md` (the morning handoff) and
`docs/resume_floppy_controller_2026-07-07.md`. Branch `fix-quicktime`,
commits `7e127ef`, `6c8438f`, `0280cfc`.

---

## 0. TL;DR — ★ MISSION NOT CLOSED (mounted once, did not reproduce)

**A 1.44MB disk mounted and read correctly, exactly once.** Build `ccb82d32`
mounted `OS-6.0.8 disk 1 of 2.dsk` as volume **"System Startup"** and the Finder
listed its 7 real items (System Folder, Installer, Installer Script, Apple HD SC
Setup, Disk First Aid, TeachText, Read Me — 1.1 MB used, 189K free), where the
previous build gave *"This disk is improperly formatted for use in this drive."*
Screenshot evidence: `scratch/hw_hidden.png`, `scratch/hw_corruption.png`.

**★★ BUT THE USER COULD NOT REPRODUCE IT.** Immediately afterwards they rebooted
the core themselves (to clear the screen corruption), mounted the disk by hand,
and **got the same "improperly formatted" error as before.** So the mount is
intermittent, configuration-dependent, or my one success differed from their
attempt in some way not yet identified. **Treat the mission as OPEN.** One boot
is never a verdict — this is precisely the trap recorded in
`[[validate-the-gate-before-the-build]]`, and I fell into the mirror image of it
by declaring success on a single observation.

**What IS solid** (proven in simulation, independent of the hardware question):
the ISM read datapath is byte-exact (1400/1400 popped bytes vs the expected
track), the sense/identity table matches MAME, and the two RTL bugs in §1 were
real. What is NOT established is that fixing them is *sufficient* on hardware.

**Two open issues, in priority order:** §3a (mount does not reproduce) then
§4 (screen corruption — also unattributed).

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

## 3a. ★★ OPEN ISSUE #1 — the mount does not reproduce

I saw one clean mount; the user, reloading the core themselves and mounting the
disk by hand right afterwards, got the **same "improperly formatted" dialog**.
Establish *what differed* before touching any RTL. Discriminators, cheapest and
most likely first:

1. **★ Which RBF actually loaded?** There are **8+ `MacLC*.rbf` files** in
   `/media/fat/_Unstable/` (`MacLC_RELEASE_20260727_f6ad562e`, `MacLC_REL_20260728`,
   `MacLC_UAFIX_…`, `MacLC_Unstable_20260707_e322926s3`, `MacLC_WRFIX…` ×2,
   `MacLCii…` ×2, plus `MacLC_ccb82d32`). Selecting a core by hand in the OSD
   makes it very easy to land on a **stale** one — the documented off-by-one
   trap in `[[scsi-fit-stabilization-mission]]` ("keep ONE launchable,
   hash-named"). **A manual reload that picked any other RBF would reproduce the
   old failure perfectly.** Check `coreRunning` / the launch log, or prune
   `_Unstable` down to the one core under test.
2. **★ Which OSD row was used?** Row 0 = *Mount Pri Floppy* = the **internal**
   drive, which is the drive the ISM session selects (Mode bits 2:1 = `01`). My
   successful mount used **row 0**. The older handoffs (and habit) say **row 1**,
   which is the secondary/external drive — the ISM session would not read it, and
   the guest would report exactly "improperly formatted". This alone could explain
   the whole discrepancy.
3. **Cold vs warm / timing.** My success was on a freshly booted guest, mounting
   once shortly after MacAtrium came up. If the failure only appears on a warm or
   long-idle guest, suspect motor/index state: `mfm_spinning` gates the encoder,
   and the index only advances while it is true.
4. **Per-fit marginality.** Same RTL, different SEED has flipped hardware
   behaviour on this core before (`[[cdchanger-tb-transport-mission]]`, morning
   handoff builds 1 vs 2). If 1-3 come back clean, re-roll SEED and re-gate.

**Do this before RTL work:** prune `_Unstable` to a single hash-named RBF,
boot it, and run the row-0 mount twice and the row-1 mount twice, capturing the
filename oracle and a screenshot each time. That 4-cell table settles items 1-2
in one pass.

## 4. ★ OPEN ISSUE #2 — screen corruption

Observed on build `ccb82d32` after the floppy mounted
(`scratch/hw_corruption.png`): in the **background** BlueSCSI Toolbox window,
the icons for `g-cdchangercrash.txt` and `MacsBug` render as **coloured pixel
noise**, and `ChangeLog`/`README` look blank. The foreground "System Startup"
window's icons are clean.

**Not diagnosed. Not attributed.** Be disciplined here — the morning session's
own lesson (and `[[validate-the-gate-before-the-build]]`) is that a symptom seen
once on one build is not a verdict.

Candidates, cheapest discriminator first:

1. **Damaged Desktop DB from the Finder bomb.** The guest bombed (error 41) and
   rebooted during this session; corrupted icon resources in one window is the
   classic signature. **Discriminator: rebuild the Desktop (boot holding
   Cmd-Option) and re-look.** Do this FIRST — it is free and would explain
   everything.
2. **Pre-existing / recurring.** The user described it as happening "again",
   so it may predate these commits. **Discriminator: load the previous build
   `2a45c1a3` (or `releases/MacLC_20260802.rbf`) with the same guest state and
   compare the same window.**
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
