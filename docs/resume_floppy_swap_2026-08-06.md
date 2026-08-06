> # ✅ RESOLVED 2026-08-06 — MISSION COMPLETE
>
> **The System 6.0.8 install from two 1.44 MB floppies ran end to end on
> hardware** (build `1c52ade1` = commit `887ebba`): disk 1 mounted at the
> flashing-`?` screen and booted, the installer ejected each disk itself (the
> re-enabled ISM eject), both OSD swaps were picked up (2 ejects, 2 guest
> DskchgClear strobes, 5 clean CSTIN edges on the HUD witness), "Installation
> on MacHd was successful", and the installed system cold-boots from the vhd.
> Fix = the §5 design landed as one protocol: SWITCHED sense reg (MAME
> `!m_dskchg` semantics) + `CSTIN <= ~insertDisk` + empty-hold + ISM eject
> under `(!ism_active || ism_sel)`. The §3 reverted-fix mystery is explained
> by MAME runtime: a swap under a live volume bombs a REAL Mac too — the
> missing SWITCHED flag made even benign transitions incoherent, and the
> Mac-authentic flow (guest ejects first) was structurally impossible while
> ISM eject was gated off. Bonus root cause found en route (`dbb736e`): Main
> packs the matched EXTENSION into the upper `ioctl_index` bits, so every
> `.img` floppy mount had been a silent no-op since day one — the §11 "eject
> then mount D2.img" test could never have worked regardless of RTL.
> Ground-truth captures: `verilator/mame/floppy/swap_tap.lua` + `run_swap.sh`
> (WSL `~/maclc_run/tap_swapB.txt`, `tap_qscreen.txt`). Historical content
> below is kept as written.

# Resume — make floppy MEDIA CHANGES visible to the guest

**Mission: unblock a System 6.0.8 install from floppy.** Branch `fix-quicktime`,
HEAD `6b0a7db`, no upstream (never pushed). Written 2026-08-06.

★ Read **[`sony_driver_mfm_read_reference.md`](sony_driver_mfm_read_reference.md)**
(ROM read path, every Sony error code, seven refuted theories) and
**[`swim_ism_read_reference.md`](swim_ism_read_reference.md)** (ISM register model)
before touching the floppy RTL. This document is about the *media-change* path only —
the **read** datapath is finished and validated, do not re-open it (§2).

---

## 0. Goal and acceptance test

Install **System 6.0.8** onto a SCSI disk from
`OS-6.0.8 disk 1 of 2.dsk` + `disk 2 of 2.dsk` (both 1,474,560 B = **1.44 MB MFM**,
so this runs through the **ISM/SWIM** path, *not* GCR).

Done when, in one session without resetting between disks:

1. The installer runs (booted from floppy, or launched from a mounted floppy).
2. It asks for **disk 2**; you mount disk 2 in the OSD; **the installer continues.**
3. The install completes and the resulting system boots.

Secondary goal, same root cause (§1): **mounting a floppy at the flashing-`?` boot
screen is picked up** instead of ignored.

## 1. Why the `?` screen and disk swapping are one mission

Both are the guest never being told the medium changed. The core has exactly one
"is there a disk?" signal — `CSTIN` — and today it is **latched**, not reported:

- `MacLC.sv`: `dsk_int_ins` is a **level** derived from the image size latched at
  *end of download*, so mounting image B while image A is in the drive takes it
  `1 → 1`. No edge.
- `rtl/floppy.v` (~line 656): the CSTIN block is
  `if (eject strobe) CSTIN<=1; else if (insertDisk) CSTIN<=0;` — **with no else**.
  An insert *latches* the line low, and only a guest EJECT strobe can raise it.

So after the first mount the drive says "a disk is present" forever, whatever the
host does. The `?` screen is the same defect seen earlier in the boot: the ROM is
polling for bootable media and never observes a change. (They *could* still diverge —
the `?` case is ROM-level boot polling, the swap case is File-Manager volume state —
so verify each separately rather than assuming one fix covers both.)

## 2. ★ DO NOT re-open the read datapath — it is finished

Hardware-verified 2026-08-05/06: an **800 KB GCR** disk mounts, a **482 KB
application launches off the floppy**, and that application **copies to a SCSI
disk** — head seeking throughout (`step_cnt` 1 → 311), zero driver errors. 1.44 MB
MFM read was validated 2026-08-03. Offline, `scripts/gcr_data_census.py` verifies
every zone boundary on both sides (tracks 0/1/16/17/32/48/64/79, and the 400K
single-sided path) serves 17/17 data fields checksum-valid with content at the
correct image offset — which **refuted** the `soff`/zone-mapping theory the previous
resume doc carried, as the older "SDRAM region != image" theory was refuted before it.

★★ **The tell that misled this hunt for a month:** `byte_cnt` frozen with `$142`
carrying only benign codes means **no read was ever attempted**, not "reads returned
bad data". A driver that reads and fails *posts a code*. If the counters are static,
look **above** the driver (volume/media state), never below it.

## 3. ★★ The attempted fix REGRESSED the mount — do not repeat it as-is

Committed as `ef430a2` + `78804c1`, **reverted in `ebbdac6`**. What it did:

- `MacLC.sv` — hold the drive EMPTY from download start until `DSK_EMPTY_CY`
  (26'h3FFFFFF ≈ 2.06 s at clk_sys) after it ends; also clear the geometry regs
  (`dsk_*_ds/ss/mfm/hd`) at download start.
- `rtl/floppy.v` — `CSTIN <= ~insertDisk`, so the drop is visible at all.

`78804c1` matters on its own: **without it the MacLC.sv half is a pure no-op**, which
`verilator/tb_disk_swap.v` caught before a deploy (a build was already in the fitter
and was killed). Keep that lesson: for a missing-EDGE bug, write the unit TB first.

**Why it was reverted** — clean same-bench A/B, cold boot + one mount each:

| core | runs | result |
|---|---|---|
| pre-fix `fd1d2c6c` | 2 | **clean** — 43072 / 44506 bytes delivered, volume lists |
| fixed `7bc0a084` | 2 | **died AT the mount** — Finder "bad F-Line instruction" (2220 B in), then "error of type -109" `nilHandleErr` (29 B in) |

Both fixed-core boots reached a clean desktop first and died at the mount, having
barely started reading. STA was clean (+0.085 setup, no negative slack) and every
offline test passed, so it is **behavioural, not a fit problem**. Archived:
`scratch/MacLC_SWAPFIX_7bc0a084.rbf`.

★ **Two behaviour changes were bundled in one fit**, so the failure could not be
attributed. Next time land them separately: (a) `CSTIN <= ~insertDisk` alone,
(b) the empty-hold, (c) the geometry clear at download start. The geometry clear is
not innocent — `dsk_int_ds` feeds `diskSides` → the GCR encoder's `sides`, and
`dsk_int_mfm/hd` feed `mfm_disk`/`mfm_hd`, so flipping them mid-session changes the
encoder's address arithmetic and the drive's identity sense bits.

## 4. ★★ ISM mode cannot eject — the MFM-specific blocker

`rtl/floppy.v:656` gates the eject decode on **`!ism_active`**:

```verilog
if (_enable == 1'b0 && !ism_active && lstrbEdge && driveWriteAddr == `DRIVE_REG_EJECT && ca2 == 1'b1)
```

That guard exists for a real reason (2026-08-03): in ISM mode the Phases register
drives the same `ca0-2`/LSTRB lines, and the register walk passes through
`$FF = {LSTRB,ca2,ca1,ca0}` which this layer decoded as EJECT — silently ejecting the
just-inserted image on every ISM probe. Its comment concludes *"An ISM read session
never needs to eject."*

**That assumption is exactly wrong for this mission.** A 1.44 MB installer disk is
read in ISM mode, and swapping disks is the entire point. So for the 6.0.8 install the
guest may be **structurally unable to eject** — worth confirming first (§8 step 1),
because if true it is a second, independent blocker from the CSTIN latching.

Fix direction: distinguish a genuine EJECT command from a Phases-register walk instead
of disabling eject wholesale. Candidates — decide with MAME (§7), don't guess:
- Qualify on ISM `ACTION` being clear (a real eject is not issued mid-read), the way
  the head-select sampling at `floppy.v:536` already qualifies itself.
- Use the ISM's own eject/eject-line semantics rather than the IWM phase decode.
- Require the exact IWM strobe shape the ROM uses (`_enable` low, correct SEL bank)
  and reject the `$FF` all-ones pattern specifically.

## 5. Prime hypothesis for the real fix: the SWITCHED sense register

`floppy.v`'s `driveRegsAsRead` hardwires **read register 6 ("disk switched")** to
`1'b0` — "nothing changed", forever:

```verilog
1'b0, // [6] disk switched?
```

Read index = `{ca2,ca1,ca0,SEL}`, so this is address `0110`. The **write** side already
exists in the register table: write `{ca1,ca0,SEL} = 001` (= `DRIVE_REG_CSTIN`) with
`ca2 = 1` is *"Reset disk switched flag"* — and today that write does nothing.

So the OS is told the medium left and came back while the disk-switched flag insists
nothing changed. That fits every observation, including the two failure modes of §3
being memory-manager/trap-level errors *at mount time* rather than driver errors: the
OS re-mounts (or re-validates) its cached volume on inconsistent state.

**Implement SWITCHED and the CSTIN transition together** — that is the change the last
attempt was missing:

1. `reg disk_switched` per drive, **set** on any media change (insert, remove, or
   host-side image replacement), **cleared** by the guest's write to register 1 with
   `ca2 = 1`, **reported** at `driveRegsAsRead[6]`.
2. Reset value: think about whether it should power up set (a disk "appeared") or
   clear. MAME will tell you (§7).
3. Only then add the CSTIN transition.

### Refinement worth having: hold empty until *observed*, not for a fixed time

The reverted fix held the drive empty for a blind 2.06 s. Better: hold empty until the
guest has actually **read the CSTIN sense register while it reads "no disk"** (count
reads at address 1 with `_enable` low), then release. That guarantees the removal was
observed, removes a magic constant, and cannot release early or hang forever if you
bound it with a generous timeout as a backstop.

## 6. Other hypotheses, cheapest first

1. **The `?` screen may not need any of this.** Check the simplest thing first: mount
   a floppy at the `?` screen and watch whether `CSTIN` actually transitions and
   whether the ROM polls it at all. If the transition happens and is ignored, the
   problem is elsewhere (e.g. the ROM has already abandoned the floppy, or takes the
   GCR path for an HD disk because of a drive-identity sense bit) and the fix is
   different. `dbg_status` bit 0 already exposes `~CSTIN`.
2. **`DRVIN`/`is_2m` and `m_mfm` identity sense** decide whether the ROM routes a disk
   down GCR or ISM. Polarity is HW-validated (see the long comment at
   `floppy.v:180-227`) — **do not "fix" it** — but a *stale* value across a swap could
   route disk 2 down the wrong path. The geometry regs feeding it are exactly what
   §3(c) clears.
3. **Invalid image sizes present no disk at all, silently.** `dsk_*_ins` requires an
   exact size match. `Install Disk 1 RAW.dsk` on the bench is **1,301,504 B** — not a
   valid floppy size, so mounting it presents *nothing* and the previous disk stays.
   ★ This confounded one of my own tests on 2026-08-06 (see §11); always check the
   byte size before drawing conclusions, and consider making an unrecognised size
   *visible* rather than silent.

## 7. ★ Get MAME ground truth BEFORE building

This exact question — what a real LC's drive reports across a media change — is
answerable offline, and MAME has settled two previous floppy arguments in this project
that source-reading got wrong (the `is_2m` polarity, and the ISM sense truth table).

Tooling: `verilator/mame/floppy/` (`run_floppy.sh`, `floppy_tap.lua`, `diag_tap.lua`,
`sonyvars_watch.lua`, `decode_ism.py`, `get_mame_src.sh`, `setup_roms.sh`) and the
process notes in [`mame_compare.md`](mame_compare.md) (macOS has no `timeout`; the
debugger defaults to the Egret HC05, not the 68020; MAME PCs are 8-digit `00Axxxxx`).
Precedent to imitate: [`findings_mame_floppy_groundtruth_2026-07-02.md`](findings_mame_floppy_groundtruth_2026-07-02.md).

Capture, on `maclc` with the same two 6.0.8 images, a **disk swap** and a
**`?`-screen insert**, and answer:

- Which sense registers does the driver/ROM poll around a change, in what order?
- What does **register 6** actually return, and when does the driver **write** register
  1 to clear it?
- Does `CSTIN` alone suffice, or is SWITCHED required?
- In ISM mode, how is an eject actually issued — and how does a real drive avoid
  confusing it with the Phases walk (§4)?
- At the `?` screen, what does the ROM poll, and how often?

## 8. Test plan

**Offline first (minutes, no bench):**

1. Extend `verilator/tb_disk_swap.v`. It already asserts four properties — empty out
   of reset, an edge on first mount, the same edge on a swap with no eject, and a
   wrong-sized file leaving the drive empty. Add: SWITCHED sets on change and clears
   on the register-1 write; **eject works while `ism_active` is high** (§4); the
   empty-hold releases only after the guest has read CSTIN.
2. Re-run the read-path regressions so a media-change change cannot silently break
   reads: `tb_gcr_read` + `gcr_data_census.py` (pass `+acclen=40 +pollgap=40`, the
   realistic LC pacing — the default fast pacing yields garbage), and `tb_ism_sony`
   (expect `PASS`, 145 sector reads, 0 failures).
3. `quartus_map --analysis_and_elaboration` (~1 min) as the first synthesis gate —
   catches Quartus 10028 multi-driver, which Verilator will not.

**On hardware — the gate that killed the last attempt, in this order:**

4. **Cold boot, ONE mount, read something** (mount an 800K disk, launch the app off
   it). This is the regression the reverted fix broke; if it fails, stop.
5. Then the swap: mount disk 1, and with the machine running mount disk 2. `byte_cnt`
   climbing is the oracle for "a real read happened"; the **screenshot filename is the
   mount oracle** for "which image is actually in the drive".
6. Then the mission test: run the 6.0.8 installer through the disk-2 prompt.
7. **Two boots minimum, always** — one boot is never a verdict.

★ **Turn the HUD back ON for this work** (`USE_DBG_HUD=1` in `MacLC.qsf`, currently
commented for release). It is the only working forensic channel on this board — the
JTAG hub's name table is corrupt — and `byte_cnt`/`$142` are how you tell "no read
attempted" from "read failed". Consider repurposing the spent MFM rows 7/8 for a
media-change witness: CSTIN transitions, SWITCHED state, and a count of guest reads of
sense register 1. Turn it OFF and re-gate before releasing.

## 9. Ops crib (what actually worked; several of these cost real time)

- **`kbdRaw:28` (Return) dismisses a Finder alert** — the OK button is the default.
  Far cheaper than hunting the button with the mouse.
- Keyboard: Cmd = `kbdRawDown:56`; E=18 (Eject), O=24 (Open), W=17 (Close),
  A=30 (Select All). ★ **Cmd-A/Cmd-O act on the FRONT window** — click the target
  window's title bar first, or you will open folders on the wrong volume.
- **Drag-to-Trash ejects a floppy** (verified — the icon disappears).
  **`Special ▸ Eject Disk` / ⌘E is often GREYED OUT** (seen with the disk's window
  frontmost in list view). Do not rely on the menu item.
- ★ **The screenshot filename is the mount oracle** (`…-Fetch GCR800K.png`). It is how
  a stale volume is spotted: filename says one image, desktop shows another.
- `scripts/grab_fresh.sh`, never stock `grab.sh` (which serves stale frames when video
  is dead). `scp` from the box needs **`-T`** for paths with spaces, plus
  `-i ~/.ssh/mister_only -o IdentitiesOnly=yes`.
- Mouse: `12× mouseMove:-60,-60` parks top-left, `12× mouseMove:60,-60` top-right;
  `mouseMove:8,0` ≈ 16 px; clicks need a ~1.4 s hold; menus track mouse-DOWN. Locate
  the cursor by frame-diff, **masking the HUD** (`d[432:,:128]=0`) or it dominates.
- Clean-shutdown choreography before any core load: park top-left, `14× (8,0)` +
  `(4,0)` → Special, `left_down`, `8× (0,8)` + `(0,4)` → Shut Down, **verify by zoom
  crop before releasing** ("Erase Disk…" is two items above), `left_up`; done when
  `[250:470,60:580]` is ≥0.9 dark. Do **not** use the guest's `Special ▸ Restart` —
  warm restart is a separate known-broken path.
- `scripts/icon_gate.py` is **STALE** — its fixed cells no longer land on icons and it
  FAILs a healthy Finder. Check colour icons by eye at 3× zoom, and use "two boots
  render pixel-identical" as the layout-independent marginality test.
- **Budget for a flaky bench.** On 2026-08-05/06 the *known-good* core produced a
  QuickTime bomb, a dead-video boot, and a happy-Mac hang on separate attempts.
  ★ Before blaming your change, reproduce the failure and run the **known-good control
  in the same session** — that is what proved the §3 regression real.

## 10. State at hand-off

- **Bench** `192.168.99.143`, `_Unstable/MacLC.rbf` = **`e51a4acd`** = the 2026-08-06
  release fit (RTL `2804d02`, **HUD OFF**), committed as
  `releases/MacLC_20260806.rbf`. STA setup +0.659 / hold +0.243, 80% ALM, 91% RAM.
- Archived RBFs in `scratch/`: `MacLC_IWMFIX_fd1d2c6c.rbf` (RTL `2804d02`, **HUD ON** —
  use this as the debug baseline), `MacLC_SWAPFIX_7bc0a084.rbf` (the reverted
  candidate, do not ship), `MacLC_RELEASE_e51a4acd.rbf`.
- **RTL is byte-identical to `2804d02`** (`git diff 2804d02 HEAD -- rtl/ verilator/sim.v`
  is empty). The only `MacLC.sv` delta is a comment.
- Working tree clean; 6 commits this session; **nothing pushed** (no upstream).
- **3 of 10 authorised build cycles used.**
- Guest: the bench disk carries a **System 7.6.1** folder and QuickTime 2.5 — that
  System is for **another core** (7.6 needs an 030; the LC cannot run it). Do not add
  7.6.1 to the core's supported list.

## 11. ★ What I did NOT verify — do not inherit these as facts

- **Whether ejecting in the guest and then mounting a different image works.**
  `readme.md` currently says it does not. That claim came from a test whose second
  image was `Install Disk 1 RAW.dsk` at **1,301,504 B — an invalid floppy size**, so no
  disk was ever presented and the old volume staying proves nothing (§6.3). **Re-test
  with two valid same-size images** (e.g. `Install7-1 D2.img`/`D3.img`, 819,200 B each)
  and correct the README either way. If it *does* work, that is an immediate
  user-facing workaround for the install — and it also means the eject path, not the
  mount path, is the shorter road to a fix.
- Whether the OSD's **"Reset & Apply"** re-reads a swapped floppy. It is what the
  README now recommends and the mechanism is sound (every cold boot with a single mount
  works), but the OSD entry itself was never exercised — blind OSD navigation is risky
  here (`Reset PRAM & Core` is a neighbour).
- Whether **System 7.6.1 boots** on anything — inferred from a folder name only.
- Whether the `?`-screen and swap failures share one cause (§1).

## 12. Disks on the bench (`/media/fat/games/MacLC/`)

| file | bytes | form |
|---|---|---|
| `OS-6.0.8 disk 1 of 2.dsk` / `disk 2 of 2.dsk` | 1,474,560 | **1.44 MB MFM — THE MISSION** |
| `OS608-1440k.dsk` | 1,474,560 | 1.44 MB MFM |
| `Install7-1 D1/D2/D3.img` | 819,200 | raw 800K GCR (good swap-test trio) |
| `Fetch GCR800K.dsk` | 819,200 | raw 800K GCR, 1 app — the read-path fixture |
| `Boot712.dsk` | 819,200 | raw 800K GCR, "Disk Tools" |
| `MacTerminal.dsk` | 409,600 | raw **400K** GCR (only 400K image present) |
| `6.0.7 System Tools / Utilities 1 / Utilities 2.dsk` | 838,484 | **DC42** 800K GCR + tags |
| `Tetris Max.dsk` | 1,474,644 | 1.44 MB **DC42** (84-byte header) |
| `Install Disk 1 RAW.dsk` | 1,301,504 | ★ **INVALID SIZE — never mounts** |

★ Do **not** use `Disk605.dsk` as a reference — it was converted to make it work, so it
is not a trustworthy sample.
