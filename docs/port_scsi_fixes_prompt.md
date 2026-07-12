# Session prompt — port the LBMacTwo SCSI deadlock/corruption fixes (4376c8f + 4f9506b + b760944)

> **REVISED 2026-06-10c.** Hardware validation of the first commit found a
> SECOND wedge: the disk target itself parked in DATA_OUT because the
> response's own length fields disagreed with the served byte count.
> The enforced invariant (both commits together): **a response serves
> exactly what its own length fields promise, clamped by the allocation
> length.** Round 2 (4f9506b): INQUIRY additional-length 32->31 (standard
> 36-byte response), MODE SENSE(6) clamped to 12 with mode-data-length
> header byte = 11 (was 0). Disks carrying an Apple_Driver43 partition run
> the on-disk HD SC driver, whose mount dialog differs from the ROM
> driver's — likely why MacLC's OS 7 (and some disks) hit this while
> minimal bench disks don't.
>
> **Port mechanics changed:** line-ending churn made a clean patch
> impossible. Instead, `scratch/scsi_fixed_4f9506b.v` is the COMPLETE
> fixed file — diff it against `rtl/scsi.v` (only real difference beyond
> the fixes: the `dbg_wrstall` output port + `bus_busy` input, both fine
> to take wholesale; `dbg_wrstall`/`dbg_phase` may stay unconnected in
> MacLC's ncr5380). Then do the ncr5380.sv hand-edits below
> (`scratch/ncr_fix_reference.patch` shows the LBMacTwo version of them).

> **REVISED 2026-06-10d — ROUND 3 IS THE BIG ONE FOR THE OS 7 HANG.**
> Round-2 HW retest still wedged at Welcome: the on-disk HD SC 4.3
> driver's async path SLEEPS on VIA2 IFR flags between pseudo-DMA chunks
> — on the Mac II, **VIA2 CA2 (IFR bit 0) = SCSI DRQ and VIA2 CB2 (IFR
> bit 3) = 5380 IRQ** (ground truth: Snow `macii/via2.rs`). LBMacTwo had
> both VIA2 inputs hardwired `1'b1` and no IRQ latch in ncr5380 → the
> driver parked forever at the first HPS 512-byte REQ pause of a
> multi-block READ(10) (probe-proven: data_cnt=512/tlen=35, dreq=1
> ignored, zero DACK reads). Fix `b760944`
> (`scratch/via2_irq_fix_b760944_reference.patch`): ncr5380 `dma_armed`
> on Start-DMA writes + `irq_latch` on phase-match falling edge while
> MR.DMA & armed (cleared by reg-7 read / bus reset), `BSR.IRQ` = latch,
> `BSR.EODMA` = bus-not-in-data-phase (was constant 0), new `o_irq`
> output; dataController `ca2_i = ~scsiDREQ`, `cb2_i = ~scsiIRQ`.
> **System 7 leans on the async SCSI Manager far more than System 6 —
> this is a prime suspect for MacLC's OS 7 boot hang.**
>
> LC-SPECIFIC DELIVERY (verified 2026-06-10 against MAME + MacLC RTL):
> the LC has NO VIA2 — `rtl/pseudovia.sv` (V8) takes its place, and it
> currently has **no SCSI inputs at all** (only vblank/slot/asc). Facts:
> - MAME's shared pseudovia device (`src/devices/machine/pseudovia.cpp`
>   ~line 148) models SCSI: `scsi_irq_w` sets **IFR bit 3 (0x08, "CB2
>   interrupt")**, `scsi_drq_w` sets **bit 0** — LEVEL-driven (assert
>   sets, deassert clears, recalc IRQ), no edge/PCR machinery.
> - BUT MAME's `maclc.cpp` does NOT connect the 5380 irq_handler (only
>   DRQ→scsi_helper for halt/bus-error DACK semantics) and still boots
>   LC System 7 — so the LC ROM driver path can complete on BSR polling
>   + DACK stalls alone. MacLC_MiSTer already has the indefinite DACK
>   stall (`MacLC.sv:529 selectSCSIDMA ? ~scsiDREQ`).
> Port order therefore: (1) scsi.v rounds 1-2 + ncr5380 chip-internal
> round 3 (irq_latch/EODMA make the BSR truthful — polled drivers read
> those bits; low risk, port as-is). (2) If OS 7 still hangs, add
> level-driven `scsi_irq`/`scsi_drq` inputs to pseudovia.sv setting IFR
> bits 3/0 per MAME pseudovia.cpp — safe (flags only raise CPU IRQs when
> the OS enables them in IER) and ~10 lines.

Run this in a session rooted at `C:\Temp\mistercore\MacLC_MiSTer`, on the
branch the user cut for SCSI testing.

## Context (from the LBMacTwo investigation, 2026-06-10)

LBMacTwo commit `4376c8f` fixed two coupled SCSI bugs, root-caused live on
hardware + by byte-level disk forensics (full writeup:
`../lbmactwo_MiSTer/docs/handoff_scsi_corruption_2026-06-10.md`, session-2
section):

1. **Allocation-length over-serve deadlock**: `scsi.v` targets served
   INQUIRY/REQUEST SENSE for the RAW allocation length instead of
   `min(alloc, actual)`. When the Mac's boot-time SCSI mount scan transfers
   fewer bytes than alloc, the target holds REQ forever with leftover bytes
   and the Mac spins polling the NCR5380 Bus & Status register for a phase
   change ("Welcome to Macintosh" hang). **This is a prime suspect for the
   MacLC System 7 boot hang** — System 7's mount scan INQUIRY pattern
   differs from System 6's, and MacLC's disk targets have the identical
   unclamped code (`rtl/scsi.v`; the disabled `scsi_empty_cd` has it too at
   ~line 866).
2. **Stale-buffer flush corruption**: a wedged-BUSY target keeps its dout
   wired-ORed onto the data bus and consumes every broadcast ACK; stray ACKs
   walk a wedged DATA_IN target until 512-byte boundary flushes write STALE
   previous-read buffer content to that command's LBA. Disk-diff signature:
   each corrupted run = 1 part-garbage sector + exact sector-aligned copies
   of an earlier boot-read. Fix: selection requires a free bus
   (`!bus_busy`) — real SCSI cannot select while BSY is asserted.

MacLC has seen occasional SCSI corruption and cannot boot OS 7 (hangs) —
both consistent with these bugs. MacLC's `ENABLE_EMPTY_CD(0)` means fewer
wedge opportunities (no fake CD answering every scan), matching "less
corruption than LBMacTwo".

## The port (verified 2026-06-10 against MacLC `new-video-technique-part-2`)

1. `git apply scratch/scsi_fix.patch` — **verified to apply clean** with
   `git apply --check`. This contains ALL functional fixes for both target
   modules: data_len clamps (INQUIRY 37 disk / 54 CD, REQUEST SENSE 18,
   alloc 0 -> 4, undo the 0->256 READ/WRITE(6) mapping for alloc lengths),
   `data_done` zero-length completion, `req_rd`/`req_wr` guards (a tlen=0
   WRITE must not flush a stale buffer block in STATUS_OUT), the new
   `bus_busy` input + selection gate on `scsi` and `scsi_empty_cd`, and a
   `dbg_phase` output on `scsi_empty_cd`.
2. `scratch/ncr_fix.patch` does NOT fully apply (MacLC's `dbg_scsi2` line
   drifted). Hand-apply its 3 small hunks to `rtl/ncr5380.sv`:
   - declare `wire [2:0] empty_cd_phase;` near the other `empty_cd_*` wires
     (~line 420);
   - on the `scsi_empty_cd` instance (~line 430): add
     `.bus_busy ( |target_bsy ),` and `.dbg_phase ( empty_cd_phase )`;
   - on the `scsi` target instance (~line 451): add
     `.bus_busy ( (|target_bsy) | empty_cd_active ),`
     (own bsy bit is harmless — the gate is only evaluated in PHASE_IDLE);
   - OPTIONAL (debug only): pack `empty_cd_phase[1:0]` into
     `dbg_scsi2[15:14]` and `{empty_cd_phase[2], empty_cd_req}` into
     `dbg_scsi2[7:6]` — only useful if/when the CD target is enabled and
     MacLC's probe reader is taught to decode it; skip if probe budget or
     reader drift makes it annoying.
3. The unconnected-`bus_busy` trap: if you skip step 2's `.bus_busy` wiring,
   the input floats and selection may never fire — the ncr5380 edits are
   REQUIRED, not optional.
4. Build + verify the RBF md5 changed (a debug-only edit once produced a
   byte-identical RBF in the sibling repo — confirm).

## Validation

- OS 7 boot test: if the hang was the alloc-length wedge, System 7 should
  now get past the SCSI mount scan. (On LBMacTwo the wedge parked the CPU
  spinning on reads of NCR reg 5 / Bus & Status — on MacLC, same signature
  would show in whatever probe shows the busy-loop address.)
- Corruption test (host-side, byte-exact): copy a known-good bootable .vhd,
  md5 it, boot a Mac OS session, clean shutdown, copy back and run
  `python ../lbmactwo_MiSTer/scripts/hda_match_sources.py <pristine> <after>`
  — PASS = zero COPY-class runs (sector-aligned copies of other disk
  regions); legit HFS metadata shows as NOVEL runs in catalog/Desktop/MDB
  regions only. `../lbmactwo_MiSTer/scripts/hfs_forensics.py <img> <lba>...`
  maps any suspect LBA to its owning file via the HFS catalog.

## Don'ts

- Don't enable `ENABLE_EMPTY_CD` as part of this port — keep the port
  minimal; the CD work has its own plan (`docs/plan_scsi_cdrom.md`), and the
  future real CD target at ID3 must ABSORB `scsi_empty_cd` (never run both
  at ID3 — same-cycle dual selection of one ID defeats the bus_busy gate).
- ~~Don't clamp MODE SENSE~~ — SUPERSEDED by the 2026-06-10c revision:
  round 2 (4f9506b) DOES clamp MODE SENSE to 12 with a consistent header;
  `scratch/scsi_fixed_4f9506b.v` already contains it.

> **REVISED 2026-06-11 — ROUND 6 (`2d025c5`) IS THE ONE THAT MATTERS
> MOST FOR ANY POLLED DRIVER (likely including LC OS 7).** The decoded
> System SCSI Manager TIB engine spins between 512-byte chunks while
> `(CSR.REQ==1 && BSR.pmatch==1)` and exits ONLY when a CSR read
> returns REQ=0. VIA2/pseudo-VIA SCSI interrupts are NOT enabled by the
> OS (PVIA-proven IER=0x02 on the Mac II) — the poll is the only
> continuation path. Port the `req_deferred` block from LBMacTwo
> `rtl/ncr5380.sv` (search "Deferred bus-visible REQ"): on a bus-visible
> REQ rising edge, hide REQ from CSR until one full CSR read completes;
> keep BSR.DRQ undeferred. Also port `5adc2e1` (req_bus split: visible
> REQ continuity across HPS block fetches — scsi.v `req_bus` output +
> ncr5380 `scsi_req_bus` mux feeding CSR/BSR.DRQ). These two together
> are the difference between "wedges at Welcome / OS 7 hang" and
> booting. The earlier pseudo-VIA IFR advice (bits 3/0) is now KNOWN to
> be unnecessary for the boot path — skip it unless something async
> demands it later.
