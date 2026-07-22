# BlueSCSI Toolbox CD Changer — Core↔HPS Contract (DESIGN)

Pins the wire contract for the BlueSCSI **CD image switcher** so the guest Mac can
enumerate and swap CD-ROM images *from within the running core* — no MiSTer OSD
trip. The intended client is **MacAtrium**, which auto-selects the correct disc for
a CD-ROM game before launching it, but any BlueSCSI-Toolbox-aware Mac app (incl. the
stock BlueSCSI CD utility) speaks the same three commands.

This is the CD-side sibling of `BLUESCSI_CORE_HPS_CONTRACT.md` (the file-sharing
Toolbox on the *disk* target, ID 0). It reuses that document's transport verbatim —
only the target, the opcode set, and the HPS handler differ.

Protocol semantics: BlueSCSI Toolbox Developer Docs (CD Changer section),
https://github.com/BlueSCSI/BlueSCSI-v2/wiki/Toolbox-Developer-Docs.
This doc specifies the **transport** (how the CDB + data cross the SPI block link)
and the **enumeration policy** (which files we list and how we mount them).

Status: **core RTL implemented + fit/STA-clean 2026-07-20** (approach (b), §10); HPS
handler + Mac client still pending. Fit: 507/553 M10K, STA met +0.247 ns (no timing
delta vs the pre-changer baseline). Command layout and media-change semantics confirmed
against BlueSCSI firmware (§2.2, §6). A stock Main still returns CHECK for
`0xD7/0xD8/0xDA` (graceful degradation, §7) — the changer lights up only when the
Main-fork handler mounts the CD-toolbox slot. OSD `SC4` CD swapping is unchanged; this
adds the Mac-side path alongside it.

---

## 1. Architecture (decided)

- **Commands land on the CD target (SCSI ID 3).** Per the BlueSCSI spec, LIST/COUNT
  enumerate a folder named for the target's ID — **`CD3/`** for our CD-ROM at ID 3.
  The initiator selects ID 3 and issues the CDB, so the transport must hang off
  `cdrom_target`, not the ID-0 disk that carries the file-sharing Toolbox.
- **The CD folder is HPS-side and configurable.** BlueSCSI's convention is `CD<id>`
  (→ `CD3/`), kept as the **default**. The core never sees the folder name — it
  forwards `0xD7/D8/DA` blind and the HPS picks the directory — so the folder is a
  pure Main-fork config knob (ini key / core setting), overridable with **no RTL
  change**. Lets the changer point at a specific game-library directory.
- **Reuse the existing transport, gate it separately.** `cdrom_target` is already the
  shared `scsi.v` module and already exposes the `tb_*` round-trip ports — today tied
  off (`ncr5380.sv`: `.tb_mounted(1'b0)`, `.tb_ack(1'b0)`, `TOOLBOX_ENABLE` unset). We
  turn them on with a **new, distinct parameter `CDCHANGER_ENABLE`** (NOT the disk's
  `TOOLBOX_ENABLE`, which would also make the CD advertise the file-sharing mode page
  0x31 and the `0xD0–D5` file ops — wrong device personality). `CDCHANGER_ENABLE`
  routes only `0xD7/0xD8/0xDA` into the transport FSM.
- **Dedicated control slot `VD_CD_TOOLBOX = 5` (VDNUM 5→6).** A second control-only
  hps_io slot, exactly like `VD_TOOLBOX=3` is for the disk. Never a real image; every
  access is a control op. The CD *data* slot `VD_CDROM=4` is untouched — the disc the
  guest reads still comes through it.
- **The switch is an HPS remap of `VD_CDROM`.** `0xD8` does not move disc bytes over
  this transport. It tells the HPS "make image N the CD"; the HPS remaps the
  `VD_CDROM` backing file — the same operation the OSD `Mount CD-ROM` performs —
  which pulses `img_mounted[VD_CDROM]` and drives the media-change the guest already
  understands (§6).

## 2. The three commands (FROZEN)

All CDBs are **10 bytes**. `0xD7/0xD8/0xDA` are group-110 vendor opcodes — the CDB
length must be special-cased to 10, same as the file Toolbox `0xD0–D9`
(`BLUESCSI_HANDOFF.md` §1.1). They do **not** collide with the Apple CD command set
(`0xC0–0xCF`, `cmd_apple_cd_op = op_code[7:4]==4'hc`).

| Opcode | Name        | Data phase | CDB |
|--------|-------------|------------|-----|
| `0xDA` | COUNT CDS   | Data-In(1) | `DA 00×9` |
| `0xD7` | LIST CDS    | Data-In(40×N) | `D7 00×9` |
| `0xD8` | SET NEXT CD | none (status only) | `D8 <index> 00×8` |

### 2.1 COUNT CDS (`0xDA`) → Data-In(1)
Single byte = number of mountable images in the CD folder (post-filter, §3). `0` if
empty/absent. **Capped at 100** (§3.5): a folder with >100 valid images serves 100 and
the HPS `log()`s the truncation. (BlueSCSI instead returns CHECK / `TOO_MANY_FILES`
above 100; we prefer serving the first 100.)

### 2.2 LIST CDS (`0xD7`) → Data-In(40 × count)
One **40-byte `ToolboxFileEntry`** per image, in the stable sorted order (§3):

| Offset | Size | Field |
|--------|------|-------|
| 0      | 1    | Index (0-based; the key `SET NEXT CD` takes) |
| 1      | 1    | Type flag — **INVERTED: `0x01` = file, `0x00` = directory** (images always `0x01`) |
| 2      | 33   | Filename, **ASCII `0x00–0x7F` only** (§3.4), NUL-padded, truncated to 32 chars |
| 35     | 5    | File size in bytes, **40-bit big-endian** |

> ✅ **Layout confirmed against BlueSCSI firmware** (`onListFiles()`,
> `src/BlueSCSI_Toolbox.cpp`; `ENTRY_SIZE=40`, `MAX_MAC_PATH=32`). Two easy-to-miss
> traps: the **type byte is inverted** (`isDir = isDirectory() ? 0x00 : 0x01`, so
> `1`=file), and the size is **40-bit** (5 bytes) BE at offset **35**, *not* 32-bit at
> 36. NB: the repo's older file-sharing handoff (`BLUESCSI_HANDOFF.md` §4.2) documents
> a 32-bit size at 36 — but the firmware uses this same 40-byte `onListFiles` for
> *both* file and CD listings, so §4.2 is the stale one. Follow the firmware here;
> reconcile §4.2 separately.

count × 40 bytes exceeds one 512-byte block past 12 entries, so the CD transport uses an
**8-sector (4 KB) buffer** (`TB_ADDRW=11`) and **fetches all `ceil(len/512)` sectors up
front, then serves linearly** (§4) — covering the full 100-entry list in one pass. The
file Toolbox keeps its single 512-byte buffer (`TB_ADDRW=8`); the size is a per-target
parameter, so disk behaviour is unchanged.

### 2.3 SET NEXT CD (`0xD8 <index>`) → status only
No data phase. `CDB[1]` = the index from a prior LIST. HPS remaps `VD_CDROM` to that
image and triggers the media change (§6). Out-of-range index or remap failure →
CHECK. GOOD once the new image is mounted.

### 2.4 Client detection — MODE SENSE page 0x31 + INQUIRY CD-ROM (LOAD-BEARING)
A Toolbox client finds the changer **before** issuing any vendor opcode, by probing
each SCSI ID with a *standard* command pair (verified against MacAtrium's
`toolbox_probe_id`, and the same as the BlueSCSI app):
1. **MODE SENSE(6) page 0x31** (`0x1A`, `CDB[2]=0x31`, alloc 64) → the response must
   contain the magic prefix **`BlueSCSI is the BEST`** anywhere in the returned bytes.
2. **INQUIRY** → peripheral device type must be **`0x05` (CD-ROM)** — this is how the
   client tells the CD changer apart from the file-Toolbox HDD (which also carries the
   0x31 magic). Without it, `LIST/SET` would land on the disk → "Unknown command D7h".

So the **CD target must serve BOTH**: INQUIRY PDT `0x05` (already does) **and** the
page-0x31 magic. The RTL adds `cd_ms31` (`CDCHANGER_ENABLE && MODE SENSE page 0x31`)
which serves the existing `mode_sense_p31_byte` (56-byte magic) on the CD target — only
for an explicit page-0x31 request; the AppleCD driver's page 0x30 / default MODE SENSE
is untouched. **Gating (current): ungated** (`CDCHANGER_ENABLE`, not `cdtb_ready`) so
detection works standalone before the HPS handler lands — MacAtrium tolerates the
follow-up `LIST/SET` CHECK gracefully (`toolbox_list_cds` returns 0). For a **release**,
revisit gating on `cdtb_ready` (the §4a "advertise only when serviceable" rule) once the
stock BlueSCSI file app is confirmed not to engage a CD's 0x31 advert.

> **Without page 0x31 the whole feature is invisible** — this was the "No BlueSCSI CD
> device found" gap (2026-07-21): the CD answered INQUIRY as a CD-ROM but a CDROM
> target's MODE SENSE always returned CD mode pages, never the magic.

## 3. Enumeration & filtering policy (HPS-side, in `maclc_cd`)

Real BlueSCSI does **zero** filtering ("no universal name for a CD image"). We are
deliberately smarter: list exactly the set `maclc_cd` can mount, collapse redundant
members of a CUE/BIN set, and keep order stable.

| File in `CD3/` | List? | Mount as |
|---|---|---|
| `.iso`, `.toast` | ✅ direct | flat 2048-byte (stock path) |
| `.chd` | ✅ direct | maclc_cd CHD decoder |
| `.cue` | ✅ direct | maclc_cd (parses tracks / sector size) |
| `.bin` referenced by **any** `.cue` | ❌ suppress | via its `.cue` |
| `.bin` **not** referenced by any `.cue` | ✅ **raw-2352** | synthesized single-track Mode-1/2352 (§3.2) |

### 3.1 CUE/BIN collapse — parse, don't basename-match
Suppress a `.bin` only if some `.cue` actually references it. Read each `.cue`'s
`FILE "…" BINARY` lines and build the set of referenced BINs; suppress those. This
handles multi-track cues, cues whose BIN has a different stem, and multiple cues in
one folder — basename matching gets all three wrong.

### 3.2 Lone `.bin` → assume raw 2352 (decided)
A `.bin` with no cue referencing it **is listed** and mounted as a single data track,
**2352 bytes/sector, Mode 1** (the common raw-dump geometry). Robustness: before
committing 2352, `maclc_cd` should sniff the first sector's 12-byte sync pattern
(`00 FF FF FF FF FF FF FF FF FF FF 00`) — present ⇒ 2352 confirmed; absent ⇒ fall
back to 2048. This keeps a mislabeled 2048 dump from mounting corrupt.

### 3.3 Stable index is load-bearing — LIST and SET must share one enumerator
Enumerate non-recursively, **sort by filename, filter, then assign 0-based indices**.
MacAtrium may LIST once and `SET NEXT CD` later against a cached index; unstable order
= wrong disc mounted. Filter dotfiles (`.DS_Store` et al.) and validate the extension
**on the full name before truncating** (BlueSCSI truncates first, which can miss a long
name's extension). Names are truncated to 32 bytes for the entry — the **index, not the
name, is authoritative** (truncation can collide display names; never the index).

> **Deliberate deviation from BlueSCSI:** the firmware does **no sorting** — it serves
> raw exFAT `openNext()` order, so its indices shift when files are added/removed. We
> sort for stability. **The invariant this creates:** `0xD7` LIST and `0xD8` SET
> (BlueSCSI's `get_file_from_index`) must walk the **same** sorted, filtered order — so
> index N *lists* and *mounts* the same disc. Route both through one shared enumerator;
> any divergence silently mounts the wrong CD.

### 3.4 Filename encoding — ASCII only, no MacRoman
The BlueSCSI wire format nominally carries MacRoman filenames, but our images live on an
**exFAT** SD card (Unicode names) and MacAtrium matches by ASCII name — so we skip
MacRoman entirely. The HPS emits **ASCII `0x00–0x7F`** in the name field; any non-ASCII
byte/codepoint in the source name is replaced with `_` (`0x5F`). No conversion table, no
NFC/NFD dance. Name CD images in ASCII (the norm for game discs); accented characters
degrade to `_` in the listing, but the **index** — the key `SET NEXT CD` uses — is
unaffected.

### 3.5 Max 100 images
Enumerate at most 100 valid images (BlueSCSI's `MAX_FILE_LISTING_FILES`). Beyond 100,
LIST serves the first 100 and COUNT returns 100; the HPS **must `log()`** the truncation
so a dropped disc is visible, not mysteriously absent. (BlueSCSI hard-errors with CHECK
/ `TOO_MANY_FILES` above 100 — we take the softer cap.)

## 4. Transport (reuse of the disk Toolbox round-trip)

Identical FSM to `scsi.v`'s `TBS_IDLE→LOAD→REQ→STAT→LATCH→DATA→RDY`, gated on
`CDCHANGER_ENABLE` instead of `TOOLBOX_ENABLE`, driving the CD target's `tb_*` slot:

| Step | Op | LBA | Payload |
|---|---|---|---|
| 1. Request | `tb_wr` | 0 | `[0..9]` = the 10-byte CDB |
| 2. Status  | `tb_rd` | 0 | HPS returns `[0]`=SCSI status · `[1]`=`0xB5` signature · `[2..3]`=Data-In length |
| 3. Data k  | `tb_rd` | `1+k` | (LIST/COUNT only) 512-byte block; last partial |

- `0xDA`/`0xD7` are Data-In → run steps 1-3, serve `len` bytes via `PHASE_DATA_OUT`
  (the disk serve path verbatim). **`0xD7` fetches all `N=ceil(len/512)` sectors
  (`k=0..N-1`, LBA `1+k`) up front into the 4 KB buffer — sector `k` at word offset
  `k·256` — then serves linearly.** The Mac-facing `PHASE_DATA_OUT` timing is therefore
  single-block-identical; only the fetch loop (`TBS_DATA`) is new (approach (b), §10).
- `0xD8` is status-only → steps 1-2; `len=0` ⇒ FSM goes straight to `TBS_RDY`,
  emit the latched status. No data phase (mirrors `0xD5 SEND END` — requesting a data
  phase here would hang the client).
- The `0xB5` signature check (step 2, `TBS_LATCH`) already guards against a stock HPS
  serving blank blocks: no handler ⇒ `[1] != 0xB5` ⇒ CHECK (§5).
- **SEND-payload collection (`tb_collect`) is unused here** — no CD-changer command
  carries Data-Out. The CD transport can drop that path; the CDB-load + Data-In serve
  are all it needs.

## 5. Plumbing (bottom-up)

| Level | Add |
|---|---|
| `rtl/scsi.v` | new params `CDCHANGER_ENABLE=0`, `TB_ADDRW=8` (CD sets 11 → 4 KB buffer); decode `0xD7/0xD8/0xDA` (10-byte CDBs — extend `cmd_toolbox_op` to `0xDA`) into `cmd_ok` + a `cmd_cdc_*` class driving `phase→PHASE_TB`; gate the `tb_*` FSM + `tb_ready` on `TOOLBOX_ENABLE \|\| CDCHANGER_ENABLE`; `data_len` for `0xD7/0xDA` = latched `tb_len`; multi-sector fetch loop in `TBS_DATA`. **No media-change RTL — `0xD8`'s HPS remap of `VD_CDROM` rides the existing `img_mounted` path (§6).** |
| `rtl/ncr5380.sv` | on `cdrom_target`: set `.CDCHANGER_ENABLE(1)`; replace the tied-off `tb_*` with real wires to the new slot (`.tb_mounted(cdtb_mounted)`, `.tb_lba(cdtb_lba)`, `.tb_rd`, `.tb_wr`, `.tb_ack(cdtb_ack)`, `.tb_buff_din(cdtb_buff_din)`). |
| `rtl/dataController_top.sv` | pass the 6 `cdtb_*` signals straight through. |
| `MacLC.sv` | `localparam VD_CD_TOOLBOX=5; VDNUM=6;` wire `sd_lba[5]/sd_rd[5]/sd_wr[5]/sd_buff_din[5]=cdtb_*`, `cdtb_ack=sd_ack[5]`, `cdtb_mounted=img_mounted[5]`. **No CONF_STR mount entry** for slot 5 (control-only, like `VD_TOOLBOX`). |
| `sys/hps_io.sv` | none beyond the `VDNUM=6` the instantiation already propagates. |

`sd_buff_addr/dout/wr` are global hps_io outputs already wired; the CD-changer buffer
self-gates its HPS writes on `cdtb_ack`, mirroring the disk Toolbox buffer.

## 6. Media-change contract (the make-or-break)

After `0xD8`, the Mac's CD driver must notice a disc change and re-read the TOC, or it
keeps showing the old volume.

**Design rule: `0xD8` reuses the *existing* MiSTer CD media-change path — it invents
nothing new.** The path that already swaps discs today (OSD `Mount CD-ROM` / `0xC0`
eject → `img_mounted[VD_CDROM]` remount) is simply re-triggered from a SCSI command.

### 6.1 How BlueSCSI does it (firmware-confirmed reference)
BlueSCSI's `0xD8` runs a deliberate **two-stage, host-poll-driven** handshake (from
`BlueSCSI_disk.cpp` `switchNextImage`, `BlueSCSI_cdrom.cpp` `cdromCloseTray`,
`SCSI2SD sense.h`/`scsi.c`):
1. On `0xD8`: close the old image, open `CDn/<name>`, recompute capacity/blocksize, set
   state **ejected + reinsert-pending** (`cdrom_events = 2`, "new media").
2. Next `TEST UNIT READY` → **CHECK CONDITION, sense `0x02` / ASC `0x3A` / ASCQ `00`
   (MEDIUM NOT PRESENT)** — reports the drive "open" — *and* internally arms the tray
   close.
3. Following command → **CHECK CONDITION, sense `0x06` / ASC `0x28` / ASCQ `00`
   (NOT-READY→READY, MEDIUM MAY HAVE CHANGED)** — a **one-shot** UNIT ATTENTION.
4. Host `REQUEST SENSE` sees the UA, then re-reads `READ TOC` + `READ CAPACITY` and
   remounts. (UA clears once delivered; in BlueSCSI it's gated on
   `S2S_CFG_ENABLE_UNIT_ATTENTION` — a target that doesn't model that flag should just
   always post it.)

The switch is **poll-driven, not pushed:** `0xD8` only stages the new image + the
ejected flag; the not-ready and the UA are emitted on the *following* two host polls.

### 6.2 What our (AppleCD) core does — reuse the path, don't copy the sense codes
Our CD target emulates the **AppleCD** (MAME `nscsi_cdrom_apple_device`); the classic-Mac
AppleCD driver already drives it via a TEST-UNIT-READY insertion poll, and OSD disc
swapping already works on that path in the shipped release. So:
- **Primary — reproduce the OSD eject→remap→remount cycle.** HPS remaps `VD_CDROM`
  (→ `img_mounted` pulse; capacity re-read at `scsi.v` ~line 540) and drives the same
  `0xC0` eject transition (`cd_eject_pulse`, ~line 548). Stage-1 not-ready uses **our
  Apple no-disc sense (ASC `0xB0`)** that the AppleCD driver already expects — **not**
  BlueSCSI's generic `0x3A`. This *is* "the standard media change we have now."
- **Belt-and-suspenders — post `0x06` / `0x28` / `00` UNIT ATTENTION** on the first
  command after ready (mirroring BlueSCSI) **only if** the prerequisite test shows the
  plain not-ready→ready remount isn't reliable for a programmatic swap. Since the OSD
  swap already remounts, this is probably unnecessary — but it's the proven fallback,
  and it's cheap to add to the CD sense path.
- **Prerequisite (do this first):** confirm on HW that an OSD disc **A→B** swap actually
  remounts B (mount A → OSD-swap to B → verify B mounts). If yes, `0xD8` = trigger that
  same cycle from the command → nearly free. If the Mac *doesn't* remount on OSD swap
  today, that's a pre-existing gap to close first, and the `0x06`/`0x28` UA is the fix.

### 6.3 Ordering
`0xD8` may return GOOD as soon as the remap is staged; the media-change rides the
subsequent `img_mounted` pulse + host polls (§6.1). MacAtrium should poll for the new
volume (or delay) before launching the game.

## 7. Graceful degradation (stock Main, no CD folder)

Mirror `BLUESCSI_CORE_HPS_CONTRACT.md` §4a:
- `cdtb_ready` latches from `img_mounted[VD_CD_TOOLBOX]`. Stock Main never mounts slot
  5 ⇒ `cdtb_ready=0` ⇒ `0xD7/0xD8/0xDA` fall out of `cmd_ok` ⇒ CHECK. The client sees
  no CD changer; nothing hangs.
- **OSD CD swapping is unaffected** either way — it runs through `VD_CDROM`, which this
  feature never touches.
- The `0xB5` signature (belt-and-suspenders) stops a blank block being read as a real
  status/length if slot 5 is ever mounted against a non-handler HPS.

## 8. HPS obligations (Main fork, `add-bluescsi-toolbox-for-MacLC`, `maclc_cd`)

On the `VD_CD_TOOLBOX` slot poll loop:
- **write @ LBA 0** → parse `buffer[0..9]` as the CDB, dispatch:
  - `0xDA` → stage `{status=GOOD, [1]=0xB5, len=1}` + a 1-byte count.
  - `0xD7` → enumerate the configured CD folder (default `CD3/`) per §3, stage
    `{GOOD, 0xB5, len=40×count}` + the entries.
  - `0xD8` → remap `VD_CDROM` to the configured folder's index `CDB[1]`; stage
    `{GOOD/CHECK, 0xB5, len=0}`. Trigger the `img_mounted[VD_CDROM]` cycle (§6). Re-init
    the new image's **TOC / sector-size** (esp. CUE / mixed-mode) so the post-swap
    `READ TOC` / `READ CAPACITY` serve the *new* disc, not the old geometry.
- **read @ LBA 0** → return `{status, 0xB5, len_hi, len_lo}`.
- **read @ LBA 1+k** → return bytes `[k×512 .. +511]` of the staged Data-In.
- No CD folder / unreadable → stage `status=CHECK, len=0` (client tolerates as
  "no changer").

Enumeration + the CUE/BIN parse + raw-2352 sniff (§3) live here, extending the
existing `maclc_cd` CD-image handling (which already mounts ISO/TOAST/CUE/CHD).

## 9. MacAtrium client flow

1. SCSI-Manager pass-through to **ID 3**: `0xDA` (count) → `0xD7` (list, match the
   game's disc by name/size, learn its index).
2. `0xD8 <index>` to mount it.
3. Poll for the new volume (or a fixed settle) before launching.

**Prerequisite risk (MacAtrium-side):** issuing arbitrary CDBs needs SCSI Manager
pass-through (`SCSIAction`/`SCSIRead` with a custom TIB) — the same mechanism the
BlueSCSI Toolbox app uses. Validate that independently; the stock BlueSCSI CD utility
can exercise `0xD7/D8/DA` to prove the core+HPS before MacAtrium integration.

## 10. Fit / resource cost

**Approach (b) — chosen 2026-07-20.** The 12-CD cap of a single-block transport is not
about M10K; it's that 512 B ÷ 40 B/entry = 12. To serve the full 100-entry list we
enlarge the CD target's `tb_buf0/tb_buf1` to **8 sectors (4 KB, `TB_ADDRW=11`)** and
**fetch-all-then-serve** — spending RAM to keep the change *out* of the delicate
serve/stall timing (approach (a), multi-block interleaved serve, was rejected for that
reason). Cost: the two CD `scsi_dpram` lanes go 512 B → 4 KB ≈ **4 M10K on the CD
target** (the file-Toolbox disk buffers stay at `TB_ADDRW=8`). The CD partition is **no
longer at the M10K ceiling** — blocks were freed since the CD-audio missions — so this
is expected to fit without a compensating pin. Still:
- Audit `map.rpt` global RAM totals before any fitter run (per the Quartus-CLI memory
  note) to confirm the headroom held after the netlist re-rolls all unpinned RAMs.
- Re-validate with the **triple gate** that is standard for this block: per-domain STA
  (fat) + boot probe + per-seed display check. The **per-seed display check stays LAW**
  here regardless of headroom — STA-met-alone has masked HW-marginal builds in this
  design before.
- Fallback if headroom is ever lost: hoist the transport to one shared `ncr5380`-level
  block muxed by target (disk vs CD), dropping the duplicate buffers.

## 11. Validation

- **RTL gate:** `quartus_map --analysis_and_elaboration MacLC` 0-errors;
  `scsi.v/ncr5380.sv/dataController_top.sv/MacLC.sv` warning-clean.
- **Fit gate:** triple gate (§10).
- **Functional (needs the Main handler + a CD folder):**
  - [ ] `0xDA` count matches the filtered listing.
  - [ ] `0xD7` names/sizes correct; CUE/BIN pair shows **one** entry (the cue); lone
        `.bin` shows and mounts (2352, sync-confirmed); ISO/TOAST/CHD all list.
  - [ ] Two LISTs in a row: identical order (stable sort).
  - [ ] `0xD8` swaps the disc; the Mac **re-reads the TOC and remounts** the new
        volume (data disc mounts; audio/mixed disc plays).
  - [ ] `0xD8` handshake: after the swap, `TEST UNIT READY` returns not-ready (Apple
        `0xB0`), then the next command drives the remount / TOC re-read. Add the
        `0x06`/`0x28` UA only if the plain remount proves unreliable (§6.2).
  - [ ] Switch data→audio→data cycles cleanly (no stale TOC).
  - [ ] Stock Main (no CD folder): changer absent, CHECK, OSD swap + boot unaffected.
  - [ ] MacAtrium auto-selects the right disc for a multi-disc title end-to-end.

## 12. Decided / deferred

- **No auto-advance.** MacAtrium always sets the disc explicitly by index; there is no
  bare "next disc" increment. (Decided 2026-07-20.)
- **Max 100 images (firm).** LIST caps at 100 entries (the BlueSCSI limit); COUNT is
  one byte. Discs beyond 100 are not listed — the HPS must `log()` the truncation so a
  silently-dropped disc is visible, not mysteriously absent.
- **Configurable CD folder.** Default `CD3/`, HPS-overridable (§1, §8). The core is
  folder-agnostic, so this is a Main-fork config knob with no RTL impact.
- **Write-back / create images** from the guest — out of scope; read-only changer.
