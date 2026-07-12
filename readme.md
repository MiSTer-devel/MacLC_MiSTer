# Macintosh LC for the [MiSTer Board](https://github.com/MiSTer-devel/Main_MiSTer/wiki)

An emulation core for the **Apple Macintosh LC** running on MiSTer FPGA.

Based on the [MacPlus MiSTer core](https://github.com/MiSTer-devel/MacPlus_MiSTer) by Sorgelig,
which originated from the [Plus Too project](http://www.bigmessowires.com/plus-too/). The Mac LC
emulates a Motorola 68020 CPU (via a modified TG68K core), the V8 gate array (video/glue),
the Egret (HC05) system controller, and the LC's other peripherals.

> **Work in progress.** This is an early, actively-developed core. Expect bugs and data loss.
> Keep backups of any disk images you mount.

## Status

### Working

- Boots **Mac OS 6.0.8, 7.1, and 7.5.5** from SCSI to the Finder desktop
- **68020 CPU** via TG68K (with core-specific tweaks), running at the LC's native ~15.67 MHz
- **SCSI hard disk** on ID 6 (read/write, boot). Multiple drives untested.
- **CD-ROM drive** on SCSI ID 3 (read-only, data discs). ISO images verified on hardware
  (July 2026); needs a CD driver in the guest System — see
  [CD-ROM support](#cd-rom-support-scsi).
- **Display:** 512×384 (12" RGB) or 640×480 (VGA), **1bpp and 2bpp black & white only**
- **Memory:** 2 MB or 10 MB configurations
- **PRAM/NVRAM:** save (on entering the OSD), automatic load at core start (or forced load),
  and clear
- **SCC serial** is wired in and "usable" but not yet doing anything useful

### Not working yet

- **Color** — any video mode above 2bpp (4/8/16bpp)
- **Sound** (silent on hardware; plays in simulation)
- **Floppy disks**

## Usage

1. Copy the `*.rbf` to the root of your MiSTer SD card.
2. Place the 512 KB Mac LC ROM as `boot0.rom` in the `MACLC` folder.
3. Place a bootable SCSI hard-disk image (`.vhd` / `.img` / `.hda`) in the `MACLC` folder.

Open the on-screen display with **F12** to mount images and change options.

## ROM

The core requires the 512 KB Macintosh LC ROM (version `$67C`, checksum `$350EACF0`),
placed as `boot0.rom`. The ROM is loaded into SDRAM at core start; changing it requires
a reset/reload.

## Hard disk support (SCSI)

The on-screen display exposes two SCSI slots:

- **Mount SCSI-6** — primary drive (ID 6), the usual boot device
- **Mount SCSI-5** — secondary drive (ID 5)

Images use a raw SCSI format (same as the SCSI2SD project, documented
[here](http://www.codesrc.com/mediawiki/index.php?title=HFSFromScratch)) with a `.vhd`,
`.img`, or `.hda` extension. The SCSI disk is writable; data written from within the OS is
persisted to the image file.

Cold boots of System 6.0.8, 7.1, and 7.5.5 to the Finder desktop have been verified (July 2026,
after a series of SCSI reliability fixes: a registered CPU status-read path, DREQ data-settle
pacing to stop byte slip, and read-prefetch/completion-IRQ fixes). A blank 20 MB image with
a partition table and SCSI driver is included as `releases/empty_hdd.zip`; a matching image is
also available from the
[MacPlus core releases](https://github.com/MiSTer-devel/MacPlus_MiSTer/tree/master/releases).
A tool to create hard-disk images (with driver and partition table) is available
[here](https://diskjockey.onegeekarmy.eu/).

> Multiple simultaneous SCSI drives have not been tested. Expect data loss — keep backups.

## CD-ROM support (SCSI)

The core emulates an Apple-compatible CD-ROM drive on **SCSI ID 3**:

- **Mount CD-ROM** — mounts a disc image (the disc auto-remounts at core start)
- **CD-ROM Drive** (Enabled/Disabled) — removes the drive from the SCSI bus entirely
  when disabled

**The guest System must have a CD driver installed** — the stock Apple *CD-ROM* extension
works: the drive presents the AppleCD 150 identity (`SONY CD-ROM CDU-8002`, byte-exact
from real hardware), which the stock driver requires — a generic identity was tried and
the driver refuses to attach. Third-party CD drivers should also work. Without a driver
the disc mounts nothing on the desktop.

Image format support:

| Format | Status |
|---|---|
| `.iso` / `.toast` / `.bin` (2048-byte sectors) | **Working** — verified on hardware, stock MiSTer Main |
| `.cue`+`.bin` (2352-byte raw), `.chd` | Experimental — requires a [forked Main_MiSTer](https://github.com/danifunker/Main_MiSTer/tree/add-bluescsi-toolbox-for-MacLC) build (untested) |

Data discs only (HFS and ISO 9660/hybrid). **CD audio is not implemented yet** — audio
tracks are ignored. Ejecting from the Finder (drag to Trash) is honored; use the OSD to
insert a different disc.

## Floppy disk support

**Not currently working.** The OSD exposes two floppy slots ("Mount Pri/Sec Floppy") and the
core accepts raw disk images (`.dsk` / `.img`), but floppy boot/read is not functional at this
time. Use a SCSI hard-disk image instead.

When floppy support is restored, raw (DiskDup) format is expected: 400k single-sided images
must be exactly 409,600 bytes and 800k double-sided images exactly 819,200 bytes. Disk Copy 4.2
(`.image` / `.dc42`) files are not supported directly and must be converted to raw format first.
[**rusty-backup**](https://github.com/danifunker/rusty-backup) can handle DC42 conversion;
other options include this
[converter](https://www.bigmessowires.com/2013/12/16/macintosh-diskcopy-4-2-floppy-image-converter/)
and the helper script at [releases/bin2dsk.sh](releases/bin2dsk.sh).

## PRAM / NVRAM

The Mac LC's parameter RAM (PRAM) — which stores settings such as the monitor color depth and
the real-time clock — is backed by a persistent NVRAM image:

- **Save:** PRAM is written back when you open the OSD.
- **Load:** the PRAM image is loaded automatically when the core starts; you can also force a
  reload via the "Mount PRAM" slot in the OSD.
- **Clear:** "Reset PRAM & Core" clears PRAM and resets the machine (a fresh, default PRAM).

A default PRAM image is included as `releases/MacLC.nvr`.

## Memory

Two configurations are selectable in the OSD: **2 MB** (motherboard RAM only) or **10 MB**
(2 MB soldered + 8 MB SIMM), matching real LC configurations. Changing the memory setting
applies on reset ("Reset & Apply CPU+Memory"). A cold boot with 10 MB selected takes longer to
complete its RAM test before booting — be patient.

### Skipping the boot RAM test (optional)

The boot ROM runs a destructive RAM test (the "memory march") on cold boot, which is what makes
a 10 MB cold boot slow. You can optionally patch the ROM to skip this test and take the ROM's
fast warm-start path instead.

> Both the stock and the patched ROM have been verified booting System 7.5.5 to the desktop on
> current builds (July 2026). The stock ROM remains the reference configuration — if you hit
> boot problems, retest with a stock, unpatched ROM before reporting.

A patcher is provided at
[`verilator/patch_skip_ramtest.py`](verilator/patch_skip_ramtest.py). It needs Python 3 and the
standard 512 KB Mac LC ROM (checksum `350EACF0`):

```bash
python3 verilator/patch_skip_ramtest.py boot0.rom boot0_skipramtest.rom
```

This applies a 2-byte patch at ROM offset `0x46558` (`cmpi.l #'WLSC',d3` → `bra.s $46570`) that
forces the warm-start path, and recomputes the header checksum so the ROM self-check still
passes. Back up your original ROM, then copy the patched file to your `MACLC` folder as
`boot0.rom`.

## Display

The core supports two monitors, selectable in the OSD:

- **640×480 VGA**
- **512×384 12" RGB** (the LC's "Macintosh 12-inch RGB Display")

Only 1bpp and 2bpp black/white and color modes currently render correctly (but no color is displayed in any mode). Aspect ratio and scaling
options are available in the OSD.

## Keyboard & mouse

Keyboard and mouse are delivered over a wire-level ADB device model. The **Alt** key maps to
the Mac's Command (⌘) key and the **Windows** key maps to Option (⌥). The numeric keypad is
emulated.

## Building from source

### FPGA (Quartus)

Built with **Intel Quartus 17.0.2 Lite**. Either open `MacLC.qpf` in the Quartus GUI and
compile, or use the scripted CLI flow (repeatable, headless-friendly):

```bash
bash scripts/setup_env.sh   # once: create scripts/local.env, set QUARTUS_BIN
bash scripts/build_only.sh  # full compile -> output_files/MacLC.rbf + STA verdict
```

See [BUILD.md](BUILD.md) for details. Deploy the resulting `.rbf` from `output_files/` to the
SD card.

### Simulation (Verilator)

A Verilator testbench is provided for development:

```bash
cd verilator
make
./obj_dir/Vemu --help
```

See [CLAUDE.md](CLAUDE.md) and the `docs/` directory for architecture notes and the
development workflow.

## Credits

- **MacPlus MiSTer** core by Sorgelig
- **Plus Too** by Steve Chamberlin (Big Mess o' Wires)
- Mac LC port and ongoing development by [danifunker](https://github.com/danifunker) and [alanswx](https://github.com/alanswx)
