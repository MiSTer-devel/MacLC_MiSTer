# Resume — 800K floppy bug LOCALIZED: data-field payload is ALL ZEROS (headers perfect) — 2026-07-06 (night)

**BIG RESULT this session:** the on-chip capture ring (built + deployed +
captured this session) turned the 800K "unreadable" bug from "content/framing
bug somewhere on track 0" into a **precisely localized defect**: the encoder
emits **correct, checksum-valid sector HEADERS for every sector, but the DATA
field payloads come out ALL ZEROS** (and the wrong length). The IWM syncs fine;
the OS finds each sector; the data field is garbage → every sector fails its
data checksum → "This disk is unreadable."

This **overturns the prior leading hypothesis** ("the IWM never byte-syncs / no
address marks"). The marks are there and perfect. The bug is downstream, in the
**SDRAM disk-data path feeding the data-field encoder**.

Predecessors: `docs/resume_floppy_content_bug_2026-07-06.md` (the capture-ring
build plan + JTAG-crash safety), `docs/findings_floppy_lbmactwo_diff_2026-07-06.md`
(encoder byte-identical to lbmactwo — still the key clue, see below),
`docs/findings_mame_floppy_groundtruth_2026-07-02.md`.

Branch `new-disk-features`. This session's commit: **`0dcf73e`** (capture ring).
Nothing pushed; the user pushes.

---

## ★★★ THE FINDING (decoder-verified, ground-truth vs MAME)

Deployed `0dcf73e` to `.143`, booted 7.1 clean (`berr_fires=0`, `boot_inits=2`,
`miss_cnt=0`), armed the ring, mounted `Disk605.dsk` (raw 800K), got the
"unreadable" dialog, dumped 1024 bytes: **`floppy_ring_trk0_0dcf73e.txt`** (repo
root). Decoded with **`scripts/gcr_analyze.py <capture> <mame_flat>`**:

```
===== CAPTURE (0dcf73e track0): 1127 bytes =====
  @016B ADDR  trk=0 sec=9 side=0 fmt=0x22 cks=0x2b OK
  @017A DATA  len=502 (closed)  zero/96=501  head=AB 96 96 96 96 96      <-- ALL ZEROS
  @03AF ADDR  trk=0 sec=8 side=0 fmt=0x22 cks=0x2a OK
  @03BD DATA  len=81  (UNTERM)  zero/96=64   head=A7 96 96 96 96 96      <-- ALL ZEROS
  @0416 ADDR  trk=0 sec=9 side=0 fmt=0x22 cks=0x2b OK
  @0427 ADDR  trk=0 sec=2 side=0 fmt=0x22 cks=0x20 OK
  @0434 ADDR  trk=0 sec=8 side=0 fmt=0x22 cks=0x2a OK
  data-field lengths: [502, 81, 17]

===== MAME 800k delivered =====
  @0A3F ADDR  trk=0 sec=0 side=0 fmt=0x22 cks=0x22 OK
  @0A4F DATA  len=704 (closed)  zero/96=9    head=96 F2 AC AD D3 FB      <-- REAL DATA
  ... every sector 0-11 present, headers valid, format 0x22
  data-field lengths: [704, 461(cut)]
```

**Reading the evidence:**
1. **Address/header fields are PERFECT and identical in quality to MAME** —
   `D5 AA 96` prologue, decoded `trk=0 side=0 fmt=0x22`, and the checksum
   (`trk ^ sec ^ side ^ fmt`) **verifies** on every one. The encoder generates
   these internally from counters, so this proves the encoder's framing/gap/
   mark/counter logic is sound. **The IWM CAN and DOES byte-sync.**
2. **Data fields are broken two ways:**
   - **Content = all zeros.** 501/502 bytes are `0x96` (= 6-and-2 GCR for
     `0x00`). MAME's data field is real varied data (only 9/704 zeros). Track 0
     of `Disk605.dsk` is a real HFS boot block (first bytes `4C 4B` = "LK" boot
     signature — confirmed via `dd`), so all-zero payload is definitively WRONG.
   - **Length is wrong and variable** (502, 81, 17 …) vs MAME's constant 704.
     A Mac 524-byte sector (512 data + 12 tag) encodes to a ~704-byte GCR data
     field. The `DE AA` epilogue is landing early/erratically.

**Conclusion:** the encoder builds a correct track skeleton (sync, gaps,
address marks with valid checksums, data-mark prologues, `DE AA` epilogues) but
the **actual sector DATA it nibblizes is 0x00**, so it emits `0x96` for the whole
payload. The OS reads each valid header, then reads a zero data field whose data
checksum fails → retries all ~12 sectors → gives up → "unreadable."

### The one nuance to explain (don't ignore it)
The ring armed **mid-field**, so the first ~0x016A bytes of the capture are the
**tail of a data field that has REAL varied GCR data** (`96 E7 DF 96 ED BC E5
…`, a `0x96` every 4th byte + a slowly-incrementing value). So it is **not**
"SDRAM always returns zero" — at least one field got real data, then the
**complete** fields that follow (sectors 9, 8) are all zeros. Pattern = **first
field real, subsequent fields zero.** Any root-cause theory must explain that.
(Candidate: a one-shot prefetch/refill that fills the first field then starves
to zero; or `gcrReadAddr` advancing correctly for field 1 then stalling/wrapping
into a zero region; or the OS's repeated track-0 re-reads hitting a buffer that
was consumed once.)

---

## THE SDRAM DISK-DATA PATH (where the zeros come from — trace this)

The data byte the encoder nibblizes originates in SDRAM and flows:

```
SDRAM word  --sdram_out[15:0]-->  byte-lane demux  -->  swim latch  -->  encoder .idata  -->  GCR out
```

Exact hops (file:line):
- **`MacLC.sv:1686`** `dsk_byte_odd = dskReadAckExt ? dskReadAddrExt[0] : dskReadAddrInt[0]`
- **`MacLC.sv:1687`** `extra_rom_data_demux = dsk_byte_odd ? {sdram_out[7:0],..} : {sdram_out[15:8],..}`
  — image is packed **2 bytes/word** (download byte-swaps: EVEN file byte = HIGH
  lane, ODD = LOW). **There is a DOCUMENTED prior bug here** (the comment at
  `MacLC.sv:1674-1685`): the addr→word conversion drops bit 0, so the wrong lane
  was picked → "0,0,3,3,4,4,7,7…" duplication → sectors failed checksum. That was
  "fixed" to select on the live parity bit. **Given the payload is now all-ZERO
  (not duplicated), this is a DIFFERENT failure than the one that comment fixed —
  but this is the first place to instrument: is `sdram_out` itself zero during
  data-field fetches, or is the demux picking a zero lane?**
- **`MacLC.sv:1667-1670`** `sdram_oe`/`sdram_do` gated by `dskReadAckInt||Ext`;
  disk read returns `extra_rom_data_demux`, else normal `sdram_out_patched`.
- **`rtl/swim.v:188`** `dskReadDataLatch <= dskReadData` (when `dskReadAckD`)
- **`rtl/dataController_top.sv:975`** `.dskReadData(memoryDataIn[7:0])` — swim
  reads the **LOW byte** of the returned word.
- **`rtl/swim.v:198-213`** `floppy_track_encoder enc (.idata(dskReadDataLatch),
  .odata(dskReadDataEnc), .addr(gcrReadAddr))`
- **`rtl/swim.v:238`** `dskReadAddr = mfm_disk ? mfmReadAddr : gcrReadAddr`
- **`rtl/floppy.v:262-289`** delivery FSM: at timer 0, `diskDataIn <=
  diskImageData` and **zero `diskImageData`**; on `dskReadAck`, `diskImageData <=
  dskReadDataEnc`. (This same-edge zeroing is why the capture strobe is
  same-cycle — see `dbg_byte_stb`.)

**KEY CLUE — encoder is byte-identical to the WORKING lbmactwo encoder** (diff
exit 0, see the lbmactwo-diff doc). So the bug is almost certainly NOT in
`floppy_track_encoder.v` — it's in **what feeds `.idata`** (the SDRAM fetch /
byte-lane demux / ack-latch handshake / image base address), which is core-glue
that MAY differ from lbmactwo. Diff `MacLC.sv`'s `extra_rom`/`dsk_byte_odd`/
`sdram_*` block and `addrController` disk-address math against lbmactwo's.

---

## ★ DECISIVE NEXT STEP — capture the RAW SDRAM byte + fetch address

The ring currently records the **post-encoder** delivered byte (`disk_data`).
Extend it (or add a 2nd ring) to record, per data-field fetch, the **pre-encoder
raw byte `dskReadDataLatch`** and **`gcrReadAddr`**. Then one capture answers it:
- raw `dskReadDataLatch` == 0 during data fields → **fetch/address/lane bug**
  (SDRAM returns zero, or demux picks a zero lane, or addr points to a zero
  region / doesn't advance). Then instrument `sdram_out` + `gcrReadAddr` sequence.
- raw `dskReadDataLatch` != 0 but encoded output == 0x96 → **encoder bug** (contra
  the byte-identical claim — would mean the diff missed a param/width).

Cheapest build: in `MacLC.sv`, widen the ring word to also latch
`dbg_flp_disk_data`'s **source** — i.e. thread `dskReadDataLatch` (add a
`dbg_flp_raw` port up the same swim→dataController→MacLC chain as
`dbg_flp_byte_stb`) and `gcrReadAddr[15:0]`, store `{raw[7:0], addr[15:0],
enc[7:0]}` per strobe (or alternate ring words). Same PFL1-mux pattern, same
gates. Then re-run the exact capture protocol below and re-diff.

Alternative (no rebuild): the current capture already all-but-proves it. If you
accept "encoder identical ⇒ fetch is the culprit," go straight to auditing the
`extra_rom`/`dsk_byte_odd`/base-address path in `MacLC.sv` + `addrController`
vs lbmactwo, and test a fix. But the raw-byte capture is the safe confirmation.

---

## CAPTURE PROTOCOL (reproducible; ~5 board-minutes) — for any floppy ring build

Board deploy + boot (keep ONE launchable — the OSD off-by-one trap):
```bash
source scripts/local.env
ssh -i ~/.ssh/mister_only root@192.168.99.143 \
  'mv /media/fat/_Unstable/MacLC_Unstable_20260706_78e484c.rbf{,.disabled} 2>/dev/null'
python tools/misterdeploy/launch_unstable_core.py \
  --push releases/MacLC_Unstable_20260706_0dcf73e.rbf \
  --core MacLC_Unstable_20260706_0dcf73e.rbf --delay 0.3 --max-tries 3
bash scripts/grab.sh boot.png                 # expect 7.1 desktop (Tools window)
bash scripts/read_probes.sh | grep -E "PSDT|PFL0|PRC0"   # berr_fires=0, boot_inits=2
```
Arm → mount → dump:
```bash
export PATH="/c/intelFPGA_lite/17.0/quartus/bin64:$PATH"
quartus_stp_tcl -t scripts/floppy_ring.tcl arm
# open OSD + mount Disk605.dsk as Pri Floppy (see OSD-drive note below), ~14 s
quartus_stp_tcl -t scripts/floppy_ring.tcl status     # RING done=1 words=256
quartus_stp_tcl -t scripts/floppy_ring.tcl dump floppy_ring_trk0_<tag>.txt
python scripts/gcr_analyze.py floppy_ring_trk0_<tag>.txt \
       scratch/mame_floppy_0702/mame_800k_delivered_flat.hex.sample
```
Re-arm + eject/remount for more 1 KB windows (re-mount WITHOUT eject does NOT
re-fire the read — proven).

### OSD keystroke driving (learned this session — the launcher only does the
### core-select menu, not in-Mac OSD navigation)
The MiSTer Remote ws API key names live in mrext `pkg/input/keyboard.go` /
`cmd/remote/control/control.go`. **Valid `kbd:` names:** `up down left right
menu back confirm cancel osd screenshot core_select user reset console
exit_console computer_osd change_background`. **`osd` = F12** (opens the core
OSD). `computer_osd` = Win+F12. Raw codes via `kbdRaw:<n>` (F12=88). To jump to a
file starting with a letter in the file browser, `kbdRaw:<letter code>` (D=32).
Reusable sender (this session): `scratchpad/ws_send.py "kbd:osd" "sleep:0.8"
"kbd:down" ...` — or fold into a committed helper next time. The core's floppy
mount is CONF_STR `F1,DSKIMG,Mount Pri Floppy` (`MacLC.sv:60`), first selectable
row under the top separator.

---

## WHAT WAS BUILT THIS SESSION (commit `0dcf73e`, all gates green)

On-chip 1024-byte GCR capture ring (the SAFE replacement for JTAG streaming,
which crashed the board last session):
- `rtl/floppy.v`: `dbg_byte_stb` — **same-cycle** delivery strobe (delivery
  zeroes `diskImageData` on the same edge it hands off, so a change-detect
  capture would read 0s).
- `rtl/swim.v`, `rtl/dataController_top.sv`, `verilator/sim.v`: thread
  `dbg_flp_byte_stb` (internal drive; dangling on ext/sim).
- `MacLC.sv`: 256×32 BRAM ring (1 M10K) behind the **existing PFL1 probe**,
  widened to `source_width(11)` and mode-muxed (NO new hub nodes — the ~40-node
  deck's name table already reads corrupted). `source = {arm[10], sel[9:8],
  addr[7:0]}`; sel 0=live (default, tooling-compatible), 1=ring word (4 bytes,
  `[7:0]`=earliest), 2=status `{8'hB5 magic, done, capturing, 2'b00, arm_cnt,
  6'd0, wptr[9:0]}`. Arm edge restarts the capture.
- `scripts/floppy_ring.tcl`: arm | status | dump — **ONE bounded session per
  action**, aborts on failure, **never reopens** (the reopen loop is what
  crashed `.143`). Dump hexdumps + auto-scans marks/sync + verdict hint.
  Offline-validated against a stubbed JTAG layer (which caught a Tcl `scan %x`
  bit31 sign-wrap bug → `%llx`; same fix applied to `scripts/floppy_rapid.tcl`).
- `scripts/gcr_analyze.py`: 6-and-2 GCR decoder/structural analyzer (NEW; the
  tool that produced the finding above). Args: `<capture-or-flat> <flat>`.

Gates: A&E 0 err; full compile 0 err, **worst slack +0.074 ns**; SCSI STA gate
**PASS 28.678 ns**; ring inferred as **1 M10K** simple-dual-port (536/553 M10K).
RBF staged **`releases/MacLC_Unstable_20260706_0dcf73e.rbf`** (md5 `b1b72624`);
it's a descendant of `78e484c`, so the HW-validated pixel-clock fix rides along.

MAME reference: `scratch/mame_floppy_0702/mame_800k_delivered_flat.hex` (full,
untracked) and `.sample` (first 4 KB, committed) — the correct delivered stream
to diff against. Also `decoded_800k_v3.txt`.

---

## HARDWARE STATE (session end)
- `.143` is **UP and healthy**, running `MacLC_Unstable_20260706_0dcf73e`
  (7.1 desktop). The floppy was **ejected by the user** after the capture (the
  capture had already completed — eject was harmless). Old
  `MacLC_Unstable_20260706_78e484c.rbf` was renamed `.disabled` (keep-one-
  launchable); to restore the pixel-clock-only build, re-enable it (or just note
  `0dcf73e` contains it).
- Launch/screenshot/probe crib in the protocol above. `scripts/floppy_ring.tcl`
  = SHORT bounded JTAG only. **Do NOT** run `scripts/floppy_rapid.tcl` for
  minutes (it crashed the board last session — `[[shared-mister-hps-exhaustion]]`).
- `.188`: untouched, lower priority.

## STILL PENDING (unchanged, lower priority than the floppy data-path fix)
- Pixel clock (#6): HW-validated CLEAN (`78e484c`, in `0dcf73e`); only OSD
  12"↔VGA switch left to eyeball. `[[pixel-clock-berr-rootcause]]`.
- QuickDraw occupancy (B′): sample `bushist.tcl`/`buslat.tcl` under Speedometer
  — but as SHORT bounded JTAG captures, not loops. `[[system-tick-halved-rootcause]]`.
- Floppy Build 2 (ISM 1.44MB): unstarted.
- Task #4: offline TG68K 020-mode cycle audit (safe anytime).

## GCR 6-and-2 decode table (disk byte → 6-bit value; used by gcr_analyze.py)
```
96=00 97=01 9A=02 9B=03 9D=04 9E=05 9F=06 A6=07 A7=08 AB=09 AC=0A AD=0B AE=0C AF=0D B2=0E B3=0F
B4=10 B5=11 B6=12 B7=13 B9=14 BA=15 BB=16 BC=17 BD=18 BE=19 BF=1A CB=1B CD=1C CE=1D CF=1E D3=1F
D6=20 D7=21 D9=22 DA=23 DB=24 DC=25 DD=26 DE=27 DF=28 E5=29 E6=2A E7=2B E9=2C EA=2D EB=2E EC=2F
ED=30 EE=31 EF=32 F2=33 F3=34 F4=35 F5=36 F6=37 F7=38 F9=39 FA=3A FB=3B FC=3C FD=3D FE=3E FF=3F
```
Address field = `D5 AA 96` + trk,sec,side,fmt,cksum(=trk^sec^side^fmt) + `DE AA`.
Data field = `D5 AA AD` + sector + ~699 nibblized data + checksum + `DE AA`.

Memory to update: `[[floppy-800k-exonerated-pfl-probes]]` (data-field-zero
verdict), `[[shared-mister-hps-exhaustion]]`, `[[mfm-1440-floppy-implemented]]`,
`[[pixel-clock-berr-rootcause]]`, `[[second-mister-188]]`,
`[[quartus-cli-rtl-validation]]`.
