# Macintosh LC for the [MiSTer Board](https://github.com/MiSTer-devel/Main_MiSTer/wiki)

An emulation core for the **Apple Macintosh LC** running on MiSTer FPGA.

Based on the [MacPlus MiSTer core](https://github.com/MiSTer-devel/MacPlus_MiSTer) by Sorgelig,
which originated from the [Plus Too project](http://www.bigmessowires.com/plus-too/). The Mac LC
emulates a Motorola 68020 CPU (via a modified TG68K core), the V8 gate array (video/glue),
the Egret (HC05) system controller, and the LC's other peripherals.

> **Work in progress.** This is an actively-developed core. Keep backups of any disk
> images you mount.

## Status

### Working

- Boots **Mac OS 6.0.8, 7.1, and 7.5.5** from SCSI to the Finder desktop
- **68020 CPU** via TG68K (with core-specific tweaks), running at the LC's native ~15.67 MHz
- **SCSI hard disk** on ID 0 (read/write, boot). Multiple drives untested.
- **File transfer** to/from the SD card via the BlueSCSI Toolbox — see
  [File transfer](#file-transfer-bluescsi-toolbox)
- **CD-ROM drive** on SCSI ID 3 — data, mixed-mode and audio discs, including the
  AppleCD Audio Player. Needs a CD driver in the guest System — see
  [CD-ROM support](#cd-rom-support-scsi).
- **Color display** — 1/2/4/8/16bpp, 512×384 (12" RGB) or 640×480 (VGA)
- **Sound**, including CD audio
- **Memory:** 2 MB or 10 MB configurations
- **PRAM/NVRAM:** save (on entering the OSD), automatic load at core start (or forced load),
  and clear
- **SCC serial** is wired in and "usable" but not yet doing anything useful

### Not working yet

- **QuickTime video playback**
- **Floppy disks**

## Usage

1. Copy the `*.rbf` to the root of your MiSTer SD card.
2. Place the 512 KB Mac LC ROM as `boot0.rom` in the `MACLC` folder.
3. Place a bootable SCSI hard-disk image (`.vhd` / `.img` / `.hda`) in the `MACLC` folder.
4. Optional: put files to share with the Mac in `games/MacLC/shared` — see
   [File transfer](#file-transfer-bluescsi-toolbox).

Open the on-screen display with **F12** to mount images and change options.

## ROM

The core requires the 512 KB Macintosh LC ROM (version `$67C`, checksum `$350EACF0`),
placed as `boot0.rom`. The ROM is loaded into SDRAM at core start; changing it requires
a reset/reload.

## SCSI bus layout

Three real targets sit on the emulated SCSI bus. The remaining OSD slots are
**not SCSI devices** — they are private channels the core uses to talk to MiSTer's
Main (file transfer, PRAM, CD swapping), and the guest never sees them:

| OSD slot | SCSI ID | Purpose |
|---|---|---|
| `Mount SCSI-0` | **0** | Primary hard disk (boot device) |
| `Mount SCSI-1` | **1** | Secondary hard disk |
| `Mount CD-ROM` | **3** | CD-ROM drive |
| `Mount PRAM` | — | PRAM/NVRAM save image (host channel) |
| *(no OSD entry)* | — | BlueSCSI Toolbox shared folder (host channel) |
| *(no OSD entry)* | — | BlueSCSI Toolbox CD changer control (host channel) |

The two host channels without an OSD entry are mounted automatically by the
forked Main_MiSTer; on stock Main they stay unmounted and the features that use
them degrade gracefully.

The Toolbox file-transfer commands are answered by the **SCSI ID 0** target and the
CD changer commands by the **ID 3** target — clients find them by INQUIRY, not by ID.

## Hard disk support (SCSI)

The on-screen display exposes two SCSI slots:

- **Mount SCSI-0** — primary drive (SCSI ID 0), the usual boot device
- **Mount SCSI-1** — secondary drive (SCSI ID 1)

> **The disk IDs are 0 and 1** (they were 6 and 5 in earlier builds). The boot SCSI ID
> is stored in PRAM, so an existing install blessed for ID 6 will not boot until you
> run **Reset PRAM & Core** — or re-bless the volume for its new ID.

Images use a raw SCSI format (same as the SCSI2SD project, documented
[here](http://www.codesrc.com/mediawiki/index.php?title=HFSFromScratch)) with a `.vhd`,
`.img`, or `.hda` extension. The SCSI disk is writable; data written from within the OS is
persisted to the image file.

Cold boots of System 6.0.8, 7.1, and 7.5.5 to the Finder desktop have been verified, and
SCSI writes were validated byte-exact on hardware (July 2026) after a series of reliability
fixes: a registered CPU status-read path, DREQ data-settle pacing to stop byte slip,
read-prefetch/completion-IRQ fixes, and a write word-pairing fix. A blank 20 MB image with
a partition table and SCSI driver is included as `releases/empty_hdd.zip`; a matching image is
also available from the
[MacPlus core releases](https://github.com/MiSTer-devel/MacPlus_MiSTer/tree/master/releases).
A tool to create hard-disk images (with driver and partition table) is available
[here](https://diskjockey.onegeekarmy.eu/).

> Multiple simultaneous SCSI drives have not been tested — keep backups.

## CD-ROM support (SCSI)

The core emulates an Apple-compatible CD-ROM drive on **SCSI ID 3**:

- **Mount CD-ROM** — mounts a disc image (the disc auto-remounts at core start)
- **CD-ROM Drive** (Enabled/Disabled) — removes the drive from the SCSI bus entirely
  when disabled

**The guest System must have a CD driver installed** — the stock Apple *CD-ROM* extension
works: the drive presents an AppleCD-family identity (`CD-ROM CDU-8004`, the AppleCD 300
mechanism), which the stock driver requires — a generic identity was tried and the driver
refuses to attach. The driver then speaks its standard SCSI-2 dialect (READ TOC incl. the
old-style full-TOC/BCD control-byte forms, PLAY MSF/TRACK, READ SUB-CHANNEL) — all served
byte-exact against BlueSCSI and Snow as references. Third-party CD drivers should also
work. Without a driver the disc mounts nothing on the desktop.

Image format support:

| Format | Status |
|---|---|
| `.iso` / `.toast` / `.bin` (2048-byte sectors) | **Working** — verified on hardware, stock MiSTer Main |
| `.cue`+`.bin` (2352-byte raw), `.chd` | **Working** — verified on hardware (July 2026); requires a [forked Main_MiSTer](https://github.com/danifunker/Main_MiSTer/tree/add-bluescsi-toolbox-for-MacLC) build |

**CD audio is fully supported** (July 2026): audio and mixed-mode discs mount correctly
(pure-audio discs reject data reads like a real drive — the Audio CD Access extension
depends on that), and the **AppleCD Audio Player** works end to end: full track listing
with durations, play, pause/resume, next/previous track, stop, and fast-forward/rewind
scan with audio, and the player's **volume slider** scales the audio. CD audio requires
`.cue`+`.bin` or `.chd` images (and therefore the forked Main, below) — flat 2048-byte
images carry no audio tracks.

The drive also implements the **BlueSCSI CD changer** commands, so a guest-side changer
utility can list the discs in `games/MacLC/CD3` and swap between them without going
through the OSD.

The exact Main_MiSTer binary these features were validated against ships in
[`releases/MiSTer`](releases/) (md5 `dda65f18`) — copy it to `/media/fat/MiSTer`
(back up the original first). The same binary also provides the file-transfer
support described below.

Ejecting from the Finder (drag to Trash) is honored; use the OSD to insert a
different disc.

## File transfer (BlueSCSI Toolbox)

Files move between the SD card and the running Mac using the **BlueSCSI Toolbox**
protocol — no floppies or network needed. The core answers the Toolbox vendor SCSI
commands and MiSTer's Main serves a folder on the SD card as shared storage.

1. Put files in `games/MacLC/shared` on the SD card (or set `SHARED_FOLDER=` in
   `MiSTer.ini` to point elsewhere).
2. Run a Toolbox client in the guest. The **BlueSCSI SD Transfer** app is included as a
   mountable disk image in [`releases/`](releases/) — mount it, then run the app from it
   or drag it onto your boot volume.
3. The app lists the shared folder: **Download** copies a file to the Mac, and
   **File → Upload File** copies one back to the SD card.

Both directions are verified byte-exact on hardware for multi-megabyte files
(August 2026), at roughly 120 KB/s down and 170 KB/s up.

This requires the [forked Main_MiSTer](https://github.com/danifunker/Main_MiSTer/tree/add-bluescsi-toolbox-for-MacLC)
build — stock Main has no Toolbox handler. The core degrades gracefully without it:
Toolbox commands simply report that no shared folder is available.

*BlueSCSI Toolbox files distributed with permission from Eric Helgeson (c) 2026*

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

All the LC's colour depths render — 1, 2, 4, 8 and 16bpp. Aspect ratio and scaling
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
- **BlueSCSI Toolbox** protocol and client by [Eric Helgeson](https://github.com/erichelgeson)
- Mac LC port and ongoing development by [danifunker](https://github.com/danifunker) and [alanswx](https://github.com/alanswx)
