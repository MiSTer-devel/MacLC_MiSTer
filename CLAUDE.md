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
- `swim.v` - SWIM floppy controller (IWM + ISM personalities)
- `scc.v` - Serial Communication Controller
- `adb.sv` - Apple Desktop Bus
- `ps2_kbd.sv`, `ps2_mouse.v` - Keyboard/mouse input
- `egret/` - Egret system controller (68HC05 + 341S0851 firmware): ADB, RTC, PRAM
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

**Conditional compilation:** `SIMULATION` is defined in `verilator/Makefile`. Guard simulation-only code (`$display`, debug counters) with `` `ifdef SIMULATION ``. (`USE_EGRET_CPU` is gone — the real HC05 Egret is unconditional as of 2026-08-09; `EGRET_BEHAVIORAL` remains as an opt-in debug fallback.)

**Top-level split:** the Verilator top is `verilator/sim.v` (`module emu`), NOT `MacLC.sv`. It has its **own** CPU instantiation and bus glue (VPA/DTACK/BERR/overlay); peripheral RTL is shared via `dataController_top`. CPU-glue/top-level fixes must go in **both** files or sim and FPGA silently diverge. Tracked differences (and a maintenance checklist) live in **`docs/verilator_differences.md`** — update it when you add a top-level signal or hardwire a sim config.

## VIA Shift Register — Simulation Sensitivity

**Critical:** Changes to the VIA SR logic in `rtl/via6522.sv` can break Egret communication and stall the boot. After any SR change, verify simulation still boots:

```bash
cd verilator && make clean && make
./obj_dir/Vemu --screenshot 450 --stop-at-frame 451 2>/dev/null 1>/dev/null
```

Check `screenshot_frame_0450.png` — it must show the **50% dither grey desktop
with the arrow cursor top-left** (boot reached cursor-visible state). A uniform
flat grey at 450 means the boot stalled — Egret communication is the first
suspect. Corroborate with `bash check_boot.sh` (stages + ADVANCING).
(Re-calibrated 2026-08-05: the old criterion was the memory-test line pattern
at frame 350, timed against VIA timers that counted 2× slow — the via6522.sv
timer fix moved every timer-paced boot delay earlier, so the pattern now
passes before frame 180 and 350 lands in a featureless VRAM-fill phase.)

**SR edge-detection patterns (history + FPGA caveat):**
- `cb2_latched` (shift-in: capturing CB2 at the CB1 rising edge) — **removed; do not re-introduce.** Shift-in uses live `cb2_i`. Re-introducing it hung the 4th Egret SR transfer in Verilator (CPU stuck polling IFR bit 2 at `0xA14E5E`).
- `ext_fall_edge_pending` (shift-out: latching CB1 falling edges in external-clock mode) — **currently IN USE in `via6522.sv`.** It was reverted in `a8f9f33`, then deliberately re-added in `e067857` ("switching to fake egret"). It boots in Verilator only because the behavioral Egret drives CB1 slowly, so edges never coalesce. It is the **suspected cause of the FPGA overlay-stuck bug**: the real HC05 toggles CB1 far faster than the VIA's E-rate (only one pending edge is consumed per E-falling phase), so edges coalesce, SR bytes corrupt, the boot ROM's Egret handshake never completes, and the ROM overlay never clears. Do NOT assume it is FPGA-safe — prefer rate-limiting CB1 in `egret_wrapper` over re-touching this SR path.

Re-verify boot (the screenshot check above) after ANY SR change.

## Known Limitations

- Floppy disks are read-only (**no write datapath exists** in `rtl/floppy.v`;
  the drive reports `WRTPRT=0` = write-protected so the OS never tries. That
  is load-bearing: the ROM's write primitive polls handshake b7 in an
  UNBOUNDED loop, so an attempted write would hang the machine, not fail.)
- **BOOTING FROM FLOPPY WORKS** (user-confirmed on hardware 2026-08-05,
  bench build `78a46cf2`). The old "Welcome to Macintosh" retry loop and the
  ~39 KB-then-UNDERRUN freeze are gone. Several fixes contributed and no
  single one was isolated: the constant-300-RPM MFM tach (`62aee5c`, which
  targeted the Welcome loop directly), the ISM drive-select fix, the INDEX
  pulse, VIA1 PA7, and the VIA timer half-rate fix (`33ebdd1` — the driver's
  install-time drive-speed check is timer-paced, so a 2x timer error would
  also have corrupted it).
- **800K GCR disks WORK END-TO-END as of 2026-08-05** — mount, catalog, and
  **file reads**: on a cold boot a 482K application was launched off an 800K
  GCR floppy and copied to a SCSI disk with zero driver errors (head seeking,
  `step_cnt` 1 -> 311). Two fixes got here:
  1. `2804d02` — "This disk is unreadable" (`-69 badCksmErr`). The IWM
     read-data latch clear was retriggered from the LEVEL `iwmRead` instead of
     firing once at the END of the access: the LC's E-paced VPA accesses (~1.23
     us) plus the ROM's ~2.5 us GCR poll loop left less gap than the 13-cen
     reload, so the latch never cleared and the CPU re-read each disk byte ~6
     times — duplicates shift a field and break its checksum.
  2. **MEDIA CHANGES — FIXED AND HW-VALIDATED 2026-08-06** (`887ebba` +
     `dbb736e`; MISSION COMPLETE: a full System 6.0.8 install from its two
     1.44 MB floppies ran end to end — installer ejects, both OSD disk swaps,
     install onto a fresh SCSI vhd, installed system boots). The ghost-volume
     class ("mounts and lists but every call fails with NO driver error and
     zero disk I/O") was the guest never being told the medium changed. Three
     inseparable pieces, all MAME-runtime-grounded (tap_swapB/tap_qscreen):
     - **SWITCHED sense reg** (read reg 6 = MAME DiskChg = `!m_dskchg`):
       reset 0, SET on any media removal (fall of `insertDisk`), survives the
       next insert, cleared ONLY by the guest's DskchgClear strobe
       (`strobeCmd == 4'hC`). The Sony driver polls NoDiskInPl+DiskChg as a
       PAIR every ~0.8 s and strobes the clear itself — watched live on HW
       (HUD w7 `dskchg_clears` increments). Landing the CSTIN transition
       WITHOUT this register was the reverted-`ebbdac6` regression.
     - **CSTIN reports `~insertDisk`** + the MacLC.sv/sim.v empty-hold (drop
       media at download START, hold 2.06 s past the end).
     - **ISM eject re-enabled** under `(!ism_active || ism_sel)` — the MAME
       devsel-forwarding condition. The old blanket `!ism_active` gate made an
       MFM installer structurally unable to eject; the phases-walk phantom
       ejects it guarded against all run with Mode b7 CLEAR, so the qualifier
       blocks them and passes genuine ejects (installer ejects seen on HW).
     ALSO fixed en route (`dbb736e`): **Main packs the matched extension of a
     multi-extension F entry into the upper `ioctl_index` bits** (.dsk = 8'h01,
     .img = 8'h41); the flag latches compared the full byte, so every `.img`
     mount was a silent no-op (downloaded, never presented) since day one —
     compare `dio_index[5:0]` only. `verilator/tb_disk_swap.v` covers the full
     protocol (incl. walk-must-not-eject and the 8'h41-index mount) — run it
     after any `insertDisk`/`CSTIN`/eject edit. HUD row 7 = the media witness
     (`floppy.v` dbg_media; decode in `scripts/parse_hud.py`).
     ★ Swap-under-a-live-volume (no eject) is HOSTILE ON A REAL MAC TOO —
     MAME 6.0.8 bombs ("Disk Initialization package not present") when the
     boot floppy is yanked: drives only eject under software control, so the
     OS has no graceful path. The Mac-authentic flow is guest-eject-first
     (or the installer's own eject), THEN mount the next image.
     ★ OSD/bench lore from the validation (ops crib additions): the in-core
     OSD opens with the cursor ON "Mount Pri Floppy" after a FRESH CORE LOAD
     but remembers its row and browser position across opens within a
     session; the screenshot-filename oracle names the LAST file downloaded
     this core session — it proves a pick happened, NOT which slot took it.
  ★ `byte_cnt` frozen + `$142` all-benign means **no read was attempted** — do
  not read it as "reads returned bad data". (And `byte_cnt` alone is NOT proof
  of internal-drive reads — the GCR delivery counter also churns on garbage
  with no disk in; corroborate with w7 `insertDisk`/`CSTIN`.)
  The old 2026-07-07 floppy-controller park is RESOLVED (doc removed); its
  "SDRAM region != image" theory was never confirmed and its JTAG chain no
  longer works (dead hub). Offline instruments that settled all of this in
  minutes: `verilator/tb_gcr_read.v` (`+track/+side/+ncap`, seeks via the real
  drive-register protocol; **always pass `+acclen=40 +pollgap=40`** or the
  stream is garbage), `scripts/gcr_census.py` (address fields),
  `scripts/gcr_data_census.py` (DATA fields verified against the standard 800K
  layout offset — every zone boundary clean, refuting the `soff` suspicion) and
  `scripts/hfs_check.py` (walks an image's catalog/extents trees offline so a
  broken source image can't fake an RTL bug).
- **1.44 MB MFM read works, and the Finder whole-disk COPY was FIXED
  2026-08-05** (`33ebdd1`): the real defect was **`rtl/via6522.sv` counting
  T1/T2 at half rate** — a `/2` prescaler stacked on enables that were already
  at VIA phi2 rate (`E_div=1'b1`), so every guest VIA-timer interval ran 2.0×
  long since June. That doubled the Sony driver's Time-Manager sleep between
  read attempts and phase-locked its re-arm one sector late (stride-2 over 18
  sectors ⇒ a closed 9-sector cycle ⇒ `-81 sectNFErr`). HW: 5 dialogs → **0,
  twice**, copy ~2 min → ~55 s. Full write-up + the SCAN-WITNESS evidence in
  **`docs/sony_driver_mfm_read_reference.md`** — read it before any floppy or
  VIA-timer work; it also decodes every Sony error code (`-65` is benign
  polling of the absent second drive) and lists **seven theories tested and
  refuted**, several of which were built before that page existed.
  Instruments: `USE_DBG_HUD` + `scripts/parse_hud.py` (rows 7/8 = SCAN-WITNESS),
  `verilator/mame/floppy/sonyvars_watch.lua` (driver retry budgets from MAME),
  `verilator/tb_mfm_idcensus.v` (full-disk ID census), `tb_ism_sony +postgap=N`.
  ★ `USE_DBG_HUD` is currently OFF (commented out) in `MacLC.qsf` — flip it
  on for debug fits only; it must be OFF in release fits.
- SCSI writes validated 2026-07-29 (word-pairing fix f38c06f/ceaec45; 14.5 MB
  in-guest duplicate byte-identical). SCSI/CD reads validated same day
  (look-ahead boundary fix 082dcc4; CD copies byte-identical to ISO
  reference). Release fits no longer carry the JTAG probe decks — an
  always-on anchor in MacLC.sv (4dfb463, extended 2026-08-03 with per-disk
  read-ring words after the 11-word anchor proved insufficient on the
  post-floppy netlist) pins the SCSI capture + ring-serve cones; do
  not remove it (comment block explains), and gate every new fit in the
  FINDER on colour icons — `scripts/icon_gate.py` on frames captured with
  `scripts/grab_fresh.sh` (stock grab.sh serves STALE frames when video is
  dead), plus a >=2-boot Finder soak (see the probes-off anchor comment in
  MacLC.sv).
- Floppy won't read at 16 MHz CPU speed
- Bus retry via HALT signal not implemented
- ~~"Original" aspect was 256:171~~ FIXED 2026-08-08: that was the Mac Plus
  512x342 screen, inherited at import — it drew ~12% wide and OVERFLOWED
  integer scaling on 1280x1024 panels (V-Integer requested 1437 px → blank
  screen). Now true 4:3 (both LC monitor modes are 4:3). Offline gate:
  `scripts/aspect_check.py` (faithful model of sys/video_freak.sv
  `video_scale_int`; also demos the old failures with `--show-broken`).
- CD-ROM (SCSI ID 3, OSD slot `SC4`): data, mixed-mode, and audio CDs.
  CD audio + the AppleCD Audio Player (listing, transport, FF/RW scan)
  fully working as of 2026-07-20 (standard SCSI-2 dialect on the
  CDU-8004 identity; BlueSCSI + Snow are the byte oracles; command gaps
  logged in docs/SCSI_CMD_GAPS.md). The **volume slider** works as of
  2026-07-29 (MODE SELECT/SENSE page 0x0E scales the CD-DA PCM),
  alongside 0x42 sub-channel formats 2/3, 0x44 READ HEADER, 0x45 PLAY
  AUDIO, 0xBB SET CD SPEED and mode page 0x2A — see
  the CD command notes in rtl/scsi.v.
- **★ The CD boot-attach stays ATTACHED during gates — never detach
  `MACLC.s4` as a gating step (user ruling 2026-08-09).** The open
  CUE/CHD-at-boot-attach hang fires intermittently on ANY build —
  including known-good ones — and has repeatedly been misread as "this
  build fails the hardware gate". Two boots of the same RBF can differ,
  so one boot is never a verdict: on a load hang, retry the boot rather
  than blaming the build (or detaching the CD). Flat 2048-byte images (ISO/TOAST)
  work on a stock Main_MiSTer; CUE/BIN (2352) and CHD need the Main
  fork's `support/maclc/maclc_cd` layer (branch
  `add-bluescsi-toolbox-for-MacLC`) — the validated binary ships in
  `releases/MiSTer`. The guest System needs the Apple CD-ROM extension
  (or a third-party CD driver) to mount discs. Serving law for any new
  DataIn command: transfer EXACTLY what the initiator arms (see
  docs/SCSI_CMD_GAPS.md).
- **Serial (SCC, modem port): MIDI OUT + MIDI IN + PPP all work, HW-validated**
  (OUT 2026-08-12 cozyMIDI → MidiLink/MT32-pi; PPP 2026-08-13 LCP+IPCP on
  7.5.5 incl. guest FTP; IN 2026-08-14). MIDI IN sources: HPS UART (MidiLink
  USB, always wired) and the user-port MIDI-in line (MT32-pi TX pin) — the
  latter joins guest RX ONLY in OSD UART mode = MIDI (`uart_mode==3` AND-merge
  in MacLC.sv), so PPP/console guest-receive can never be hijacked by the user
  port (the 2026-08-13 serialIn-mux lesson). v1 is channel A only; printer-port
  TX (`txd_b_out`) still dangles at dataController. Regression gate for ANY SCC
  serial/baud/FIFO edit: `verilator/tb_scc_midi.v` (build cmd in its header;
  §3 = MIDI-in RX at 31250; keep the ROM-style loopback prelude).
