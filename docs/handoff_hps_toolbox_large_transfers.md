# Handoff prompt — HPS-side BlueSCSI Toolbox large transfers

Paste everything below the line into the session that owns `../Main_MiSTer`.
Written 2026-07-31, after the core-side SEND transport fix landed in
`MacLC_MiSTer` (`5d87ace`, ported from MacIIvi `205800b` + `7efe80e`).

---

## Task

Raise the BlueSCSI Toolbox per-command transfer size above the current
512-byte SEND / 4 KB GET baseline, in the Main_MiSTer fork.

**Repo:** `../Main_MiSTer`, branch `add-bluescsi-toolbox-for-MacLC`
**Tip at writing:** `4370d00`
**File:** `support/mac/mac_toolbox.cpp` (+ `mac_toolbox.h`)

This is a **throughput** change. The wire protocol is already specified —
do not invent encodings. See `docs/BLUESCSI_HANDOFF.md` §4.3 (GET) and
§4.5 (SEND) in the MacLC repo for the authoritative CDB layouts.

## DO NOT REDO — already committed

- `4370d00` **buffered SEND writes.** `/media/fat` is exFAT mounted
  `sync,dirsync`, and the old per-chunk `fseeko` defeated stdio buffering,
  costing one synchronous card `write()` per 512-byte chunk (~5500 for a
  2.7 MiB file, each exposed to multi-ms erase stalls). Now `setvbuf` 64 KB
  plus a `ftello`-guarded seek, so a sequential copy flushes in ~64 KB runs.
  Because buffering hides I/O errors from `fwrite`, every close site checks
  `fflush`/`ferror`/`fclose` and SEND END reports CHECK on failure.
- `96caa9d` **LBA-1 tail reassembly.** A 512-byte SEND payload sits at
  request-block bytes 16..527, so its last 16 bytes arrive as a separate
  request block at LBA 1 (`tb_tail`). Do not disturb this.

If you find yourself editing `setvbuf`, the seek guard, or `tb_tail`, stop —
you are redoing solved work.

## Current state, measured

**HPS side (`mac_toolbox.cpp`):**

| thing | value | line |
|---|---|---|
| `TB_PAYLOAD_OFF` | 16 | 223 |
| `TB_PAYLOAD_MAX` | 496 (`512 - 16`) | 224 |
| `TB_CHUNK_MAX` | **512** — the SEND ceiling | 225 |
| `tb_tail[]` | 512 B, LBA-1 block | 227 |
| `tb_get` block parse | `blocks = cdb[6] ? cdb[6] : 1; want = blocks * 4096` | 189 |
| `tbx_channel::resp` | `std::vector<uint8_t>` — **no fixed ceiling** | 33 |

So **GET is already multi-block aware on this side** and the response
staging is unbounded; **SEND is structurally 512-only** (`TB_CHUNK_MAX`,
and the 496-under-CDB + 16-tail split).

**Core side (`MacLC_MiSTer`, branch `toolbox-large-files`):**

| thing | value |
|---|---|
| tb buffer | `TB_ADDRW=11` → **4 KB** (2 dprams × 2^11 × 8 bit) |
| `TB_MAXSEC` | `1 << (TB_ADDRW-8)` = **8** sectors |
| `tb_srv_len` | clamps a served DataIn to `TB_MAXSEC * 512` |
| `data_len` for 0xD4 | **fixed 32'd512** — the DataOut phase is exactly one block |
| 0xD9 capabilities | **`0x00` — nothing advertised** |

## The coupling that decides everything

Three things must agree, and **the capability byte is the gate**:

1. **The core advertises** capabilities in `0xD9` DEVICE INFO subcmd 1
   (`0x01` = CAP_LARGE_TRANSFERS, multi-block GET; `0x02` = CAP_LARGE_SEND,
   up to 64 × 512 = 32 KB per SEND). It currently returns `0x00`, so
   **clients stay at baseline no matter what you change here.** An HPS-only
   change accomplishes nothing until the core advertises.
2. **The core must buffer a whole chunk.** The design stages the entire
   payload before the HPS round trip, so chunk size ≤ tb buffer.
3. **The HPS must handle the chunk** — this task.

### Core RAM budget — read before proposing 32 KB

The core sits at **507/553 RAM blocks (92%)**, 46 free. Each `TB_ADDRW`
step doubles both lane dprams (~8192 usable bits per M10K in ×8 mode):

| TB_ADDRW | buffer | extra M10K | RAM total |
|---|---|---|---|
| 11 (now) | 4 KB | — | 507 (92%) |
| 12 | 8 KB | +4 | ~511 |
| 13 | 16 KB | +12 | ~519 |
| 14 | 32 KB | +28 | ~535 (97%) |

The protocol's 32 KB ceiling is *barely* reachable and would re-roll every
unpinned memory in the design (this project has repeatedly been bitten by
that "migrating victim" behaviour). **Do not assume 32 KB is available.**

## Recommended staging

**Stage 1 — 4 KB SEND, no new core RAM.** The buffer already holds 4 KB.
Raise `TB_CHUNK_MAX` to 4096, generalise the head/tail reassembly (the
payload now spans request-block sectors 0..8, not just 0..1), and keep
clamping to whatever the CDB says is valid. That is an 8× cut in round
trips for uploads at zero FPGA cost. Coordinate with the core session:
it must advertise `0x02` and extend `data_len`/the DataOut length for
0xD4 from the fixed 512 to `CDB[6] * 512`, keeping the rule that the
phase length is the **full block count**, never the valid-byte count —
that confusion was the original bug (`5d87ace`).

**Stage 2 — measure before going further.** With buffered writes already
in, the remaining cost per chunk is one SCSI round trip, not a card write.
Measure MB/s at 512 B vs 4 KB before spending RAM on 8/16/32 KB.

## Hazards

- **Serving law.** Transfer EXACTLY what the initiator armed. Over- and
  under-serving are both HW-witnessed bus wedges in this project. For SEND
  the DataOut length is the full block count from CDB[6]; the valid-byte
  count only tells you how much to *write to disk*.
- **Both CDB encodings stay supported.** `CDB[6]` (512-blocks) when
  non-zero, else legacy `u16(CDB[1..2])`. v0 clients use the legacy form
  and the final partial chunk of a large-send file uses it too.
- **Offsets are in 512-byte blocks** (`CDB[3..5]`, 24-bit BE) in both
  encodings — not bytes.
- **Never change the request-block layout** (CDB at [0..9], payload at
  [16..]). The core mirrors it exactly.
- The core clamps a DataIn serve to `TB_MAXSEC * 512`; if you stage a
  longer response it is silently truncated, so keep the two in sync.

## Verification

- `MacLC_MiSTer/verilator/scsi_bench --mode toolbox` mirrors this handler
  (COUNT / LIST / SEND / GET round trips) and is the fastest desk check;
  `--mode toolboxslow` models an HPS that stalls past the watchdog.
- On hardware: copy files **both** directions and byte-compare. Use sizes
  that are deliberately NOT multiples of the chunk size, plus one that is —
  the original bug only showed on the short final chunk, so an
  exact-multiple file will pass a broken build.
- Watch for 16-byte holes at 512-byte intervals: that signature means the
  tail reassembly broke.
