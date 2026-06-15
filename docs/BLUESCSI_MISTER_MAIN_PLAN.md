# BlueSCSI Toolbox — MiSTer Main (HPS) Implementation Plan

High-level plan for the **HPS/firmware half** of BlueSCSI Toolbox support on this
core. The wire protocol (every opcode, byte layout, phase, edge case) is fully
specified in **`BLUESCSI_HANDOFF.md`** and is *not* repeated here — that document
is platform-agnostic and tells you *what* the bytes mean. This document is the
MiSTer-specific realization: *where* the logic lives, *how* the FPGA core and the
ARM `Main_MiSTer` binary talk, and *what* changes in each.

Goal (per the user): copy files **to and from** the emulated Mac via a host-side
**shared folder**, using the stock "BlueSCSI SD Transfer" Mac client. CD
switching and the other Toolbox extras are **out of scope**.

> Sibling repo: the HPS firmware source is the **`Main_MiSTer`** checkout next to
> this one (`../Main_MiSTer`). All `user_io.cpp` / `user_io.h` line references
> below are into that tree.

---

## 1. Why this is split across two binaries

The FPGA core has **no filesystem** — it reaches the outside world only through
the HPS. Every interesting Toolbox command (`0xD0` LIST, `0xD1` GET, `0xD3/4/5`
SEND) is a *filesystem* operation. Therefore the Toolbox **command logic must
live in `Main_MiSTer`** (the ARM Linux side that has `scandir`/`open`/`read`/
`write`), and the FPGA SCSI target becomes a thin pass-through that ferries the
CDB and bytes between the SCSI bus and the HPS.

This is unlike Snow (the reference impl in `../snow/core/src/mac/scsi/toolbox.rs`),
where the emulator *is* the host and calls `std::fs` in-process. Our "host" is a
separate binary across an SPI link, so the work is a **port + a transport**, not
a drop-in.

---

## 2. RTL ↔ HPS boundary — what actually needs Main

Not every Toolbox opcode needs the HPS. Detection and the static replies are
pure RTL (they look just like the existing `INQUIRY` / `MODE SENSE` responders in
`rtl/scsi.v`). Only the filesystem ops cross to the HPS:

| Concern | Side | Notes |
|---|---|---|
| Device detection: INQUIRY, MODE SENSE **page 0x31** magic string | **RTL only** | Extend the existing `mode_sense_dout` mux in `rtl/scsi.v` (~L437). No Main change. |
| `0xD9` DEVICE INFO / capabilities | **RTL only** | Static bytes (device list, API ver, cap flags). Like INQUIRY. |
| `0xD6` TOGGLE DEBUG | **RTL only** | A stored bool; can be a no-op. |
| `0xD2` COUNT, `0xD0` LIST | **HPS** | Directory scan. |
| `0xD1` GET (download) | **HPS** | `File::read` at offset — reuses the disk **read** machinery. |
| `0xD3/D4/D5` SEND (upload) | **HPS** | `File::write` — reuses the disk **write** machinery. |

**Consequence for sequencing:** detection + `0xD9` can be proven with **zero Main
changes** (see Milestone 0). The Main fork is only needed once you want a real
file list and transfers.

The only RTL changes the protocol forces (from `BLUESCSI_HANDOFF.md` §1):
accept `0xD0–0xD9` as **10-byte CDBs** (today `rtl/scsi.v` L702–703 only decodes
command groups `000/001/010`), and route the filesystem opcodes through the new
HPS channel below instead of the disk read/write path.

---

## 3. Transport — reuse the SD-block path (no new SPI protocol)

The enabling insight: MiSTer's **SD-card emulation path is already a
core-driven, bidirectional, 16 KB bulk pipe** between the SCSI target and the
HPS. We ride it instead of inventing a new SPI channel.

How it already works in the poll loop (`user_io.cpp`):
- Core drives, HPS polls: each `user_io_poll()` issues `UIO_GET_SDSTAT`; bit
  `0x8000` = request pending, `op = c&3` (1=read, 2=write), `disk = (c>>2)&0xF`,
  then the LBA is read (L3186–3194).
- **Write (core→HPS):** `spi_w(UIO_SECTOR_WR|ack)` + `spi_block_read(buffer,…)`
  pulls up to `sz` bytes out of the core's `sd_buff` (L3285–3287).
- **Read (HPS→core):** fill `buffer`, then `spi_w(UIO_SECTOR_RD|ack)` +
  `spi_block_write(buffer,…)` pushes them in (L3426–3428).
- Host buffer is **`buffer[16][UIO_BUFFER_SIZE]` = 16 KB/slot** (L3176;
  `UIO_BUFFER_SIZE`, `user_io.h` L167).
- There is already a **non-caching, create-on-write device type** (`type==2`):
  it forces `buffer_lba=-1` every access (L3430–3433) and creates the file on the
  LBA-0 write (L3289). This is the precedent for "this slot is special, don't
  treat it as a flat image."
- Special-slot dispatch already exists: `a2_*`, `c64_*`, `n64_process_save` are
  branched ahead of the generic file path (L3256–3274). **Our Toolbox handler
  hooks in exactly here.**

### Mechanism: a reserved "Toolbox" disk slot

1. Allocate one extra virtual-disk slot (MacLC has SCSI-6, SCSI-5, PRAM today;
   add a 4th `VD_TOOLBOX`). Wire its `sd_lba/sd_rd/sd_wr/sd_buff/sd_ack` through
   `sys/hps_io.sv` like the others.
2. Mark that slot with a new **`SD_TYPE_TOOLBOX`** so the poll loop dispatches it
   to the Toolbox handler rather than `FileRead/WriteAdv`.
3. A Toolbox command is a **write-then-read transaction** on that slot:
   - **Request (write op):** core writes a control block = `[10-byte CDB]` +
     (for SEND) the Data-Out payload. HPS parses the CDB and runs the handler.
   - **Response (read op):** HPS stages `[status][u16 length][response bytes]`;
     core reads it and feeds it into the SCSI Data-In/Status phases.

Because GET (≤32 KB) and SEND (≤32 KB) exceed one 512-byte sector, the **bulk
payload rides the normal multi-block read/write**, while the small CDB rides a
reserved **control LBA**. GET then maps onto `FileReadAdv` and SEND onto
`FileWriteAdv` — i.e. the bulk data path is *already built*; the only new HPS code
is the directory scan, the file open/close lifecycle, and opcode routing.

> **First detailed-design task (left open here):** pin the exact control-block
> framing — which reserved LBA carries the CDB, how the HPS returns the dynamic
> response *length* to the RTL before the Data-In phase, and the read-back of the
> final status. Recommended: in-band control block (rides only `UIO_SECTOR_RD/WR`,
> no new opcodes). Alternative if framing is awkward in RTL: a tiny out-of-band
> `UIO_TB_*` register pair. This choice is the contract in §4.

---

## 4. The core↔HPS contract (build the two halves independently)

Both halves only need to agree on this. Freeze it first.

- **Request block (core→HPS, write op @ control LBA):**
  `cdb[0..9]` · `flags` (dir = DataIn/DataOut/None) · `u16 outdata_len` ·
  `outdata[…]`.
- **Response header (HPS→core, read op @ control LBA):**
  `status` (0x00 GOOD / 0x02 CHECK) · `u16 data_len` (actual bytes the HPS will
  serve — drives the RTL Data-In length; a short value signals EOF per
  `BLUESCSI_HANDOFF.md` §4.3).
- **Bulk data:** subsequent read ops (DataIn) or write ops (DataOut) move
  `data_len`/`outdata_len` bytes via `sd_buff`, chunked to ≤16 KB.
- **Two-pass Data-Out** (`BLUESCSI_HANDOFF.md` §1.5): for SEND, the handler is
  first asked with no payload (returns "need N bytes"), the core collects N on
  the bus, then the handler is re-presented with the payload and returns status.
  The transaction framing must allow this round trip.

---

## 5. `Main_MiSTer` changes (the deliverable of this plan)

1. **New `toolbox.cpp` / `toolbox.h`** — a near-direct port of
   `../snow/core/src/mac/scsi/toolbox.rs` / `BLUESCSI_HANDOFF.md` §4:
   `list_files`, `count_files`, `get_file`, `send_file_prep/10/end`. State =
   `{ shared_dir, FILE* open_file }` (§3 of the handoff). Enforce the
   stable-sort, dotfile filter, 255-entry cap, and the path-escape hardening
   (§3, §4.4, gotcha #10).
2. **`user_io.cpp` poll-loop hook** — in the special-slot dispatch
   (L3256–3274), add `if (sd_type[disk]==SD_TYPE_TOOLBOX) toolbox_handle(op, lba,
   buffer[disk], …)` ahead of the generic read/write branches (L3275 write,
   L3325 read). Add a `tb_*` state block next to `sd_image[]`.
3. **New `SD_TYPE_TOOLBOX`** device type + the mount path that sets it when the
   shared folder is configured (analogous to how `sd_type[]` is assigned today).
4. **Shared-folder config** — how `shared_dir` gets set. Lightest options:
   an `.ini` key (e.g. `shared_folder=/media/fat/shared`) read at init, or a
   "Mount Shared" menu entry that stores a *directory* path instead of opening a
   file. (No existing folder-picker precedent was found in Main, so this is a
   small addition either way — config plumbing, not protocol.)
5. **MacRoman ⇄ UTF-8 helpers** — port Snow's `util::mac` (`macroman_to_utf8` /
   `utf8_to_macroman`) or add the fixed 128-entry table (`BLUESCSI_HANDOFF.md`
   §6). Needed for filenames with accented characters.
6. **Build / deploy** — `make` in `Main_MiSTer` (ARM cross-toolchain
   `arm-linux-gnueabihf`); output is the `MiSTer` binary at the SD-card root;
   reboot to load. Carry as a fork rebased onto each upstream release tracked
   (currently running **.143**).

---

## 6. Data-flow walkthroughs

- **LIST (`0xD0`, Data-In):** RTL writes CDB → HPS `scandir`+sort builds
  `40×count` bytes, returns `data_len` → RTL drains it (chunked) into Data-In →
  Status GOOD. *Exercises the whole transport + the dynamic-length handshake.*
- **GET (`0xD1`, Data-In):** RTL writes CDB → on `offset==0` HPS opens the
  indexed file; HPS `FileReadAdv(offset×4096, count×4096)` → returns actual bytes
  (short = EOF) → RTL Data-In. *Bulk read reuses the disk read machinery.*
- **SEND (`0xD3→0xD4*→0xD5`, Data-Out):** PREP creates/opens the file (33-byte
  name payload); each DATA writes `bytes` at `offset×512` via `FileWriteAdv`
  (two-pass Data-Out); END flushes/closes. *Bulk write reuses the disk write
  machinery; only the file-handle source differs.*

---

## 7. Milestones

- **M0 — Detection, no Main fork.** RTL-only: MODE SENSE page 0x31 + INQUIRY +
  `0xD9` + `0xD6`. The Mac client detects the device and opens its transfer
  window (listing empty). Proves detection with zero HPS work.
- **M1 — First HPS round trip.** `0xD2` COUNT + `0xD0` LIST end-to-end. Client
  shows the real file list. Proves the transport + dynamic length (the two
  riskiest pieces) before touching the file lifecycle.
- **M2 — Download.** `0xD1` GET. A >4 KB file copies host→Mac, byte-exact; test
  both `CDB[6]=0` (v0) and multi-block.
- **M3 — Upload.** `0xD3/D4/D5` SEND. A non-512-multiple file copies Mac→host,
  byte-exact, including the legacy final-chunk encoding; re-upload overwrites.

Validate against the checklist in `BLUESCSI_HANDOFF.md` §5.

---

## 8. Risks & open decisions

1. **Dynamic response length.** `rtl/scsi.v` drives `data_len` up front; Toolbox
   lengths are HPS-decided, so the RTL must read the response header (§4) *before*
   serving Data-In. This restructures the phase flow for Toolbox opcodes (not a
   drop-in like INQUIRY). Primary RTL design point.
2. **32 KB transfer vs 16 KB buffer.** `CAP_LARGE_TRANSFERS`/`CAP_LARGE_SEND`
   advertise 32 KB, but `buffer[]` is 16 KB. Either cap the advertised capability
   (serve ≤16 KB / 4×4 KB blocks) or chunk into ≤16 KB buffer-fills (the existing
   multi-block flush already does this).
3. **Mid-command HPS stall / client timeout.** The round trip injects HPS-poll
   latency mid-command. Architecturally this is the *same* stall the disk read
   path already absorbs (`io_busy`/`req_bus`-held — the #2 prefetch saga), so the
   mechanism exists; risk is the Toolbox client having tighter timeouts than the
   HD driver. Probe early (M1).
4. **Distribution / upstream tracking.** A custom `MiSTer` binary affects **every
   core** on the box and must be rebased per release. Given the Toolbox authors'
   stated "prototype then port" intent, the clean long-term play is to **upstream
   a generic Toolbox folder-service** to Main (usable by any core) rather than
   carry a private fork.
5. **Shared-folder config mechanism** — `.ini` key vs menu entry (§5.4). Decide
   before M1.
6. **Slot allocation** — confirm a free `VD_TOOLBOX` index and `sys/hps_io.sv`
   `VDNUM` headroom alongside SCSI-6 / SCSI-5 / PRAM.

---

## 9. References

- `docs/BLUESCSI_HANDOFF.md` — the complete, authoritative protocol spec (read
  this for any byte-level question).
- `../snow/core/src/mac/scsi/toolbox.rs` — reference implementation to port
  (and `controller.rs` / `mod.rs` for the `ScsiCmdResult` Data-In/Out/Status
  dispatch model; `util/mac` for MacRoman).
- `../Main_MiSTer/user_io.cpp` — SD-block transport & poll loop (hook points
  L3176, L3256–3274, L3285, L3325, L3426); `user_io.h` — UIO opcodes.
- `rtl/scsi.v` — SCSI target (CDB decode L697–733, MODE SENSE responder ~L437,
  the `io_busy`/prefetch stall the round trip reuses).
- BlueSCSI Toolbox Developer Docs —
  https://github.com/BlueSCSI/BlueSCSI-v2/wiki/Toolbox-Developer-Docs
