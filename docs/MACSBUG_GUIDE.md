# MacsBug Guide for Macintosh LC Hardware Verification

This guide walks through using MacsBug on a real Macintosh LC to dump hardware
register values and verify the memory map against our MiSTer core implementation.

## Installing MacsBug

1. Download **MacsBug 6.6.3** (the final version). It's available from:
   - Macintosh Garden (search "MacsBug")
   - Apple's legacy developer tools archives
2. Copy the `MacsBug` file into your **System Folder** (not into Extensions, just the
   top level of the System Folder). On System 7, it auto-routes to the right place.
3. Restart the Mac. MacsBug loads silently at boot.
4. To verify it's loaded: press **Command-Power** (the power key on ADB keyboards,
   usually top-right). You should drop into a text-mode debugger prompt: a `>` cursor
   on a dark screen.

If you don't have a Command-Power key, you can also use the **programmer's switch**
(the plastic button on the left side of the LC case). The rear button is Reset, the
front button is Interrupt (NMI). Press the front/interrupt button to enter MacsBug.

## Essential MacsBug Commands

| Command | Description |
|---------|-------------|
| `dm <addr>` | Display memory at address (hex). Shows 128 bytes. |
| `dm <addr> <count>` | Display `count` bytes starting at address. |
| `db <addr>` | Display memory as bytes (8-bit view). |
| `dw <addr>` | Display memory as words (16-bit view). |
| `dl <addr>` | Display memory as longs (32-bit view). |
| `sm <addr> <value>` | Set memory (write byte/word/long to address). |
| `g` | Go (resume execution, exit debugger). |
| `rb` | Reboot the Mac. |
| `il <addr>` | Disassemble instructions at address. |
| `brk <addr>` | Set breakpoint at address. |
| `td` | Total display (show CPU registers). |
| `dm SP` | Display stack contents. |

**Important notes:**
- All addresses and values are in **hexadecimal** (no `$` or `0x` prefix needed in MacsBug).
- The LC boots in **24-bit mode** by default. Addresses wrap at $FFFFFF.
- Reading I/O registers can have **side effects** (some clear on read). Be careful
  with repeated reads of interrupt flag registers.
- The VIA is on the **upper byte** of the data bus. Use byte-sized reads at even addresses.

## Addressing Modes: 24-bit vs 32-bit

Your TattleTech report shows the LC is booted in 24-bit mode. In 24-bit mode:
- I/O space at `$F0xxxx` is accessible directly
- In 32-bit mode, the full address would be `$50F0xxxx`

All addresses below use **24-bit mode** (which is your default).

---

## Device-by-Device Verification

### 1. VIA1 ($F00000 - $F01FFF)

The VIA uses a 512-byte stride with registers selected by address bits A12-A9.
Only the **upper byte** (even addresses) contains valid data.

```
dm F00000 2       ; Reg 0:  ORB   - Output Register B (data direction dependent)
dm F00200 2       ; Reg 1:  ORA   - Output Register A (with handshake)
dm F00400 2       ; Reg 2:  DDRB  - Data Direction Register B
dm F00600 2       ; Reg 3:  DDRA  - Data Direction Register A
dm F00800 2       ; Reg 4:  T1C-L - Timer 1 Counter Low
dm F00A00 2       ; Reg 5:  T1C-H - Timer 1 Counter High
dm F00C00 2       ; Reg 6:  T1L-L - Timer 1 Latch Low
dm F00E00 2       ; Reg 7:  T1L-H - Timer 1 Latch High
dm F01000 2       ; Reg 8:  T2C-L - Timer 2 Counter Low
dm F01200 2       ; Reg 9:  T2C-H - Timer 2 Counter High
dm F01400 2       ; Reg 10: SR    - Shift Register
dm F01600 2       ; Reg 11: ACR   - Auxiliary Control Register
dm F01800 2       ; Reg 12: PCR   - Peripheral Control Register
dm F01A00 2       ; Reg 13: IFR   - Interrupt Flag Register (CAUTION: bits clear on read)
dm F01C00 2       ; Reg 14: IER   - Interrupt Enable Register
dm F01E00 2       ; Reg 15: ORA   - Output Register A (no handshake)
```

**What to record:** DDRB, DDRA, ACR, PCR, IER values. These tell us the VIA configuration.

### 2. SCC - Serial Communication Controller ($F04000 - $F05FFF)

The SCC has separate read and write addresses. Register is selected by A1-A0.

**Read registers:**
```
dm F04000 2       ; Channel B Control (RR0 - status)
dm F04002 2       ; Channel A Control (RR0 - status)
dm F04004 2       ; Channel B Data
dm F04006 2       ; Channel A Data
```

**Note:** To read other RR registers, you must first write the register number to
the control port (WR0 pointer). This is tricky from MacsBug. Just reading RR0
(the default) is sufficient for verification.

**What to record:** RR0 values for both channels. Tells us SCC presence and status.

### 3. SCSI - NCR5380 ($F10000 - $F11FFF)

Registers are at 8-byte stride: `(offset >> 3) & 0xF`

```
dm F10000 2       ; Reg 0: Current SCSI Data (read) / Output Data (write)
dm F10008 2       ; Reg 1: Initiator Command
dm F10010 2       ; Reg 2: Mode
dm F10018 2       ; Reg 3: Target Command
dm F10020 2       ; Reg 4: Current SCSI Bus Status (read)
dm F10028 2       ; Reg 5: Bus and Status (read) / Start DMA Send (write)
dm F10030 2       ; Reg 6: Input Data (read) / Start DMA Target Receive (write)
dm F10038 2       ; Reg 7: Reset Parity/Interrupts (read) / Start DMA Initiator Receive (write)
```

**SCSI DRQ (pseudo-DMA) windows:**
```
dm F06000 2       ; SCSI DRQ window 1
dm F12000 2       ; SCSI DRQ window 2
```

**What to record:** Registers 1, 2, 4, 5. Tells us SCSI controller state.

### 4. ASC - Apple Sound Chip ($F14000 - $F15FFF)

```
dm F14000 20      ; First 32 bytes - includes FIFO area
dm F14800 2       ; Version register (should read $E8 for ASC in LC)
dm F14801 2       ; Mode register
dm F14802 2       ; Control register
dm F14803 2       ; FIFO status
dm F14804 2       ; FIFO IRQ status
dm F14805 2       ; Wave control
dm F14806 2       ; Volume
```

**Key verification:** The version register at offset $800 should return **$E8**.
This confirms it's an ASC (vs $00 for no ASC, or other values for EASC).

**What to record:** Version byte and mode/control register values.

### 5. IWM/SWIM ($F16000 - $F17FFF)

Registers at 256-byte stride: `(offset >> 8) & 0xF`

```
dm F16000 2       ; Reg 0:  CA0 state
dm F16100 2       ; Reg 1:  CA0 state
dm F16200 2       ; Reg 2:  CA1 state
dm F16300 2       ; Reg 3:  CA1 state
dm F16400 2       ; Reg 4:  CA2 state
dm F16500 2       ; Reg 5:  CA2 state
dm F16600 2       ; Reg 6:  LSTRB state
dm F16700 2       ; Reg 7:  LSTRB state
dm F16800 2       ; Reg 8:  ENABLE
dm F16900 2       ; Reg 9:  ENABLE
dm F16A00 2       ; Reg 10: SELECT (drive select)
dm F16B00 2       ; Reg 11: SELECT
dm F16C00 2       ; Reg 12: Q6
dm F16D00 2       ; Reg 13: Q6
dm F16E00 2       ; Reg 14: Q7
dm F16F00 2       ; Reg 15: Q7
```

**Note:** IWM registers are stateful. Even-offset reads return status, odd offsets
toggle states. Be careful - just reading these changes the IWM state machine.
Safest approach is to just read the status register:

```
dm F16E00 2       ; Q6=1, Q7=0: Read status register (safe)
```

**What to record:** Status register value.

### 6. Ariel RAMDAC ($F24000 - $F25FFF)

```
dm F24000 2       ; Palette address (write: set CLUT index to read/write)
dm F24002 2       ; Palette data (read/write R, G, B sequentially)
dm F24004 2       ; Control register
dm F24006 2       ; Key color register (for chroma key)
```

**To dump the first palette entry:**
```
sm F24000 00      ; Set palette address to 0
dm F24002 2       ; Read Red component
dm F24002 2       ; Read Green component (auto-increments)
dm F24002 2       ; Read Blue component (auto-increments)
```

**What to record:** Control register value, and a few palette entries.

### 7. PseudoVIA / RBV ($F26000 - $F27FFF)

This is the most important one to verify thoroughly. It has two access modes.

#### Native Mode Registers (offset $000-$0FF):

```
dm F26000 2       ; Reg $00: Port B output
dm F26001 2       ; Reg $01: RAM Config (read-only)
dm F26002 2       ; Reg $02: Slot/VBlank interrupt status (active low)
dm F26003 2       ; Reg $03: IFR (Interrupt Flag Register)
dm F26010 2       ; Reg $10: Video config (monitor ID in bits 5:3, bpp in bits 2:0)
dm F26012 2       ; Reg $12: Slot IER (Interrupt Enable Register)
dm F26013 2       ; Reg $13: IER (legacy VIA style)
```

#### VIA-Compatible Mode Registers (offset $100+, register = offset >> 9):

```
dm F26200 2       ; VIA-compat Reg 1:  Port A
dm F27A00 2       ; VIA-compat Reg 13: IFR
dm F27C00 2       ; VIA-compat Reg 14: IER
```

**What to record:** All of the above. Especially:
- **Reg $01 (RAM Config):** Should reflect your 10MB RAM. Our core returns $07 for 4MB.
  This may be different on real hardware with 10MB.
- **Reg $02 (Slot Status):** Active-low interrupt status. Bit 6 = VBlank, Bit 5 = Slot,
  Bit 4 = ASC.
- **Reg $10 (Video Config):** Bits 5:3 = monitor ID, Bits 2:0 = video bpp mode.
  Record this to verify monitor detection.
- **Reg $12, $13 (IER values):** What interrupts the ROM has enabled.

### 8. VRAM ($F40000 - $FBFFFF)

```
dm F40000 80      ; First 128 bytes of VRAM
dm F40000 200     ; First 512 bytes (one scanline at 1bpp or half at 8bpp)
```

**What to record:** Just confirm VRAM is readable and contains pixel data.

### 9. ROM ($A00000 - $A7FFFF)

```
dm A00000 40      ; ROM header (first 64 bytes)
dl A00000         ; First long - should be reset vector or checksum
```

**What to record:** First 16 bytes of ROM for comparison.

### 10. RAM Boundaries

```
dm 000000 40      ; Start of RAM
dm 9FFFC0 40      ; End of 10MB RAM region (if accessible)
dm 3FFFC0 40      ; End of 4MB boundary
dm 7FFFC0 40      ; End of 8MB boundary
```

**What to record:** Which ranges are readable vs bus error.

---

## Quick Verification Script

Enter MacsBug (Command-Power or Interrupt switch), then run these commands
in sequence. Write down or photograph the screen after each one:

```
; === Identity ===
dm A00000 20

; === PseudoVIA (most critical) ===
dm F26000 4
dm F26010 2
dm F26012 2
dm F26013 2

; === VIA1 ===
dm F00400 2
dm F00600 2
dm F01600 2
dm F01800 2
dm F01C00 2

; === ASC Version ===
dm F14800 2

; === SCSI Status ===
dm F10020 2
dm F10028 2

; === SCC Status ===
dm F04000 2
dm F04002 2

; === Resume ===
g
```

## Tips

- **Take photos** of each screen. MacsBug shows 24 lines at a time.
- **Press Space** to scroll if output is longer than one screen.
- **Type `g`** and press Return to resume normal Mac operation at any time.
- **Don't panic** if the screen goes dark - that's normal for MacsBug's text mode.
- If the Mac crashes after returning from MacsBug, that's OK - the register reads
  may have changed hardware state. Just restart and try fewer reads at a time.
- **Bus errors**: If you read an unmapped address, MacsBug will show a bus error.
  This is useful! It tells us that address range is not decoded on real hardware.

## Recording Template

Use this template to record your findings:

```
Date: ___________

PseudoVIA Reg $00 (Port B):    ____
PseudoVIA Reg $01 (RAM Cfg):   ____
PseudoVIA Reg $02 (Slot Stat): ____
PseudoVIA Reg $03 (IFR):       ____
PseudoVIA Reg $10 (Video Cfg): ____
PseudoVIA Reg $12 (Slot IER):  ____
PseudoVIA Reg $13 (IER):       ____

VIA1 Reg 2 (DDRB):  ____
VIA1 Reg 3 (DDRA):  ____
VIA1 Reg 11 (ACR):  ____
VIA1 Reg 12 (PCR):  ____
VIA1 Reg 14 (IER):  ____

ASC Version ($F14800): ____

SCSI Reg 4 (Bus Status): ____
SCSI Reg 5 (Status):     ____

SCC Ch.B RR0: ____
SCC Ch.A RR0: ____

ROM first 8 bytes: ____ ____ ____ ____
RAM Config value:  ____

Bus errors at: _______________
```
