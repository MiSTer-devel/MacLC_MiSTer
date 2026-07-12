# Resume — SCSI CD-ROM at ID 3 (branch `add-scsi-cdrom`) — 2026-07-12

Mission: CD-ROM drive on SCSI ID 3 with **.iso / .bin+.cue / .toast / .chd**
support, surfaced in the OSD. Plan of record: `docs/plan_scsi_cdrom.md`
(STATUS block at top reflects this implementation).

## What exists (this session)

### Core (`add-scsi-cdrom`, cut from master @ dd4d4da)
- `rtl/scsi.v` — `CDROM` parameter on the proven disk target. CDROM=0
  constant-folds to the pre-CD netlist (both disk instances untouched);
  CDROM=1 = read-only 2048-byte-block AppleCD drive. MAME
  `nscsi_cdrom_apple_device` (`../mame/src/devices/bus/nscsi/cd.cpp`) is the
  byte oracle: SONY CDU-8002 INQUIRY (54 B), READ CAPACITY 2048, READ 6/10
  (lba/tlen <<2 at latch time → ring machinery unchanged in 512-byte units),
  Apple vendor TOC 0xC1 (BCD/MSF; leadout MSF from a mount-time divider FSM),
  0xC2 subcode, 0xCC audio status (VOID), 0xC0 eject (drops `mounted`; OSD
  remount = insert), 0xC8-0xCD stubs, 0xCE payload discard, MODE SENSE
  WP+2048 (+page 0x30 apple_magic), sense 0xB0 no-disc / 0x3A post-eject /
  ILLEGAL on writes, PREVENT/ALLOW honored.
- `rtl/ncr5380.sv` — `cdrom_target` instance (ID 3, `RING_LOG=3` = 4 KB ring;
  M10K budget is near-full at the disks' RING_LOG=5). Supersedes the
  never-enabled `scsi_empty_cd` stub (module kept, no longer instantiated).
  `ENABLE_EMPTY_CD` parameter removed.
- `MacLC.sv` — slot `VD_CDROM=4`, `VDNUM=5`; OSD `SC4,ISOTO*CUEBINCHD` +
  `OI,CD-ROM Drive,Enabled,Disabled` (status[18], default Enabled).
  **Disabled = ID 3 never answers selection = exact pre-CD bus** (the A/B
  lever if HW misbehaves). `TO*` is how `.toast` matches (Main extension
  match is exact on ≤3 chars, wildcard `*` supported).
- `verilator/sim.v` + `sim_main.cpp` — CD on **sim slot 2** (`--cdrom <iso>`),
  `cd_enable` tied 1 (so every sim boot regression-tests the disc-less CD
  answering the ROM SCSI scan — the 2026-06-10 empty-CD wedge class).
  `docs/verilator_differences.md` updated (slot 2 vs FPGA slot 4).

### Main_MiSTer (fork branch `add-bluescsi-toolbox-for-MacLC` @ 1df25b7)
- `support/maclc/maclc_cd.{h,cpp}` + `user_io.cpp` hooks (`SD_TYPE_MACCD`):
  on mounting slot 4 for the MacLC core, `.chd` (libchdr via
  `support/chd/mister_chd`, first data track) and `.cue`(+bin) and raw-2352
  images are served as a **flat 2048-byte-sector virtual disc**; reported
  img_size = data sectors × 2048. Flat 2048 images (.iso/.toast/2048-bin)
  return PASSTHRU → generic path, zero new risk. Compile-gated with
  `make BASE=arm-linux-gnueabihf bin/support/maclc/maclc_cd.cpp.o
  bin/user_io.cpp.o` (Ubuntu cross gcc; deployable binary should come from
  the usual toolchain/docker so glibc matches the MiSTer image).
  NOTE: the user's uncommitted toolbox WIP (toolbox.cpp/h + one user_io.cpp
  hunk switching to `toolbox_shared_ready()`) is intentionally NOT in the
  commit — left in the working tree.

## Gates run
- Quartus A&E: 0 errors (cdrom_target elaborates, CDROM=0/1 params
  confirmed in map.rpt).
- Verilator: parse + full build clean; boot run(s) — see session summary
  for the frame-350 screenshot verdict + SCSI trace.
- Full Quartus compile: kicked off this session (`build_cdrom.log`);
  final rebuild needed for the last data_len tweak (TOC alloc clamp) —
  check `git log` vs the RBF before deploying.

## HW test plan (next session)
1. Deploy RBF (dated+hashed name per convention) to .143; keep ONE
   launchable rbf. Stock ROM + known-good 7.1/7.5.5 HDD image.
2. **Regression first**: no CD mounted, CD-ROM Drive = Enabled → boot to
   desktop must be provenance-clean (the ROM scan now selects ID 3 and
   gets INQUIRY/no-disc; on HW this is the new codepath).
   If anything smells: OSD CD-ROM Drive → Disabled = pre-CD bus (A/B).
3. Mac side: System needs **Apple CD-ROM extension** in the booted System
   Folder (7.x: CD-ROM Setup/"Apple CD-ROM" INIT) — or FWB CD-ROM ToolKit.
   The stock extension binds because of the SONY CDU-8002 INQUIRY.
4. Mount a small ISO via OSD → within ~2 s the driver's TUR poll should
   see it; desktop shows the volume. Test: ISO (stock Main OK), then on
   the fork build: .toast, .cue+bin (2352), .chd.
5. Eject via Finder (Special > Eject / drag to trash) → 0xC0 → volume
   goes away; OSD remount = insert next disc.
6. Watch the wedge surfaces: the AppleCD driver TUR-polls ~1/s FOREVER —
   these polls now interleave with HDD traffic on the same bus. The #2
   (DMA stall) and #3 (CSR bit6 read) classes have new traffic patterns.
   `dbg_scsi*` probes still only decode targets 0/1; the CD target's dbg
   ports are unconnected (add an ISSP mux if it needs eyes).

## Known gaps / deliberate deferrals
- CD audio (0xC8-0xCE real playback, CDDA into ASC mixer): plan Phase 3.
- Multi-track/multi-session: first data track only (Mac data discs).
- READ(12), MMC 0x43 TOC: not implemented (Apple driver doesn't use them).
- Sim `--cdrom` run requires the sim_main.cpp rebuild that landed AFTER
  the first background build this session (see summary).
- `releases/` RBF: stage from `output_files/MacLC.rbf` after the FINAL
  rebuild (post-TOC-clamp).
