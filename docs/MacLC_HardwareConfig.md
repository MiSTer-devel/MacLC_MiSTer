# Macintosh LC (original, "Pinball") — Hardware Configuration & MAME Implementation

A consolidated reference covering the original Macintosh LC's data-bus layout, CPU
cache, hardware/MAME differences, support-chip wiring, PDS expansion cards, and the
interrupt/VIA register map.

All MAME references are to the `maclc` machine as implemented in
`src/mame/apple/maclc.cpp` and `src/mame/apple/v8.cpp`, plus the NuBus/PDS card
infrastructure under `src/devices/bus/nubus/` and the shared
`src/devices/machine/pseudovia.cpp`. Line numbers reflect the tree at the time of
writing.

---

## Table of Contents

1. [Data-bus specifications (MAME-configured)](#1-data-bus-specifications-mame-configured)
2. [Data-bus specifications (actual hardware) and how they differ](#2-data-bus-specifications-actual-hardware)
3. [CPU cache](#3-cpu-cache)
4. [Hardware layout & MAME-implementation notes](#4-hardware-layout--mame-implementation-notes)
5. [PDS expansion cards](#5-pds-expansion-cards)
6. [How the LC PDS slot is wired](#6-how-the-lc-pds-slot-is-wired)
7. [PDS card connection deep-dives](#7-pds-card-connection-deep-dives)
8. [Interrupt map (68k levels)](#8-interrupt-map-68k-levels)
9. [VIA1 register & pin map](#9-via1-register--pin-map)
10. [PseudoVIA ("VIA2") register & IRQ map](#10-pseudovia-via2-register--irq-map)

---

## 1. Data-bus specifications (MAME-configured)

The LC is a **68020 with a full 32-bit data bus**, and the **V8 gate array** is the
gatekeeper for almost all of memory and I/O. The V8 decodes the bus and presents the
various support chips at *mixed* widths — some 32-bit, some 16-bit, some byte-wide —
with the narrow devices wrapped so they sit on the right byte lanes of the 020's
32-bit bus.

This table is how the **emulator** wires the buses (a functional model — the handler
widths used in code):

| Component | MAME handler width | Address range | Source |
|---|---|---|---|
| CPU — MC68020HMMU | **32-bit** | whole `AS_PROGRAM` | `maclc.cpp:342`, `m68020.cpp:91` (`32,32`) |
| ROM | **32-bit** (`ROM_REGION32_BE`) | `0x000000–0x0FFFFF` | `maclc.cpp:594` |
| RAM (DRAM) | **32-bit** (`u32*`) | `0x000000` / `0x800000` | `maclc.cpp:163`, `v8.cpp:374` |
| VRAM | **32-bit** (`u32[]`) | `0x540000–0x5BFFFF` | `v8.cpp:485-493` |
| V8 ASIC | mixed (sub-map) | `0xA00000–0xFFFFFF` | `maclc.cpp:184` (`.m()`) |
| VIA1 (65C22) | **16-bit** wrapper / 8-bit core | `0x500000–0x501FFF` | `v8.cpp:434-460` |
| PseudoVIA | **8-bit** | `0x526000–0x527FFF` | `v8.cpp:94` |
| ASC (sound) | **8-bit** | `0x514000–0x515FFF` | `v8.cpp:92` |
| Ariel (CLUT/DAC) | **8-bit** | `0x524000–0x525FFF` | `v8.cpp:93` |
| SCC (85C30 serial) | **16-bit** wrapper / 8-bit core | `0xF04000–0xF05FFF` | `maclc.cpp:114-122` |
| SCSI (NCR5380) PIO | **16-bit** (high byte) | `0xF10000–0xF11FFF` | `maclc.cpp:206-220` |
| SCSI pseudo-DMA | **32-bit** (mem_mask) | `0xF06000`, `0xF12000` | `maclc.cpp:222-266` |
| SWIM1 (floppy) | **16-bit** (high byte) | `0xF16000–0xF17FFF` | `maclc.cpp:268-287` |

### Per-component detail (with source)

**CPU — Motorola MC68020 (HMMU variant), 32-bit data bus**
`maclc.cpp:342` `M68020HMMU(config, m_maincpu, C15M);` — clock `C15M` = 15.6672 MHz.
The device constructor (`src/devices/cpu/m68000/m68020.cpp:90-91`) passes `32,32` =
32-bit address and 32-bit data bus. Everything else hangs off this 32-bit
`AS_PROGRAM` space (`maclc.cpp:343`).

**V8 memory controller — the bus decoder**
`maclc.cpp:184` routes `0xA00000–0xFFFFFF` into the V8 with
`.m(m_v8, FUNC(v8_device::map))`, so the V8's internal map (`v8.cpp:87-97`) lives
directly on the CPU's 32-bit bus. Note `map.global_mask(0x80ffffff)`
(`maclc.cpp:181`) — the V8 only decodes bit 31 + bits 23-0.

**ROM / RAM / VRAM — all 32-bit.** ROM is `ROM_REGION32_BE` (`maclc.cpp:594`)
installed from a `u32*`; RAM is handed to the V8 as `m_ram->pointer<u32>()`
(`maclc.cpp:163`) and installed with `install_ram` (`v8.cpp:374,392,415`); VRAM is a
`u32[]` with `vram_r`/`vram_w` (`v8.cpp:485-493`).

**VIA1 (65C22) — 8-bit chip on a 16-bit window, byte-mirrored.** `v8.cpp:91` maps it
16-bit; `v8.cpp:434-447` reads the 8-bit VIA and returns `(data & 0xff) | (data << 8)`
— it duplicates the byte across both lanes so a read on either half of the word gets
the register. Writes (`v8.cpp:449-460`) accept either byte lane via
`ACCESSING_BITS_0_7` / `ACCESSING_BITS_8_15`. The VIA itself runs at
`15.6672 MHz / 20` ≈ 783.36 kHz (`v8.cpp:111`), hence the `via_sync()` cycle-stealing.

**PseudoVIA — native 8-bit.** `v8.cpp:94`. This is the V8's built-in VIA2-equivalent
for slot/video IRQs (note `screen_vblank → pseudovia slot_irq_w<0x40>`, `v8.cpp:108`).

**ASC (sound) and Ariel (RAMDAC) — native 8-bit.** `v8.cpp:92-93`.

**SCC (Z85C30 serial) — 8-bit core on a 16-bit window.** `maclc.cpp:186` + wrapper at
`maclc.cpp:114-122`: read returns `(result<<8)|result` (mirrored), write takes
`data>>8` (high byte).

**SCSI (NCR53C80)** — two paths:
- Programmed I/O, 16-bit, data on the high byte: `maclc.cpp:206-220`.
- Pseudo-DMA (DRQ), 32-bit, driven by `mem_mask`: `maclc.cpp:222-266` streams 1/2/4
  bytes MSB-first depending on `0xff000000` / `0xffff0000` / `0xffffffff`.

**SWIM1 (floppy) — 8-bit core on a 16-bit window, high byte.** `maclc.cpp:268-287`:
read returns `result << 8`; the access also burns 5 CPU cycles
(`adjust_icount(-5)`).

---

## 2. Data-bus specifications (actual hardware)

The single fact that separates real silicon from MAME's model: per EveryMac, the LC
is *"a 32-bit processor and a 16-bit data path."* The **V8 narrows the entire memory
and I/O system to 16 bits**, and the 68020 uses dynamic bus sizing (DSACK) to split
each 32-bit access into two 16-bit cycles.

| Component | Real data-bus width | Notes |
|---|---|---|
| CPU — MC68020 @ 15.6672 MHz | **32-bit core, 16-bit external path** | 68020 dynamic bus sizing: V8 declares a 16-bit port, so each longword = two 16-bit bus cycles. The defining LC performance compromise. |
| System / memory bus (through V8) | **16-bit** | V8 bridges the 32-bit CPU bus down to a 16-bit system bus for all memory and I/O. |
| RAM — 2 MB onboard + 2× 30-pin SIMM | **16-bit** | 30-pin SIMMs are 8 bits each, so they install **as a matched pair** to form the 16-bit word. 2 MB std, max 10 MB. |
| ROM (512 KB) | **16-bit** | On the same 16-bit V8 bus. |
| VRAM (256 KB std → 512 KB SIMM) | **16-bit** | Dedicated VRAM SIMM slot; V8 fetches video over the 16-bit path. 256 KB → 640×480×4bpp; 512 KB → 640×480×8bpp. |
| V8 ASIC | **32-bit ↔ 16-bit bridge** | Integrates memory controller, video timing/framebuffer, ASC sound, a VIA2-equivalent register block, and glue logic. |
| VIA1 (65C22) | **8-bit** | Byte-wide chip on one byte lane of the 16-bit bus. |
| PseudoVIA (= VIA2-equivalent) | **8-bit** | **Not a discrete chip** — a register block inside the V8. |
| ASC (Apple Sound Chip) | **8-bit** | Integrated into the V8 in the LC (a discrete part on bigger Macs). |
| Ariel (CLUT / video DAC) | **8-bit** | Palette/DAC register interface. |
| SCC (Zilog 85C30 serial) | **8-bit** | Byte lane of the 16-bit bus. |
| SCSI (NCR 5380) | **8-bit** | Byte lane; pseudo-DMA region just streams successive bytes. |
| SWIM (floppy controller) | **8-bit** | Byte lane. |

### Reading the two tables together

The deltas are all explained by one fact — **MAME models the memory side at the
CPU's native 32 bits, while the real LC narrows it to 16 bits in the V8:**

- **CPU:** Same chip, but MAME runs the 020 against a 32-bit memory model and skips
  the real machine's two-cycle-per-longword penalty. MAME instead approximates LC
  slowness with `via_sync()` and explicit `adjust_icount` cycle-stealing on slow
  devices.
- **RAM / ROM / VRAM:** MAME = 32-bit (`u32`); hardware = **16-bit**. This is the
  single biggest difference and the whole reason the real LC felt sluggish.
- **8-bit peripherals (VIA, SCC, SCSI, SWIM, ASC, Ariel, PseudoVIA):** the *chips*
  are genuinely 8-bit in both columns. MAME's "16-bit wrapper" entries aren't a wider
  chip — they're MAME placing that one byte onto a 16-bit access. The `<< 8` in those
  wrappers reflects the real hardware: these byte-wide devices sit on the **upper
  byte lane** of the V8's 16-bit bus. The VIA wrapper *duplicates* the byte across
  both lanes (`(data & 0xff) | (data << 8)`) so a read of either half returns the
  register.

**Sources:** [EveryMac — Macintosh LC specs](https://everymac.com/systems/apple/mac_lc/specs/mac_lc.html),
[Low End Mac — Mac LC](https://lowendmac.com/1990/mac-lc/),
[Wikipedia — Macintosh LC](https://en.wikipedia.org/wiki/Macintosh_LC).

---

## 3. CPU cache

Effectively **256 bytes**, and all of it is on the CPU itself, not on the board.

The LC's cache is just whatever is built into its **Motorola 68020**:

- **256-byte on-chip instruction cache** — direct-mapped, organized as 64 entries ×
  one 32-bit longword each. This is the only cache the LC has.
- **No data cache.** That was added by the 68030 (which got a second 256-byte cache
  for data); the plain 68020 in the LC has instruction cache only.
- **No external / L2 cache on the motherboard.** The original LC has no cache slot and
  no board-level cache RAM.

The headline number people quote for the LC is **256 bytes of instruction cache**,
integral to the 68020.

Extra wrinkle given the 16-bit memory path: that little instruction cache mattered
*more* on the LC than on a comparable 32-bit-bus machine. Any instruction fetch that
misses the cache pays the double-cycle penalty of the V8's 16-bit bus, so code that
fit in the 256-byte cache loop ran noticeably better than code that didn't.

---

## 4. Hardware layout & MAME-implementation notes

### Hardware-layout things specific to the LC

**1. It's an HMMU machine, not a PMMU machine — and it runs in 24-bit mode.**
The CPU is instantiated as `M68020HMMU` (`maclc.cpp:342`), i.e. Apple's *HMMU*
address-translation glue, not the Motorola 68851 PMMU. The HMMU enable is toggled at
runtime — PseudoVIA PB3 drives it (`v8.cpp:349-352` → `write_hmmu_enable` →
`set_hmmu` at `maclc.cpp:155-158`), switching between `M68K_HMMU_DISABLE` and
`M68K_HMMU_ENABLE_LC`. This is why the LC is "32-bit dirty" and boots in 24-bit
addressing. A real PMMU is the wrong mental model for an FPGA port.

**2. The CPU does not start on its own — Egret holds it in reset.**
At `v8.cpp:205` the V8 asserts `INPUT_LINE_HALT` on reset, with the comment *"main cpu
shouldn't start until Egret wakes it up."* The **Egret** microcontroller (`341S0850`,
`maclc.cpp:418-420`) releases it via `egret_reset_w`. Egret↔system comms ride on
**VIA1's shift register** — `CB1`/`CB2` = clock/data (`maclc.cpp:425-426`,
`v8.cpp:424-432`). A boot that hangs before the Welcome screen on these machines is
very often the VIA-shift-register/PMU handshake or the VIA IRQ path. (The Mac II uses
a discrete VIA+RTC+ADB transceiver, not Egret, so the mechanism differs — but the
"CPU waits on a VIA-driven handshake" theme is the same.)

**3. Classic boot-overlay trick.**
On reset the V8 mirrors ROM at `0x000000` (`m_overlay=true`, `v8.cpp:207-217`). The
*first* ROM fetch through `rom_switch_r` flips the overlay off and remaps RAM to zero
(`v8.cpp:225-235`). So the address map differs for the first few instructions vs
forever after.

**4. Interrupt hierarchy is three-level, autovectored.**
The V8 fields IRQs at fixed 68k levels (`v8.cpp:287-315`): **SCC = 4,
VIA2/PseudoVIA = 2, VIA1 = 1**. The PseudoVIA *is* the LC's "VIA2" — it aggregates
slot IRQs, the ASC sound IRQ (`v8.cpp:120`), and screen VBL (`v8.cpp:108`,
`slot_irq_w<0x40>`).

**5. Two different 60 Hz sources.**
- The **60.15 Hz timer** in the V8 toggles **VIA1 CA1** (`v8.cpp:179,199,243-247`) —
  the traditional "Sixty Hertz" tick.
- The **real screen VBL** goes to the PseudoVIA (`v8.cpp:108`). Two distinct
  interrupt sources software treats differently.

**6. PDS slot — and the LC has its own card list.**
The LC's 96-pin Processor-Direct Slot is modeled as a NuBus device in `LC_PDS` bus
mode (`maclc.cpp:408-411`), with only slot $E's IRQ wired (`slot2_irq_w`,
`v8.cpp:323-326`). `maclc()` uses `mac_pdslc_orig_cards` (`maclc.cpp:447`) — a
different, smaller card list than the LC II's `mac_pdslc_cards`.

**7. Sound chain: ASC → DFAC → speaker, with Egret as the filter's controller.**
The Apple Sound Chip feeds the **DFAC** (Apple's audio filter, `maclc.cpp:396-398`),
and Egret programs the DFAC over an I²C-ish SCL/SDA/latch line (`maclc.cpp:421-423`).
Sound volume/filter state flows CPU → Egret → DFAC, not CPU → DFAC directly.

**8. RAM layout is aliased and config-driven.** Motherboard RAM is always mirrored at
`0x800000`; SIMM (bank A) goes at `0`, motherboard fills in after, with a special-case
for the 10 MB config (`v8.cpp:354-420`). The original LC has **2 MB soldered**
(`set_baseram_is_4M(false)`, `maclc.cpp:451`); the LC II/Classic II have 4 MB.

### MAME-implementation caveats

- **One driver, five machines.** `maclc.cpp` covers `maclc` (68020+V8), `maclc2`
  (68030+V8), `maccclas` (Color Classic, 68030+**Spice**+Cuda), `mactv` (Mac TV,
  68030@32 MHz+**Tinkerbell**+Cuda), and `macclas2` (Classic II, 68030+**Eagle**
  +Egret). Spice/Eagle/Tinkerbell are subclasses of the `V8` device — real Apple
  codenames for the V8 derivatives. Only `maclc` is the "LC1."
- **The 16-bit bus is not modeled as 16-bit.** RAM/ROM/VRAM are `u32` in MAME. The
  slowness is approximated via `via_sync()` (`v8.cpp:462-483`) and explicit
  `adjust_icount(-5)` penalties (e.g. SWIM, `maclc.cpp:272`). MAME timing ≠ real
  bus-cycle timing.
- **VRAM is over-allocated.** The V8 always carves a fixed **1 MB** `u32` VRAM array
  (`v8.cpp:175`), regardless of the real 256K/512K SIMM. Don't read the LC's true
  VRAM size out of MAME.
- **Optional FPU via a config switch.** `machine_reset` reads a config port bit to
  `set_fpu_enable` (`maclc.cpp:170-173`). The shipping LC had no 68882; treat this as
  a MAME convenience.
- **ROM packaging differs across the family.** `maclc` loads one 512 KB big-endian
  image (`ROM_LOAD`, `maclc.cpp:596`), while `maclc2` loads **four byte-wide chips
  interleaved** as 32-bit (`ROM_LOAD32_BYTE`, `maclc.cpp:601-604`) — a hint at the
  different physical ROM organization between the two boards.

---

## 5. PDS expansion cards

Two LC-PDS card lists in `src/devices/bus/nubus/cards.cpp`. The original LC uses the
`_orig` list (`maclc.cpp:447`); the LC II / Classic II / later use the plain list.

**Original LC — `mac_pdslc_orig_cards` (`cards.cpp:92-98`):**

| Option | Device | Card |
|---|---|---|
| `macconilc` | `PDSLC_MACCONILC` | Asante MacCON i LC Ethernet |
| `ro8lc` | `PDSLC_COLORVUE8LC` | RasterOps ColorVue 8LC video |
| `enetlc` | `PDSLC_ENETLC` | Apple Ethernet LC |
| `enetlctp` | `PDSLC_ENETLCTP` | Apple Ethernet LC Twisted-Pair |

**LC II and later — `mac_pdslc_cards` (`cards.cpp:84-89`):** same minus the video
card — `macconilc`, `enetlc`, `enetlctp`.

Two things worth flagging:
- **The ColorVue 8LC is original-LC-only** (`cards.cpp:91` comment). Per `8lc.cpp:9-10`,
  the card takes address-decoding shortcuts that only work on the original LC — which
  is why it's segregated into the `_orig` list.
- **The Apple IIe Card is not emulated.** Despite being the LC's most famous PDS card,
  MAME's list has only three Ethernet variants and one video card.

---

## 6. How the LC PDS slot is wired

The 96-pin Processor-Direct Slot is modeled through the NuBus infrastructure in a
special bus mode (`maclc.cpp:408-414`):

```c
nubus.set_bus_mode(nubus_device::nubus_mode_t::LC_PDS);  // maclc.cpp:411
nubus.set_address_mask(0x80ffffff);                       // maclc.cpp:410
nubus.out_irqe_callback().set(m_v8, FUNC(v8_device::slot2_irq_w)); // only slot $E IRQ
```

**The defining quirk — undecoded address lines.** The original LC PDS doesn't decode
A24–A30 (`nubus.cpp:136-137`). So a card's nominal `0xFsxxxxxx` slot space appears
aliased:

```c
// nubus.cpp:138-146  (LC_PDS mode)
case nubus_mode_t::LC_PDS:
    // 32-bit mode: 0xFxxxxxxx shows up as 0x8xxxxxxx
    install ... 0x80000000..0x80ffffff
    // 24-bit mode: shows up as 0x00Exxxxx
    install ... 0x00e00000..0x00efffff
```

This is why every card installs **multiple mirror mappings** of the same registers.
It reflects real silicon — the ColorVue comment even says *"the real card appears to
ignore A31… on the LC and LC II, A24-A30 are not decoded"* (`8lc.cpp:183`).

**Slot number & space.** PDS = slot `$E`. `get_slotspace() = 0xf0000000 | (slot<<24)`
(`nubus.h:44`), so slotspace = `0xFE000000`. All three LC cards `set_pds_slot(0xe)`
and the driver looks for them there.

**Two ways a card grabs address space:**
- `install_map()` / `install_device()` — within the 16 MB slot space `$Fs000000`
  (`nubus.h:146-153`).
- `install_lcpds_map()` — a *free-form* map over the **entire 32-bit space**
  `0x0000'0000–0xffff'ffff`, for "LC PDS cards which need to get outside of the box"
  (`nubus.h:165-170`). The Ethernet LC uses this.

**Slot IRQ path:** card calls `raise_slot_irq()` → `nubus().set_irq_line($E)`
(`nubus.h:213-216`) → `out_irqe_callback` → `v8_device::slot2_irq_w` →
`pseudovia->slot_irq_w<0x20>` (`v8.cpp:323-326`) → 68k level 2.

---

## 7. PDS card connection deep-dives

### A. Apple Ethernet LC / LC-TP — the bus-mastering one (`enetlc.cpp`)

- **Chip:** National **DP83932 "SONIC"** @ 20 MHz (`enetlc.cpp:62`).
- **Key architectural point:** SONIC is a **bus-master**. Unlike NuBus Ethernet cards,
  it DMAs *directly into the LC's main RAM* (`enetlc.cpp:10-12`). MAME wires SONIC's
  own bus to the NuBus host space so it can reach system memory:
  ```c
  m_sonic->set_bus(m_fulltag.c_str(), AS_DATA);  // enetlc.cpp:66
  ```
- **Mapping** uses the free-form `install_lcpds_map` (`enetlc.cpp:127`). SONIC
  registers land at the A24-30-stripped image `0x80000000`, **16-bit on the high
  word**:
  ```c
  map(0x8000'0000, 0x8000'01ff).m(m_sonic, ...).umask32(0xffff0000);  // enetlc.cpp:113
  ```
  with extra mirrors for 24-bit mode (`0x80040000`/`0x80400000`) and LC III/5xx
  (`0xFE000000`) — one card image covering several machines.
- **MAC PROM:** stored bit-swizzled, forced into Apple's OUI `08:00:07`
  (`enetlc.cpp:130-139`); a word-read of the MAC region returns a magic `0x0028` that
  looks like a card-presence check (`enetlc.cpp:150-154`).
- **IRQ:** `m_sonic->out_int_cb → slot_irq_w` (`enetlc.cpp:68`).

### B. Asante MacCON i LC — the NE2000-style one (`nubus_asntmc3b.cpp`)

- **Chip:** National **DP8390D** — a Mac repackaging of the ISA **NE2000**
  (`nubus_asntmc3b.cpp:13, 121`).
- **Opposite of SONIC:** **no host DMA.** The CPU must copy packets to/from the card's
  **64 KB on-card RAM** (`0x10000`, `nubus_asntmc3b.cpp:186`), and the DP8390 only
  DMAs *within that local buffer* (`dp_mem_read`/`dp_mem_write`, lines 280-290).
- **Hardwired to slot $E** (`set_pds_slot(0xe)`, line 211).
- **Mapping** (`nubus_asntmc3b.cpp:195-198`): on-card RAM at `slotspace+0xD0000`
  (8-bit), DP8390 registers at `slotspace+0xE0000` (32-bit handlers, but data on the
  **high byte** with an inverted index — `cs_write(0xf-offset, data>>24)`, lines
  233-254). A second mapping at `slotspace + (slotno<<20)` provides the **24-bit-mode
  mirror** (line 194).
- Register vs. remote-DMA accesses are distinguished by mem_mask: `0xff000000` = a
  register (byte), `0xffff0000` = remote DMA (16-bit word) — `dp_r`/`dp_w`, lines
  233-266.
- **IRQ:** `dp_irq_w → raise/lower_slot_irq` (lines 268-278).
- This same `nubus_mac8390_device` base also implements the NuBus Asante MC3NB and
  Apple's NuBus Ethernet — only the ROM and slot differ.

### C. RasterOps ColorVue 8LC — the video one (`8lc.cpp`)

- **Function:** 1/2/4/8 bpp at **1024×768** (`8lc.cpp:5-6`).
- **Chips:** a **TMS34061** video controller + **768 KB VRAM** (`VRAM_SIZE = 0xc0000`)
  + a RAMDAC (`8lc.cpp:54, 117-119`).
- **Mapping** (`8lc.cpp:179-187`): VRAM at `0xe00000+slotspace`, TMS34061 regs at
  `+0xEC0000`, RAMDAC at `+0xEE0000` — **plus a duplicate set at bare `0xE00000`**
  because the card ignores the high address lines. This is the explicit "A24–A30 not
  decoded" workaround, and the reason it's original-LC-only.
- **Control register** (`8lc.cpp:21-28`): oscillator select (80 / 57.28 MHz), bpp
  mode, X-zoom, VBL status, display enable, monitor-sense.
- **RAMDAC** at `+0xEE0000`: classic write-address-then-R/G/B-triplet CLUT loading
  (`8lc.cpp:378-418`).
- **IRQ:** TMS34061 `int_callback → vblank_w → raise/lower_slot_irq`
  (`8lc.cpp:121, 280-290`).

---

## 8. Interrupt map (68k levels)

The V8 collapses everything to three autovectored levels
(`v8_device::field_interrupts`, `v8.cpp:287-315`):

| 68k level | Source | Wired by |
|---|---|---|
| **4** | SCC (serial) | `scc_irq_w` (`v8.cpp:317-321`) |
| **2** | VIA2 / PseudoVIA (slots, ASC, SCSI, VBL) | `via2_irq` (`v8.cpp:281-285`) |
| **1** | VIA1 | `via1_irq` (`v8.cpp:275-279`) |
| (7 / NMI) | programmer's switch — Cuda variants only | `nmi_callback` (`maclc.cpp:488`, not on `maclc`) |

Only the highest pending level is asserted; the previously-asserted line is cleared
first (`v8.cpp:304-314`).

---

## 9. VIA1 register & pin map

VIA1 is a real **Rockwell 65C22** (`R65NC22`) clocked at **15.6672 MHz ÷ 20 ≈
783.36 kHz** (`v8.cpp:111`). It's reached at **`0x500000`**, with registers spaced
**0x200 apart** (`offset >>= 8; offset &= 0x0f` in `mac_via_r`, `v8.cpp:438-439`).
Standard 6522 layout:

| Reg | Addr (`0x500000+`) | 6522 function | LC use |
|---|---|---|---|
| 0 | `+0x000` | ORB/IRB (Port B) | Egret handshake (see pins) |
| 1 | `+0x200` | ORA/IRA (Port A) | mostly fixed / config |
| 2 | `+0x400` | DDRB | |
| 3 | `+0x600` | DDRA | |
| 4–7 | `+0x800…E00` | T1 counter/latch | timers |
| 8–9 | `+0x1000…1200` | T2 counter | timer |
| A | `+0x1400` | **SR (shift register)** | **ADB/Egret serial data** |
| B | `+0x1600` | ACR | |
| C | `+0x1800` | PCR | |
| D | `+0x1A00` | IFR | level-1 flags |
| E | `+0x1C00` | IER | |
| F | `+0x1E00` | ORA/IRA (no handshake) | |

**Port pins, as wired in the V8** (the important part for a reimplementation):

| Pin | Dir | Function | Source |
|---|---|---|---|
| PA (in) | R | reads `0xD4 \| config bit0` (mostly fixed; bit 0 = config/FPU) | `via_in_a`, `v8.cpp:249-252` |
| PA5 (out) | W | **floppy head-select (HDSEL)** | `via_out_a`, `v8.cpp:264-267` |
| PB3 (in) | R | Egret transceiver session (`get_xcvr_session`) | `via_in_b`, `v8.cpp:254-257` |
| PB4 (out) | W | Egret `set_via_full` | `via_out_b`, `v8.cpp:269-273` |
| PB5 (out) | W | Egret `set_sys_session` | `via_out_b`, `v8.cpp:269-273` |
| CA1 (in) | — | **60.15 Hz tick** | `mac_6015_tick`, `v8.cpp:243-247` |
| CB1 (in) | — | Egret clock (drives the SR) | `cb1_w`, `v8.cpp:424-427` |
| CB2 (i/o) | — | Egret data (in via `cb2_w`, out via `via_out_cb2`) | `v8.cpp:259-262, 429-432` |
| IRQ (out) | — | → 68k **level 1** | `via1_irq`, `v8.cpp:275-279` |

In the LC, **VIA1 is mostly the Egret comms channel** (PB3/4/5 + the CB1/CB2 shift
register) plus floppy HDSEL and the 60 Hz tick. This is the handshake that gates boot.

---

## 10. PseudoVIA ("VIA2") register & IRQ map

This is **not a discrete chip** — it's a VIA2-equivalent register block inside the V8
(`APPLE_V8_PSEUDOVIA`, clocked at 15.6672 MHz, `v8.cpp:124`), reached at
**`0x526000`** (`v8.cpp:94`). It's a 6522-*ish* interface with **no timers, no shift
register, no DDRs** (`pseudovia.cpp:9-11`); the V8 variant decodes only A0/A1/A4 →
registers 0,1,2,3,0x10,0x11,0x12,0x13 (`pseudovia.cpp:16-20`).

| Reg | Function | LC specifics |
|---|---|---|
| `0x00` | Port B | **bit 3 (write) = HMMU enable** (`via2_pb_w`, `v8.cpp:349-352`) |
| `0x01` | Config (Port A equiv.) | **read = `m_config\|0x04`; write sets RAM-size config** (`via2_config_r/w`, `v8.cpp:328-337`) |
| `0x02` | Slot/VBL flag register | bit `0x40`=VBL, bits `0x20/0x10/0x08`=slots $E/$D/$C (active-low); reset `0x7f` |
| `0x03` | **IFR** | bit0=SCSI DRQ, bit1=any-slot, bit3=SCSI IRQ, bit4=ASC IRQ, bit7=summary; write to ack; reset `0x1b` |
| `0x10` | Video config | read = `montype<<3` (`via2_video_config_r`, `v8.cpp:339-342`) |
| `0x12` | Slot interrupt enable | mask of `0x78` slot bits (`pseudovia.cpp:193-194`) |
| `0x13` | **IER** | bit7 set/clear convention; **bit7 reads back as 0** on V8 (`pseudovia.cpp:20, 242-245`) |

**IRQ aggregation (`pseudovia_recalc_irqs`, `pseudovia.cpp:190-218`):**

```
slot_irqs = (~reg2 & 0x78) & (reg0x12 & 0x78);   // enabled, active slots
if (slot_irqs) reg3 |= 0x02;                      // "any slot" into IFR
ifr = reg3 & reg0x13 & 0x1b;                       // mask = SCSI-DRQ|slot|SCSI|ASC
if (ifr) -> assert IRQ (reg3 |= 0x80)  else clear
```

The enable mask `0x1b` = bits 0 (SCSI DRQ), 1 (any-slot), 3 (SCSI IRQ), 4 (ASC).
Output goes via `irq_callback → via2_irq →` 68k **level 2** (`v8.cpp:130, 281-285`).

**V8-specific quirk:** the **ASC interrupt is level-triggered** here
(`v8_pseudovia_device::asc_irq_w`, `pseudovia.cpp:315-327`), and writing a 1 to ack
the ASC bit in reg 0x03 is deliberately a NOP (`pseudovia.cpp:354`) — a real
difference from a true 6522 and from the base RBV. (For contrast, the IIci/IIsi RBV is
edge-triggered, and Sonora/MSC decode more address bits — all in the same file.)

---

*Generated from analysis of the MAME source tree (`src/mame/apple/maclc.cpp`,
`src/mame/apple/v8.cpp`, `src/devices/bus/nubus/`, `src/devices/machine/pseudovia.cpp`)
cross-referenced with EveryMac / Low End Mac / Wikipedia hardware specifications.*
