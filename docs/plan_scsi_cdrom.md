# Plan — SCSI CD-ROM drive (ISO / TOAST + CHD)

> **STATUS 2026-07-12 (branch `add-scsi-cdrom`): Phases 1+2 IMPLEMENTED, HW test pending.**
> Phase 1 landed as a `CDROM` parameter on the proven `scsi.v` target (not a
> separate module): disk instances constant-fold to the pre-CD netlist, the ID-3
> instance reuses the wedge-hardened REQ/ACK/ring machinery. hps_io slot moved
> to **4** (master had grown PRAM=2 + Toolbox=3 since this plan), OSD `SC4` +
> `OI` enable option (status[18]). Phase 2 did **NOT** need the feared EXT_BUS
> bridge: the Toolbox branch's per-slot `sd_type` dispatch in Main_MiSTer let
> CUE/CHD/raw-2352 be served as a **flat 2048-byte virtual block device**
> (`support/maclc/maclc_cd.cpp`, Main branch `add-bluescsi-toolbox-for-MacLC`) —
> the RTL never learns the container format; flat ISO/TOAST passes through
> stock-Main generic mounts. CD audio (Phase 3) still deferred. §2.2's in-RTL
> 2352 straddle path: dropped, superseded by the Main-side normalization.

Date: 2026-06-08 (rev 2026-06-09) · Branch: `new-video-technique-part-2`
Scope agreed with user: **ISO + TOAST** (in-core) **+ CHD** (via firmware).
**One CD drive** (SCSI ID 3). BIN/CUE no longer a target (it comes free once the
firmware path exists, but isn't a goal). **CD audio deferred** (data CDs only).

---

## REVISION (2026-06-09) — supersedes §0, §2.2, §5, §7

Three clarifications reshape the plan:

1. **Firmware ≠ Mac detecting the drive.** The Mac mounts a CD via the **RTL
   SCSI device** (INQUIRY type `0x05`, READ TOC, READ(10) @ 2048) + the **Apple
   CD-ROM extension** in the booted System (host software). That's pure FPGA +
   host SW. Firmware only matters for **decoding the image format** (CHD). The
   host-driver requirement can't be "baked into" the RTL drive (it's Mac
   software) — document it / optionally ship a sample HD image with the
   extension preinstalled.
2. **CHD is compressed → unreadable in the FPGA.** It MUST be decoded by
   Main_MiSTer (libchdr) and pushed to the core. **Mechanism now verified by
   source review** (see FIRMWARE GROUND TRUTH below): per-core firmware support
   code decodes the image with `lib/libchdr` and serves **normalized 2048-byte
   user-data sectors** to the FPGA over a **task-file/management channel**
   (`hps_ext.v` cmds `0x61`/`0x62`), *not* the generic `sd_lba` block interface
   and *not* a transparent block device. The good news: the CHD decode itself is
   already abstracted in Main_MiSTer as a clean **"give me LBA N → 2048 bytes"**
   call (`mister_chd_read_sector`) — exactly the §2.2/§5 sector-source interface.
   ⇒ CHD = reuse `support/chd/` + `lib/libchdr` verbatim + a Mac-specific
   FPGA↔firmware bridge, **hardware-validated only** (no Verilator coverage).
3. **CD audio deferred.** 2352 raw + SCSI PLAY AUDIO + routing PCM into the
   core's audio mixer is a separate feature. v1 = **data CDs only**. The full
   Apple audio command set (MAME ground truth) is now documented in **Appendix
   A** so it's ready to implement, not researched, when un-deferred.

**Recommended sequencing (de-risk the novel part first):**
* **Phase 1 (now): in-core ISO/TOAST.** Prove the SCSI CD-ROM *device* — the
  format-independent, novel, risky part — using ISO via the existing block
  interface, fully testable in Verilator + MAME oracle, then on HW (Mac mounts
  an ISO). Architect the device's sector source as a clean **"give me 2048-byte
  block N"** interface with two backends: (a) block-device (ISO) now,
  (b) firmware-fed (CHD) later. This is the "bake it into the drive" goal — the
  device is format-agnostic.
* **Phase 2: firmware CD subsystem for CHD** behind the same interface.
  Cross-repo (Main_MiSTer), hardware-only.
* **Phase 3: CD audio** (deferred). Orthogonal to format but reuses Phase 2's
  EXT_BUS bridge, so it follows it. Command set in Appendix A; work plan in §5.1.

Why ISO first: the SCSI target + Apple-driver mounting is identical for every
format and is the part most likely to fight us. Proving it on the cheapest,
sim-testable format means Phase 2 only adds a *sector source*, not a new device.

---

## MAME GROUND TRUTH (verified 2026-06-09, `../mame`)

`src/mame/apple/maclc.cpp:352` attaches `NSCSI_CDROM_APPLE` at **SCSI ID 3**
(HD at ID 6) — our existing ID layout is already MAME-faithful. Device model:
`src/devices/bus/nscsi/cd.cpp` `nscsi_cdrom_apple_device`.

* **INQUIRY (page 0):** type `0x05`, removable `0x80`, b2=`01`, b3=`01`, addl
  len `0x31`, vendor `"SONY    "`, product `"CD-ROM CDU-8002 "`, rev `"1.8g"`,
  then vendor bytes `d0 90 27 3e 01 04 91 .. 18 06 f0 fe`. **Our existing
  `scsi_empty_cd` INQUIRY bytes already match this exactly** (it was modeled on
  this device) — reuse verbatim.
* **No-disc sense = ASC `0xB0`** (vendor), *not* `0x3A`. MAME comment
  (cd.cpp:1214): with `0x3A` "MacOS … hammers the drive asking the user to
  format it." `scsi_empty_cd` already returns `0xB0`. Keep it.
* **Block size = 2048** (`cd.h:55`). Data reads use **standard**
  `READ(6)=0x08 / READ(10)=0x28 / READ(12)=0xA8` and `READ CAPACITY=0x25` —
  the Apple device falls through to the base CD handler for these
  (cd.cpp:1789-1797).
* **Apple VENDOR commands (all 10-byte CDBs, group 0xc0):** `EJECT=0xC0`,
  **`READ TOC=0xC1`** (BCD track #s, MSF addresses — *not* standard MMC
  `0x43`), `READ Q SUBCODE=0xC2`, `READ HEADER=0xC3`, audio
  `0xC8–0xCE`. `scsi_command_done`: 0xc0-group commands are length 10.
* **TEST UNIT READY:** GOOD if media present, else no-disc (`0xB0`).
* **CD audio** (CDDA) is wired to the speaker in MAME (`maclc.cpp:355`) — but
  **deferred** here (data CDs only); stub `0xC8–0xCE` as accepted/no-op. The
  **full audio command set is captured in Appendix A** for when it's un-deferred.

**Firmware / internal-vs-external answer (your question):** MAME models the
internal `NSCSI_CDROM_APPLE` and external `NSCSI_CDROM_APPLE_EXT` with
**identical** SCSI behavior (the `_ext` class just delegates; no INQUIRY/command
override). So there is **no per-drive "firmware" the core must provide, and no
internal-vs-external difference** at the SCSI level. What makes the Mac *mount a
data CD* is the **Apple CD-ROM system extension** in the booted System Folder
(host software), or a **driver partition on the disc** (bootable Apple CDs load
their driver from block 0 — that's image content, not core/firmware). The
MiSTer-firmware piece remains **only** for decoding CHD (libchdr); it is
unrelated to the Mac recognizing the drive.

## FIRMWARE GROUND TRUTH (Main_MiSTer + ao486 review, verified 2026-06-09)

Reviewed `../ao486_MiSTer` (FPGA side) and `../Main_MiSTer` (firmware side). ao486
is the canonical MiSTer "firmware data-CD reader," so it answers the Phase-2
unknowns directly. **Key architectural finding:** in the MiSTer-canonical design
the **firmware does ALL CD command interpretation *and* image decode**; the FPGA
is a thin **task-file + data buffer + 3-bit request code**. This is the *opposite*
of our Phase-1 in-RTL SCSI target — see "Architectural fork" below.

### FPGA side (what the core must expose) — `ao486_MiSTer`
* **`rtl/hps_ext.v`** (110 lines, directly copyable): the EXT_BUS bridge. Protocol:
  byte-0 strobe returns a status word `{4'hE, …, ext_req}` (the per-device
  `request` codes); byte-1 sets `ext_addr` (auto-increments, line 63); then
  cmd **`0x61`** = host→core mgmt write (sub-addr `0xF3` routes to the CDDA audio
  FIFO), cmd **`0x62`** = core→host mgmt read, cmd `0x63` = MIDI. **This is the
  "exact EXT_BUS/download handshake" §5 listed as a Phase-2 risk** — now resolved
  to a concrete reference.
* **`rtl/soc/ide.v`** (314 lines): a *dumb* IDE task-file. Guest-facing `io_*`
  registers + a `mgmt_*` port firmware drives + two `dpram` data buffers. Exposes
  a 3-bit `request` (`reset` / `new command` / `data send-recv`). **No INQUIRY /
  READ TOC / READ / CHD logic in RTL at all.**
* **`rtl/soc/cdda.v`** + `hps_ext` `0x61`/`0xF3`: CD-audio PCM path (reference for
  the deferred audio feature).

### Firmware side (what Main_MiSTer already implements) — `Main_MiSTer`
* **`ide.cpp::ide_io(num, req)`** (line 964): the poll handler. `ide_check()`
  returns the `request` word; `req==4` → new command (`cdrom_handle_cmd`), `req==5`
  → data phase (`cdrom_handle_pkt` / `cdrom_read` / mode-select). Data moves via
  `ide_sendbuf`/`ide_recvbuf` to buffer reg 255 (the `ide.v` dpram).
* **`ide_cdrom.cpp`** (1767 lines): a **complete ATAPI/MMC CD-ROM emulation** —
  the full closest analog to our scsi_cdrom, but in C++:
  * `cdrom_parse(num, file)` (line 1657): tries **CHD → CUE → ISO** loaders; "" =
    unmount. Single entry point.
  * `check_iso_file`/`check_magic` (line 62-110): **ISO auto-detect** by reading
    the ISO9660/High-Sierra **PVD at sector 16** across candidate sector sizes
    {2048, 2352-mode1, 2336-mode2, 2352-mode2} + offset 16/24. **More robust than
    our §2.2 "Mode1 sync-bytes" heuristic — adopt this instead.**
  * `read_cd_sectors` (line 994): **normalizes any sector size to 2048** by
    `FileSeek(pre=16|24)` + read 2048 + `FileSeek(post)`. **This is the 2352
    straddle §2.2 feared — trivial in firmware (byte-granular seeks, not
    512-blocks).**
  * `read_toc` (line 556), `cd_inquiry` (1134), `mode_sense` (733),
    `disc_info`/`track_info`, sense (`set_sense`/`get_sense`) — full MMC command
    set. **Note: this is standard MMC `0x43` TOC**, *not* Apple vendor `0xC1`;
    not directly reusable if we keep RTL command decode (Option C).
  * `cdrom_read` (1020): serves data sectors; CHD branch caches a decompressed
    hunk and `memcpy`s the 2048 user bytes out.
* **`support/chd/mister_chd.cpp`** (186 lines) — **the single biggest reusable
  asset, format-clean:**
  * `mister_load_chd(file, &toc)` (line 31): `chd_open` + parse
    `CDROM_TRACK_METADATA2` → fills a `toc_t` (`cd.h`) of tracks (type, sector
    size 2048/2336/2352, start/end, pregap, the CHD 4-sector-pad `offset`).
  * `mister_chd_read_sector(chd_f, lba, d_off, s_off, len, dst, hunkbuf, *hunknum)`
    (line 163): hunk-cached decode — **exactly the "give me LBA N → 2048 bytes"
    sector source §2.2/§5 specify.** Reuse verbatim.
* **`lib/libchdr`** — the decoder (`chd_open`/`chd_read`, FLAC/zlib/huffman). Reuse
  verbatim.

### Architectural fork (the real Phase-2 decision)
| | **A. Hybrid (current plan)** | **B. Firmware target (ao486-style)** | **C. Mac-optimal hybrid** |
|---|---|---|---|
| SCSI command decode | in RTL (`scsi_cdrom`) | in firmware | in RTL (`scsi_cdrom`) |
| Image decode (ISO/CHD/cue) | ISO in RTL via block IF; CHD in firmware | all in firmware | ISO in RTL via block IF; **CHD sector source in firmware via `mister_chd_*`** |
| FPGA role | full SCSI target | thin task-file (`ide.v`-like) | full SCSI target + a CHD sector-fetch bridge |
| Verilator coverage | Phase 1 yes | none | Phase 1 yes |
| Reuses Main_MiSTer | `mister_chd` only | almost all of `ide_cdrom.cpp` | `mister_chd` + libchdr |
| Mac-specific cost | Apple SCSI cmds in RTL + new firmware bridge | Apple SCSI cmds in C++ (port MMC→Apple `0xC1`/`0xB0`/SONY INQUIRY) | Apple SCSI cmds in RTL + small CHD bridge |

**Recommendation: stay with the hybrid (A/C).** The Mac uses an **NCR5380 SCSI bus
the core already arbitrates in RTL** (`scsi.v` + `ncr5380.sv`) — unlike ao486's
register-level ATAPI device that the x86 guest drives, which is *why* ao486 put
command decode in firmware. Our SCSI phase machine + Apple command set belong in
RTL (testable in Verilator, MAME-diffable). Phase 2 then adds **only a CHD sector
source**: reuse `mister_chd_read_sector` + libchdr unchanged, behind the §2.2
"block N" interface. We do **not** need to port `ide_cdrom.cpp`'s MMC command
emulation (our RTL does Apple SCSI), and we do **not** reuse its `read_toc`
(we synthesize the Apple `0xC1` TOC in RTL per §2.3).

## 0. TL;DR / recommendation  *(historical — see REVISION above)*

There are two honest routes to "BIN/CUE":

* **Phase 1 — in-core CD target, no firmware.** A real read-only SCSI CD-ROM
  device that reads **2048-byte logical blocks** off a mounted image via the
  block interface the core already has. Auto-detects the on-disk sector format,
  so it transparently handles **ISO**, **TOAST** (identical to ISO), and a
  **raw single-track data `.bin`** (mounted directly). Fully verifiable in
  Verilator. This is the bulk of the value and the recommended first milestone.

* **Phase 2 — full `.cue`/`.chd` the MiSTer-native way.** Mounting the `.cue`
  *text* file (or a `.chd`) so it "just works" like other CD cores requires
  **Main_MiSTer firmware support code + an `EXT_BUS`/`hps_ext` bridge** in the
  FPGA (this is how ao486 — an ATAPI *data-CD* reader, the closest analog —
  does it; MegaCD/PSX too). Cross-repo, needs hardware to validate. Optional
  follow-on.

> Why `.cue` can't be done in-core: the HPS mounts exactly **one** file per
> slot. Selecting a `.cue` mounts the tiny text file; the core can't then open
> the `.bin` it references. So in-core BIN/CUE means **mount the `.bin`**, and we
> sniff the format from the data. The convenience of picking the `.cue` (and
> multi-track / audio / CHD) is what needs Phase 2.

Everything Phase 1 needs already half-exists: `rtl/scsi.v::scsi_empty_cd`
(SCSI **ID 3**, INQUIRY device-type `0x05`, identifies as
`SONY CD-ROM CDU-8002`) is a media-less CD-ROM stub gated off by
`ENABLE_EMPTY_CD=0` (`rtl/dataController_top.sv:340`). Phase 1 replaces it with a
media-capable target and puts it on a mountable OSD slot.

---

## 1. Current state (verified)

* `rtl/ncr5380.sv` instantiates `DEVS=2` real disk targets (`scsi.v`, SCSI **ID
  6 & 5**) → HPS slots **0,1** (`SC0`,`SC1`), plus `scsi_empty_cd` (ID 3, gated
  off). `scsi.v` is hardwired to **512-byte** blocks (`scsi.v:355` returns
  block-size `0x200`; lengths use `tlen<<9`).
* `MacLC.sv` CONF_STR: `SC0`,`SC1` (HD), `SC2,NVR` (PRAM). `VDNUM=3`
  (slots 0,1 SCSI; slot 2 PRAM). `localparam VD_PRAM=2`.
* `img_size` is a **single** 64-bit bus, valid only for the slot pulsing in
  `img_mounted`; each target latches its own size on its `img_mounted[i]`.
  HD targets get `img_size[40:9]` = byte size ÷512 = count of 512-byte blocks.
* `verilator/sim.v` has its **own** SCSI/HPS wiring; `sim_blkdevice.{h,cpp}`
  serves images (supports `kVDNUM=10`, 512-byte blocks). `sim_main.cpp` has
  `--scsi0/--scsi1`. **CPU-glue/top-level wiring must change in BOTH
  `MacLC.sv` and `sim.v`** (see `docs/verilator_differences.md`).
* `sys/hps_io.sv` is a **generic block device** (no `sd_req_type`/CD channel),
  but it **does** expose the `EXT_BUS` port (line 174) — the hook Phase 2 needs.

---

## 2. Phase 1 — in-core CD-ROM target (ISO / TOAST / raw BIN)

### 2.1 New module `scsi_cdrom` (in `rtl/scsi.v`)

Model on `scsi.v` (the HD target) — reuse its phase machine, REQ/ACK
handshake, `scsi_dpram` buffering, and `io_rd`/`io_wr` generation. Differences:

| Concern | HD target (`scsi.v`) | CD target (`scsi_cdrom`) |
|---|---|---|
| INQUIRY | type 0x00, "SEAGATE ST225N" | type **0x05**, removable **0x80**, **"SONY"/"CD-ROM CDU-8002"** (reuse `scsi_empty_cd` descriptor bytes so the Apple CD driver binds) |
| READ CAPACITY block size | 512 (`0x200`) | **2048** (`0x800`); last-LBA = `(blocks512/4) - 1` |
| READ(6/0x08)/READ(10/0x28)/READ(12/0xA8) | `io_lba=lba`, len `tlen<<9` | logical block N, len L → SD reads `4*N..` , data-out length `L*2048` (standard MMC opcodes; Apple driver uses these for data) |
| TEST UNIT READY | OK | **OK when mounted**, else no-disc (sense `SK_NOT_READY` / ASC **`0xB0`**) |
| WRITE | supported | **rejected** (read-only) → CHECK COND |
| READ TOC | — | **Apple `0xC1`** (BCD/MSF), synthesize single data track (see 2.3) |
| EJECT `0xC0`, READ Q SUBCODE `0xC2`, READ HEADER `0xC3` | — | minimal (eject → set no-disc; subcode/header → zeros) |
| AUDIO `0xC8`–`0xCE`, Q SUBCODE `0xC2` | — | **deferred** — accept as no-op GOOD (data CDs only); full set in **Appendix A** |
| MODE SENSE(6/0x1A) | minimal | minimal valid header (block size 2048) |
| PREVENT/ALLOW MEDIUM REMOVAL (0x1E), START/STOP (0x1B) | — | accept (GOOD) |
| REQUEST SENSE (0x03) | supported | supported (report no-disc `0xB0` when unmounted) |

### 2.2 Block-size mapping & sector source (the crux)

> **Phase 1 = ISO/2048 only** (the 2352 straddle path below is **out of scope**;
> CHD's firmware backend delivers normalized 2048 user data in Phase 2). The key
> deliverable here is a clean **`get block N (2048 bytes)`** interface the device
> reads through, with a block-device backend now and a firmware backend later.

One 2048-byte CD logical block. Layouts (for reference; only 2048 in Phase 1):

* **ISO / TOAST (Mode1/2048 or Mode2/2048):** file is contiguous 2048-byte
  user data. CD block N = SD sectors `[4N .. 4N+3]` (4×512). Clean, 512-aligned,
  reuses the HD buffer pattern (just 4 sectors/block instead of 1).
* **Raw `.bin` (Mode1/2352):** each 2352-byte raw sector = 12 sync + 4 header +
  **2048 user** + 288 EDC/ECC. User data for block N is at file byte
  `N*2352 + 16`, length 2048. 2352 is **not** 512-aligned → the 2048 window
  straddles 5 consecutive 512-byte SD sectors at a variable sub-offset.

**Auto-detect** — prefer Main_MiSTer's proven method over the sync-byte guess:
read the **ISO9660/High-Sierra PVD at logical sector 16** and probe candidate
sector sizes {2048, 2352 mode1 (+16), 2336 mode2 (+24), 2352 mode2 (+24)} for the
`CD001`/`CDROM` magic (`ide_cdrom.cpp::check_magic` line 62; the byte test is
`pvd[0]==1 && "CD001" && pvd[6]==1`). The matching probe yields both `sec_size`
and `data_off`. Fall back to 2048/0. Latch per mount. (Phase-1 ISO will hit the
2048/`data_off=0` case; the others matter only if 2352 `.bin` is in scope.)

**Buffering for 2352:** widen the read path to cover a 2048 window spanning ≤5
SD sectors. Cleanest is a small **image-reader** helper that, given logical
block N, computes `first_sd = (N*sec_size + data_off) >> 9`,
`byte_off = (N*sec_size + data_off) & 511`, issues the needed consecutive SD
reads, and streams out 2048 bytes starting at `byte_off`. For ISO this collapses
to `byte_off=0`, 4 sectors. Implement the reader once; both formats flow through
it.

> If the 2352 straddle path proves too fiddly to land cleanly, fall back:
> **Phase 1 ships ISO/TOAST + 2048-mode `.bin`**, and 2352 `.bin` rolls into
> Phase 2 (firmware already normalizes to user data). Decide during impl.

### 2.3 Synthesized TOC — **Apple READ TOC `0xC1`** (not MMC 0x43)

The Apple driver uses the vendor command `APPLE_READ_TOC=0xC1` with BCD track
numbers and **MSF** addresses (cd.cpp:1296). `cmd[9]` bits 7:6 select the
operation: `00`=first/last track # (BCD), `01`=lead-out start MSF,
`10`=track range from a start track. For a single data track, synthesize:

* op `00`: first track=1, last track=1 (BCD).
* op `01`: lead-out start = `to_msf(capacity)` (BCD M/S/F).
* op `10`: per-track descriptor = ADR/control `0x14` (data track), then start
  MSF (BCD). Frame=LBA → `m=lba/(75*60)`, `s=(lba/75)%60`, `f=lba%75`, each BCD.

Return no-disc (`0xB0`) when unmounted. This is enough for the Apple CD-ROM
driver to read an ISO9660/HFS data CD. (Standard MMC `0x43` need not be
implemented — the Apple driver doesn't use it.)

### 2.4 Wiring `scsi_cdrom` into `ncr5380.sv`

* Give the CD target its own `io_lba/io_rd/io_wr/io_ack/sd_buff_din` on a
  **new block-device index 2** (the two HD targets keep 0,1). Keep the `DEVS=2`
  HD `generate` loop; instantiate the CD target separately wired to index 2.
  Drop/disable `scsi_empty_cd` (superseded).
* Its `target_bsy/cd/io/msg/req/dout` join the same wired-OR mux that already
  handles targets + empty_cd.
* `img_mounted[2]`, `img_size`, `io_*[2]`, `sd_buff_din[2]` come from the new
  HPS slot.

### 2.5 OSD slot + HPS plumbing (`MacLC.sv`)

* CONF_STR: insert CD slot, renumber PRAM:
  * Phase 1: `"SC2,ISO,Mount CD-ROM;"` (CD = block slot **2**). Add `CHD` to the
    ext list only once the Phase-2 firmware path lands → `"SC2,ISOCHD,...;"`.
  * `"SC3,NVR,Mount PRAM;"` (PRAM moves 2 → **3**)
  * **Confirm at impl:** the `SCn` token + 3-char extension list. Extensions are
    3-char chunks (`ISO`,`CHD`). `.toast` is 5 chars → likely won't
    extension-match; treat TOAST as ISO and document "rename `.toast`→`.iso`"
    (RTL auto-detect handles the bytes regardless of name).
* `VDNUM 3 → 4`; `VD_PRAM 2 → 3`. Extend `sd_lba/sd_rd/sd_wr/sd_ack/
  sd_buff_din/img_mounted` stitching for slot 2 (CD) and move PRAM to 3.
* Feed the CD target `img_size` (use `[40:9]`, i.e. 512-block count, ÷4 inside
  the target for 2048-block capacity; for 2352 capacity derives from
  `bytes/2352`).

### 2.6 Sim parity (`verilator/sim.v` + `sim_main.cpp`)

* Mirror §2.4–2.5 wiring in `sim.v` (its own SCSI/HPS glue).
* Add `--cdrom <file>` in `sim_main.cpp` mounting an ISO to the CD slot
  (`sim_blkdevice` already supports the extra slot; bump its used count).
* Update `docs/verilator_differences.md` with the new top-level slot.

### 2.7 Host-side requirement (document, not code)

The booted System needs the **Apple CD-ROM** extension (or a 3rd-party driver,
e.g. FWB CD-ROM ToolKit) to mount the drive. The INQUIRY string
(`SONY CD-ROM CDU-8002`) is a known Apple-supported drive, so the stock Apple
driver should bind. Note in README/handoff.

---

## 3. Verification (Phase 1)

1. **Build gate:** `cd verilator && make clean && make`; boot screenshot still
   shows the memory-test pattern (VIA-SR regression gate from CLAUDE.md).
2. **CD command stream vs MAME oracle:** run MAME `maclc` with the same ISO
   (`docs/mame_compare.md`) and diff the SCSI INQUIRY / READ TOC / READ(10)
   request+response stream against our target. Single run, analyze logs
   (per `feedback_simulation`).
3. **End-to-end:** boot the SCSI HD (`--scsi0 HD0-...hda`, which has the Apple
   CD-ROM extension) + `--cdrom test.iso`; confirm the CD volume mounts on the
   desktop (or at minimum INQUIRY=type5, READ CAPACITY=2048, TOC, and the first
   READ(10) of the HFS/ISO9660 volume header return correct bytes).
4. **Regression:** existing `--scsi0` HD boot unchanged (`check_boot.sh`).

## 4. Quartus-clean check (per CLAUDE.md)

Each new `reg` driven from exactly one `always`; no multi-driver. New SCSI ID 3
target replaces the empty_cd cleanly. Verify before FPGA.

---

## 5. Phase 2 — CHD via firmware  *(scope now concrete after Main_MiSTer review)*

Keep the **Option C** shape: RTL `scsi_cdrom` still decodes every Apple SCSI
command and synthesizes the `0xC1` TOC; firmware supplies **only** normalized
2048-byte sectors for a CHD-mounted image, behind the §2.2 "block N" interface.

**Reuse verbatim from Main_MiSTer (do not re-implement):**
* `lib/libchdr` — the CHD decoder.
* `support/chd/mister_chd.cpp` — `mister_load_chd(file,&toc)` (builds a `toc_t`
  of tracks: type, 2048/2336/2352 sector size, start/end, pregap, the CHD
  4-sector-pad `offset`) and `mister_chd_read_sector(...)` (hunk-cached → 2048
  user bytes). Plus `cd.h` (`toc_t`/`cd_track_t`).

**Mac-specific work to add:**
1. **FPGA bridge.** Port `ao486_MiSTer/rtl/hps_ext.v` onto our `hps_io` `EXT_BUS`
   port (`sys/hps_io.sv` line 174, already exposed). Use the `0x62` core→host
   mgmt-read path to let firmware push sectors into a small CD buffer the
   `scsi_cdrom` sector-source reads, and a `request`/`ext_req` code to signal
   "CD slot wants block N." Mirror `ide.v`'s thin task-file/buffer pattern for
   just the CD sector window (we do *not* need its full IDE register file).
2. **Main_MiSTer support code** (e.g. `support/maclc/` or fold into the existing
   CD path): on mount of a `.chd`, call `mister_load_chd`; pick the data track;
   on each "block N" request, call `mister_chd_read_sector` and ship 2048 bytes
   over the bridge. ~100 lines of glue around the reused functions — **not** a
   new CD emulator.
3. `scsi_cdrom`'s sector source gains a second backend: `chd_mounted ?
   firmware-fed : block-device(ISO)`. No change to the SCSI command logic, TOC
   synthesis, or INQUIRY — those stay in RTL from Phase 1. (TOC capacity/track
   bounds for CHD come from the firmware-supplied `toc_t`.)

**What we deliberately DON'T take from ao486:** its in-firmware MMC command
emulation (`cdrom_handle_pkt`, `read_toc`, `cd_inquiry`, `mode_sense`) — our RTL
target already speaks Apple SCSI, and ao486's TOC is MMC `0x43`, not Apple `0xC1`.

* **Risks:** cross-repo (Main_MiSTer build), the bridge handshake is new Mac glue
  (but `hps_ext.v` is a copyable template), **hardware-only** validation (no
  firmware in Verilator). Smaller than originally feared — the hard part (CHD
  decode + TOC parse + sector normalization) is reused, not written.

---

## 5.1 Phase 3 — CD audio (deferred; follow-on after Phase 2)

**Status: DEFERRED.** v1 = data CDs only. Listed as a first-class phase so the
work and its dependencies are explicit. CD audio is **orthogonal to the
data-format axis** — it applies to raw `.cue`/`.bin` audio tracks *and* CHD audio
tracks, not just one format — but it **depends on Phase 2's EXT_BUS bridge** for
the PCM transport, so it sequences **after** Phase 2.

Three pieces:
1. **RTL audio command handlers** in `scsi_cdrom` — `0xC8–0xCE` + `0xC2` READ Q
   SUBCODE: a small state machine over CDDA position + play/pause/stop +
   per-channel gain. **CDB layouts & semantics: Appendix A (§A.2)** (all `0xCx`
   are 10-byte CDBs; MSF/track fields BCD). Phase 1 already stubs these as no-op
   GOOD — Phase 3 makes them real.
2. **2352-byte raw audio read path** — distinct from the 2048 data path. Red Book
   CD-DA = 2352 B/sector, 16-bit signed stereo, 44.1 kHz. ISO/cue audio tracks
   read raw 2352; CHD audio tracks via `mister_chd_read_sector` at 2352 (Phase
   2's decode, different length).
3. **PCM into the core audio mixer** — feed CD-DA samples into the ASC audio
   output with per-channel gain set by `0xCE` AUDIO CONTROL. Transport reuses the
   Phase-2 EXT_BUS bridge (ao486 reference: `rtl/soc/cdda.v` + `hps_ext.v` cmd
   `0x61`/sub-addr `0xF3` PCM FIFO).

Also fold in MODE SENSE page `0x0E` (CD Audio Control) here (§A.3).

**Verification:** Verilator covers the command state machine (play/pause/stop/
status/position over a synthetic TOC); the actual PCM mix is **HW-validated** (no
audio render in sim). **No rework of the Phase 1/2 data path.**

---

## 6. Touch list

**Phase 1 (RTL + sim, this repo only):**
* `rtl/scsi.v` — new `scsi_cdrom` (2048-block target, format auto-detect, TOC).
* `rtl/ncr5380.sv` — instantiate CD target on block-index 2; retire empty_cd.
* `rtl/dataController_top.sv` — pass CD `img_*`/`io_*`/`sd_buff_din[2]`.
* `MacLC.sv` — CONF_STR (+CD slot, renumber PRAM), `VDNUM`, `VD_PRAM`, slot
  stitching.
* `verilator/sim.v` — same wiring.
* `verilator/sim_main.cpp` — `--cdrom` arg.
* `docs/verilator_differences.md`, README/handoff — host-driver + toast note.

**Phase 2 (optional, cross-repo):**
* `rtl/hps_ext.v` (new) — port `ao486_MiSTer/rtl/hps_ext.v`; wire `EXT_BUS` in
  `MacLC.sv` + a thin CD sector-buffer/`request` in `scsi_cdrom`.
* `Main_MiSTer` — `support/maclc/` glue (~100 lines) calling reused
  `support/chd/mister_chd.cpp` + `lib/libchdr`; hook into the OSD CD slot mount.
* Reused unchanged: `Main_MiSTer/lib/libchdr`, `support/chd/mister_chd.{cpp,h}`,
  `cd.h`.

**Phase 3 (CD audio, deferred — see §5.1 + Appendix A):**
* `rtl/scsi.v` — audio command handlers (`0xC8–0xCE`, `0xC2`) + 2352 raw read
  path; MODE SENSE page `0x0E`.
* `MacLC.sv` / `rtl/dataController_top.sv` — CD-DA PCM into the ASC mixer +
  per-channel gain reg.
* `rtl/hps_ext.v` + `Main_MiSTer` — extend the Phase-2 bridge with the `0xF3`
  PCM FIFO; firmware ships 2352 audio sectors via `mister_chd_read_sector`.

## 7. Open decisions to confirm before coding
1. **2352 `.bin` in Phase 1, or defer to Phase 2?** Now lower-risk: adopt the
   firmware `check_magic` PVD probe (§2.2) for detection, and the
   `read_cd_sectors` seek-skip pattern for normalization. Still recommend
   **ISO/2048 first**, 2352 as a fast-follow once the 2048 path is proven.
2. **CONF_STR token/ext** — confirm `SCn` + 3-char ext matching; toast handling.
3. **One CD drive (ID 3) or two?** Default: one, at ID 3 (Apple default).
4. **Architectural fork confirmed?** Recommendation is the **hybrid (Option
   A/C)**: RTL Apple-SCSI command decode + Verilator-testable ISO in Phase 1,
   firmware `mister_chd_*` sector source in Phase 2. Rejecting the full
   ao486-style firmware target (Option B) because the Mac arbitrates SCSI in RTL.
   Confirm before Phase 2 (it's the one place we could instead go all-firmware).

---

## Appendix A — Apple CD audio command set (MAME ground truth)

> **Status: DEFERRED (v1 = data CDs only).** Captured now so the audio feature is
> a known quantity, not a research project, when we pick it up. Source:
> `../mame/src/devices/bus/nscsi/cd.cpp` `nscsi_cdrom_apple_device` (the device
> `maclc.cpp` attaches at SCSI ID 3). Spec: *"Apple CD-ROM SCSI Command Set"* v1.4,
> 1988 — Apple's customization of the **Sony CDU-541** command set. **All
> `0xCx` CDBs are 10 bytes** (`scsi_command_done`: `command & 0xf0 == 0xc0 →
> length 10`). Multi-byte MSF/track fields are **BCD**.

### A.1 Vendor command map (`apple_scsi_command_e`, cd.cpp:1192)
| Opcode | Name | Audio? | Plan handling |
|---|---|---|---|
| `0xC0` | EJECT DISC | — | data-CD: stop+unload, set no-disc sense; honor PREVENT/ALLOW |
| `0xC1` | READ TOC | — | **data-CD (§2.3)** — already required |
| `0xC2` | READ Q SUBCODE | playback pos | data-CD: zeros OK; audio: real position |
| `0xC3` | READ HEADER | — | minimal (zeros); MAME has no handler → base/illegal |
| `0xC8` | AUDIO TRACK SEARCH | ✓ | deferred |
| `0xC9` | AUDIO PLAY | ✓ | deferred |
| `0xCA` | AUDIO PAUSE | ✓ | deferred |
| `0xCB` | AUDIO STOP | ✓ | deferred |
| `0xCC` | AUDIO STATUS | ✓ | deferred |
| `0xCD` | AUDIO SCAN | ✓ | deferred |
| `0xCE` | AUDIO CONTROL (volume) | ✓ | deferred |

### A.2 Audio command CDB layouts & semantics (cd.cpp:1376-1799)
Common: **address mode = `CDB[9] & 0xC0`** → `0x00`=LBA, `0x40`=MSF (BCD in
`CDB[5..7]`), `0x80`=track # (BCD in `CDB[5]`; **track 0 = stop**).

* **`0xC8` AUDIO TRACK SEARCH** — seek/arm play position without altering the
  fundamental play/pause state. `CDB[1] bit4`: 1=play, 0=pause-after-seek. Sets
  start LBA; uses `m_stop_position` as the end. → `start_audio(start, stop-start)`.
* **`0xC9` AUDIO PLAY** — `CDB[1] bit4`: 0 = `CDB` carries the **start** addr
  (stop was set by a prior STOP); 1 = `CDB` carries the **stop** addr (start was
  set by a prior TRACK SEARCH). MSF in `CDB[3..5]` for this opcode. Track 0 in
  track-mode = stop. → `cdda->start_audio()`.
* **`0xCA` AUDIO PAUSE** — `CDB[1] == 0x10` → pause; else → resume **and**
  cancel any active scan.
* **`0xCB` AUDIO STOP** — sets `m_stop_position` (per address mode; track-mode
  uses *end* of the given track, i.e. next track start − 1). If current LBA has
  already passed it → stop immediately.
* **`0xCC` AUDIO STATUS** — returns **6 bytes**. `type = CDB[3]`:
  * `type 0`: `[0]` = status code {`0`=PLAYING, `1`=PAUSED, `2`=PLAYING_MUTED,
    `3`=REACHED_END, `4`=ERROR, `5`=VOID/idle}; `[1]`=0; `[2]`=ADR/control of
    current track; `[3..5]` = current absolute **MSF (BCD)**.
  * `type 1` ("volume status"): `[0]`=left gain 0-255, `[1]`=right gain 0-255.
* **`0xCD` AUDIO SCAN** — fast scan from the addressed position; `CDB[1] bit4`:
  0=forward, `0x10`=reverse. Terminated by an `0xCA` PAUSE-OFF.
* **`0xCE` AUDIO CONTROL (volume)** — `scsi_data_out` of `CDB[8]` bytes into
  buffer id 3; `scsi_put_data` byte 0 → **left output gain** (`/255`), byte 1 →
  **right output gain**. This is the per-channel CD-DA volume.
* **`0xC2` READ Q SUBCODE** — returns **9 bytes** (all BCD where applicable):
  `[0]`=control nibble, `[1]`=track, `[2]`=index(=1), `[3..5]`=relative M/S/F,
  `[6..8]`=absolute M/S/F.

### A.3 Supporting pieces (not `0xCx`, but part of audio support)
* **MODE SENSE page `0x0E`** = CD Audio Control page (cd.cpp:273/587). **MODE
  SENSE page `0x30`** = the "magic Apple page" (`apple_magic[0x17]`, cd.cpp:606)
  — *also relevant to driver binding even for data-only*; worth implementing in
  Phase 1 if the stock Apple driver proves picky.
* **PCM characteristics:** Red Book CD-DA = **2352 bytes/sector, 16-bit signed
  stereo, 44.1 kHz**. The audio path reads raw 2352 sectors (not 2048).
* **Routing:** `maclc.cpp:355` routes the drive's CDDA output to the Mac speaker.
  For us this means the FPGA must **mix CD-DA PCM into the core audio output**
  (ASC mixer), with per-channel gain set by `0xCE`. Reference: ao486's
  `rtl/soc/cdda.v` + `hps_ext.v` cmd `0x61`/sub-addr `0xF3` PCM FIFO.

### A.4 Work breakdown
→ See **Phase 3 (§5.1)** for the work breakdown, dependencies, and verification.
This appendix is the command-set reference that phase implements against.
