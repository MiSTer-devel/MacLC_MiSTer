# Verilator sim vs. FPGA core — known differences

Living record of where the Verilator simulator (`verilator/sim.v` + the
`verilator/sim_main.cpp` C++ harness) differs from the synthesised FPGA core
(`MacLC.sv` + `sys/`). Keep this updated when you add a top-level signal, change
CPU/bus glue, or hardwire a config in one place.

**Why this matters:** `verilator/sim.v` is the Verilator top (`module emu`), NOT
`MacLC.sv`. It has its **own** CPU instantiation and bus glue (VPA / DTACK / BERR
/ overlay). All peripheral RTL is shared through `dataController_top`, but any
CPU-glue or top-level wiring fix must be made in **both** files or sim and FPGA
silently diverge. (This has bitten us before — e.g. sim once hardwired
`.berr(1'b0)`, masking the MOVES bus-error fix.)

Last audited: 2026-08-02 (sim MFM floppy detection wired — see below).

**2026-08-02 — sim floppy MFM/HD detection un-hardwired (both tops now
equivalent):** `sim.v` used to pass `.diskMFM(2'b00)/.diskHD(2'b00)` ("MFM path
not exercised"). With the ISM read engine implemented it now mirrors
`MacLC.sv`'s mount detection: `dsk_{int,ext}_{mfm,hd}` latched at download end
from the raw word count (368640 = 720K, 737280 = 1.44M) or the DC42
`disk_format` byte (word 40 low byte, values 2/3), the latter newly latched in
sim's DC42 block. `--floppy0/--floppy1 <img>` therefore exercises the full
ISM/MFM read path in sim. Remaining sim-only difference: none for floppy;
MacLC.sv additionally latches `dsk_*_ds/ss` from `dc42_disk_format` 0/1 while
sim keys GCR sizes off byte counts (+42-word DC42 variants) — same outcomes for
valid images.

**2026-06-13 — floppy byte-demux fix (both tops, kept identical):** the disk
image is packed 2 bytes/SDRAM-word; the byte returned to the track encoder must
be selected by `dskReadAddr[0]`, but both tops used `memoryAddr[0]` — which is
`dskReadAddr[1]` after addrController's `>>1` word conversion drops bit 0. Odd
disk bytes were duplicated and their even partners skipped, corrupting every GCR
data field (drive mounts, data unreadable — the long-standing "floppy read"
limitation). Fixed in `MacLC.sv` and `verilator/sim.v` identically
(`dsk_byte_odd = dskReadAckExt ? dskReadAddrExt[0] : dskReadAddrInt[0]`). Present
since core init (`93cf1ad`). NB: a separate 16 MHz IWM read-timing risk may still
affect reads — to be evaluated on HW after this fix.

**2026-06-12 — intentional FPGA-only additions (cold-load reset hardening):**
all in `MacLC.sv` / `rtl/sdram.v`, none applicable to sim:
- `rom_loaded` latch: system reset is held from FPGA config until the first
  boot0.rom download (dio_index 0) begins, closing the window where the 68k
  executed the previous core's leftover SDRAM contents. Sim preloads/streams
  the ROM immediately and its RAM model initialises clean, so no equivalent
  is needed in `sim.v` (its `n_reset` block already gates on `dio_download`).
- `pll_locked` 2-FF synchroniser (`pll_locked_s`) feeding the reset block and
  PRAM FSM. Sim's `pll_locked = !reset` is already synchronous.
- `sdram_reinit` pulse (user resets R0/R6/core button → content-preserving
  SDRAM re-init) + JEDEC-robust init ladder in `rtl/sdram.v` (100 µs wait,
  precharge-all, 8× auto-refresh, MRS). `rtl/sdram.v` is not compiled by the
  Verilator build at all (sim.v has its own RAM model).

**2026-06-11 — selectASC divergence FIXED (was a real FPGA-only bug):**
`sim.v` connected `.selectASC(selectASC)` on its addrController instance;
`MacLC.sv` NEVER did — the wire floated to GND on hardware, so ASC register
access was dead on FPGA while sim audio worked. Found when the new probe deck
made the dangling net visible (Quartus warning 12110). Both tops now connect it.

**2026-06-11 — intentional FPGA-only addition:** `rtl/dbg_probes.sv` (JTAG
In-System probes, `docs/jtag_probes.md`) is instantiated ONLY in `MacLC.sv` —
`altsource_probe` is an Altera primitive and must never reach Verilator. The
probe FEED wires exist in both tops (ncr5380 `dbg_ncr`/`dbg_ncr2`/`dbg_wr`
through `dataController_top`); sim.v ties them off explicitly.

---

## ✅ Shared / verified identical

These must stay identical; they were checked and match today.

- **All peripheral RTL** — instantiated once in `dataController_top` (used by both
  tops): VIA, pseudovia, V8 video, Ariel DAC, IWM/SWIM, SCC, NCR5380/SCSI, ASC,
  the Egret HC05 wrapper, and **`adb_device` (ADB kbd+mouse) + the ADB
  open-collector loopback + the SCSI upper-byte write fix**.
- **CPU bus glue (both tops, byte-identical):**
  - `cpu_berr = fc7_berr && !_cpuAS`
  - `_cpuVPA  = fc7_iack ? 0 : (fc7_berr ? 1 : ~(!_cpuAS && cpuAddr[23:21]==3'b111 && !selectVRAM))`
  - `_cpuDTACK= fc7_berr ? 1 : (~(!_cpuAS && (cpuAddr[23:21]!=3'b111 || selectVRAM)) | !dtack_en)`
  - `dtack_en` always-block, `fc7_berr`, `fc7_iack`, `overlay_trigger`,
    `memoryOverlayOn`.
- `ram_config_phys` wiring; pseudovia address `.addr({cpuAddr[12:1], tg68_a[0]})`
  (the old sim-only A0 fix is now matched).
- `CE_PIXEL = v8_ce_pix` (the old "hardwired 1" pixel-doubling bug is fixed in both).
- `ps2_key` / `ps2_mouse` are wired into `dataController_top` in both → the ADB
  device gets real input on sim **and** FPGA.

## ⚠️ Intentional differences (reduced sim coverage, not bugs)

| Thing | Sim (`sim.v`) | FPGA (`MacLC.sv`) | Consequence |
|---|---|---|---|
| RAM size | `configRAMSize = 8'h24` (2 MB, hardwired) | `status[4] ? 8'hE4 : 8'h24` (2 MB / 10 MB) | **10 MB / SIMM path never exercised in sim** |
| Monitor ID | `v8_monitor_id = 4'h6` (640×480, hardwired) | `status[11:10]`-selected | **Other resolutions are FPGA-only** |
| `clk_sys` | 32 MHz from the testbench | PLL `outclk_1` | same frequency; no functional diff |
| Debug HUD / ports | absent | Row-M overlay, `*_dbg_*`, `selectUnmapped`, `synthesis keep` taps | FPGA-only observability; harmless |
| Framework | bespoke C++ harness (`sim_main.cpp`) | `sys/` (HPS I/O, HDMI/scaler, OSD, audio out) | sim has no HPS/HDMI/scaler |
| PRAM NVRAM persistence | `dataController_top` `pram_*` ports tied off (`pram_load_wr=0`, `pram_save_addr=0`, outputs open) | FSM in `MacLC.sv` (SD slot 2 save image, load-on-mount / flush-on-OSD / Reset PRAM&Core) drives them | **PRAM save/restore is FPGA-only**; sim still boots with `egret.pram` (zeros). The Egret `pram[]` mirror + `pram_load_*/save_*` ports in `egret_wrapper.sv` are shared and identical. |
| CD-ROM (SCSI ID 3) block-device slot | sim block-device **slot 2** (`--cdrom <iso>`; `sd_*[2]`, `img_mounted[2]`), `cd_enable` hardwired 1 | hps_io **slot `VD_CDROM`=4** (`SC4` OSD entry), `cd_enable = ~status[18]` (OSD "CD-ROM Drive") | Same `dataController_top` `cd_*` ports both sides; only the slot index and the enable source differ. Sim boots with the disc-less CD target answering the ROM SCSI scan (regression for the 2026-06-10 empty-CD wedge class). |

## 🔴 Inherent gap — keep in mind

- **Memory model:** sim uses `sim_ram` (ideal, zero-latency block RAM); the FPGA
  uses the real `sdram` controller with bus-slot latency. **A design that boots
  in Verilator can still fail on hardware for SDRAM timing/latency reasons.**
  Historically real here (stale-read / DTACK-before-cpu-slot issues). "Boots in
  sim" ≠ "boots on FPGA" for anything timing-sensitive on the memory bus.

## Host-input harness (sim only)

`sim_main.cpp` drives `ps2_key`/`ps2_mouse` from the host (SDL):
- Keyboard: host keys → `ps2_key` (Scan-Code-Set-2; the ADB device translates).
- Mouse: click the VGA image to capture (SDL relative mode; Esc/F1 to release);
  motion/left-click → `ps2_mouse` with X/Y sign bits set. Arrow keys + A/B are a
  fallback when not captured. On FPGA these come from the HPS (USB) instead.

## CD audio (2026-07-16)

`dataController_top` gained `cd_snd_l/r` (CD-audio PCM from the SCSI CDROM
target's cd_audio engine). `MacLC.sv` mixes them into AUDIO_L/R (half gain,
saturating); `sim.v` leaves them unconnected (PINMISSING is waived) — sim CD
mounts also read garbage from the TOC-blob window (the sim blockdevice has no
HPS windows), so the engine takes its synthesized single-track fallback there.

## Maintenance checklist (when editing the core)

1. Touching CPU/bus glue (BERR/VPA/DTACK/overlay/IPL)? Edit **both** `sim.v` and
   `MacLC.sv`, then re-diff the assignments.
2. Adding a top-level config (RAM size, monitor, CPU speed)? Decide the sim's
   fixed value and note it here.
3. Adding a `dataController_top` port? It propagates to both tops automatically —
   only the connections in each top differ.
4. Re-run the audit (compare instantiations + the glue assignments) and update
   the "Last audited" date above. See `docs/mame_compare.md` for ground-truth checks.
