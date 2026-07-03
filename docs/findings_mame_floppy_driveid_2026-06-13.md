> **⚠ PARTIALLY SUPERSEDED 2026-07-02 — see `docs/findings_mame_floppy_groundtruth_2026-07-02.md`**
> (runtime trace with *bootable* disks). Confirmed here: Fix B (ISM reg decode `n&7`), Fix A's
> reg 0xC=1. **Overturned:** reg 0xF is `is_2m` = **1 for DD / 0 for HD** (our `mfm_hd` is
> inverted); Fix C (`effSEL` from ISM Mode bit5) is **wrong on the LC** (head-select is V8 PA5
> in all modes — maclc never wires the SWIM hdsel_cb); the drive-ID probe actually runs as
> **IWM status reads**, 800K data I/O never leaves IWM, and this doc's runtime-trace sections
> were skewed by a false-triggering decoder (GCR write sync-groups faked an ISM switch).
> Two new fatal bugs found: the IWM→ISM switch detector (enable-gated → never fires) and the
> ISM Phases full-byte readback. Full diff list in the 07-02 doc §7.

# Findings — MAME ground truth for the floppy drive-ID (and why 1.44 MB / 800 K fail)

*2026-06-13. Ran MAME 0.264 `maclc` (native, in WSL Ubuntu-24.04) as ground
truth, per `docs/handoff_mame_floppy_driveid_2026-06-13.md`. The handoff's mental
model (IWM-mode drive-ID with a `{ca2,ca1,ca0,SEL}` bit-order problem) turned out
to be **wrong in an important way**: the maclc ROM drives the SWIM in **ISM mode**
for floppy access, and the real bugs are (1) our ISM register decode is off by a
bit field, and (2) our drive-sense "SuperDrive signature" is incomplete. Both are
now pinned to MAME source. This supersedes the bit-order theory.*

## TL;DR — the three concrete bugs (all MAME-source-grounded)

1. **ISM register decode is wrong.** `rtl/swim.v` decodes the ISM register as
   `cpuAddrRegHi[3:1]` (= `(addr>>10)&7`). MAME (`swim1.cpp ism_read`: `switch(offset & 7)`)
   and **the ROM's own behaviour** use `(addr>>9)&7` = `cpuAddrRegHi[2:0]`. The
   code comment even says "lower 3 bits" while taking the upper three. → **Fix:
   `ism_reg_addr = cpuAddrRegHi[2:0]`.**
2. **Drive does not report as a SuperDrive.** The OS identifies the drive by
   reading sense regs **0xC,0xD,0xE,0xF** and matching the 4-bit pattern `x011`
   (MAME `floppy.cpp mac_floppy_device::wpt_r`, "Initial state of bits f-c"
   comment). Our `floppy.v` returns `0` for reg 0xC and `mfm_disk` for reg 0xD,
   so the signature comes out **`0000` (=400K GCR drive) for an 800K disk** and
   **`1010` (=800K GCR drive) for a 1.44M disk** — never `x011`. The OS therefore
   never sees a SuperDrive and never takes the MFM path. → **Fix: reg 0xC = 1,
   reg 0xD = 1.**
3. **ISM-mode head-select uses the wrong source.** In ISM mode MAME drives the
   drive's side/HDSEL from **Mode register bit5** (`swim1.cpp`: `m_hdsel_cb((m_ism_mode>>5)&1)`),
   not VIA PA5. Our `swim.v` always feeds VIA PA5 as `SEL` to `floppy.v`. Sense
   regs 0xC–0xF all need HDSEL=1, which in ISM mode comes from Mode bit5. → **Fix:
   in ISM mode pass `ism_mode_reg[5]` as the floppy `SEL`.**

These explain the handoff's symptom exactly: every disk gets the GCR
"unreadable / One-Sided / Two-Sided" dialog because the OS thinks the drive is a
plain GCR drive (400K/800K), never a SuperDrive.

## How the ROM really talks to the floppy (the big surprise)

The maclc ROM **switches the SWIM from IWM to ISM mode almost immediately**
(frame ~191, PC `00A4797E`), via the documented 4× mode-register write with bit6
toggling `1,0,1,1` (captured bytes `57,17,57,57`). This happens for an **800K**
disk too — ISM mode is the primary interface; IWM is only the power-on default the
ROM briefly leaves. (It does bounce IWM↔ISM a few times during init.)

Proof of the register-decode bug, straight from the bus capture: the ROM does
`WR $F16800=F5` immediately followed by `RD $F17800 → F5` (and `F6→F6, F7→F7,…`).
`$F16800`→ n=4, `$F17800`→ n=12. Those read back the *same* value, so they are the
*same* ISM register. `n&7`: 4 and 12 both = **reg 4 (Phases)** — write-phases /
read-phases-back. ✓ `n>>1` (our code): 2 and 6 — two different registers. ✗

## MAME ground truth — drive sense register (`mac_floppy_device::wpt_r`)

Register index: **`reg = (phases & 7) | (head_select << 3)` = `{ss, ca2, ca1, ca0}`**
(`ss` = side/HDSEL). Values (mfd75w SuperDrive):

| reg | name | returns | our `floppy.v` bit (idx `{ca2,ca1,ca0,SEL}`) | our value | OK? |
|----|----|----|----|----|----|
| 0x0 | Dir | m_dir | [0] DIRTN | dir | ✓ |
| 0x1 | Step | 1 | [2] STEP | 1 | ✓ |
| 0x2 | Motor | m_mon | [4] MOTORON | motoron | ✓ |
| 0x3 | Eject/DiskChg | !m_dskchg | [6] SWITCHED | 0 | ~ (see note) |
| 0x4/0xC | RdData0/Index | superdrive: motor-off→1 | [8]/[**9**] RDDATA0/1 | 0 | **✗ reg C** |
| 0x5 | **Superdrive** | **has_mfm=1** | [10] SUPERDR | 1 | ✓ |
| 0x6 | DoubleSide | sides==2 | [12] SIDES | 1 | ✓ |
| 0x7 | NoDrive | 0 | [14] INSTALLED | 0 | ✓ |
| 0x8 | NoDiskInPl | image==null | [1] CSTIN | CSTIN | ✓ |
| 0x9 | NoWrProtect | !wpt | [3] WRTPRT | 0 | ✓ (WP) |
| 0xA | NotTrack0 | cyl!=0 | [5] TK0 | ~(trk==0) | ✓ |
| 0xB | NoTachPulse | tach | [7] TACH | tach | ✓ |
| 0xD | **MFMModeOn** | **m_mfm (dflt 1)** | [**11**] MFMModeOn | mfm_disk | **✗ reg D** |
| 0xE | NoReady | m_ready | [13] READY | 0 | ✓ (0=ready) |
| 0xF | **HD/is_2m** | **is_2m** | [15] DRVIN | mfm_hd | ✓ |

**The identification signature** (wpt_r comment, bits f‑c = is_2m, ready, mfm, rd1):

```
0000 = 400K GCR drive
x011 = Superdrive   (x = HD hole of inserted disk: 1=HD/1.44M, 0=DD)
1010 = 800K GCR drive
1110 = HD-20 drive ;  1111 = no drive
```

So **SuperDrive + HD disk = `1011`, SuperDrive + DD disk = `0011`** (matches
`docs/swim_ism_read_reference.md` §H). That requires **reg 0xF=is_2m (1 for HD),
reg 0xE=0 (ready), reg 0xD=1, reg 0xC=1**. We already have F (=mfm_hd) and E (=0);
we were missing **C and D**.

`m_mfm` (reg 0xD) defaults to `has_mfm` (=1 for a SuperDrive) and is toggled by
the phase-strobe commands **$9 = MFMModeOn (→1)** and **$D = GCRModeOn (→0)**
(`seek_phase_w`). For identification it reads 1; constant 1 is a faithful default.

## MAME ground truth — how sense is *read* in each mode (`swim1.cpp`)

- **IWM mode** (`read`, control `&0xc0`): `0x40` (status) returns
  `(m_iwm_status & 0x7f) | (wpt_r ? 0x80 : 0)` → **sense in D7**. Matches our
  `swim.v` IWM status mux.
- **ISM mode** (`ism_read`): register = `offset & 7`. **Handshake (reg 7)** sets
  **bit3 (0x08) = wpt_r (sense)**, bit0=mark, bit1=`!CRC0`, bit5=error,
  bit7:6=fifo avail/full. (Our `swim.v` puts sense in bits 3 *and* 2; bit3 is the
  one that matters — bit2 should be 0 to match, harmless either way.)

So in ISM mode the OS reads a drive sense register by: set ca2/ca1/ca0 via the
**Phases** reg (4), set HDSEL via **Mode bit5**, read **Handshake** reg (7) bit3.

## Fixes applied this session (UNVERIFIED — no Verilator on this box, FPGA is shared)

- `rtl/swim.v`: `ism_reg_addr = cpuAddrRegHi[2:0]` (was `[3:1]`). Bug #1.
- `rtl/floppy.v`: `driveRegsAsRead[9]` (reg C) = `1'b1`; `[11]` (reg D, MFMModeOn)
  = `1'b1`. Bug #2 → signature becomes `0011` (800K/DD) / `1011` (1.44M/HD).
- `rtl/swim.v`: floppy `SEL` = `ism_mode ? ism_mode_reg[5] : SEL`. Bug #3.

**Must be HW-validated** (Quartus build + deploy to .143). I could not build here.

## Still open / next steps (need a bootable Mac disk trace or HW)

- **Read datapath.** My local test disks (`releases/Disk605.dsk` 800K; a blank/FAT
  1.44M) are not images the maclc ROM will *boot*, so MAME gave up before a full
  sector read — I did not capture a clean "good read" cadence. To pin the read
  loop, trace MAME with a **bootable** Mac disk (e.g. the rig's `Tetris Max.dsk` /
  `OS-6.0.8 disk 1.dsk`). Open question: is 800K data read in **IWM** mode
  (existing `floppy_track_encoder` GCR path) or **ISM** mode (Setup bit2=1, GCR
  datapath into the ISM FIFO — *not implemented* in our `swim.v`, which only feeds
  `mfm_byte`)? The trace shows the ROM bounces back to IWM after the ISM drive-ID,
  which *suggests* IWM-mode GCR for 800K — but it was not confirmed with a real read.
- **reg 0xD strobe tracking.** Ideally `MFMModeOn` tracks $9/$D (default 1) rather
  than constant 1. Our `floppy.v` write decode (`driveWriteAddr={ca1,ca0,SEL}`)
  currently can't even distinguish $9 from $D (no ca2) — would need extending.
- **is_2m polarity.** `mfd75w_device::is_2m()` literally returns true only for
  SSDD/DSDD variants — confusing vs the `1011`(HD)/`0011`(DD) signature. We keep
  `reg F = mfm_hd` (1 for HD) per the signature + reference doc; verify on HW that
  a real 1.44M disk reads HD.
- **reg 0x3 (Eject/DiskChg)** = `!m_dskchg`; we hardcode 0. Likely fine but unverified.

## Reproduce (WSL MAME tooling — all new, in `verilator/mame/floppy/`)

```bash
# one-time: assemble the romset from in-repo ROMs (boot0.rom + rtl/egret/*.bin)
wsl -d Ubuntu-24.04 bash verilator/mame/floppy/setup_roms.sh      # -> ~/maclc_roms, verifyroms OK

# capture a bus trace (VIA1 $F00000-$F01FFF + SWIM $F16000-$F17FFF, exec order)
wsl ... bash verilator/mame/floppy/run_floppy.sh <disk.dsk> 12 /tmp/tap.txt

# decode: IWM status sense reads + full IWM/ISM reconstruction
wsl ... python3 verilator/mame/floppy/decode_tap.py /tmp/tap.txt   # IWM status reads
wsl ... python3 verilator/mame/floppy/decode_ism.py /tmp/tap.txt   # IWM+ISM, transitions, sense
```

Tap byte lane: VIA/SWIM live on **D[31:24]** of the 68020 longword (mem_mask
`0xFF000000`); `floppy_tap.lua` extracts that byte. MAME maincpu PCs are `00Axxxxx`.
MAME source pulled to `/tmp/{swim1,floppy}.cpp` (tag `mame0264`) via
`get_mame_src.sh`.
