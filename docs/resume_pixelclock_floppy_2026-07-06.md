# Resume — pixel-clock BERR fix (HW-unverified) + floppy 800K during-insert capture (2026-07-06 PM)

You are picking up MacLC_MiSTer right after the **pixel-clock hardware A/B** and
the **first `.143` floppy reproduction**. Power is BACK; `.143` is live. **Read
this whole doc first.** Predecessors: `docs/resume_floppy_and_video_2026-07-03.md`
(hardware crib), `docs/findings_floppy_lbmactwo_diff_2026-07-06.md` (floppy source
of truth — encoder EXONERATED), `docs/findings_mame_floppy_groundtruth_2026-07-02.md`
(the 800K byte-stream reference to diff against).

- **Branch:** `new-disk-features` @ `78e484c`. Nothing pushed; the user pushes.
  Today's commits: `a1a879b` (floppy probes+IWM hardening), pixel-clock trilogy
  `1adb2a0`→`56b9888`, and `78e484c` (★ the BERR fix below).
- **Gate/build flow unchanged:** A&E (`quartus_map --analysis_and_elaboration
  MacLC`, 0 err/64 warn) → `bash scripts/build_only.sh` (~21 min) → SCSI gate
  (`quartus_sta -t scripts/check_scsi_timing.tcl`, PASS ≥ +0.5 ns). `MacLC.qsf`
  shows modified — leave it.

## ★ PIXEL CLOCK — FIXED & HW-VALIDATED (task #6 CLOSED)

Build `78e484c` gated (STA +0.165 ns, SCSI 27.5 ns), staged
`releases/MacLC_Unstable_20260706_78e484c.rbf` (md5 `5c2df507`), deployed to
`.143`, and **booted CLEAN to the 7.1 desktop**: `berr_fires=0`, `boot_inits=2`,
`max_stall=8.11 ms` (= the a1a879b healthy baseline; the storming 56b9888 was
255 / 8 / 250 ms). No color artifacting (the bad build froze with garbage at the
screen bottom). The static-config-IS-the-VGA-rate fix is confirmed: a VGA boot
does zero PLL reconfig, so CLK_VIDEO no longer glitches during the HPS mount.
VGA now scans at 25.175 MHz → 59.94 Hz. `78e484c` is the **sole launchable** RBF
on the box. `(PFR frozen=1 BERR-NEAR-DEATH is the known false-alarm probe —
counts routine $8 vector reads; PSDT berr_fires is the authoritative signal.)`

**Left to verify at leisure (non-blocking):** (a) the OSD **12"↔VGA switch**
actually reconfigs cleanly mid-session (C0 45↔28) without a wedge — the only
runtime-reconfig path that still fires; (b) eyeball VGA refresh on a real monitor
/ the ascal report to confirm 59.94 Hz. Neither blocks floppy or QuickDraw.

## ★ WHAT WAS FOUND & FIXED THIS SESSION (do not re-derive)

**The 56b9888 pixel-clock build BERR-storms on HW; root cause = boot-time PLL
reconfig.** Deterministic on `.143`, cold AND warm: `PSDT berr_fires=255`,
`max_stall ~250 ms`, `PRC0 boot_inits=8`, CPU wedged fetching I/O space
(`PIFA F0xxxx`), `PFR cause=BERR-NEAR-DEATH`. The reconfig FSM retargets C0
from the static value to the OSD-selected rate ~100-500 ms after core load —
that PLL unlock/relock **glitches CLK_VIDEO exactly while the HPS is mounting SD
images and ascal is locking**, collapsing SCSI serving into 250 ms DMA stalls →
the stall watchdog BERR-storms → TG68 unrecoverable frames wedge the CPU.

**A/B PROOF (both on `.143`, JTAG probes):**
| Build | pixel clock | berr_fires | boot_inits | result |
|---|---|---|---|---|
| `a1a879b` | no (16.25 MHz) | **0** | **2** | boots clean to desktop |
| `56b9888` | reconfig at boot | **255** | **8** | hard wedge, both cold+warm |

**FIX (`78e484c`, HW-UNVERIFIED):** static PLL config IS the VGA rate
(C0=28 / 25.175 MHz) and the FSM change-detect **inits to that same value**, so
a VGA boot performs **zero** reconfig. An OSD switch to 12" RGB (C0=45, slower
than the 25.175 STA constraint = safe) still reconfigs — mid-session, long after
mount. Portrait (C0=12, faster) stays unwired; restore a /12 static constraint
before ever exposing it. Memory: `[[pixel-clock-implemented]]`.

**Rule learned:** no MiSTer core reconfigs its CLK_VIDEO PLL mid-stream during
boot. pll_hdmi reconfig is sys_top-coordinated; ao486 retargets its *system*
PLL, not CLK_VIDEO. Keep CLK_VIDEO static across the HPS mount window.

### If it STILL wedges after 78e484c
The glitch-during-mount theory is then incomplete. Next suspects, in order:
(a) the *initial* PLL lock itself (even static) races the mount — try holding
`RESET_n`/video-domain reset until `pll_video_locked` has been stable N ms, or
gating the framework video reset on lock; (b) a CDC in `536a0a3` feeding a
CPU-visible path — audit the clk_vid→clk_sys VBL/HBL 2FF (pseudovia VBL IRQ) and
the `words_per_line` crossing into addrController VRAM packing; (c) fall back to
`a1a879b` (no pixel clock) and ship floppy/QuickDraw without it. The `*_meta`
syncs are false-pathed in MacLC.sdc; `emu|pllv|*|divclk` is its own async clock
group (added `56b9888`).

## ★ FLOPPY — 800K "unreadable" REPRODUCED on the healthy build (real bug, NOT a .188 artifact)

Mounting `Disk605.dsk` (clean raw 800K, in `games/MACLC/`) as Pri Floppy on
`.143`/`a1a879b`/7.1 → **"This disk is unreadable: Do you want to initialize it?
[Eject] [One-Sided] [Two-Sided]"**. That dialog = the 800K GCR failure (the
MFM/HD failure is a differently-worded "One-/Two-Sided" dialog). So the July-2
`.188` verdict was NOT a test artifact — 800K is genuinely broken, and F3's
routing fix did not cure it. The encoder is still exonerated (byte-identical to
lbmactwo, `findings_floppy_lbmactwo_diff`), so the bug is **dynamic** — in
delivery/timing or byte-stream content, which is exactly what the probes read.

**This session's capture was POST-FAILURE (inconclusive on its own):** the dialog
was already up before sampling. Across 22 samples `PFL0 byte_cnt` sat frozen at
**7011** (`+0/s`), `miss_cnt=0`, classified **IDLE (no RDDATA polling)**;
`PFL1 step_cnt8=0`, `iwm_latch=FF`, but `disk_data` **cycled through valid 6&2
GCR codes** (96, D9, 9F, CF, F2, DA…) → SDRAM fetch + encoder are alive; the OS
had already given up. 7011 bytes ≈ a few tracks of address-field reads before
rejection ⇒ consistent with **wrong byte-stream content**, but unproven until
captured live.

### ★ IMMEDIATE FLOPPY NEXT ACTION (the decisive capture)
The dialog is UP on `.143` now. To catch the read in-flight:
1. Arm the sampler: `for i in $(seq 1 15); do bash scripts/read_probes.sh 2>&1 |
   grep -E "PFL0|PFL1"; done` (run in background; ~7 s/sample).
2. **Have the user click `Eject`, then re-mount `Disk605.dsk` via OSD** (a fresh
   insertDisk edge is what re-fires the read; re-mounting without ejecting does
   NOT re-trigger — proven this session, byte_cnt never moved on re-mount).
3. Watch for `byte_cnt` **climbing** and `step_cnt8` **incrementing** (seek) with
   `side` toggling. Then decide:
   - **byte_cnt climbs, disk stays unreadable** → byte-stream CONTENT bug. Diff
     the delivered stream against the MAME reference: address mark
     `D5 AA 96 96 9A 96 D9 D6 DE AA`, FORMAT byte `$22`, from
     `scratch/mame_floppy_0702/data_reads_800k.txt.gz` (seq 564693+). Add a
     PFL2 shift-register probe (capture N consecutive delivered bytes) if PFL1's
     single `disk_data` byte isn't enough.
   - **byte_cnt frozen while OS polls (miss_cnt climbs)** → DELIVERY starvation:
     revisit the `driveReadDataSelected && _enable==0` gate that MacLC dropped
     vs lbmactwo (`swim.v` floppy delivery), and the SDRAM read-race phase
     (lbmactwo's `ce_p_div2` T3 latch; ours passes `clk8_en_p/n` straight —
     audited N/A but re-check under live timing).
   - **step_cnt8 stays 0 / no RDDATA polling at all** → drive-ID still mis-routing
     (the OS isn't taking the GCR path); re-examine sense reg 0xF/`is_2m` on HW.

## HARDWARE STATE (as of handoff)
- **`.143`** (JTAG): running `MacLC_Unstable_20260706_a1a879b.rbf` (healthy,
  floppy probe deck), 7.1 desktop, **800K "unreadable" dialog UP** (Eject to
  clear). `s0=MacLC_7-1.hda` (restored from `.bak_71_20260702`; the live s0 had
  been a typo'd `MacLC_7-1.hdaa` → non-existent file). `s1=MacLC_6-0-8-POP.hda`
  (DATA only — soured as boot). **Sole launchable RBF = a1a879b**; `56b9888`
  (bad pixclk) + `a48c5ea` renamed `.disabled` this session (one-launchable rule
  restored). Deploy `78e484c` → it becomes sole launchable, disable a1a879b.
- **`.188`**: untouched this session; still pre-tick-fix. Lower priority.
- Launch recipe: `source scripts/local.env; python
  tools/misterdeploy/launch_unstable_core.py --push <rbf> --core <basename>
  --delay 0.3 --max-tries 3`. Screenshot: `bash scripts/grab.sh out.png`.
  Probes: `bash scripts/read_probes.sh` (JTAG, bypasses HPS — free).

## STILL PENDING (not touched — HW time went to pixel-clock A/B + floppy)
- **QuickDraw occupancy capture** (Investigation B′): user runs Speedometer Color
  Benchmarks (~3 iters) on `.143` while you sample `bushist.tcl 15` +
  `buslat.tcl 15` mid-draw. Occupancy is the verdict: ~95-100% = bus-bound
  (prefetch/I-cache fix), ~70% = TG68K-internal (task #4, the 020 cycle-count
  audit). Probe deck is IN a1a879b — can run now on the healthy build.
- **Floppy Build 2** (ISM 1.44MB engine) — unstarted; predecessor doc has the spec.

## OPEN TASKS
- #4 (pending): offline TG68K 020-mode cycle-count audit (QuickDraw prep).
- #6 (in_progress): pixel-clock BERR root-cause — fix committed `78e484c`,
  **awaiting the in-flight build + HW re-test** to close.

Memory: `[[pixel-clock-implemented]]`, `[[floppy-800k-exonerated-pfl-probes]]`,
`[[system-tick-halved-rootcause]]`, `[[scsi-fit-stabilization-mission]]`,
`[[second-mister-188]]`, `[[shared-mister-hps-exhaustion]]`,
`[[quartus-cli-rtl-validation]]`.
