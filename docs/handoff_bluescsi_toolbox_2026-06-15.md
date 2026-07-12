# Handoff — BlueSCSI Toolbox (core + HPS), 2026-06-15

Resume point for the BlueSCSI Toolbox feature: let the guest Mac copy files
to/from a host **shared folder** via the BlueSCSI "SD Transfer" client. Built
**core-side (FPGA RTL) first, then the HPS handler in `Main_MiSTer`**, and
they meet over a frozen transport contract.

---

## ▶ RESUME HERE (the immediate next step)

Everything for a first **HW co-test of the DataIn (download) path is built and
the core is staged**, but **not launched and the HPS binary is not deployed**.
To run the co-test:

1. Deploy the custom HPS binary (backup first — it's the system binary):
   `cp /media/fat/MiSTer /media/fat/MiSTer.bak` on the device, then scp
   `../Main_MiSTer/bin/MiSTer` → `/media/fat/MiSTer`. Reboot to load it.
2. Set **`SHARED_FOLDER=/media/fat/shared`** in `MiSTer.ini` (or `MacLC.ini`) and
   drop **a few small ASCII-named files** there (**≤12 files, ≤512 B each** — the
   RTL serve is single-block for now; bigger overflows the 512 B buffer).
3. Launch the staged core: `bash scripts/deploy_screenshot.sh` (reboot + OSD
   select) or pick `_Unstable → MacLC.rbf` from the OSD.
4. Mount a disk on **SCSI-6** (ID 6 = the primary/Toolbox target).
5. On the Mac, run **BlueSCSI SD Transfer** → expect device detection (SNOW
   vendor + page 0x31) and **COUNT / LIST / small-GET** to work.

This is the **first functional test of the round-trip** — its byte-lane order,
`tb_ack` handshake, and status-latch timing are a *first cut* modelled on the
disk path and have never run. Treat failures as expected-to-debug; the
JTAG `dbg_*` probes and `printf`s are the visibility.

---

## State of the repos

**`MacLC_MiSTer` @ `new-disk-features`** (committed, NOT pushed):
- `e3824a6` — MacLC.qsf: register dbg_probes/mfm_track_encoder/vram_bram (pre-existing, unrelated).
- `9af7a04` — **BlueSCSI Toolbox core-side**: scsi.v (M0+M1), ncr5380.sv, dataController_top.sv, MacLC.sv, rtl/scsi_vendor.vh, docs/BLUESCSI_{CORE_HPS_CONTRACT,MISTER_MAIN_PLAN}.md.

**`../Main_MiSTer` @ `add-bluescsi-toolbox-for-MacLC`** (committed, NOT pushed):
- `9b104d5` — **HPS handler**: toolbox.cpp/.h (new) + user_io.cpp/.h.

**Local-only / uncommitted:**
- `rtl/scsi_vendor.vh` is edited to `"SNOW    "` and **skip-worktree'd** (so it
  won't commit; git shows clean). The committed value is `"MiSTer  "`. Revert
  with `git update-index --no-skip-worktree rtl/scsi_vendor.vh && git checkout rtl/scsi_vendor.vh`.

**Built artifacts (not committed; gitignored):**
- `output_files/MacLC.rbf` — full Quartus compile, **SNOW vendor + M1 RTL**,
  timing **met** (worst setup slack +0.472 ns), 0 errors. **STAGED** on the
  MiSTer at `/media/fat/_Unstable/MacLC.rbf` (md5-verified), **not launched**.
- `../Main_MiSTer/bin/MiSTer` — ARM binary built in WSL with the Linaro
  `arm-none-linux-gnueabihf` toolchain (glibc-safe; "GNU/Linux 3.2.0" baseline).
  Toolbox code confirmed linked in (`strings | grep -i bluescsi`). **Not deployed.**

---

## What's implemented

Read the three design docs for detail: `docs/BLUESCSI_HANDOFF.md` (protocol,
pre-existing), `docs/BLUESCSI_MISTER_MAIN_PLAN.md` (HPS plan),
`docs/BLUESCSI_CORE_HPS_CONTRACT.md` (the **frozen** transport contract — slot,
block layout, FSM, §4a graceful degradation).

**M0 — detection (rtl/scsi.v, RTL-only, works on a stock HPS):** decode
`0xD0–0xD9` as 10-byte CDBs; MODE SENSE **page 0x31** magic string; `0xD9`
DEVICE INFO; `0xD6` TOGGLE DEBUG. Gated to the **primary target ID 6** via
`parameter TOOLBOX_ENABLE` (set `i==0` in ncr5380's generate loop).

**M1 — transport (FIRST CUT, untestable until the co-test):**
- Dedicated isolated hps_io slot **`VD_TOOLBOX`=3** (VDNUM 3→4), threaded
  `scsi → ncr5380` (target 0 only) `→ dataController_top → MacLC.sv`. Disk path untouched.
- Round-trip FSM in scsi.v: `PHASE_TB` + `tb_state` (LOAD→REQ→STAT→LATCH→DATA→RDY),
  512 B byte-split buffer (`tb_buf0/1`, mirrors the disk buffer so pseudo-DMA
  pairing works), for DataIn ops **0xD0 LIST / 0xD1 GET / 0xD2 COUNT**.
  Sequence: load CDB → `tb_wr`@lba0 → `tb_rd`@lba0 (status+`0xB5` sig+len) →
  `tb_rd`@lba1 (512 B data) → serve. `tb_ready` (mount) gate → CHECK when no
  folder, so it's safe on a stock HPS.

**HPS handler (Main_MiSTer/toolbox.cpp, DataIn only):** ports
`snow/core/src/mac/scsi/toolbox.rs` — COUNT/LIST/GET against `cfg.shared_folder`.
`SD_TYPE_TOOLBOX=4`, `TOOLBOX_SLOT=3`, `is_maclc()`, poll-loop dispatch (after
the IIGS branch), and a lazy one-shot auto-mount that pulses `UIO_SET_SDSTAT(1<<3)`
when MacLC is up and `SHARED_FOLDER` is set (→ latches `tb_ready` in the FPGA).
`toolbox_fill` already serves `lba>=1`, so the HPS is **multi-block ready** — only
the RTL fetch loop is single-block.

---

## What remains

1. **HW co-test** the DataIn round-trip (see RESUME HERE) — validate byte order /
   handshake / status-latch on real hardware with the Main handler.
2. **RTL multi-block fetch** (GET >512 B, LIST >12 files) — sequential `tb_rd`
   @ lba 1,2,…; HPS needs no change.
3. **SEND / upload** (0xD3/D4/D5, DataOut): RTL payload-collect + a 2nd buffer
   sector; HPS `toolbox_request` lba>=1 + a `send_file` path + `macroman_to_utf8`.
4. **Full MacRoman** table (currently ASCII + '?' stub in toolbox.cpp §utf8_to_macroman).

---

## Commands / environment

- **MiSTer**: `root@192.168.99.143`, key `~/.ssh/mister_only`, MiSTer Remote on
  `8182`. Config in `scripts/local.env` (gitignored). It is a **stock image with
  NO toolchain** — never build there. Shared box: batch SSH, don't churn.
- **Build RBF**: `quartus_sh --flow compile MacLC` (`GENERATE_RBF_FILE ON` →
  `output_files/MacLC.rbf`). Quartus CLI at `/c/intelFPGA_lite/17.0/quartus/bin64`.
- **RTL validate (no Verilator on this Windows box)**: `quartus_map.exe
  --analysis_and_elaboration MacLC` (~1 min; 0 errors / ~65 warn baseline for A&E,
  ~356 for a full compile). See the `quartus-cli-rtl-validation` memory.
- **Build Main_MiSTer**: in **WSL** with the **Linaro `arm-none-linux-gnueabihf`**
  toolchain → `bin/MiSTer`. Do NOT use Ubuntu's `arm-linux-gnueabihf-` gcc 13
  (glibc 2.39 → fails on the MiSTer). Compile-check just the changed .cpp:
  `MSYS_NO_PATHCONV=1 wsl.exe -e bash -c "... arm-linux-gnueabihf-g++ <Makefile flags> -c toolbox.cpp"`.
- **Stage/validate deploy**: `python tools/misterdeploy/launch_unstable_core.py
  --dry-run --push output_files/MacLC.rbf` (validates host/folder/core, touches
  nothing). Full launch: `bash scripts/deploy_screenshot.sh`. `_Unstable` resolves
  to `/media/fat/_Unstable`.

## Gotchas

- **Never commit a SNOW (or any foreign) vendor**: `scsi_vendor.vh` default is
  `"MiSTer  "`; local override via edit + skip-worktree. (memory: no-competitor-names-in-source.)
- Quartus `.qsf` is NOT general Tcl — `if {[file exists ...]}` → Error 125048.
  That's why the vendor override is a tracked default + skip-worktree, not a
  gitignored optional `` `include``.
- The HPS binary is the **system** firmware — back it up before swapping, reboot
  to load. The Toolbox code is gated (`is_maclc()` + `SHARED_FOLDER`) so it's
  inert for other cores.
- Timing is **marginal** (+0.472 ns) — this design has long closed timing
  tightly (memory: tg68-multicycle-timing). Re-check slack after any RTL change.
