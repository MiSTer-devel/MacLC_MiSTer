# Floppy 800K GCR — lbmactwo diff, static exoneration, PFLP probe deck (2026-07-06)

*Offline session (both MiSTers down, power outage). Supersedes the never-landed
`findings_gcr_encoder_diff_2026-07-03.md` and CORRECTS the resume doc's prime
suspect. Method: line-by-line diff of our floppy chain against
`../lbmactwo_MiSTer` (Mac II core), which the user confirms reads 800K GCR
disks correctly on hardware — same PlusToo lineage, same floppy.v/encoder
ancestry, same Sony driver family in the guest OS. Its git history documents
its own path from our exact symptom ("disk detected, data unreadable") to
working, which makes it a superior ground truth to re-deriving from MAME.*

## TL;DR

1. **The GCR track encoder is byte-identical** to the working core
   (`diff` exit 0). Zone math, 6&2 nibbler, checksums, format byte `$22`,
   sync/epilogue framing — all exonerated in one stroke.
2. **The resume doc's prime suspect was WRONG.** The track→image-offset math
   does NOT ignore zoned recording: `soff` implements the cumulative
   12/11/10/9/8 sectors/track layout correctly (verified arithmetically for
   all five zones, both sides).
3. **The killer bug class lbmactwo hit — wrong byte-lane demux — was already
   found and fixed in OUR core on June 15** (`2a2bd7c`, the `dsk_byte_odd`
   demux; comment documents the historical `0,0,3,3,4,4,7,7…` corruption) and
   **WAS in the July-2 Build 1 RBF** (`3a46a80`) that still tested
   "unreadable" on `.188` (verified via `git show` + `build_floppy1.log`).
4. **Every remaining layer audits clean** (details below). Conclusion: either
   the July-2 `.188` result is invalid (no JTAG there; the session itself
   logged "could NOT confirm whether F3's routing took"), or the residual bug
   is dynamic and needs probes. **This session built the probe deck.**

## The lbmactwo fix inventory (ac44312 "readable disks") mapped onto MacLC

| # | Their bug | Their symptom | MacLC status |
|---|---|---|---|
| 1 | RDDATA sense-address constants vs re-encoded {SEL,CA2,CA1,CA0} sense index | newByteReady never fired, IWM read zeros | N/A — we kept the legacy {ca2,ca1,ca0,SEL} encoding *consistently*; readData mux + side-switch verified index-correct |
| 2 | F1/F2 mounts at ioctl_index 1/2, core checked 2/3 → floppy download shredded the boot ROM | no chime with disk inserted | N/A — we check 1/2; ROM at word `$500000`, floppies `$600000/$700000`, no overlap |
| 3 | ce_p_div2 at T2: data latch 1 clk32 after ack capture, SDRAM dout not ready → stale bytes | disk detected, garbled GCR | N/A by construction — we pass `clk8_en_p/n` straight (T1 ack / T3 latch, the arrangement they fixed TO); our sdram.v lands `dout` at t==6 (mid-busPhase-3), one clk_64 before the T3 latch; path is a same-PLL 65→32.5 MHz transfer, timed by STA, no false-paths in MacLC.sdc |
| 4 | readyToAdvanceHead overrun guard | reads at 1/5–1/10 speed | N/A — ours is already always-ready (matches their final state) |
| 5 | NuBus decl ROMs listened on ioctl_index 1 → every floppy mount corrupted them | chime, Welcome, hang | No analog: grep shows the only index consumers are the download handler and the index-0 reset gate |
| — | (their byte-addressed SDRAM mapping sidesteps our word+demux design) | — | our demux fixed June 15 (`2a2bd7c`), in the failed build |

## Additional layers audited clean this session

- **Sense truth table**: all 16 registers of `driveRegsAsRead` traced through
  our `{ca2,ca1,ca0,SEL}` index against the MAME runtime capture
  (`findings_mame_floppy_groundtruth_2026-07-02.md` §4). All 16 match,
  including the shadowed ones: MAME regs 0x4/0xC land on our indices 8/9,
  intercepted by the `diskDataIn` mux — whose MSB is always 1 for legal GCR
  bytes (Sony code table ≥ `$96`), which is exactly the value the SuperDrive
  `x011` signature needs. Reg 0x9 reads "locked" deliberately (read-only
  floppy). Reg 0xE reads ready-immediately (spin-up wait skipped; OS polls
  until 0, gets it instantly — benign).
- **SEL/HDSEL** = VIA1 PA5 (`dataController_top.sv:441`) ✓ MAME v8.cpp:266.
  `driveSel` = PA4 gating exists in BOTH cores (theirs works with it) —
  exonerated as a differentiator.
- **Fetch arbitration**: CPU owns busCycle 0/1/3, floppy owns slot 2
  (post-slot-reclaim); INT drive acked every 3rd rotation ≈ 1.48 µs — ~10
  refreshes per 16 µs byte slot; the continuously-refreshed
  `diskImageData` design is self-healing across the 2-clk32 addr-update
  transient (over-fetch guarantees the LAST refresh before consumption is
  coherent).
- **Download packing**: `dio_data <= {ioctl_data[7:0], ioctl_data[15:8]}`
  (even byte → high lane) is proven by the ROM booting at all (same swap
  feeds the ROM download; 68k reads it big-endian-correct), and the demux
  picks the matching lane.
- **Provenance of the July-2 test build**: `build_floppy1.log` shows a real
  compile (Jul 2 22:49→23:10) with floppy.v/swim.v changes; `git show
  3a46a80:MacLC.sv` contains both the demux fix and the swap. The BUILD was
  valid — which leaves the TEST (launch/mount procedure on `.188`, a box
  with no JTAG and a documented reboot-instability quirk) or a dynamic
  effect.

## ★ Landmine documented: do NOT "just fix" F1 (ISM switch detector)

F1 (detector never fires — nested in the enabled-write branch) remains
unfixed, **deliberately**. The entire ISM register layer is over-sampled:
`ism_param_idx` auto-increment, FIFO pushes/pops, and the switch-counter FSM
all run on EVERY `cen` tick of a held CPU access (5+ ticks per access on
E-paced cycles), not once per access. Today that layer is dead code (detector
never fires ⇒ ISM never activates ⇒ the ROM's SWIM self-test fails cleanly
and the OS runs IWM/GCR-only, which is EXACTLY what 800K GCR needs — the OS
never uses ISM for GCR data). Fixing F1 without one-shotting the whole ISM
access layer would make the ROM's boot-time self-test go haywire instead of
failing cleanly. F1+F2+access-one-shots belong to Build 2 (the 1.44MB ISM
engine) as a unit.

## What this session changed (build `MacLC_Unstable_20260706_<hash>.rbf`)

**PFLP diagnostic deck** (ported from lbmactwo's PFLP/PIWM, observation-only):

- `rtl/floppy.v`: `dbg_byte_cnt` / `dbg_miss_cnt` (16-bit wrapping; counted
  ONLY while phases are parked on RDDATA0/1 with the drive enabled — i.e.
  while the OS is actually consuming), `dbg_disk_image_data`,
  `dbg_drive_track/side`, `dbg_step_cnt`.
- `rtl/swim.v` → `rtl/dataController_top.sv` → `MacLC.sv`: passthroughs +
  two ISSP probes:
  - **PFL0** = `{byte_cnt[15:0], miss_cnt[15:0]}`
  - **PFL1** = `{track[6:0], side, iwm_latch[7:0], step_cnt[7:0], disk_data[7:0]}`

**IWM hardening** (MAME-grounded, HW-validated on lbmactwo, low-risk):

- Data-register read returns `$FF` when no drive is enabled (MAME:
  `active ? data : FF`).
- Drive-enable rising edge clears `readDataLatch` + arms a ~126 µs squelch
  (`readDataArmDelay`, 0x400 cen ticks) before the first byte latches —
  MAME clears the data register entering active read mode; prevents a stale
  idle byte poisoning the mount's first sync hunt.
- `readDataLatch` now only loads with a drive enabled and the squelch
  elapsed.

A&E: 0 errors / 64 warnings (baseline). `verilator/sim.v` untouched — the new
dataController ports are dbg-only and left unconnected there (legal); no
functional sim/FPGA divergence introduced.

## Test protocol when power returns (`.143` — the JTAG box, NOT `.188`)

1. Deploy the hash-named RBF (one launchable MacLC per box). Boot the 7.5.5
   SCSI desktop as usual.
2. Mount the raw 800K image (819,200 B — `System Tools.dsk` fixture) as
   **Pri Floppy** (probes watch the INTERNAL drive only).
3. Sample PFL0/PFL1 via `scripts/read_probes.sh` twice ~10 s apart, then
   answer the ladder:
   - **byte_cnt static, step_cnt static** → the OS never even polls RDDATA →
     drive-ID/mount-decision problem (or the mount didn't take — check OSD).
   - **byte_cnt climbing ≈ 3.9 k/s, miss_cnt static, sectors still rejected**
     → delivery is healthy end-to-end in RTL ⇒ compare `disk_data` stream
     legality (must be ≥ `$96` GCR codes) and suspect the last hop / CPU
     consumption; escalate to SignalTap on `readDataLatch`.
   - **miss_cnt climbing** → SDRAM extra-slot starvation (the one dynamic
     failure the static audit can't exclude) → look at slot arbitration
     under load.
   - **track walks 0→79 with step_cnt bursts and the dialog appears at the
     end** → reads "succeed" but content wrong → byte-lane/order issue after
     all → dump `disk_data` sequence vs the image.
4. If it just mounts clean: the July-2 verdict was a test artifact (the
   suspicion this doc documents); close Investigation A for 800K and move to
   Build 2.

## Files touched today

`rtl/floppy.v`, `rtl/swim.v`, `rtl/dataController_top.sv`, `MacLC.sv`
(wires + PFL0/PFL1 + dataController wiring). Build log:
`build_floppy_probes.log`.
