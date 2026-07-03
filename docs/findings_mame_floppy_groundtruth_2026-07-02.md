# MAME runtime ground truth — floppy drive-ID, GCR (800K) & MFM (1.44MB) reads

*2026-07-02. MAME 0.264 `maclc` in WSL, tap of the SWIM ($F16000-$F17FFF) + VIA/V8
($F00000-$F01FFF) windows while booting **real bootable disks**: `6.0.7 System
Tools.dsk` (DC42 800K GCR, from the rig) and `OS-6.0.8 disk 1 of 2.dsk` (raw
1,474,560 MFM). Both mount and read in MAME — the 800K trace even captures the OS
**writing** a sector back (Desktop file), the 1.44M trace captures the boot blocks
(`System Startup`) streaming out of the ISM FIFO. This supersedes parts of
`docs/findings_mame_floppy_driveid_2026-06-13.md` (see "Corrections" §10) and
completes the "NEXT SESSION" task from `docs/handoff_mame_floppy_driveid_2026-06-13.md`.*

**Raw artifacts:** `scratch/mame_floppy_0702/` — `decoded_800k_v3.txt`,
`decoded_1440k_v3.txt` (full reconstructions: timelines, sense tables, strobe
logs, stream excerpts), `data_reads_800k.txt.gz` (5.9M IWM data-reg reads, seq/
frame/pc/byte), `data_reads_1440k.txt.gz`, `decode_v2.py` (the exact-semantics
decoder), plus the two disk images. Raw 500-700MB taps kept in WSL
`~/maclc_run/tap_{800k,1440k}.txt.gz`. Repro: §9.

---

## 0. TL;DR — why every disk is "unreadable" on our core

The trace exposes **two fatal RTL bugs that were invisible to source-reading**
plus several protocol mismatches. In order of kill-priority:

1. **Our IWM→ISM switch can never fire** — the ROM performs the 4-write switch
   sequence **with all drives disabled**; our detector only runs when a drive is
   enabled (`rtl/swim.v` puts it in the write-*data* branch). The ROM's SWIM
   self-test at boot therefore fails → the OS runs IWM/GCR-only forever → **a
   1.44M disk gets the GCR "One-/Two-Sided" dialog**. (§3, diff F1)
2. **ISM Phases readback is wrong** (`F5` written must read back `F5`; we return
   `05`) — even with the switch fixed, the ROM's register self-test and the Sony
   driver's per-mount ISM probe both fail on this. (§3, diff F2)
3. **Sense reg 0xF (HD/is_2m) is inverted** — MAME/hardware: **1 = DD disk,
   0 = HD disk** (`mfd75w::is_2m()` true only for SSDD/DSDD). We return
   `mfm_hd` (1=HD). Consequence: OS mounts a 1.44M disk as GCR and an 800K disk
   as MFM — *both* fail. This alone reproduces the exact HW symptom even before
   ISM is involved. (§4, diff F3)
4. **800K GCR data is read in IWM mode, never ISM** — the whole 5.9M-byte read
   session stays in IWM. Our existing IWM/GCR path is the right datapath; the
   ISM-GCR path is NOT needed for 800K. The reference byte stream to match is
   captured (§5). MFM (1.44M) is read **entirely in ISM mode** with the drive
   selected via **ISM Mode bits 7/2:1** — which our RTL ignores (diff F6).

## 1. Capture setup (what ran)

- MAME 0.264 `/usr/games/mame`, rompath `~/maclc_roms` (boot0.rom + Egret ROMs,
  built by `verilator/mame/floppy/setup_roms.sh`), `-ramsize 2M -nothrottle
  -video none`, 30 emulated seconds per disk, `floppy_tap.lua` bus tap.
- Decoder: `scratch/mame_floppy_0702/decode_v2.py`. The old
  `verilator/mame/floppy/decode_{tap,ism}.py` have a **false IWM→ISM trigger**:
  they advance the ISM-switch pattern on *any* `{q7,q6}=11` write, but GCR
  write-data (self-sync groups `FF 3F CF F3 FC`) contains the bit6 pattern
  1,0,1,1, so the first sector *write* flipped the old decoder into fantasy-ISM
  and everything after seq ~747k in the 06-13-style decode is mislabelled.
  MAME's real rule (below) is immune. **Do not reuse the old decoders.**

### MAME semantics implemented by decode_v2.py (all verified in 0.264 source)

- `swim1.cpp iwm_control()`: SWIM offset `n=(addr>>9)&0xF`. `n<8` = phase lines
  (bit `n>>1` of `m_phases` = `n&1`; b0..b3 = ca0,ca1,ca2,LSTRB). `n>=8` =
  control bits: 8/9=ENABLE(0x10), 10/11=EXTSEL(0x20), 12/13=Q6, 14/15=Q7.
- **IWM→ISM counter advances ONLY on accesses to offset 0xF** (`$F17E00`;
  reads act as `data=0x00`), pattern on written bit6 = 1,0,1,1; **any other
  SWIM access resets the counter** (`swim1.cpp:547-570`).
- `(control&0xC0)==0xC0` + odd offset: write goes to the **data** register if
  active (=ENABLE on), else to the **mode** register.
- IWM reads dispatch on `control&0xC0`: `00`=data (active ? data : FF),
  `40`=status = `(m_iwm_status&0x7F) | (sense<<7)` (status bit5=active, bits4:0
  = IWM mode), `80`=write-handshake, `C0`=FF.
- Drive sense register index = `(phases&7) | (head_select<<3)`; **on the LC
  head_select is V8 VIA1 Port-A bit5** (`$F00000` ORA) — `maclc.cpp` does NOT
  connect the SWIM's `hdsel_cb`, so **ISM Mode bit5 does nothing on an LC**
  (`v8.cpp:258 write_hdsel(BIT(data,5))`).
- Write strobes (`mac_floppy::seek_phase_w`, LSTRB **rising**): cmd =
  `{ss,ca2,ca1,ca0}`: 0=DirNext 1=StepOn 2=MotorOn 3=EjectOff 4=DirPrev
  5=StepOff 6=MotorOff 7=EjectOn **9=MFMModeOn C=DskchgClear D=GCRModeOn**.
- ISM regs = `offset&7` (confirmed live: `WR $F16800=F5` / `RD $F17800=F5`,
  n=4 and n=12 both hit Phases). ISM devsel = `mode&0x80 ? (mode>>1)&3 : 0`.

## 2. Boot timeline (both disks identical until the mount decision)

| seq | frame | PC | event |
|---|---|---|---|
| 37046-37049 | F0191 | A4795E-6A | ROM: intDrive, q6L, ENABLE-off, q6H (whd read 80) |
| 37050-37053 | F0191 | A47970-7E | **WR $F17E00 = 57,17,57,57 → ISM** (drives disabled!) |
| 37054-37091 | F0191 | A47984-C6 | **ROM SWIM self-test**: Phases walk `F5,F6,F7,FF,FE…F0` — each written value read back verbatim from reg4 |
| 37092-37484 | F0191 | A479DA-A47B40 | Setup rd/wr (00), ModeClr 38, **16-byte Param RAM test** (read 16, write 00,11,…FF, read back — ×5 passes, ModeClr 38 between each resets param index) |
| 37486 | F0191 | A47BEE | ModeClr **F8** → exits ISM (mode=00) |
| 96540 | F0235 | A009E2 | early NoDiskInPl read, **devsel=0 → pull-up 1** |
| 124152-124171 | F0278 | A6EAB6-E2 | Sony driver ISM **presence check**: switch → (1.44M trace also shows Phases F5 readback here) → ModeClr F8 → back to IWM |
| 124162-124370 | F0278 | A6D4xx/A6D7xx | Sony per-drive probe: devsel INT (NoDrive=0), then **EXT** (all pull-up 1s, incl. NoDrive=1 → no external drive), EjectOn strobes to EXT |
| F0308-F0547 | | A6D460/464 | ~0.5s polls: NoDiskInPl=0 (disk in), DiskChg=0 — always read in PAIRS |
| 555091+ | F0558 | A6D63E+ | **Mount begins**: DiskChg, NoDiskInPl, **read 0xD MFMModeOn (=1)**, strobe **GCRModeOn ($D)**, read Motor, strobe **MotorOn ($2)**, poll **0xE NoReady ×144 until 0** (2 index pulses), seek (DirNext/DirPrev + StepOn ×N, Step-complete poll 0x1), sense **0xF** |
| 800K path | F0563+ | A6D4xx | **stays IWM**, reads GCR stream (5.93M data-reg reads in ~20s emulated); F0662+: **writes a sector back** (whd-handshake paced) |
| 1.44M path | F0623 | A6EB64+ | devsel→none, **switch to ISM again** and stay there: full MFM session (§6) |

## 3. The ROM's SWIM check — what our RTL must survive

The LC ROM decides at boot whether the floppy controller is a SWIM. The check =
ISM switch + Phases readback + Param-RAM test (timeline above). If any step
fails the machine is treated as IWM-only → **no MFM ever, for any disk**.

- The four `57,17,57,57` writes go to **$F17E00** with `control=0xC0` and
  **ENABLE off** (first ENABLE happens 87k accesses later). `0x57` = IWM mode
  bits S=1,M=1,H=1,L=1 + bit6; MAME treats them as mode-register writes AND runs
  the ISM counter (offset==0xF only).
- After the 4th write the ROM immediately does `WR reg4=F5 / RD reg4 → F5`,
  then walks `F6,F7,FF,FE,FD…F0` — the **full 8-bit** value must read back
  (high nibble = phase output-enables, always F in practice).
- Param test relies on **ModeClr resetting the param index to 0**
  (`swim1.cpp ism_write case 6: m_ism_param_idx = 0`).
- The same Phases-readback probe is repeated by the Sony driver at **every ISM
  entry** (F0278 presence check, F0623 MFM session init) — PC `A6EB18/A6EB1C`.

## 4. Drive-ID ground truth (the sense truth tables)

Full tables in `decoded_*_v3.txt`. Summarized, internal drive (mfd75w
SuperDrive), disk in, values observed over the whole boot:

| reg | name | 800K DD disk | 1.44M HD disk | notes |
|---|---|---|---|---|
| 0x0 | Dir | 0/1 | 1 | last-commanded step dir |
| 0x1 | Step | 1 | 1 | step complete (polled ×2636 during seeks) |
| 0x2 | Motor | 0=on | 0 | 1 before MotorOn strobe |
| 0x3 | DiskChg | 0 | 0 | `!m_dskchg` |
| 0x4 | RdData0 | 1 (motor-off) | idx pulse | SuperDrive: motor-off/no-disk → 1, else `!idx` (0.7% low duty) |
| 0x5 | Superdrive | **1** | **1** | |
| 0x6 | DoubleSide | 1 | 1 | |
| 0x7 | NoDrive | **0** | **0** | EXT (absent) drive reads 1 |
| 0x8 | NoDiskInPl | **0** | **0** | 1 with devsel=0 (pull-up) |
| 0x9 | NoWrProtect | 1 | 1 | writable |
| 0xA | NotTrack0 | 0 @trk0 | 0 | |
| 0xB | NoTachPulse | pulses | — | |
| 0xC | RdData1 | **1** | idx | same rule as 0x4 |
| 0xD | MFMModeOn | 1 → **0 after $D strobe** (×318) | 0 → **1 after $9 strobe** (×199) | **the OS verifies the strobe took effect** |
| 0xE | NoReady | 1×144 then **0** | same | ready ~2 index pulses after motor-on |
| 0xF | HD/is_2m | **1** (×4) | **0** (×4) | **1=DD, 0=HD — inverted vs our RTL** |

Identify nibble f..c: **DD disk → `1011`, HD disk → `0011`** ("x011 SuperDrive,
x = is_2m"). The OS then: x=1 → GCR/IWM mount; x=0 → MFM/ISM mount.

**All sense reads are plain IWM status reads** (`control&0xC0==0x40`, sense in
bit7; status low bits = `{active,mode[4:0]}`: observed 37/B7 enabled, 17/97
idle). Head-select for regs 8-F = **V8 PA5** writes (PC A6D432/A6D43A toggles
around each high-bank read). Reads always come in pairs (driver debounce).

## 5. 800K GCR — IWM-mode read/write reference

**The OS never uses ISM for GCR data.** After GCRModeOn + MotorOn + ready + seek
it reads the IWM data register (`control&0xC0==0x00`) in a tight poll loop.

- **Poll cadence:** ~3-5 polls per byte; polls between bytes return **00**
  (shift in progress); a completed byte appears with MSB set and is **consumed
  once** (register auto-clears ~2µs after a valid MSB-set read — matches our
  `readLatchClearTimer`). Byte period ≈16µs (our 128-clk timer is right).
- **Address field** (track 0, side 0, sector 2 shown; from `data_reads_800k`):
  `FF×24+ | D5 AA 96 | 96 9A 96 D9 D6 | DE AA` — 6&2 nibbles: track=96(0),
  sector=9A(2), side=96(0), **format=D9 (=0x22, double-sided 800K)**, checksum
  D6 (= 0^2^0^0x22 encoded). Any deviation here (format byte, checksum seed)
  makes the Sony driver reject the sector → "unreadable".
- **Data field:** `FF×4-5 | (D5 AA) AD | <sector nibble> | 699 6&2 nibbles |
  4 checksum nibbles | DE AA` (the CPU's polls missed the D5 AA of the data
  prologue in the capture — it syncs and catches from AD; our encoder must
  still emit the full `D5 AA AD`).
- **Write path** (Desktop-file write-back, F0662+, PC A6E50C/A6E510): CPU polls
  the **write-handshake** register (RD `$F17800`, `control==0x80`) → `7F` =
  busy ×~11, `FF` = ready → writes next byte to `$F17A00` (data reg, active).
  Stream: `FF 3F CF F3 FC FF | D5 AA AD | 9A | <6&2 data> …` — note the sync
  groups `3F CF F3 FC` (bit6 = 0,1,1,1 — with the leading FF this is the
  1,0,1,1 sequence that must NOT trigger an ISM switch; MAME is immune because
  these writes are to offset 0xD, not 0xF).

## 6. 1.44MB MFM — the complete ISM protocol (PCs A6EBxx-A6EFxx)

Session init (once per mount attempt, F0623):

```
devsel -> none (IWM ENABLE off)
WR $F17E00: 57,17,57,57            ; -> ISM
ModeClr 38 ; WR Phases F5, RD Phases -> F5   ; presence re-check
ISM Setup = 20                      ; bit5=1 IBM, bit2=0 MFM read, 3.5", fclk
ModeClr 04 ; ModeSet 82             ; mode=C2: MOTOR(b7) + drive-select 01=INT
                                    ;   (ISM devsel — NOT the IWM enables!)
strobe MFMModeOn ($9)               ; via ISM Phases write, LSTRB rising,
                                    ;   V8-PA5=1 + ca210=001 (PC A6ED2C)
   (verify: sense 0xD now reads 1 through the ISM handshake bit3)
```

Per-sector read loop (PC A6EE46-A6EF9E, one iteration ≈ one ID field):

```
WR Phases = F4          ; park phases on RdData0 (ca2=1) — hi nibble F = OE
RD Error (reg2)         ; clear error
ModeClr 18              ; ACTION,WRITE off
ModeSet 01 ; ModeClr 01 ; pulse FIFO-clear
RD Error
ModeSet 08              ; ACTION on, WRITE off -> READ STARTS (edge!)
poll Handshake (reg7):  ; byte=08 while hunting (bit3=sense/index, FIFO empty)
                        ; ~2000 polls/sector-time (b7=0 between fields!)
when b7 (data avail) + b0 (mark): pop reg1 (Mark) x10:
    A1 A1 A1 FE  C H R N(=02)  CRChi CRClo
if not target sector: ModeClr 18, loop
if target: keep popping through the data field:
    A1 A1 A1 FB  <512 data bytes>  CRChi CRClo
```

Captured ID sweep (`decoded_1440k_v3` / pop dump): `…FE 00 00 07 02 60 C9`,
`FE 00 00 08 02 70 F7`, … `FE 00 00 12 02 9C 4F`, `FE 00 00 01 02 CA 6F` ← the
CRC for `A1 A1 A1 FE 00 00 01 02` = **CA 6F, byte-identical to the worked
example in docs/swim_ism_read_reference.md §F** (CRC spec validated end-to-end).
Data field pops show the boot blocks (`…"System Startup"…`). All pops use the
**Mark register (reg1)** — including data bytes. Head switching mid-session =
**V8 PA5 writes** (A6ECE8/A6ECF0); ISM Mode bit5 stays 0 the whole session.
Seeks are performed while in ISM (StepOn strobes via Phases writes + Step
polls through Handshake bit3).

## 7. THE DIFF LIST — MAME vs our RTL, item by item

Ordered by severity. "Step" references: T-numbers = timeline §2, quotes =
capture evidence.

**F1. IWM→ISM switch detector — never fires / false-fires.**
- MAME: counter on **offset-0xF accesses only**, regardless of drive enable
  (`swim1.cpp:547-570`); reads participate (data=0). Mode-vs-data write =
  `active` (ENABLE), not address.
- Ours: `rtl/swim.v:464-510` — detector nested in `if (diskEnableExt |
  diskEnableInt)` inside the `{q7,q6}=11` write case; the disabled branch
  resets the counter.
- Step: T-37050 — the ROM's switch happens **with drives disabled** → our
  counter never leaves 0 → no ISM, self-test fails, no MFM ever. Converse:
  during the F0662 sector write (drive enabled) the data bytes `FF 3F CF F3`
  would advance our detector to a **spurious ISM switch mid-write**.
- Fix: detect on any access with `cpuAddrRegHi==4'hF` (write data bit6 pattern
  1,0,1,1; a read = data 0); reset on any other SWIM access; drop the enable
  qualification. Keep mode-reg write = `{q7,q6}=11 && !enabled` (that part is
  right).

**F2. ISM Phases (reg4) readback must return all 8 written bits.**
- MAME: `m_phases = data` / `return m_phases` (`swim1.cpp:294-300,214`).
- Ours: `rtl/swim.v:325` returns `{4'b0000, lstrb, ca2, ca1, ca0}`; write
  `:431-436` keeps only the low nibble.
- Step: T-37054 (`F5`→`F5` ×20+), repeated at every Sony ISM entry (A6EB18).
- Fix: store an 8-bit `ism_phases` (low nibble drives ca0/ca1/ca2/lstrb as
  today; high nibble latched as written), return it on reg4 reads.

**F3. Sense reg 0xF (HD/is_2m) inverted.**
- MAME: `mfd75w::is_2m()` = true for SSDD/**DSDD** only (`floppy.cpp:3088`);
  captured 800K→1, 1.44M→**0**, no-disk→0 (pull-up aside).
- Ours: `rtl/floppy.v:124` `driveRegsAsRead[15] = mfm_hd`.
- Step: §4 table. Consequence table: 800K reads 0011→OS goes MFM (fails);
  1.44M reads 1011→OS goes GCR (the "One-/Two-Sided" dialog seen on HW).
- Fix: `[15] = ~CSTIN && !mfm_hd` — i.e. 1 only when a **DD** disk is present
  (insertDisk-qualified), 0 for HD or empty.

**F4. Sense reg 0xD (MFMModeOn) must track the $9/$D strobes.**
- MAME: `m_mfm` reset to `has_mfm`(=1); seek cmd 9 sets, cmd D clears
  (SuperDrive only).
- Ours: `rtl/floppy.v:128` constant `1'b1`.
- Step: 800K seq 555117 (reads 1) → strobe $D (555126) → reads **0** ×318;
  1.44M strobe $9 (641095) → reads **1** ×199. The OS checks the readback; a
  constant would derail both mode paths.
- Fix: new `m_mfm` reg in floppy.v (reset 1), driven by the strobe decode (F5).

**F5. Write-strobe decode is 3-bit; misses $9/$C/$D (SEL=1 commands).**
- MAME: cmd = `{ss,ca2,ca1,ca0}` at LSTRB **rising** (`floppy.cpp:2921+`).
- Ours: `rtl/floppy.v:276` `driveWriteAddr={ca1,ca0,SEL}` + ca2-as-value, acts
  on LSTRB **falling** (`lstrbEdge`, :269). Dir/Step/Motor/Eject work out
  equivalent for SEL=0; $9/$D (and $C DskchgClear) are unreachable.
- Fix: decode 4-bit `{SEL,ca2,ca1,ca0}` on the strobe edge; add 9→`m_mfm=1`,
  D→`m_mfm=0`, C→clear disk-changed. (Rising-vs-falling: values are stable
  across the pulse; falling is acceptable, note only.)
Amendment to both: **the strobes arrive via ISM Phases writes too** (reg4 write
with bit3) — our reg4 write path already updates lstrb/ca* so the shared edge
logic in floppy.v covers it once F6 enables the drive.

**F6. ISM-mode drive select/enable ignored → whole MFM session talks to a
disabled drive.**
- MAME: ISM devsel = `mode&0x80 ? (mode>>1)&3 : 0` (`swim1.cpp:560` +
  ism mode writes); captured: IWM ENABLE goes OFF (T-640964) *before* the MFM
  session; drive selected by `ModeSet 82` → mode C2.
- Ours: floppy `_enable` derives only from IWM soft-switch enables
  (`rtl/swim.v:158,193`).
- Step: §6 init. Without this, in ISM: sense=pull-up-1 (readData=FF), steps
  ignored, motor state wrong, index/tach dead.
- Fix: `enableInt_eff = ism_mode ? (ism_mode_reg[7] && ism_mode_reg[2:1]==2'b01)
  : (diskEnableInt & driveSel)`, analogous for ext (2'b10).

**F7. ISM Handshake byte layout + FIFO gating.**
- MAME (`swim1.cpp:224-250`): b0 = **newest** FIFO entry has M_MARK; b1 =
  !(newest & M_CRC0); b2 = rddata (not sense); b3 = sense; b5 = error; read
  mode: b7 = pos>=1, b6 = pos==2. **b7=0 between fields** — the driver's hunt
  loop depends on it (captured: ~2000 polls of `08` per sector gap, then pops
  only when data lands).
- Ours: `rtl/swim.v:333-338` — in `ism_read_active` forces b7=b6=1 constantly,
  puts sense on b2 **and** b3, b0 from the *current* generator byte.
- Step: §6 poll loop (byte `08` while hunting — ours would return `C8`+ and
  the driver would pop gap bytes at CPU speed with no mark framing).
- Fix: feed the MFM generator through the real 2-entry FIFO at the 16µs byte
  rate (`fifo_push` when pos<2 && ACTION-read), handshake bits from FIFO state;
  b2=0 (or rddata), sense only on b3.

**F8. ISM ACTION edge must reset the read machinery; ModeClr resets param_idx.**
- MAME: read-start on `(mode&0x18)==0x08` **rising** (`swim1.cpp:364`) resets
  shifter/CRC/mark hunt; `ism_write case 6` always does `m_ism_param_idx=0`.
  The driver pulses `ModeSet 01 / ModeClr 01` (FIFO clear) before each arm.
- Ours: `ism_read_active` is level-only (`rtl/swim.v:225`); no param_idx reset
  on ModeClr (`:439`); FIFO-clear on bit0 present but our generator
  (`mfm_track_encoder`) free-runs across arms.
- Step: §6 loop re-arms 18×/rev; without the edge-reset the generator state
  (mid-sector) leaks across attempts.

**F9. IWM status bit5.**
- MAME: bit5 of status = ACTIVE (any selected drive); captured 37/B7 vs 17/97.
- Ours: `rtl/swim.v:347` uses `diskEnableExt & diskEnableInt` (AND — both
  drives!). Fix: OR (or the active latch).

**F10. IWM write-handshake (whd) constant-ready.**
- MAME: b7 pulses ready per byte (captured `7F`×11 → `FF` → write), low 6 bits
  read 1s, b6=no-underrun set on write-mode entry.
- Ours: `rtl/swim.v:349` constant `C0` (never throttles; low bits 0).
- Consequence: host-paced GCR writes overrun/underrun on HW. Low priority
  (writes are read-only-adjacent today) but this is the write-corruption
  reference.

**F11. `effSEL` (06-13 "Fix C") is wrong for the LC — revert to VIA PA5 in all
modes.**
- MAME: `maclc.cpp` never wires the SWIM `hdsel_cb`; drive `ss` comes only from
  **V8 via1 PA5** (`v8.cpp:258`). Captured: ISM mode bit5 = 0 through the
  entire MFM session; PA5 toggles do the head selection (and address the
  high sense bank during ID checks through the ISM handshake).
- Ours: `rtl/swim.v:144` `effSEL = ism_mode ? ism_mode_reg[5] : SEL` → in ISM
  the SEL is stuck 0 → high sense regs (incl. 0xD verify) unreachable, side 1
  unreadable.
- Fix: `effSEL = SEL`. (Keep a comment: on machines that wire hdsel_cb —
  Quadras — mode bit5 matters; not the LC.)

**F12. Sense reg 0x4 (RdData0) motor-off value.**
- MAME: SuperDrive reg 4 and C read 1 when no-disk or motor-off, else `!idx`.
- Ours: `[8] RDDATA0 = 0` constant (`rtl/floppy.v:134`), reg C already fixed
  to 1. Captured 0x4 → 1 (×2, motor off). Make 4 match C (and ideally both
  reflect `!idx` with motor on — the MFM hunt uses it as index sense).

**Confirmed-correct (no change):** ISM reg decode `n&7`
(`rtl/swim.v:258`, 06-13 Fix B) — proven live by the `$F16800/$F17800`
aliasing; reg 0xC=1 (06-13 Fix A half); reg 0x5 Superdrive=1; 16-byte param
RAM with `&15` wrap; IWM read-latch clear timing (≈14 clks); 128-clk GCR byte
timer; GCR-in-IWM architecture (no ISM-GCR path needed for the LC's OS).

## 8. What this means for bug #2 (800K GCR garbage) — next probe

The IWM datapath *architecture* matches MAME; the remaining suspects are the
**encoder byte stream** vs §5's reference (format byte `$22`, 6&2 checksum,
sync-FF runs, epilogues) and the fixed-vs-zoned rotation (MAME feeds constant
2µs cells; we do too — OK). Actionable: run the Verilator sim (on a permitted
box) with the same 800K image, capture `dskReadDataEnc` for track 0, and diff
against `data_reads_800k.txt.gz` non-zero bytes from seq 564693 (first
address mark `D5 AA 96 96 9A 96 D9 D6 DE AA`). Note the fixed drive-ID (F3)
may cure the 800K symptom by itself — with reg 0xF=1 the OS will finally take
the GCR path it never took before.

## 9. Reproduce

```bash
# stage (once): bash verilator/mame/floppy/setup_roms.sh   (in WSL)
# tools with CRLF stripped live in WSL ~/maclc_tools (copy of verilator/mame/floppy/*)
wsl -e bash -c 'cd ~/maclc_tools && MAX_FRAME=100000 bash run_floppy.sh \
  ~/maclc_run/sys607_tools_800k.dsk 30 ~/maclc_run/tap_800k.txt'
wsl -e bash -c 'python3 <repo>/scratch/mame_floppy_0702/decode_v2.py \
  ~/maclc_run/tap_800k.txt --max-data 600 --dump-data data_reads.txt > decoded.txt'
```
Disk images: `scratch/mame_floppy_0702/{sys607_tools_800k,os608_disk1_1440k}.dsk`
(from the rig; `Install Disk 1 RAW.dsk` on the rig is still 1,301,504 B = not a
valid 1.44M image — don't use it). MAME source refs pulled by
`verilator/mame/floppy/get_mame_src.sh` → `/tmp/{swim1,floppy}.cpp` (+
`maclc.cpp`, `v8.cpp` fetched the same way this session).

## 10. Corrections to earlier docs

- `findings_mame_floppy_driveid_2026-06-13.md`:
  - "reg F = mfm_hd (1 for HD)" — **wrong**, runtime shows 1=DD/0=HD (F3).
  - Fix C (`effSEL` from ISM mode bit5) — **wrong for the LC** (F11); the LC
    head-select is V8 PA5 in every mode.
  - "SWIM1 drives sense on both b2 and b3" (also in
    `swim_ism_read_reference.md` §C) — 0.264 source + capture: **b3 only**,
    b2 is rddata.
  - The 06-13 session's ISM interpretation of the drive-ID probe was based on
    the false-triggering decoder; the actual drive-ID probe runs in **IWM**
    status reads (§4), and 800K data I/O never leaves IWM.
- `handoff_mame_floppy_driveid_2026-06-13.md` "NEXT SESSION" items: done here
  (bootable-disk trace, drive-ID phase→register table, GCR read cadence, MFM
  ISM protocol). The "is the ISM FIFO/Setup read path needed?" question:
  **yes for MFM only**, with the exact protocol in §6.
