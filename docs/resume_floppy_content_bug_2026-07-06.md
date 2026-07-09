# Resume — 800K floppy = byte-stream CONTENT bug (decisively captured) + ★ JTAG-crash safety lesson (2026-07-06 late PM)

You are picking up MacLC_MiSTer right after a **live in-flight JTAG capture of the
800K floppy read** that decisively classified the bug — AND after that same
capture **crashed the `.143` MiSTer**. Read the SAFETY box first, then the
finding. Predecessors: `docs/resume_pixelclock_floppy_2026-07-06.md` (pixel-clock
fix + prior floppy state), `docs/findings_floppy_lbmactwo_diff_2026-07-06.md`
(encoder EXONERATED — byte-identical to lbmactwo), `docs/findings_mame_floppy_groundtruth_2026-07-02.md`
(the 800K byte-stream reference), `floppy_content_capture_0706.log` (THE capture, repo root).

- **Branch:** `new-disk-features` @ `78e484c`. Nothing pushed; the user pushes.
  New this session (untracked): `scripts/floppy_rapid.tcl` (rapid sampler — see
  DANGER), `floppy_content_capture_0706.log`. `MacLC.qsf` still shows modified —
  leave it.
- **Gate/build flow unchanged:** A&E (`quartus_map --analysis_and_elaboration
  MacLC`) → `bash scripts/build_only.sh` (~21 min) → SCSI STA gate
  (`quartus_sta -t scripts/check_scsi_timing.tcl`, PASS ≥ +0.5 ns).

## ★★ SAFETY — the rapid JTAG sampler CRASHED the MiSTer (new lesson, obey it)

`scripts/floppy_rapid.tcl` holds ONE In-System source-probe session open and
reads PFL0/PFL1 in a tight loop for **minutes** (this run: 12000 samples ≈ 6 min,
`dly=15`), and on a transient read failure it **ends + re-enumerates + restarts**
the probe session mid-run (a reopen fired during the read burst here). **That
sustained source-probe traffic + session churn wedged `.143`.**

Corrections to the prior doc's "JTAG bypasses HPS — free" claim: a **single-shot**
`read_probes.sh` is fine, but a **minutes-long continuous source-probe session is
NOT free** — it destabilized the board. RULES going forward:
- **Never** run a multi-minute JTAG probe loop against a board you need stable.
- Keep any live JTAG capture to **seconds**, bounded (`n` small), no session reopen.
- For a long byte stream, move the capture **on-chip** (small BRAM ring that
  records N delivered bytes on the first post-insert read) and read it out in ONE
  short JTAG burst — do NOT stream over JTAG for minutes.
- **First action next session:** power-cycle `.143`, relaunch `a1a879b`, and
  re-validate healthy (boot to 7.1 desktop; `read_probes.sh` ONCE → `PSDT
  berr_fires=0`, `boot_inits=2`, `max_stall < ~10 ms`) BEFORE trusting any read.
- Fold this into memory `[[shared-mister-hps-exhaustion]]` and
  `[[floppy-800k-exonerated-pfl-probes]]`.

## ★ THE DECISIVE FINDING — 800K read is a byte-stream CONTENT bug on track 0

Mounting `Disk605.dsk` (clean raw 800K, `games/MACLC/`) as Pri Floppy on
`.143`/`a1a879b`/7.1 → "This disk is unreadable" — **captured live** with the new
rapid sampler (`floppy_content_capture_0706.log`, ~32 samples/s). Timeline
(PFL0=`{byte_cnt[31:16],miss_cnt[15:0]}`, PFL1=`{trk[31:25],side[24],lat[23:16],step_cnt[15:8],disk_data[7:0]}`):

| phase | samples / t | byte_cnt | miss | trk/side/step | reading? |
|---|---|---|---|---|---|
| idle (pre-mount) | 0–1200 / 0–41 s | ~2261→2272 frozen | 0 | 0 / 1 / 0 | no |
| **READ BURST** | 1210–1385 / 41.3–50.7 s | **explodes, wraps ×2+** | **0** | **0 / 0 / 0** | **YES** |
| give-up | 1385+ / 50.7 s+ | frozen @ 9742, lat→FF | 0 | 0 / 0 / 0 | no → dialog |

Read burst detail: `byte_cnt` climbs ~1900–2000 bytes per 32 ms sample (~60 kB/s
peak), through the 16-bit range with **multiple wraps** (…31504→wrap→8008→31591→wrap→1517→9742).
Total ≈ **~138 kB streamed in ~9.4 s ≈ ~12 tracks' worth of GCR** — and **every
byte came off track 0** (`trk=0`, `step_cnt8=0` the entire time: the head **never
stepped**), `side=0`, `miss_cnt=0` throughout. Then the OS froze `byte_cnt` and
rejected the disk.

**Interpretation (high confidence):** the OS took the GCR read path, read ~12
tracks' worth of bytes off track 0 with **flawless delivery** (`miss=0`, free
~60 kB/s climb), **never achieved a valid/syncable track format**, never advanced
past track 0, and declared the disk unreadable. This capture **DEFINITIVELY**:
- **EXONERATES delivery/starvation** — `miss_cnt=0`, `byte_cnt` climbed freely.
- **EXONERATES drive-ID mis-routing** — the OS clearly took the GCR read path
  (side-select, drive-enable, heavy sustained reads).
- **PINS the bug on the CONTENT/framing of the delivered GCR stream on track 0** —
  the address marks / GCR nibblization / sync+gap framing don't match what the
  ROM's IWM reader expects, so it can't byte-sync → can't validate → rejects.

Reconciles with the encoder being byte-identical to lbmactwo ONLY if the defect
is **dynamic**: delivery TIMING/phase causing the IWM to latch at the wrong bit
boundary, or wrong inter-sector **sync/gap** bytes so byte-sync never locks, or a
track-0-specific framing issue. `byte_cnt` counts DELIVERED bytes (SDRAM→IWM) —
high — but whether the IWM achieves **bit/byte SYNC** on them is the open question.
The single `disk_data` snapshots showed legal GCR (≥0x96) **and** 00/FF (gap/sync);
one byte at a time can't confirm the address-mark sequence.

## ★ IMMEDIATE NEXT ACTION — capture the CONSECUTIVE byte stream, diff vs MAME

Goal: get the actual **delivered byte SEQUENCE on track 0** and look for the
address mark `D5 AA 96 96 9A 96 D9 D6 DE AA` and FORMAT byte `$22`, then diff
against MAME `scratch/mame_floppy_0702/data_reads_800k.txt.gz` (seq 564693+; also
`decoded_800k_v3.txt`). **Do this ON-CHIP, not via a long JTAG loop (see SAFETY).**

RTL sketch (all A&E-gated, then one ~21-min build):
1. `rtl/floppy.v` (~L305–319, where `dbg_byte_cnt` increments on the delivery
   strobe): add a **byte-capture ring** — on each delivery strobe write
   `disk_data` into a small BRAM (e.g. 512×8) indexed by a counter that **arms on
   the insertDisk edge and stops when full**. (Or, minimal first cut: a 4-deep
   shift reg `dbg_flp_last4 <= {last4[23:0], disk_data}` for a 32-bit PFL2 window
   — cheaper, but only 4 bytes/JTAG-read, so you'd still need several SHORT reads.)
2. Thread the new signal(s) through `rtl/swim.v` → `rtl/dataController_top.sv`
   (mirror the existing `dbg_flp_byte_cnt`/`dbg_flp_disk_data`/`dbg_flp_step_cnt`
   ports at `dataController_top.sv:149`, `swim.v:89`).
3. `rtl/dbg_probes.sv`: add an `altsource_probe` with `.instance_id("PFL2")`,
   `.probe_width(32)` (deck is 15 instances; LBMacTwo JTAG-hub ceiling ~20 → room).
   For the BRAM-ring readout, add a small source-driven address + a probe for the
   data word so one JTAG session sweeps the ring in a few reads.
4. `scripts/cpu_state.tcl`: decode PFL2 (split 32b → 4 bytes b0..b3), or a ring
   dump loop (SHORT).
5. Deploy the new RBF as sole launchable; power-cycled board; mount `Disk605.dsk`;
   ONE bounded capture; reconstruct the stream; diff vs MAME. Then decide:
   - **Address mark present but sectors/checksums wrong** → nibblization/CRC bug.
   - **No `D5 AA 96` sync anywhere** → sync/gap framing wrong → IWM never locks
     (matches "reads 12 tracks off track 0, never syncs"). Re-examine the
     bit-cell / gap encoding in `floppy_track_encoder.v` and the delivery phase.

## HARDWARE STATE (post-crash)
- **`.143` CRASHED** by the rapid sampler (see SAFETY). Power-cycle + re-validate
  before ANY reading. Loaded RBF was `MacLC_Unstable_20260706_a1a879b.rbf`
  (healthy floppy-probe deck); `78e484c` (pixel-clock fix, HW-validated clean
  earlier today) is staged in `releases/`. `s0=MacLC_7-1.hda` (7.1 desktop).
  `Disk605.dsk` (games/MACLC/) reproduces "unreadable" on a fresh mount.
- **`.188`:** untouched, pre-tick-fix, lower priority.
- Launch: `source scripts/local.env; python tools/misterdeploy/launch_unstable_core.py
  --push <rbf> --core <basename> --delay 0.3 --max-tries 3`. Screenshot:
  `bash scripts/grab.sh out.png` (HPS API — fine). Probe: `bash scripts/read_probes.sh`
  (single-shot JTAG — OK). **`scripts/floppy_rapid.tcl` — SHORT runs only, if at all.**

## STILL PENDING (unchanged)
- **Pixel clock (#6):** HW-validated CLEAN (`78e484c`, `berr_fires=0`, boots to
  desktop, no artifacting; VGA→59.94 Hz). Non-blocking leftovers: OSD 12"↔VGA
  switch reconfigs cleanly mid-session; eyeball 59.94 Hz. `[[pixel-clock-berr-rootcause]]`.
- **QuickDraw occupancy (B′):** user runs Speedometer 3.23 (on the 7.1 desktop)
  while you sample `bushist.tcl` + `buslat.tcl` — but per SAFETY, do these as
  SHORT bounded JTAG captures, not loops. ~95–100% = bus-bound; ~70% = TG68K
  (task #4). `[[system-tick-halved-rootcause]]`.
- **Floppy Build 2 (ISM 1.44MB):** unstarted; spec in the predecessor docs.
- **Task #4:** offline TG68K 020-mode cycle-count audit (QuickDraw prep — offline,
  safe to do anytime).

Memory: `[[floppy-800k-exonerated-pfl-probes]]` (UPDATE with content-bug verdict +
JTAG-crash lesson), `[[shared-mister-hps-exhaustion]]` (UPDATE: minutes-long
source-probe session is NOT free), `[[pixel-clock-berr-rootcause]]`,
`[[system-tick-halved-rootcause]]`, `[[second-mister-188]]`,
`[[quartus-cli-rtl-validation]]`, `[[mfm-1440-floppy-implemented]]`.

---

## ★ 2026-07-06 (late-late PM) — CAPTURE RING IMPLEMENTED (on-chip, per SAFETY)

The "IMMEDIATE NEXT ACTION" above is **built** (this session), with one design
change from the sketch: **no PFL2/PFL3 instances.** The real hub is ~40 nodes
(dbg_probes.sv PBH0 comment: name table already reads back corrupted; the "deck
is 15" claim above was stale) — so the ring hides behind the **existing PFL1**
node, widened to `source_width(11)`. Existing tooling is unaffected (source
resets to 0 = live PFL1 layout).

**RTL (4 files):**
- `rtl/floppy.v` — `dbg_byte_stb`: same-cycle delivery strobe, identical
  qualification to the `dbg_byte_cnt` increment. MUST be same-cycle: the
  delivery block latches `diskImageData` into `diskDataIn` and ZEROES it on the
  same edge (a one-cycle-late change-detect capture would read 00s).
- `rtl/swim.v`, `rtl/dataController_top.sv` — thread `dbg_flp_byte_stb` up
  (mirrors the existing dbg ports; dangling on floppyExt, internal drive only).
- `MacLC.sv` — 256×32 BRAM ring (1 M10K) + 4-byte assembler + arm/done FSM +
  PFL1 probe mux. `source = {arm[10], sel[9:8], addr[7:0]}`; sel 0=live,
  1=ring word (4 bytes, [7:0]=earliest), 2=status
  `{8'hB5, done, capturing, 2'b00, arm_cnt[3:0], 6'd0, wptr[9:0]}`.
  Arm edge restarts the capture; full at 1024 bytes (~20 ms into the burst).

**Reader: `scripts/floppy_ring.tcl`** (arm | status | dump [outfile]) — ONE
bounded session per action, ~5 s dump sweep, NO mid-run reopen (aborts on
failure instead — the reopen loop is what crashed the board). Dump writes a
hexdump + flat hex and auto-scans: FF sync runs, `D5 AA 96` / `D5 AA AD`
marks, `DE AA` epilogues, malformed `D5 AA ?x`, bytes <0x80; prints a verdict
hint (no marks ⇒ framing broken; marks present ⇒ diff fields/checksums vs
MAME `scratch/mame_floppy_0702/decoded_800k_v3.txt`).

**HW protocol (~5 board-minutes):**
1. `source scripts/local.env && python tools/misterdeploy/launch_unstable_core.py
   --push releases/MacLC_Unstable_20260706_<hash>.rbf --core <same name>
   --delay 0.3 --max-tries 3` (sole launchable; watch the stale-MACLC-rbf trap)
2. Boot 7.1 desktop → `bash scripts/grab.sh boot_check.png` →
   `bash scripts/read_probes.sh` ONCE → PSDT berr_fires=0, boot_inits=2.
3. `quartus_stp_tcl -t scripts/floppy_ring.tcl arm`
4. Mount `Disk605.dsk` as Pri Floppy via OSD (user did this step last session);
   wait for the "unreadable" dialog (~50 s).
5. `quartus_stp_tcl -t scripts/floppy_ring.tcl dump` → verdict scan; diff
   offline vs MAME. Re-arm + eject/remount for additional 1 KB windows.

**Board state at session end:** `.143` was power-cycled after the crash
(up, ssh OK) but is running **MacLCii** (bootcore is commented out ⇒ somebody
launched it deliberately ~21:00) — board treated as CLAIMED by the user /
LC II session; nothing deployed, JTAG untouched. Deploy when the user frees it.
