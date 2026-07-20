# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Macintosh LC emulation core for the MiSTer FPGA platform. It's based on the MacPlus core by Sorgelig, which originated from the Plus Too project. The core emulates the Motorola 68000 CPU and various Macintosh peripherals.

## Build Commands

**See [BUILD.md](BUILD.md) for the full scripted CLI build/deploy flow** (setup,
`scripts/build_only.sh` modes, status output, running multiple builds on one host,
and porting the toolchain to other cores).

### FPGA Build (Quartus)
The project uses Intel Quartus 17.0.2 Lite Edition.

**GUI:**
- Open `MacLC.qpf` in Quartus
- Compile to generate RBF output in `output_files/`
- Deploy RBF to MiSTer SD card root

**CLI (see [BUILD.md](BUILD.md)):**
```bash
bash scripts/setup_env.sh     # first time: create scripts/local.env, then set QUARTUS_BIN
bash scripts/build_only.sh    # full compile -> output_files/MacLC.rbf + status summary
bash scripts/deploy_screenshot.sh   # optional: push + launch on the MiSTer
```

### Verilator Simulation
```bash
cd verilator
make        # Build simulator
make clean  # Clean build artifacts
./obj_dir/Vemu  # Run interactive simulator (requires SDL2, OpenGL)
```

#### Simulator Command Line Options
```bash
./obj_dir/Vemu --help                    # Show all options
./obj_dir/Vemu --screenshot 360          # Take screenshot at frame 360
./obj_dir/Vemu --stop-at-frame 400       # Exit after frame 400
./obj_dir/Vemu --screenshot 360 --stop-at-frame 361  # screenshot
```

Key options:
- `--screenshot <frame>` - Save PNG screenshot at specified frame number
- `--stop-at-frame <frame>` - Exit simulation after reaching frame count
- `--trace` - Enable FST waveform tracing (outputs to `trace.fst`)

Note: Boot takes approximately 360 frames to reach the Mac desktop.
Note: No hard drive is configured in the simulator, so the desktop won't fully load.

#### Boot Verification
```bash
cd verilator
./check_boot.sh              # Analyze existing cpu_trace.log
./check_boot.sh --run        # Run 30 frames + analyze
./check_boot.sh --run 100    # Run N frames + analyze
```
Exit codes: 0=PASS, 1=FAIL, 2=missing log. Suitable for pre-commit hooks.

#### Simulation Logs
- **CPU trace log:** `verilator/cpu_trace.log` - Contains 68K CPU instruction trace
- **Console output (stderr):** Contains HC05 (Egret) traces, VIA/peripheral debug messages
- **Important:** Do NOT re-run the simulator multiple times when diagnosing. Run once, then analyze the log files.

#### Comparing against MAME (ground truth)
When the core misbehaves, diff it against MAME's `maclc` running the same ROM.
Tooling: `verilator/mame/` (`run_mame.sh`, `tap.lua`, `snap.lua`, `trace.dbg`).
Full process + gotchas: **`docs/mame_compare.md`** (memory tap, maincpu trace,
PC-stream divergence diff; macOS has no `timeout`, debugger defaults to the Egret
HC05 not the 68020, MAME PCs are 8-digit `00Axxxxx`, etc.).

## Framework Files Are OFF-LIMITS (`sys/`)

**NEVER modify files under `sys/` (the MiSTer framework: sys_top.v, ascal.vhd,
osd.v, hps_io, pll_hdmi, .sdc files, etc.).** The only permitted change is a
wholesale update of framework files taken directly from the upstream MiSTer
template repo. If a fit, timing, or resource problem traces into the framework,
reconcile it from OUR side — `rtl/`, `MacLC.sv`, `MacLC.qsf`, `MacLC.sdc` —
never by patching the framework in place.

Why (learned 2026-07-17): a night of framework edits (RAM attributes in
ascal.vhd/osd.v, a PALETTE generic in sys_top.v) produced STA-met builds with
dead video and confounded every hardware A/B for hours. Framework internals
(scaler pipeline, clock-domain handoffs) have invariants that are not visible
from this repo; local edits there create failure modes that pass STA and only
show up on hardware.

## Architecture

### Top-Level Module
- `MacLC.sv` - Main system module (module name: `emu`)
- Entry point for the MiSTer framework via `sys/sys_top.v`

### RTL Structure (`/rtl`)

**CPU Core:**
- `tg68k/` - TG68K CPU core (68000)

**Memory & Storage:**
- `sdram.v` - SDRAM controller
- `scsi.v`, `ncr5380.sv` - SCSI hard drive interface
- `floppy.v`, `floppy_track_encoder.v` - Floppy drive emulation

**I/O Peripherals:**
- `via6522.sv` - Versatile Interface Adapter (parallel I/O, timers)
- `pseudovia.sv` - VIA emulation for LC models
- `iwm.v` - Integrated Woz Machine (floppy controller)
- `scc.v` - Serial Communication Controller
- `adb.sv` - Apple Desktop Bus
- `ps2_kbd.sv`, `ps2_mouse.v` - Keyboard/mouse input
- `rtc.v` - Real-Time Clock
- `uart/` - UART TX/RX modules

**Video Subsystem:**
- `maclc_v8_video.sv` - Mac LC Video Engine (V8)
- `ariel_ramdac.sv` - Video DAC
- `addrController_top.v`, `addrDecoder.v` - Address generation
- `dataController_top.sv` - Data control

### System Framework (`/sys`)
Standard MiSTer framework files (video scaling, HPS I/O, audio output). Generally should not need modification for core-specific work.

## Key Technical Details

- **Target FPGA:** Cyclone V (MiSTer DE10-Nano)
- **System clock:** Generated via `rtl/pll.v`
- **Memory:** 1MB/4MB RAM configurations, DDR3 SDRAM interface
- **Video modes:** 1/2/4/8/16 bpp
- **CPU speeds:** 8 MHz (original) or 16 MHz

## File Locations

- `files.qip` - Lists all RTL source files for Quartus
- `MacLC.qsf` - Quartus project settings
- `releases/` - Pre-built RBF files and ROM images. Only release-quality and
  provenance artifacts belong here (dated `MacLC_YYYYMMDD.rbf` releases and the
  hash-named build they were copied from) — probe/A-B/experiment RBFs do not.
- `scratch/` - **(gitignored) ALL session scratch goes here**: screenshots,
  build/launch logs, probe RBFs, captures, analysis dumps. Never leave scratch
  work in the repo root and never commit it.

## CPU Conversion Notes

When working with CPU cores, see `how-to-convert-cpu.txt` for GHDL-based VHDL to Verilog conversion process using:
```bash
ghdl synth -fsynopsys -fexplicit --latches --out=verilog
```

## Verilator vs Quartus Compatibility

**Critical:** Verilator allows multiple `always` blocks to drive the same `reg`, but Quartus does not (Error 10028: "Can't resolve multiple constant drivers"). When writing or modifying RTL:

- Each `reg` must be driven from exactly **one** `always` block for Quartus synthesis
- If timer logic, PRAM loading, or other hardware needs to write the same register as a CPU write path, **merge them into a single `always` block**
- Use `if/else if` priority within the block to handle the different write sources
- Verilator builds (`make` in `verilator/`) will succeed even with multiple drivers — always verify the design is Quartus-clean before targeting FPGA

**Conditional compilation:** `USE_EGRET_CPU` and `SIMULATION` are defined in `verilator/Makefile` for simulation. For FPGA, `USE_EGRET_CPU` is set in `MacLC.qsf`. Guard simulation-only code (`$display`, debug counters) with `` `ifdef SIMULATION ``.

**Top-level split:** the Verilator top is `verilator/sim.v` (`module emu`), NOT `MacLC.sv`. It has its **own** CPU instantiation and bus glue (VPA/DTACK/BERR/overlay); peripheral RTL is shared via `dataController_top`. CPU-glue/top-level fixes must go in **both** files or sim and FPGA silently diverge. Tracked differences (and a maintenance checklist) live in **`docs/verilator_differences.md`** — update it when you add a top-level signal or hardwire a sim config.

## VIA Shift Register — Simulation Sensitivity

**Critical:** Changes to the VIA SR logic in `rtl/via6522.sv` can break Egret communication and stall the boot. After any SR change, verify simulation still boots:

```bash
cd verilator && make clean && make
./obj_dir/Vemu --screenshot 350 --stop-at-frame 351 2>/dev/null 1>/dev/null
```

Check `screenshot_frame_0350.png` — it must show the grey/black alternating line pattern (memory test). Uniform grey means the SR change broke Egret communication.

**SR edge-detection patterns (history + FPGA caveat):**
- `cb2_latched` (shift-in: capturing CB2 at the CB1 rising edge) — **removed; do not re-introduce.** Shift-in uses live `cb2_i`. Re-introducing it hung the 4th Egret SR transfer in Verilator (CPU stuck polling IFR bit 2 at `0xA14E5E`).
- `ext_fall_edge_pending` (shift-out: latching CB1 falling edges in external-clock mode) — **currently IN USE in `via6522.sv`.** It was reverted in `a8f9f33`, then deliberately re-added in `e067857` ("switching to fake egret"). It boots in Verilator only because the behavioral Egret drives CB1 slowly, so edges never coalesce. It is the **suspected cause of the FPGA overlay-stuck bug**: the real HC05 toggles CB1 far faster than the VIA's E-rate (only one pending edge is consumed per E-falling phase), so edges coalesce, SR bytes corrupt, the boot ROM's Egret handshake never completes, and the ROM overlay never clears. Do NOT assume it is FPGA-safe — prefer rate-limiting CB1 in `egret_wrapper` over re-touching this SR path.

Re-verify boot (the screenshot check above) after ANY SR change.

## Known Limitations

- Floppy disks are read-only
- SCSI writes work but are experimental
- Floppy won't read at 16 MHz CPU speed
- Bus retry via HALT signal not implemented
- CD-ROM (SCSI ID 3, OSD slot `SC4`): data, mixed-mode, and audio CDs.
  CD audio + the AppleCD Audio Player (listing, transport, FF/RW scan)
  fully working as of 2026-07-20 (standard SCSI-2 dialect on the
  CDU-8004 identity; BlueSCSI + Snow are the byte oracles; command gaps
  logged in docs/SCSI_CMD_GAPS.md). Flat 2048-byte images (ISO/TOAST)
  work on a stock Main_MiSTer; CUE/BIN (2352) and CHD need the Main
  fork's `support/maclc/maclc_cd` layer (branch
  `add-bluescsi-toolbox-for-MacLC`) — the validated binary ships in
  `releases/MiSTer`. The guest System needs the Apple CD-ROM extension
  (or a third-party CD driver) to mount discs. Serving law for any new
  DataIn command: transfer EXACTLY what the initiator arms (see
  docs/SCSI_CMD_GAPS.md).
