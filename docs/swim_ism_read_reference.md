# SWIM ISM-mode MFM READ — register-level reference (for 1.44 MB support)

*Ground truth: MAME `swim1.cpp` (the Mac LC instantiates **SWIM1** @ C15M, drive
`35hd`/`mfd75w` — `src/mame/apple/maclc.cpp`) + Apple SWIM Chip User's Reference.
Compiled 2026-06-13 from a MAME-source research pass. Use this to implement the
ISM read path in `rtl/swim.v` + a new MFM track generator. The existing GCR
(IWM-mode) path in `floppy.v`/`floppy_track_encoder.v` is unrelated and stays.*

> ⚠ **Corrections applied 2026-08-03** (this file was compiled from a MAME
> *source*-reading pass on 06-13; two claims were later overturned by the MAME
> 0.264 **runtime** capture in `findings_mame_floppy_groundtruth_2026-07-02.md`,
> and both had already cost a session each):
> - **§C: SWIM1 does NOT drive sense on both handshake b2 and b3 — b3 only.**
>   `swim1.cpp:224-250` (0.264) never sets 0x04; b2 is rddata. Verified against
>   the source this session.
> - **§H / below: the SuperDrive identify nibble for an HD disk is `0011`, not
>   `1011`.** `is_2m` is **1 for DD, 0 for HD** — inverted from what a plain
>   reading of `floppy.cpp` suggests. `rtl/floppy.v` implements the *correct*
>   (runtime-verified) polarity; do not "fix" it to match the old text.

## Key takeaways (why 1.44 MB doesn't work today)

1. **Drive must report SuperDrive.** The OS reads drive **sense reg 0x5** =
   `m_has_mfm`; our `floppy.v` returns `SUPERDR=0`, so the OS never tries MFM.
   The f..c sense nibble must read **`0011`** for SuperDrive + HD disk
   (`1011` for SuperDrive + DD). *(Status 2026-08-03: implemented and verified —
   `verilator/tb_sense.v` sweeps all 16 sense registers against the runtime
   capture and the identify nibble reads `0011` for an HD disk.)*
2. **ISM read datapath is unimplemented.** `swim.v`'s ISM FIFO is only filled by
   CPU writes; nothing feeds decoded disk bytes in. Reads return empty.
3. **Timing is NOT the blocker.** The driver polls Handshake bit7; deliver bytes
   at ~16 µs/byte *or faster*, just never let `fifo_pos > 2` (overrun = Error b2).
   Our E clock (CPU/20 ≈ 812.5 kHz) is fine.

## A) ISM register map (`offset & 7`) — swim1.cpp:179-338

| off | READ | WRITE |
|----|----|----|
| 0 | **Data**: `fifo_pop`; if popped word has M_MARK → set Error b1; if empty → Error b2 (underrun) | Data: `fifo_push(data)` |
| 1 | **Mark**: same pop as 0 but does NOT raise mark-error | Mark: `fifo_push(M_MARK\|data)` |
| 2 | **Error**: returns `ism_error`, **clears on read** | CRC: `fifo_push(M_CRC)` (write-only token) |
| 3 | **Param[idx]**: returns param, idx=`(idx+1)&15` (**16-byte** RAM on SWIM1) | Param[idx] write, idx `&15` |
| 4 | Phases: returns `m_phases` | Phases: `m_phases=data; update_phases()` |
| 5 | Setup: returns `ism_setup` | Setup: `ism_setup=data` |
| 6 | Status: returns `ism_mode` | **Mode-CLEAR**: `ism_mode &= ~data`, `param_idx=0` |
| 7 | **Handshake** (see C) | **Mode-SET**: `ism_mode \|= data` |

SWIM1 note: write-6 is plain `&= ~data` (can clear bit6 to exit ISM). SWIM2
force-re-ORs 0x40 — do NOT copy SWIM2 here. Param wrap is `&15` on SWIM1 (`&3` on
SWIM2). These are real SWIM1-vs-SWIM2 differences; the LC is **SWIM1**.

## B) MODE & SETUP register bits

**MODE** (set via reg7, clear via reg6, read via reg6) — swim1.cpp:133-145:

| bit | mask | meaning |
|----|----|----|
| 7 | 0x80 | motor on |
| 6 | 0x40 | **ISM select** (1=ISM, 0=IWM) |
| 5 | 0x20 | HDSEL / head select |
| 4 | 0x10 | **write(1) vs read(0)** |
| 3 | 0x08 | **ACTION** (start/active) |
| 2:1 | 0x06 | drive-select code (gated by b7) |
| 0 | 0x01 | clear FIFO |

**"Entering read mode" is detected as `(mode & 0x18) == 0x08`** (ACTION set,
write clear) — swim1.cpp:371. That edge resets the shift register, CRC, and the
correction state machine. So the hardware **start-read trigger = rising edge of
`ACTION=1 && WRITE=0` while ISM selected**.

**SETUP** (read/write reg5) — swim1.cpp:305-313:

| bit | mask | meaning |
|----|----|----|
| 7 | 0x80 | MOTORON timer enable |
| 6 | 0x40 | TSM / GCR **write** select |
| 5 | 0x20 | **IBM(1) vs Apple(0)** format |
| 4 | 0x10 | ECM error-correction enable |
| 3 | 0x08 | clock fclk/2(1) vs fclk(0) |
| 2 | 0x04 | **GCR(1) vs MFM(0)** — the **read** encoding select |
| 1 | 0x02 | 3.5" select |
| 0 | 0x01 | HDSEL vs Q3 head-select source |

⚠ **Two GCR/MFM bits.** Bit **2 (0x04)** selects the **read** datapath:
`if (ism_setup & 0x04) GCR; else MFM` (swim1.cpp:377,1149). Bit 6 is the write
side. **For an MFM read: bit2=0, bit5=1 (IBM).** Those two are load-bearing.

## C) HANDSHAKE (read reg7) — swim1.cpp:224-250

| bit | mask | condition | meaning |
|----|----|----|----|
| 0 | 0x01 | top FIFO word has M_MARK | **next byte is a MARK** (A1 sync) |
| 1 | 0x02 | `!(word & M_CRC0)` | **CRC**: reads **0 when CRC good (==0)**, else 1 |
| 2 | 0x04 | **rddata — never set by SWIM1** | (not sense; see correction at top) |
| 3 | 0x08 | `!m_floppy \|\| m_floppy->wpt_r()` | **SENSE** (the phase-addressed drive register) |
| 5 | 0x20 | `ism_error != 0` | error pending |
| 6 | 0x40 | FIFO-full (read: pos==2) | "2 bytes ready" |
| 7 | 0x80 | FIFO-not-empty (read: pos>=1) | **data available** |

Bits 7:6 are direction-dependent: in **read** mode pos==2→0xc0, pos==1→0x80,
pos==0→none (so b7=data-ready, b6=full); in write mode it's inverted
(space-available). **Read loop:** poll reg7; b7 set → read reg0; b0 tells you the
byte is a mark; b5 = error; b1 = CRC-good-at-this-byte (0=good). SWIM1 drives
sense on **b3 only** — b2 is rddata and is never set (0.264 source, re-verified
2026-08-03; the earlier "both b2 and b3" claim was wrong).

**b0/b1 describe the NEWEST FIFO entry** (`m_ism_fifo[pos-1]`) and both read 0
when the FIFO is empty — the guard matters, an empty FIFO must not report a
stale mark/CRC.

⚠ **b3 is the phase-addressed sense line, so during an MFM read it is the
INDEX pulse.** The driver parks the phases on RdData0/1 (`Phases = F4`) for the
whole session, and on a SuperDrive with an MFM disk those sense registers return
`!index` (MAME `mac_floppy::wpt_r`; Snow `drive.rs`:
`RDDATA0 | RDDATA1 if mfm && motor => !at_index()`). The Sony driver polls it
millions of times per session to bound its sector searches, so a floppy model
that never pulses the index will hang the mount even if every delivered byte is
correct. Our track generator emits a real once-per-revolution preamble
(gap4a 80×4E + sync + IAM + gap1 50×4E) and derives the index from it.

## D) MARK semantics — swim1.cpp:1159-1196

The A1 sync bytes **are delivered to the FIFO, each flagged as a mark** (word =
`M_MARK | 0xA1` = `0x1A1`) — not consumed, not collapsed. Mechanism: the A1 has a
missing clock bit (wire pattern `0x4489`); the decoder flags `tsm_mark`, pushes
the byte with M_MARK, **and re-clears the running CRC to 0xCDB4 at that byte**.
- Reading a marked word via **reg0** sets Error b1; via **reg1** does not.
  Handshake b0 pre-warns the next byte is a mark.
- **ID field bytes seen:** `A1(m) A1(m) A1(m) FE  C H R N  CRChi CRClo`
- **Data field bytes seen:** `A1(m) A1(m) A1(m) FB  <512 data>  CRChi CRClo`
- The FE/FB address-mark bytes are **normal** (non-mark) bytes after the 3 marks.

## E) MFM track byte layout (1.44 MB, IBM System/34)

Format (MAME `pc_dsk.cpp` 1.44M): **18 sec/trk, 512 B/sec, N=2, 80 cyl, 2 heads,
sector base = 1 (1-based), gaps {gap4a=80, gap1=50, gap2=22, gap3=108},
interleave 1:1.** Cylinder/head are 0-based, sector R is **1..18**.

Track preamble (once): `4E×80 | 00×12 | C2 C2 C2 FC (IAM) | 4E×50`. The driver
usually ignores the IAM — don't depend on it.

Per sector ×18:
```
00 × 12                      ; ID sync
A1 A1 A1                     ; 3 MARK bytes (raw 0x4489)
FE                           ; ID address mark (normal)
C H R N(=0x02)               ; cyl, head, sector(1-based), size
CRChi CRClo                  ; CRC-16-CCITT over [A1 A1 A1 FE C H R N]
4E × 22                      ; gap 2
00 × 12                      ; data sync
A1 A1 A1                     ; 3 MARK bytes
FB                           ; data address mark (0xFB normal; 0xF8=deleted)
<512 data bytes>
CRChi CRClo                  ; CRC over [A1 A1 A1 FB <512 data>]
4E × 108                     ; gap 3
```
Sync fields are 12×0x00 everywhere; gap byte is 0x4E.

## F) CRC — verified — swim1.cpp:592-604

- **CRC-16-CCITT, poly 0x1021, MSB-first, no reflection, no final XOR.**
- **Seed 0xCDB4**, which is *exactly* `CRC-CCITT(init=0xFFFF)` over `A1 A1 A1`
  (verified). So either seed 0xCDB4 then feed `FE/FB + payload`, OR init 0xFFFF
  and include all three A1s — identical result.
- CRC is **re-cleared at each mark byte**, then updated over each subsequent
  non-mark byte until the next mark.
- Worked values (verified): `CRC(0xFFFF; A1 A1 A1)=0xCDB4`;
  `A1 A1 A1 FE 00 00 01 02 → 0xCA6F`; `A1 A1 A1 FB + 512×00 → 0xDA6E`.
  Residue over `field + 2 stored CRC bytes` = **0x0000** → set the per-byte
  M_CRC0 flag when running CRC hits 0 (drives Handshake b1 to 0 = good).
- FPGA recipe: 16-bit reg; on each decoded A1 load 0xCDB4; per data byte run 8×
  `crc = (crc & 0x8000) ? (crc<<1)^0x1021 : (crc<<1)` with the byte bit XORed in
  MSB-first.

## G) Timing — swim1.cpp:607-609

HD 3.5" = 500 kbit/s MFM = 2 µs/bit ⇒ **~16 µs per decoded byte**. The 2-entry
FIFO gives ~16 µs slack/byte; **the driver polls Handshake b7, it is not
edge/interrupt-timed**. Producer model: **advance one decoded byte into the FIFO
whenever ACTION&read are set and `fifo_pos < 2`**, on your byte-cell clock. The
SWIM1 is clocked C15M with ISM in half-clocks — irrelevant if we generate bytes.

## H) Drive identification (SuperDrive + HD sense) — floppy.cpp:3172-3336

Not in the SWIM — in the **drive sense register**, addressed by the phase lines
`reg = (phases & 7) | (head_select ? 8 : 0)`, returning one sense bit. Full table
(`wpt_r()`):

| reg | name | returns |
|----|----|----|
| 0x0 | Dir | step direction |
| 0x1 | Step | step active (always 1) |
| 0x2 | Motor | motor on |
| 0x3 | Eject/DiskChg | `!dskchg` |
| 0x4/0xC | RdData0/Index | MFM drives: `!idx` |
| **0x5** | **Superdrive** | **`has_mfm`** ← OS gate for MFM |
| 0x6 | DoubleSide | `sides==2` |
| 0x7 | NoDrive | 0 (drive present) |
| 0x8 | NoDiskInPl | `image==null` (1=no disk) |
| 0x9 | NoWrProtect | `!wpt` |
| 0xA | NotTrack0 | `cyl != 0` |
| 0xB | NoTachPulse | tach (120 pulses/rev) |
| **0xD** | **MFMModeOn** | **`m_mfm`** |
| 0xE | NoReady | `ready` |
| **0xF** | **HD** | **`is_2m()`** (DSHD variant) |

Detection sequence the OS runs:
1. Read **0x5** → must be **1** (SuperDrive). Plain 800K drive = 0 → no MFM.
2. Read **0xF** → **1** for HD disk, 0 for DD. (HD hole in the shell.)
3. Strobe phase **0x9** = "MFM mode on" (sets `m_mfm` if SuperDrive); **0xD** =
   "GCR mode on". 1.44 MB spins constant **300 RPM, 500 kbit/s CAV** (vs 800K's
   zoned CLV).
4. Program SWIM Setup (bit2=0, bit5=1) + Mode (ISM, read, ACTION) and read.

The f..c sense nibble must read **`0011`** for SuperDrive + **HD** disk and
**`1011`** for SuperDrive + **DD** — i.e. `is_2m` is **1 for DD, 0 for HD**.
(The opposite is written elsewhere in older notes and is WRONG; settled by the
MAME 0.264 runtime capture, where both disks actually mount. Inverting it sends
800K disks down MFM and 1.44M disks down GCR, and both then fail.)

**Our drive must report:** 0x5=1, 0xF=1 (HD image) / 0 (800K), 0x6=1, 0xD tracks
the 0x9/0xD strobes, 0x8=0 (disk in), 0xE=1 (ready).

## Source files (mamedev/mame master)
- `src/devices/machine/swim1.cpp` — **primary**: regs 184-338, CRC 592-604, FIFO
  617-644, MFM decode/mark/CRC0 1100-1200, handshake 224-250.
- `swim1.h` — `M_MARK=0x100, M_CRC=0x200, M_CRC0=0x400`.
- `src/devices/imagedev/floppy.cpp` — `mac_floppy_device` sense 3172-3336;
  `mfd75w` = SuperDrive (`has_mfm`, `is_2m`).
- `src/lib/formats/pc_dsk.cpp` — 1.44M tuple (18 spt, N=2, base 1, gaps 80/50/22/108).
- `src/lib/formats/upd765_dsk.cpp` — `get_desc_mfm()` exact track layout.
- `src/mame/apple/maclc.cpp` — confirms SWIM1 @ C15M, `35hd` drive.

Apple docs: SWIM Chip User's Reference (archive.org `SWIMDesignDocs`); SWIM Chip
Spec 1987-09 (bitsavers `SWIM_chip_spec_198707.pdf`).

## Appendix: DC42 (DiskCopy 4.2) container format

*From `..\rusty-backup\src\rbformats\dc42.rs` (known-good reader/writer). This is
the image **container**; the data fork inside is plain logical sectors — the
SWIM/MFM encoding above is applied by us on the fly. MAME's loaders are
GCR-oriented (`ap_dsk35`) and may not ingest DC42 1.44 MB, so this is the
authoritative container reference.*

84-byte header, then data fork (logical 512-byte sectors, **in order, no
interleave**), then optional tag data.

| offset | size | field |
|----|----|----|
| 0x00 | 64 | disk name — Pascal string (len byte 1..63, then name) |
| 0x40 | 4 | **data_size** (u32 BE) — sector-data bytes |
| 0x44 | 4 | **tag_size** (u32 BE) — 12 B/sector for 800K GCR; **0 for MFM** |
| 0x48 | 4 | data_checksum (u32 BE) |
| 0x4C | 4 | tag_checksum (u32 BE) |
| 0x50 | 1 | **disk_format**: 0=400K GCR, 1=800K GCR, **2=720K MFM, 3=1440K MFM** |
| 0x51 | 1 | format_byte: 0x02=single-sided, 0x22=double-sided (HD) |
| 0x52 | 2 | private magic = **0x0100** (BE) |
| 0x54 | — | data fork starts |

Detect: name-len byte (0x00) in 1..63 **and** magic 0x0100 at 0x52 **and**
`file_size == 84 + data_size + tag_size`.

**Why this matters for us:**
- **disk_format byte (0x50) routes the path** — 0/1 → IWM/GCR (existing
  `floppy_track_encoder`), 2/3 → ISM/MFM (new) — and gives capacity directly,
  far more robust than guessing from total download length.
- tag_size=0 for MFM ⇒ a 1.44 MB DC42 image = header(84) + 1,474,560 data, clean.
- Data fork = logical sectors in order = exactly the track generator's input.

**Hardware capture during `ioctl_download`** (word index = byte/2, little-endian
read so `ioctl_data[7:0]` is the even/lower byte): name-len at **word 0** low
byte; **disk_format at word 40 low byte (byte 0x50)**; magic at **word 41**
(`==0x0001` after LE read of BE 0x0100). Capture disk_format provisionally at
word 40, commit only if the magic validates at word 41.

DC42 checksum (informational; the OS doesn't verify on read, so HW needn't):
per 16-bit BE word `sum = (sum + word).rotate_right(1)` in u32.

rusty-backup's `encode_dc42(name, data)` can mint a test image from a raw
1.44 MB sector dump for HW validation (`disk_format=3, format_byte=0x22,
tag_size=0`).
