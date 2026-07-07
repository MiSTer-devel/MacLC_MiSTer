# Floppy 800K — capture re-decoded: SDRAM does NOT hold the mounted image (2026-07-07)

*Offline session over the 0dcf73e ring capture (`floppy_ring_trk0_0dcf73e.txt`).
CORRECTS `docs/resume_floppy_and_video_2026-07-03.md` /
`resume_pixelclock_floppy_2026-07-06.md`'s "data-field payload is all zeros /
headers perfect ⇒ encoder input zero" framing in a fundamental way.*

## TL;DR

1. **Track 0 of `Disk605.dsk` is mostly zeros IN THE FILE.** Sectors 5–11:
   0/512 nonzero bytes; sector 2 (MDB): 46/512; sector 4: 12/512. Only the
   boot blocks (secs 0–1) and the bitmap (sec 3) are dense. The captured
   "all-zero data fields" for sectors 9/8 therefore match... nothing: they
   *would* be correct content for this disk, and the prior session's diff
   against MAME was comparing against a DIFFERENT disk's content (the MAME
   flat came from the System Tools fixture). **Sample-window trap.**
2. **But the stream is NOT correct either.** The capture's leading
   "real varied data" tail was inverted through an exact Python replica of
   `floppy_track_encoder.v`'s 6&2 nibbler (`scratchpad nibbler_replica.py`,
   backward solver `invert_tail.py`, anchored on the field's decoded DSUM
   `c1=FA c2=00 c3=4A`; **unique solution** across 46 triples). The recovered
   138 input bytes (`81 81 65 0E 8B FD 46 F5 E7 5C ...`) appear **nowhere in
   Disk605.dsk, boot0.rom, or any other local image**.
3. **The garbage field is track 0, sector 7** — it closes into a normal
   ~58-byte FF sync gap immediately followed by the `trk=0 sec=9` address
   field (encoder physical order ...5,7,9,11), and no head seek fits in that
   ~1 ms. Image sector 7 is all zeros; the encoder delivered garbage there.
4. **⇒ VERDICT: the SDRAM floppy-image region ($600000 words+) holds stale
   garbage (zero-dominated — matching a leftover framebuffer/previous-core
   memory), not the downloaded image.** "This disk is unreadable" is simply
   the boot blocks reading back garbage. The encoder, fetch path, headers,
   framing — all exonerated (again); the **mount-time download** is the bug.
5. **The source file is NOT the problem**: all four SD-card copies of
   Disk605.dsk on `.143` md5-match the local copy (`1ea1ef42...`).

## Why the download is suspicious and yet audits clean

- The FPGA-side handshake (`ioctl_wait`/`dio_write`/slot-end clear) is
  byte-identical to MacPlus_MiSTer and lbmactwo_MiSTer — both download
  floppies live, successfully.
- `boot0.rom` (index 0) streams through the SAME handshake+SDRAM path at
  core load and lands intact — but with the machine held in RESET
  (`MacLC.sv:131`). A floppy mount streams with the CPU live. Live CPU
  writes work (the guest runs); reset-time extra-slot writes work (ROM);
  **live extra-slot writes are the untested combination.**
- `sdram.v` executes one full random access per busCycle by fixed schedule
  (t==0 RAS sample, t==2 CAS+data, auto-precharge) — no drop mechanism found
  statically. The hps_io.sv here is a newer framework generation than
  lbmactwo's (address sequencing differs) but both are widely shipped.

## The instrument built this session (one compile answers WHY)

Ring v2 (same PFL1 dual-mode probe, same 1 M10K):
- **ring word = {gcrReadAddr[15:0], raw dskReadDataLatch[7:0], enc[7:0]}**
  per delivered byte (256 strobes/arm, re-armable) — separates zero/garbage
  SDRAM content from address-walk faults from encoder faults.
- **sel 3 = download acceptance counters** (reset at index-1 download start,
  count on the same slot-exit event that clears ioctl_wait):
  - D1: `dl_words[19:0]` — accepted write slots. Expect **409600**.
  - D2: `dl_nonzero[19:0]` — accepted words ≠ 0. Disk605 expect **382785**.
  - D3: size-latch flags + last `dio_addr` (expect ds=1, 0x64000).
  - D4: `dl_xor[15:0]` — XOR of accepted `dio_data`. Disk605 expect **0x0926**.

Decision table after one mount:
- `dl_words` ≪ 409600 → write slots lost core-side (handshake/slot grant).
- `dl_words` full, `dl_nonzero`/`dl_xor` wrong → HPS/hps_io stream delivered
  wrong bytes (framework/SPI side).
- All three correct, ring raw = stale garbage at correct addrs → the write
  itself doesn't land (sdram.v live-write execution) — SignalTap next.
- All three correct, ring raw = image content → content is FINE; pivot to
  the IWM/CPU-read side (mode-B CPU-read ring next build).

RTL: `rtl/floppy.v` (+`dbg_raw_byte`/`dbg_gcr_addr`), `rtl/swim.v`,
`rtl/dataController_top.sv` (passthroughs), `MacLC.sv` (ring repack + dl
counters + sel3). Tools: `scripts/floppy_ring.tcl` (v2 dump + DL readout;
stub-validated offline incl. a Tcl switch-comment gotcha),
`scripts/raw_compare.py` (raw-vs-image verdict + dl references),
`scripts/gcr_analyze.py` (unchanged, parses FLAT-ENC).

## Protocol (unchanged from resume doc, plus)

- `status` now prints DL counters — read them RIGHT AFTER the mount.
- Compare `dl_nonzero`/`dl_xor` against `raw_compare.py` output for the
  EXACT image mounted.
- PFL0 byte/miss counters: record BEFORE and AFTER the mount this time.
