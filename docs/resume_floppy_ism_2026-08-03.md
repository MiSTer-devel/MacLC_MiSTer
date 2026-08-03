# Resume — 1.44MB MFM floppy (SWIM ISM read engine), 2026-08-03

**Authoritative handoff for the floppy mission.** Supersedes
`docs/resume_floppy_controller_2026-07-07.md` (whose §1 mount recipe is now known
to be WRONG — see §3). Branch `fix-quicktime`, commit `a5ef2ac` (+ uncommitted
`MacLC.qsf` SEED change).

---

## 0. TL;DR — where we are

Build 2 of the ISM engine **boots clean and the OS now takes the MFM/ISM path for
a 1.44MB disk** — a real advance over July, where 1.44M disks were routed to GCR
and never touched ISM at all. The disk still does not mount: the guest reports
**"This disk is improperly formatted for use in this drive."**

Two distinct open problems, in priority order:

1. **★ OSD row asymmetry (BLOCKING, probably the bigger fish).** Mounting a disk
   via OSD **row 0** produces *no guest reaction at all* (neither 800K nor
   1.44M). Mounting via **row 1** always produces a reaction. Per `CONF_STR`
   order (`F1` = Mount Pri Floppy, then `F2` = Mount Sec Floppy) row 0 should be
   the *internal* drive — the one that matters. Unresolved whether this is a
   regression from the ISM commit or predates it; the A/B against the pre-ISM
   release was in flight when the session ended (§3).
2. **The ISM read itself returns data the OS rejects** (§4).

---

## 1. What was built (commit `a5ef2ac`)

The July "Build 2" plan (F1, F2, F6, F7, F8 + access one-shots) implemented in
`rtl/swim.v`, `rtl/floppy.v`, `rtl/mfm_track_encoder.v`, `verilator/sim.v`:

- **F1** IWM→ISM switch keys on offset-0xF accesses, drive-enable independent.
- **F2** Phases register reads back all 8 written bits.
- **F6** ISM-mode drive select from Mode b7 + b2:1 (`01`=INT, `10`=EXT).
- **F7** real 2-entry FIFO fed at the 16 µs byte cell, mark-sync hunt,
  MAME-shaped Handshake.
- **F8** ACTION-edge re-arm + ModeClr param reset.
- **Access one-shots**: all ISM register side effects commit once per CPU access
  (`acc_end`), fixing the documented over-sampling (the 68k holds UDS across many
  `cen` ticks). This was the July landmine — do not revert it.

**Verified:** Quartus A&S clean; the ROM's SWIM self-test passes in Verilator
byte-for-byte per the MAME 0.264 ground truth (ISM switch → `F5,F6,F7,FF..F0`
phases walk → `ModeClr F8` exit).

---

## 2. ★★ Builds burned: 2 of the 10-build budget

| # | RBF md5 | SEED | STA | HARDWARE |
|---|---|---|---|---|
| 1 | `85912c51` | 5 | met +0.247 ns | **FAILED** — boot 1 wedged (Finder menu bar, no icons, dead to input); boot 2 **"Finder — bad F-Line instruction"** |
| 2 | `833c327b` | 7 | met +0.247 ns | **CLEAN** — full MacAtrium desktop, colour icons, responsive |

**Same RTL, different SEED — the failure was a marginal fit, not a logic bug.**
This is the documented per-fit marginality class (identical signature to the July
`e322926` seed-1 lottery). `MacLC.qsf` SEED is currently **7** (uncommitted).

**The gate was validated** before blaming the build: `releases/MacLC_20260802.rbf`
booted to a populated desktop on the same box/HD/config in the same hour. Keep
doing this — see `[[validate-the-gate-before-the-build]]`.

---

## 3. ★★★ THE MOUNT RECIPE — the July doc is WRONG, do not follow it

`docs/resume_floppy_controller_2026-07-07.md` §1 says to use **no** `kbd:down`
("the cursor already lands on Mount Pri Floppy"). On the current Main firmware
that is **false in effect**: a row-0 mount is ignored by the guest.

Empirically, on build `833c327b` (healthy, 2-for-2 each way):

```bash
# ROW 1 — the ONLY row the guest reacts to:
python tools/misterdeploy/ws_send.py --host 192.168.99.143 \
  kbd:osd sleep:1.2 kbd:down sleep:0.4 kbd:confirm sleep:1.5 \
  kbdRaw:24 sleep:1.0 kbd:confirm sleep:10      # kbdRaw:24='O', 32='D'
bash scripts/grab.sh scratch/out.png
```

| mount target | 800K `Disk605.dsk` | 1.44M `OS-6.0.8 disk 1 of 2.dsk` |
|---|---|---|
| **row 0** (0 downs) | no reaction | no reaction |
| **row 1** (1 down)  | "This disk is unreadable" + One-Sided/Two-Sided | "improperly formatted for use in this drive" + Initialize |

Both rows *do* mount a file (proven: the MiSTer screenshot filename tracks the
mounted image — a free mount oracle, use it). So both are file-mount rows, and
the guest only ever reads the drive fed by row 1.

**★ UNRESOLVED and the first thing to settle next session:** is row 0 dead
because of the ISM commit, or was it always dead? The A/B (deploy
`releases/MacLC_20260802.rbf`, already on the box, mount 800K to row 0) was
launched but **its result was never read**. Evidence pointing at *pre-existing*:
July's ring — wired to `floppyInt` — captured 138 kB of internal-drive GCR reads,
so the internal drive was alive pre-ISM. Evidence pointing at *my change*: the
only edit to `floppyInt._enable` is the ISM mux
(`ism_mode ? ~ism_devsel_int : ~(diskEnableInt & driveSel)`), which differs only
when `ism_mode`=1.

Candidate mechanisms worth checking (cheap, code-only):
- `rtl/floppy.v` eject: `ejectIndicatorTimer` **never decrements while
  `insertDisk` is high** (the `else if (insertDisk)` branch shadows the decrement).
  One EJECT strobe while a disk is mounted latches `diskEject` high, which wipes
  `dsk_int_*` in `MacLC.sv` — a disk that can never stay inserted.
- `driveSel = via_pa_o[4]` (`dataController_top.sv:508`) gates **only** the
  internal drive. On Mac II-family VIAs PA4 is the ROM-overlay bit, not a drive
  select; if the OS drives it low, the internal drive is permanently disabled.
  MAME's LC wires head-select from PA5 only (`v8.cpp:258`) and nothing to PA4.

---

## 4. The ISM read failure (problem 2)

With the 1.44M image in the reactive drive the guest says **"improperly
formatted for use in this drive"** — a *different* dialog from the GCR path's
"unreadable", so the OS identified a SuperDrive + HD disk and took the MFM/ISM
route. It read something structured and rejected it.

**Reference audited and SOUND** (do not re-question it): the test image is a
valid Mac HFS 1.44M disk — 1,474,560 B, boot block `4C4B` ("LK"), MDB signature
`0x4244` at offset 1024, volume name **"System Startup2"**. Local copy
`scratch/mame_floppy_0702/os608_disk1_1440k.dsk`, on the box as
`/media/fat/games/MacLC/OS-6.0.8 disk 1 of 2.dsk` (md5 `67764876…`, byte-identical).

**Drive-ID is CORRECT — do not "fix" it.** `is_2m` (sense reg `0xF`) reads
**0 for an HD disk, 1 for DD**, per the MAME 0.264 *runtime* capture
(`docs/findings_mame_floppy_groundtruth_2026-07-02.md` §4: "x=1 → GCR/IWM mount;
x=0 → MFM/ISM mount"). The comment block at `rtl/floppy.v:139-145` is **stale June
source-reading text that contradicts the code** and claims HD ⇒ `1011`; it nearly
caused a wrong "fix" this session. Delete/correct it.

Next suspects for the bad payload, in order:
1. **Region vs. drive mismatch** — whichever drive the OS actually reads must be
   the one whose SDRAM region got the image (`index 1 → $600000 → floppyInt`,
   `index 2 → $700000 → floppyExt`; download and read bases verified matching in
   `MacLC.sv:1768-1769` and `addrController_top.v:210-211`). If the OS reads the
   internal drive while the user mounts "Pri", this is *also* the July
   "SDRAM region ≠ image" finding — same bug, not a new one.
2. Sector→image byte mapping / side ordering in `mfm_track_encoder.v`.
3. FIFO/Handshake shape (`swim.v:411-420`) and the mark-sync hunt.

---

## 5. Ops notes learned this session (save the time)

- **Screenshot filename = mount oracle.** `scripts/grab.sh` prints the remote
  name, which is the currently-mounted image (`…-Disk605.png`). Free confirmation
  that a mount landed, and of *which* file.
- **The OSD is NOT captured** by the screenshot API — you cannot see the menu or
  the file browser. Navigate blind, verify via the filename oracle.
- **Guest liveness test without the mouse:** Cmd-A (`kbdRawDown:56 kbdRaw:30
  kbdRawUp:56`) visibly selects icons. Left **Alt = Command** (`rtl/adb.sv:364`).
- **★ The ADB power key (`kbdRaw:116`) does NOT work on build `833c327b`** —
  three attempts, including a 0.6 s press-and-hold, produced no shutdown dialog,
  while Cmd-A/Cmd-W/Return all worked. It *did* work on the pre-ISM core earlier
  the same night. Worth a look: it blocks the clean-shutdown protocol.
- `ws_send.py` is **keyboard only** — no mouse, so Finder ▸ Special ▸ Shut Down
  is unreachable; there is currently no keyboard path to a clean shut down.
- The CD is detached from the boot config (`MACLC.s4` →
  `MACLC.s4.bak_floppy20260802`) to avoid the CUE/CHD-at-boot hang. **Restore it
  when the floppy mission ends.**
- Deploy: `python tools/misterdeploy/launch_unstable_core.py --host
  192.168.99.143 --ssh-key ~/.ssh/mister_only --push <rbf> --core <name.rbf>`.
  The `--host` default (`MiSTer.local`) does not resolve here — always pass it.

---

## 6. Recommended next steps

1. **Finish the row-0 A/B** (§3) — deploy `releases/MacLC_20260802.rbf`, mount
   800K to row 0, and see whether the guest reacts. This decides whether to spend
   the next build on an internal-drive fix or on the ISM payload.
2. Fold into **build 3** (batch them — builds are ~17-20 min and the budget is 8):
   - the `ejectIndicatorTimer` starvation fix (§3),
   - dropping/【re-deriving】the `& driveSel` gate on the internal drive (§3),
   - the stale `floppy.v:139-145` comment (§4).
3. Only then chase the payload (§4) — and prefer a **targeted unit testbench**
   over a full-boot sim: a full System boot in Verilator takes hours, whereas the
   ISM protocol can be driven directly against `swim`+`floppy`+
   `mfm_track_encoder` in seconds with complete byte visibility.
4. Keep the per-fit gate: every new fit must reach a populated Finder desktop
   before any floppy verdict is trusted. STA does not predict it.
