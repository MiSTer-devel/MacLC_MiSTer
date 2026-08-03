# Resume — 1.44MB MFM floppy (SWIM ISM read engine), 2026-08-03

**Authoritative handoff for the floppy mission.** Supersedes
`docs/resume_floppy_controller_2026-07-07.md` (whose §1 mount recipe is now known
to be WRONG — see §3). Branch `fix-quicktime`, commit `a5ef2ac` (+ uncommitted
`MacLC.qsf` SEED change).

---

## 0. TL;DR — where we are

The ISM engine **boots clean and the OS now takes the MFM/ISM path for a 1.44MB
disk** — a real advance over July, where 1.44M disks were routed to GCR and never
touched ISM at all. The disk does not yet mount: the guest reports **"This disk is
improperly formatted for use in this drive."** (versus the GCR path's "unreadable"
+ One-Sided/Two-Sided, so the two paths are now clearly distinguishable).

**RESOLVED this session — the primary drive going dead was MY regression, and it
is fixed (build 3, HW-confirmed).** Root cause: the ISM Phases register drives the
same `ca0-2/LSTRB` lines as the IWM soft switches, and the phase walks pass
through `$FF` = `{LSTRB,ca2,ca1,ca0}=1111`, which `floppy.v` decodes as
`driveWriteAddr 6 (EJECT)` + `ca2=1`. Every per-mount ISM probe ejected the image
it had just inserted. Only the ISM-selected drive was hit, which is why the
*external* drive still worked and the failure looked like a routing/SDRAM-region
bug. Proven by A/B: pre-ISM release reacts on row 0, build `833c327b` does not;
after the fix (`2a45c1a3`) row 0 reacts again. **Both drives now behave
identically.**

Remaining problem: **the ISM read returns a payload the OS rejects** (§4).

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
| 2 | `833c327b` | 7 | met +0.247 ns | **CLEAN** — full MacAtrium desktop, colour icons, responsive. Row 0 dead (the eject regression). |
| 3 | `2a45c1a3` | 7 | met +0.243 ns | **CLEAN** — boots to MacAtrium; **row 0 restored** (800K → "unreadable"; 1.44M → "improperly formatted", same as row 1). Commit `e522736`. |
| — | **not built** | — | — | Commit `586ed77`, the ISM **motor** fix, is **committed but NEVER BUILT, DEPLOYED OR TESTED** — the fit was cancelled. `mfm_spinning` was keyed on the IWM `MOTORON` register only, but an ISM session spins the drive with **Mode bit 7** (`swim_ism_read_reference.md` §B) and need never touch `MOTORON`, so the byte engine could stay parked for the entire MFM session. Now `motor \|\| ism_sel`. **This is a reasoned fix, not a verified one — gate it first.** |

**Budget: 3 of 10 builds used.** `MacLC.qsf` SEED is committed as 7.
`.143` is left running build 3 (`2a45c1a3`) with the 1.44M image mounted and an
"improperly formatted" dialog on screen — harmless, eject any time.

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

**RESOLVED — it was the ISM eject regression (§0), fixed in build 3.** On build
`2a45c1a3` row 0 reacts again and both drives behave identically. The table above
is the *symptom* record; the row-1 recipe remains the one to use because it is
what these results were gathered with, but row 0 is no longer dead.

Two theories considered and **discarded** (don't spend time on them again):
- `ejectIndicatorTimer` "never decrements while `insertDisk` is high" — it does
  self-resolve: `diskEject` is combinational, so `MacLC.sv` clears `dsk_int_*`
  within a cycle, `insertDisk` drops, and the timer then counts down.
- `driveSel = via_pa_o[4]` gating only the internal drive — plausible (PA4 is the
  overlay bit on Mac II-family VIAs, and MAME's LC wires nothing to PA4), but it
  cannot be the cause: row 0 works on the pre-ISM build with the same gate.
  Still worth revisiting on its own merits some day.

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

### Ruled out (do NOT re-audit)

- **Region/plumbing symmetry.** Download and read bases match:
  `index 1 → $600000 → floppyInt`, `index 2 → $700000 → floppyExt`
  (`MacLC.sv:1768-1769`, `addrController_top.v:210-211`). No swap.
- **Guest RAM cannot reach the floppy region.** `ram_sdram_word`
  (`addrController_top.v:177-180`) is bounded — motherboard mirror wraps to 20
  bits, SIMM caps at `$4FFFFF`, ROM `$500000`, VRAM `$580000`. Nothing the CPU
  does can scribble on `$600000+`.
- **★ July's "SDRAM region ≠ image" verdict is very likely an ARTIFACT.** That
  capture mounted with `kbd:down` (→ index 2 → `$700000`) while the ring watched
  `floppyInt` reading `$600000` — a region that never received that image. Its
  "138 bytes of garbage found in no image" is exactly what an untouched region
  looks like. Do not resume the download-doesn't-land hunt on that evidence.
- **Sector→image address math** in `mfm_track_encoder.v:65-76`:
  `((track*2+side)*SPT + sector)*512 + offset`, shift-add decomposition verified
  correct (`block_hd = ts*16 + ts*2 = ts*18`), max = 1,474,559 ✓.
- **Drive-ID polarity** (§4 above) — correct as written.

### Next suspects for the bad payload, in order

1. **The ISM motor gate** — build 4, described in §2. Best current candidate: if
   the driver only ever commands the motor via ISM Mode b7, the old gate meant
   *zero* bytes were delivered for the whole session.
2. **Handshake b2/b3.** `swim_ism_read_reference.md` §C says SWIM1 sets **both**
   0x04 and 0x08 from wprot/sense; `swim.v:411-420` sets b3 only and hardcodes
   b2=0, citing a "0.264 correction". These two sources contradict each other —
   settle it against MAME before trusting either.
3. Mark-sync hunt / FIFO shape (`swim.v:293`, `571`), and whether the driver
   needs bytes delivered during gaps as well as fields.

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

1. **Gate build 4** (the ISM motor fix) — mount the 1.44M image to row 1 and see
   whether the dialog changes or the volume mounts.
2. **★ If build 4 does not mount it, stop guessing and buy VISIBILITY.** Every
   build so far has been a 1-bit experiment against a blind read path, and the
   budget is finite. Two good options:
   - **A targeted unit testbench** (preferred): drive the ISM register protocol
     directly against `swim` + `floppy` + `mfm_track_encoder` with a small RAM
     model standing in for the image. Runs in seconds, shows every delivered
     byte, Handshake value and FIFO transition. A *full System boot* in Verilator
     is the thing to avoid (hours); a unit TB is not.
   - **A 1-bit hardware oracle** if the TB is impractical: gate `CSTIN` on a
     readback of the image's first word (both test images start `4C 4B` = "LK")
     so the guest's "disk appears / does not appear" answers *"does the region
     the drive reads actually hold the mounted image?"* with no JTAG. Three
     distinguishable outcomes: no disk = fetch/region wrong; disk + mounts =
     fixed; disk + "improperly formatted" = region fine, framing wrong.
3. Keep the per-fit gate: every new fit must reach a populated Finder desktop
   before any floppy verdict is trusted. STA does not predict it (build 1).
4. Restore the CD boot config when the mission ends (§5).
