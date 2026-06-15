# BlueSCSI Toolbox — Core↔HPS Transport Contract (FROZEN)

This pins the exact wire contract between the FPGA core and `Main_MiSTer` for the
Toolbox filesystem commands, so the RTL (this repo) and the HPS handler
(`Main_MiSTer`, later) can be built independently and meet in the middle. It is
the concrete realization of `BLUESCSI_MISTER_MAIN_PLAN.md` §3–4.

Protocol semantics (what the bytes mean) live in `BLUESCSI_HANDOFF.md`. **This
doc only specifies the *transport*** — how a Toolbox CDB and its data cross the
SPI block link.

Status: **frozen design, RTL implementation in progress.** M0 (detection:
`0xD9`/`0xD6`/MODE SENSE 0x31) is already done in `rtl/scsi.v` and needs none of
this. This contract covers M1+ (the filesystem ops `0xD0/D1/D2/D3/D4/D5`).

---

## 1. Architecture (decided)

- **Dedicated, isolated VD slot.** A new hps_io block-device slot
  `VD_TOOLBOX = 3` (VDNUM 3 → 4). The disk read/write path is **not touched** —
  zero regression risk to the (hard-won) disk I/O.
- **Primary target only.** The Toolbox transport + buffer live in `rtl/scsi.v`,
  enabled by a new `parameter TOOLBOX_ENABLE` that is set **only on the ID 6
  target** (`i==0` in the ncr5380 generate loop, `scsi #(.ID(3'd6-i))`). The ID 5
  target is a plain disk. No second-target arbiter.
  - M0 detection is currently in the shared module so *both* targets advertise
    Toolbox. When wiring M1, gate the detection (`mode_sense_p31`, `cmd_tb_*`) on
    `TOOLBOX_ENABLE` too, so only ID 6 presents as a Toolbox device.
- **Non-prefetched sequential transfer.** Unlike the disk read ring, Toolbox data
  moves one 512-byte block at a time (fetch-then-serve). File transfer is not
  boot-critical; the per-block HPS stall is acceptable and keeps the FSM small.

## 2. Plumbing (the new signals, bottom-up)

A single (non-array) Toolbox block interface threaded up to slot 3:

| Level | Add |
|---|---|
| `rtl/scsi.v` | params `TOOLBOX_ENABLE`; ports `tb_lba[31:0]` (o), `tb_rd` (o), `tb_wr` (o), `tb_ack` (i), `tb_mounted` (i), `tb_buff_din[15:0]` (o). Shares the existing `sd_buff_addr/sd_buff_dout/sd_buff_wr` inputs. A 512-byte `scsi_dpram` toolbox buffer (only generated when `TOOLBOX_ENABLE`). |
| `rtl/ncr5380.sv` | same 5 ports (single, not `[DEVS]`); connect to the `target` instance **only when `i==0`** (else tie `tb_rd/tb_wr=0`). `tb_ack` gated by `target_bsy[0]` like the disk `io_ack`. |
| `rtl/dataController_top.sv` | pass the 5 ports straight through. |
| `MacLC.sv` | `VD_TOOLBOX=3`, `VDNUM=4`; `assign sd_lba[3]=tb_lba; sd_rd[3]=tb_rd; sd_wr[3]=tb_wr; tb_ack=sd_ack[3]; tb_mounted=img_mounted[3]; sd_buff_din[3]=tb_buff_din;`. **No CONF_STR mount entry for the slot until Main lands** (see §4a). |
| `sys/hps_io.sv` | none beyond the `VDNUM=4` the instantiation already propagates. |

`sd_buff_addr/dout/wr` are global hps_io outputs already wired in; the Toolbox
buffer reuses them (its writes self-gate on `tb_ack`, mirroring the disk buffer's
`sd_buff_wr & target_bsy[i]`).

## 3. The transport contract (FROZEN)

The Toolbox slot is **never a real disk image** — every access is a control op.
512-byte blocks (the sd_buff sector size). All multi-byte ints big-endian.

**A Toolbox command = one request write, then a status read, then (DataIn only)
data reads:**

| Step | Op | LBA | Buffer payload |
|---|---|---|---|
| 1. Request | `tb_wr` | `0` | `[0..9]`=CDB · `[10]`=dir flag · `[11..12]`=outdata_len · `[16..]`=SEND payload (≤512−16) |
| 2. Status  | `tb_rd` | `0` | HPS returns `[0]`=SCSI status (`00`/`02`) · `[1]`=signature `0xB5` · `[2..3]`=DataIn byte length |
| 3. Data k  | `tb_rd` | `1+k` | (DataIn only, `k=0,1,…`) pure 512-byte data block; last block partial |

- **dir flag** (`[10]`): `0`=DataIn (LIST/COUNT/GET/D9-style), `1`=DataOut (SEND),
  `2`=none (status only). Lets the HPS pick the two-pass path without re-decoding.
- **Status block is header-only** (no data) — keeps data blocks at clean 0-based
  512-byte offsets, avoiding the off-by-N byte-slip class this core has bled over.
- The HPS **runs the handler during step 1** (the write) and stages the result;
  steps 2–3 just read it back. The core waits for each `tb_ack` before the next
  op, so ordering holds across the HPS poll loop.
- **EOF on GET** is a `len` shorter than requested (incl. `len=0`), per
  `BLUESCSI_HANDOFF.md` §4.3 — surfaced via the step-2 length, not an error.

## 4. scsi.v FSM (new phases)

```
CMD_IN ─(0xD0/D1/D2/D9-fs, DataIn)─────────────► TB_REQ ─► TB_STAT ─► DATA_OUT ─► STATUS_OUT
        ─(0xD3/D4 SEND, DataOut)─► DATA_IN ─────► TB_REQ ─► TB_STAT ─────────────► STATUS_OUT
        ─(0xD5 SEND END, none)──────────────────► TB_REQ ─► TB_STAT ─────────────► STATUS_OUT
```

- **TB_REQ**: write CDB (+ collected SEND payload) to the tb buffer, pulse `tb_wr`
  @ LBA 0, wait `tb_ack`.
- **TB_STAT**: pulse `tb_rd` @ LBA 0, wait `tb_ack`, latch `status` and `len`.
- **DATA_OUT (Toolbox)**: serve from the tb buffer; `data_len = len`. When the Mac
  drains the current 512-byte block, fetch the next (`tb_rd` @ LBA `1+k`) and
  stall via the existing `io_busy` mechanism until `tb_ack`. Serve until `len`.
- **STATUS_OUT**: emit the latched `status` (GOOD/CHECK), then MSG/IDLE as today.

`cmd_dout` gains a Toolbox source reading the tb buffer (like it reads buffer0/1
for disk reads). `data_len` for Toolbox-fs commands = the latched `len`.

## 4a. Graceful degradation — safe to deploy with NO HPS handler

The core must run correctly on a **stock `Main_MiSTer`** (no Toolbox handler, no
shared folder). Guarantees:

1. **Disk I/O & boot: unaffected.** The dedicated slot isolates the Toolbox path;
   the disk read/write engine is unchanged. The core boots and runs identically to
   today whether or not the HPS side exists.
2. **Toolbox path is dormant unless the client pokes it.** The FSM only activates
   on `0xD0–0xD5`, which only the BlueSCSI client sends. M0 detection is pure RTL
   and works standalone.
3. **No hang, no garbage — gate on `tb_ready`.** Latch `tb_ready` from
   `tb_mounted` (`img_mounted[VD_TOOLBOX]`). The round-trip (TB_REQ/TB_STAT) is
   entered **only if `tb_ready`**; otherwise `0xD0–0xD5` return **CHECK CONDITION
   immediately** with no `tb_rd`/`tb_wr` issued. With a stock HPS and no shared
   folder the slot is never mounted → `tb_ready=0` → the client reads "no shared
   folder / empty" (`BLUESCSI_HANDOFF.md` §5, §8) — the dormant M0 state.
   - The stock HPS *would* ack slot 3 (its poll loop services slots 0–3, blank-
     block-and-ack for an unmounted image), so the gate isn't strictly required to
     avoid a hang — but it makes degradation **deterministic** instead of relying
     on undefined blank-block contents (`0x00` vs `0xFF`).
4. **Signature check (belt-and-suspenders).** If a round-trip ever does happen
   against a non-Toolbox HPS (e.g. someone mounts a flat image on the slot), the
   step-2 status block's `[1] != 0xB5` → CHECK, so a blank block's `0x00`/`0xFF`
   is never served as a real status/length.
5. **No CONF_STR mount entry for the slot until Main lands**, so a flat image
   can't be pointed at it by accident. The shared-folder config arrives with the
   HPS handler.

Net: M0 works standalone today; M1 degrades cleanly to "empty folder" on a stock
HPS and lights up only when the Main handler + shared folder land. The core never
breaks or hangs either way.

## 5. HPS obligations (Main_MiSTer, built later against this)

On the `SD_TYPE_TOOLBOX` slot, in the `user_io.cpp` poll loop:
- **write op, LBA 0** → parse `buffer[0..9]` as the CDB, run the Toolbox handler
  (port of `snow/.../toolbox.rs`, per `BLUESCSI_HANDOFF.md` §4), stage `{status,
  DataIn bytes}`. For SEND, also consume the payload at `buffer[16..]`.
- **read op, LBA 0** → return `{status, 0xB5, len_hi, len_lo}` (the `0xB5`
  signature tells the core a real Toolbox handler answered — see §4a).
- **read op, LBA 1+k** → return data bytes `[k×512 .. k×512+511]` of the staged
  DataIn response.
- No shared folder configured → stage `status=CHECK (0x02)`, `len=0` (the client
  tolerates this as "empty", per §5/§8 of the handoff).

## 6. Validation

- **Now (RTL):** `quartus_map.exe --analysis_and_elaboration MacLC` must stay
  0-errors and `scsi.v`/`ncr5380.sv`/`dataController_top.sv`/`MacLC.sv`
  warning-clean (see the memory note on the Quartus CLI check).
- **After Main:** HW — run BlueSCSI SD Transfer on the Mac, list/download/upload a
  file against a host shared folder; validate byte-for-byte per `BLUESCSI_HANDOFF.md` §5.

## 7. Open / deferred (not blocking the RTL)

- Shared-folder configuration (ini key vs menu) — HPS-side, decided when Main lands.
- Large-transfer caps (`CAP_LARGE_TRANSFERS`/`CAP_LARGE_SEND`) stay **off** (M0
  advertises `0x00`) until the transport is proven; v0 paths (1×4 KB GET, ≤512 B
  SEND) only. Revisit buffer sizing before advertising 32 KB.
