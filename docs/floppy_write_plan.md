# Plan: Diskette Write Support for MacLC_MiSTer

Scoped 2026-09-07; staging rationale revised 2026-09-14 (§1). Stage 1 (GCR)
is code complete and hardware-gated through Phase 4b as of 2026-09-16; stage 2
(MFM) has not started.

Prior art, all local and all ours:

- `../MacPlus_MiSTer/FLOPPY_WRITE_PLAN.md` — the same feature, phases 0–5 done
  and shipped. Donates RTL and a six-defect review list.
- `../UK101_MiSTer/SAVE_AND_DISK_PLAN.md` — donates the **write-address
  anchoring** design (§6.1) and the multi-slot block-device plumbing pattern.

This plan is not a copy of either. It records what is DIFFERENT here, and what
ports over unchanged.

---

## 1. Scope

**RELEASE GATE — owner's ruling 2026-09-15: nothing is released until every
format is covered.** One PR, one release: GCR *and* MFM, read *and* write *and*
format. The stage split below is INTERNAL SEQUENCING — the order the work was
built and validated in — and is not a shipping plan; the shipped feature is the
whole format list, not a stage of it.

**Stage 1 — GCR (400K/800K).** Exact MacPlus parity, and it keeps the first
hardware write run inside a format whose write semantics are already solved on a
sister core. 1.44MB/720K MFM stays read-only until stage 2.

**Stage 2 — MFM/ISM writes.** §8.

★ Revised 2026-09-14. The original rationale — *"it carries the one design
problem that is new to this core"* — is **retired**: UK101 answered that problem
(§6.1) before any code was written. The split stands on two different legs, both
stronger than the one they replace:

- **Risk containment.** Phase 3 proves the write handshake on hardware for the
  first time, and a wrong handshake HANGS the machine (§2.1, §6.4). A GCR data
  field self-identifies its sector (§4), so a stage-1 commit is gated by
  "checksum valid AND the field named its own sector" — no positional inference
  anywhere in the path. Folding MFM in puts an unproven handshake and an
  unproven positional anchor on the same first hardware run, against the user's
  real images. UK101's severity inversion is the warning (§6.1): its
  rotational-position attempt failed *safely* and was caught by the guest's own
  verify; the more plausible-sounding replacement failed *catastrophically*,
  writing through to media and destroying an unrelated sector header.
- ~~**Shippability.**~~ **RETIRED 2026-09-15** by the release gate above — GCR
  write is not a release on its own any more, so this leg is gone. Risk
  containment carries the split unaided: the first hardware write run should not
  also be the first run of an unproven positional anchor.

What the UK101 find DID change is scheduling *within* stage 1: two stage-2
design decisions are cheap now and expensive to retrofit, so they land in
Phase 3 even though MFM writes ship later — the identity-bearing staging ring
and the format-neutral committer.

**Formatting is IN SCOPE, for both formats.** ★ Corrected 2026-09-15. This
paragraph previously read *"out of scope in both stages, as on MacPlus"* and
both halves of that were wrong:

- **MacPlus ships formatting.** `../MacPlus_MiSTer` `7712c0e` (2026-09-10 —
  three days after this plan was first written) landed Erase Disk, hardware
  confirmed: *"Read, write and a full format have all been confirmed on hardware
  through the chained drive."* Donor inventory in §1.1.
- **MFM formatting is not the flux job it sounds like.** The LC's MFM path is
  BYTE-level: the SWIM does the data separation and the CPU only ever sees
  decoded bytes plus a mark flag through the ISM FIFO (`rtl/mfm_track_encoder.v`
  header; `rtl/swim.v:40` "Push data+mark to FIFO", FIFO b8 = MARK at `:164`).
  A guest format is therefore the CPU pushing `00 x12 / A1 A1 A1 (mark) / FE /
  C H R N / CRC-16 / 4E …` as plain bytes — a byte-stream state machine plus
  CRC-16-CCITT, with no flux recovery, no PLL and no bit windows. If anything it
  is SIMPLER than the GCR decoder, which carries 6:2 nibblization and a
  three-way checksum chain.

So whole-track address-field writes are the same class of work here as sector
writes, not a separate discipline. What makes formatting non-trivial on this
core is not the encoding but the **read-side relay** (§1.1) and the **sidedness
ceiling** (§1.1) — two defects MacPlus already found and fixed, which we would
otherwise rediscover on hardware.

(UK101's `wr_ptr` reset-on-seek makes its FORMAT correct for free — see §6.1.)

### 1.1 Donor inventory — MacPlus `7712c0e` (Erase Disk)

Surveyed 2026-09-15. Only the floppy half of that commit is relevant; its
daisy-chain / HD 20 / `iwm.v` half is Plus-specific and the LC has neither an
HD 20 nor an IWM chip (it has a SWIM).

| From MacPlus | Lines | Transfer to LC |
|---|---|---|
| `rtl/floppy_track_decoder.v` | 384 | **Essentially verbatim.** Machine-independent: raw write-stream bytes + geometry in, verified sectors out. Already reports the address fields a format writes (`amark`, `fmt_mark`, `fmt_ds`) — that *is* its format support. |
| `rtl/floppy_write_committer.v` | 160 | Ports; LC slot / base-address differences only. |
| `rtl/floppy_sd_writer.v` | 218 | Ports; same. |
| `floppy_track_encoder.v` format relay | ~+60 | **Clean port.** Diffed 2026-09-15: our encoder is the same file minus the relay. |
| Media sidedness (`floppy_loader.v` + `floppy.v`) | ~125 | Concept only — our `floppy_loader.v` is the new block-device one, so this is a re-implementation, not a copy. |

Two defects that commit paid for, which we inherit the fixes to rather than
rediscovering:

1. **The format relay / `fmt1Err`.** The ROM requires sector 0 to be the first
   address field it sees after the track is written; a free-running read side
   fails the format. The encoder must relay the read position to wherever the
   format actually put sector 0, measured from the address mark the decoder
   reports.
2. **The sidedness ceiling.** The address field's format byte was derived from
   the image file's SIZE, so a One-Sided erase of an 819,200-byte image
   formatted side 0 and then advertised the disk as double-sided — letting the
   driver build an 800K volume over a side that was never formatted. Every 3.5"
   diskette is one medium; 400K vs 800K is a formatting choice and nothing on
   the diskette records it. `doubleSidedDisk` needs three terms, each a ceiling
   on the next: drive mechanism, file size, then the medium itself (sniffed from
   the volume header at load, re-read from the format byte once a format
   overwrites it).

**Also checked, and no help** (confirming the 2026-09-07 survey in §8 from the
local copies): `../BBCMicro_MiSTer/rtl/fdc1772/fdc1772.v` stubs the WD1772's
Write Track outright — `// write track TODO: fake` at `:657` — and the MiSTer
Atari ST core uses the same file. `../Apple-IIgs_MiSTer/rtl/iwm_flux.v` is
flux-level but Apple GCR, not MFM. Minimig/Amiga does decode written MFM tracks,
but to Amiga track layout (sync `$4489`, odd/even bit split, no IDAM and no
CRC-16), so only the cell-level encoding would transfer and that is exactly the
layer we do not need. See §8 for why the controller-model cores (`u765.sv`,
`fdc1772.v`) structurally cannot donate an answer.

---

## 2. Where the core stands today

**2.1 — Every disk reports write-protected.** `rtl/floppy.v:241` hardwires
`1'b0, // WRTPRT = locked` in `driveRegsAsRead`. The OS reads this, concludes
the disk is locked, and never attempts a write.

★ This is load-bearing today, not merely a default. Per CLAUDE.md the ROM's
write primitive polls its handshake in an UNBOUNDED loop: a write attempted
against the current stub handshake would HANG the machine, not fail.
Unhardwiring WRTPRT and implementing the real handshake are the same commit.

**2.2 — The write datapath is a stub.** `rtl/floppy.v:76` declares
`input [7:0] writeData` and the file never references it again.

**2.3 — The IWM handshake lies.** `rtl/swim.v:176`:

```verilog
assign _iwmBusy = 1'b1;       // write buffer empty
assign _writeUnderrun = 1'b1;
```

**2.4 — ISM write mode runs no engine at all.** `rtl/swim.v:376`:
`ism_arm = ism_mode && ism_mode_reg[3] && !ism_mode_reg[4]` — ACTION on, WRITE
off. Setting Mode b4 today does nothing.

**2.5 — Floppies are downloads, not block devices.** `MacLC.sv:83-84` are
`F1`/`F2` CONF_STR rows streamed once through `ioctl_download` into SDRAM
(images live at word `23'h600000` internal / `23'h700000` external,
`rtl/addrController_top.v:275-276`). `ioctl_download` is one-way: there is no
file handle to write back through, so no amount of GCR decoding persists
anything. **This is the single biggest structural obstacle**, exactly as on
MacPlus. `VDNUM` is already 6 (`MacLC.sv:211`), so widening is routine.

**2.6 — There is a free extra slot, but the write path should not use it.**
`extra_slot_count == 2` is idle (`rtl/addrController_top.v:359`, legacy sound
DMA removed). Use the `sdram.v` LEVEL-handshake requester pattern instead — §6.3.

---

## 3. What the LC does NOT have to deal with

Stated explicitly because it is where the LC's validation matrix is strictly
smaller than MacPlus's.

| Axis | MacPlus | MacLC |
|---|---|---|
| CPU speed | OSD `O5,Speed,8MHz,16MHz` fans `status_turbo` into `cpu_en_p/n`, DTACK, BOTH VIAs' `E_div`, and the disk logic | **One fixed rate.** No turbo, no `E_div` select, no `clk16_en_*` |
| Machine model | 5 models via `rtl/mac_model.v` → `configROMSize`, `machineType`, `romSlot`, `drive800k`, `scsiPresent` | **One machine.** No equivalent module, none needed |
| ROM | 4 `bootN.rom` images selected by `romSlot` | **One ROM** (`dio_index == 0`, `MacLC.sv:167`) |
| CPU | Plus/SE 68000 variants | **Hardwired** `localparam [1:0] status_cpu = 2'b10; // 68020` (`MacLC.sv:170`) |
| Drive capability | Per-model `drive800k` gates 400K-only mechanisms, passed into `floppy.v` | Both drives identical; media type comes from the image |
| External port contention | HD20/DCD is exclusive with the external floppy | Nothing else claims the port |

MacPlus's write path must hold across roughly *5 ROMs × 2 CPU rates × 2 drive
capabilities × DCD-present-or-not*. Stage 1 here is **2 drives × {400K, 800K}**.

In particular there is **one ROM write loop to satisfy**, so MacPlus's Phase 3
risk ("will this ROM tolerate the byte-synchronous drive model") is answered
once and stays answered.

The one axis where the LC is *more* complex is format: GCR and MFM through the
same SWIM. Stage 1 exists to take that off the table for v1.

★ **CLAUDE.md was stale here; CORRECTED 2026-09-14.** "CPU speeds: 8 MHz
(original) or 16 MHz" and the known limitation "Floppy won't read at 16 MHz CPU
speed" were both inherited MacPlus text, and neither was true of this core. The
rate is **fixed 16.25 MHz**: `clk_sys` 32.5 MHz (`rtl/pll.v` outclk_1) with
`clk16_en_p/n` alternating every cycle (`rtl/addrController_top.v:115`), so a
phi1/phi2 pair spans 2 clk_sys cycles. The 8.125 MHz `clk8_en_p/n` off the same
divider is the peripheral bus enable — the likely origin of the "8 MHz" half.
The second line mattered most: it is a *floppy timing* limitation pointing at a
mode that does not exist, i.e. a ready-made false lead for exactly this work.

---

## 4. Target architecture (stage 1)

```
Mac CPU --write--> IWM writeData reg  --> floppy.v write strobe (1 byte / 16us)
                        |                          |
              real _iwmBusy handshake              v
                                        floppy_track_decoder.v   (PORT)
                                        strip sync, find D5 AA AD,
                                        de-nibblize 6:2, verify checksum
                                                   |
                                                   v
                                        512-byte BRAM sector buffer
                                                   |
                              +--------------------+--------------------+
                              v                                         v
                  SDRAM image write-back                     HPS sd_wr -> file on SD
                  (sdram.v level-handshake port)             (LBA = offset >> 9,
                  keeps the read path coherent                + DC42 header offset)
```

Two choices carried from MacPlus, both still right here:

- **Buffer a whole sector in BRAM before committing.** Gives a natural place to
  enforce "only commit on valid checksum", produces exactly the 512-byte buffer
  `sd_buff` wants, and avoids byte-granular strobe control.
- **Write to both SDRAM and SD.** SDRAM keeps the in-memory image coherent so
  the guest's read-after-write verify passes; the `sd_wr` makes it durable.

**Stage 1 needs no rotational anchor.** An Apple GCR data field carries its own
sector number (`D5 AA AD` + 6-bit sector), so: **sector** from the decoded
data-field header, **track** from `driveTrack`, **side** from `driveSide`. This
is the property that made MacPlus tractable. Stage 2 loses it — §6.1.

---

## 5. Phases

Each phase ends at a gate evaluable on its own.

### Phase 0 — Sim harness and format ground truth — **COMPLETE 2026-09-14**
*No core changes, and none were made.*

**Gate result: PASS.** 160 track dumps (all 80 tracks x 2 sides) from the real
`rtl/floppy_track_encoder.v`; **1600/1600 sectors round-trip byte-exactly**, and
all rejection cases hold. Artifacts:
`verilator/tb_floppy_track_encoder.v`, `scripts/gcr_common.py`,
`scripts/gcr_gen_image.py`, `scripts/gcr_decode_track.py`,
`scripts/gcr_test_negative.py` (build + run lines in each header).

- ~~Bench driving `rtl/floppy_track_encoder.v` standalone against a synthetic
  image.~~ **DONE.** Runs under **Icarus 12.0, natively on Windows** (no
  Verilator, no WSL) — the bench is one standalone module with `$readmemh` /
  `$fopen`, so it needs none of the `verilator/Makefile` machinery. `+alltracks`
  does the full sweep in ~83 s; the default is the representative 4 tracks x 2
  sides in ~4.5 s. **Phase 1 onward still needs Verilator 5.x** (`tb_disk_swap.v`,
  and Phase 2's RTL-to-RTL round-trip); apt on Ubuntu 22.04 ships 4.038, which
  has neither `--binary` nor `--timing`, so that means building from source.
- ~~Reference decoder in Python; confirm byte-exact recovery of all sectors.~~
  **DONE**, against the RTL dumps rather than a model of the encoder.
- ~~Fix the stale CLAUDE.md CPU-speed lines (§3).~~ **DONE 2026-09-14.**

**Gate:** the reference decoder round-trips every sector of a synthetic 800K
image byte-exactly, and rejects a corrupt data byte, a corrupt checksum byte,
and a truncated field.

MacPlus's `sim/` artifacts ported over. **The "confirm, do not assume" check
was done and is the strongest single result here: `rtl/floppy_track_encoder.v`
is BYTE-IDENTICAL between the two cores** (plain `diff`, zero differences), so
the ported decoder inherits MacPlus's validation rather than merely resembling
it. Re-run that diff before trusting any of this again.

★ **UPDATE 2026-09-15 — the two files are no longer byte-identical, and the
claim above still holds.** MacPlus `7712c0e` added the format relay to its
encoder (§1.1), so a plain `diff` now reports 76 changed lines. Re-checked
line by line: **every one of them is inside the relay block** (the `wr_*`
ports, the `relay_*` registers, `STATE_GAP`, `rev_len`/`SECTOR_BYTES`) or is
trailing whitespace. Ours is MacPlus's file MINUS the relay, so the stream
this core emits is unchanged and the inheritance is intact. The right check
from here is therefore not `diff` but `diff -w` filtered for relay lines — or
simply the Phase 2 round-trip, which tests the property directly rather than
by proxy. Two deliberate
departures from MacPlus's artifact list:

- **`encoder_model.py` was NOT ported.** Its job there was to prove a Python
  reading of the nibbler correct so a decoder could be built from it. With
  Icarus present the decoder is validated directly against real RTL dumps,
  which is strictly stronger — a model cannot catch a misunderstanding it
  shares with the decoder built from it. Port it only if a future task needs
  GCR streams generated without a simulator.
- **The negative tests were rebuilt, not ported.** MacPlus's asserted only that
  an error was reported *somewhere near* the corruption, and its truncation case
  asserted `len(errors) >= 0`, which is vacuously true. Ours name the sector:
  the corrupted one must vanish and every other sector must survive byte-intact.
  ★ That required cutting the stream to ONE REVOLUTION first — a 20000-byte
  capture holds 2+ revolutions, so each sector appears twice and corrupting one
  copy leaves the other to be "recovered", a test that passes while proving
  nothing.

Format facts established from the FSM while building this, all load-bearing for
Phase 2's RTL decoder:

- Sector layout is `SYN0 56 | ADDR 10 | SYN1 5 | DHDR 4 | DZRO 12 | DPRE 4 |
  DATA 683 | DSUM 4 | DTRL 3 | WAIT 1` = **782 bytes**, confirmed against the
  observed mark-to-mark pitch. ★ **DZRO is 12 bytes, not 8** — the RTL comment
  says "8 zero bytes" but the FSM counts to 11.
- The encoder writes with an **interleave of 2** (sectors come off the track
  0,2,4,... then 1,3,5,...). Harmless for a decoder keyed on the sector number
  in the field; fatal for one that infers position.
- **The nibbler needs a one-group LOOKBACK.** `nib_xor_0/1/2` are registers read
  combinationally, so group *g*'s four output bytes encode group *(g-1)*'s three
  data bytes, not their own. This is the bug MacPlus shipped first and caught
  only by round-tripping against RTL — not by reading the Verilog.

### Phase 1 — Convert floppies to block devices (still read-only) — **COMPLETE 2026-09-15**
*The riskiest plumbing change, isolated from any write behaviour.*

**Gate result: PASS, on hardware, on a STOCK Main.** Every item below was run;
details in "Gate progress".<br>
Code: `2fff730` + `85bdf83` + `410a064`.

- CONF_STR: `F1`/`F2` → `S` mount slots; widen `VDNUM` from 6, keeping every
  existing device on its current index so users' saved mounts are undisturbed.
- Mount-time loader FSM: on `img_mounted`, stream the image via `sd_rd` into
  SDRAM at the existing `600000`/`700000` word offsets.
- Re-derive the media-change machinery from `img_mounted`/`img_size` — §6.2.
- Latch `img_readonly` per slot **at that slot's own mount pulse**. Precedent to
  copy verbatim: `../UK101_MiSTer/UK101.sv:274-277` (four drives, four
  independent latches) — cited by MacPlus's plan for the same reason.

**Gate (hardware):** boots from floppy exactly as before — both drives, 400K and
800K, GCR and MFM, DC42 and raw, eject and remount, floppy + SCSI together. No
write behaviour introduced. A regression here is provably plumbing.

**Gate progress (2026-09-15) — ALL ITEMS PASS.** "Both drives" is moot since
`410a064` removed the phantom second floppy.
- ✅ **Boots from floppy** — raw 800K GCR, System 6.0.8 System Tools.
- ✅ **Mounts** — 400K GCR, 800K GCR and 1.44MB MFM, DC42 *and* raw.
- ✅ **Eject and remount** (media change) — several disks mounted and
  unmounted in succession, all correct. No ghost volume, no stuck `SWITCHED`.
  ★ Run it
  **guest-eject-first**, and **not against the boot floppy**: per CLAUDE.md,
  swapping under a live volume is hostile on a real Mac too (MAME 6.0.8 bombs
  with "Disk Initialization package not present" when the boot floppy is
  yanked), because drives only eject under software control and the OS has no
  graceful path. An OSD swap with no guest eject would therefore produce a
  FALSE failure. Boot from SCSI, then mount / guest-eject / mount-a-different
  image. The regression being hunted is the ghost volume: mounts and lists but
  every call fails with no driver error and zero disk I/O, which is what the
  guest never being told the medium changed looks like.
- ✅ **Boots from a DC42** — the `mk_dc42.py` fixture built from the same
  System 6.0.8 disk. No LC-bootable DC42 existed to test with (every one to
  hand is 1985-87 era, a non-bootable application disk, or truncated), so the
  fixture is the raw disk that is known to boot, wrapped: byte-identical
  payload, making raw-vs-DC42 an exact A/B whose only variable is the 84-byte
  strip. Both booted. **The strip is correct end to end**, which is a stronger
  result than a mount — a wrong offset would still mount and list.

★ Watch the **tag section** when making DC42 fixtures. A DC42 may legally carry
`tagSize` 0, and an 800K image built that way has a payload of exactly 819200
bytes — which *passes* the raw size test, masking a regression to size-based
geometry with the very image meant to catch it. `mk_dc42.py` therefore always
writes the tags (zero-filled; HFS does not read them), giving the 838400-byte
payload that matches no size test.

★ **Four of the 19 DC42 images on the owner's machine are damaged**, found by
checksum-verifying them all before choosing a fixture: the three System 2.0.1
disks have bad data checksums (modified after creation) and
`Arkanoid_1_00.dsk` is a valid DC42 truncated by exactly 84 bytes — its payload
is 819116, not a whole number of sectors. Verify a fixture before gating on it;
a bad image imitates a core bug perfectly. (`Arkanoid_1_00` would make a good
negative case later.)

### Phase 2 — GCR decoder RTL — **COMPLETE 2026-09-15**

**Gate result: PASS.** `verilator/tb_floppy_track_decoder.v` drives the real
`rtl/floppy_track_encoder.v` into the real `rtl/floppy_track_decoder.v`:
**6269 checks green over all 160 track/side combinations**, 4000 sector
acceptances (25 per track = 2+ revolutions each), covering all
16×(12+11+10+9+8)×2 = **1600 distinct sectors byte-exactly**, plus six negative
cases. Runs on Icarus 12.0 natively — ~2m38s for the sweep, ~20 s for the
default representative 8 tracks. Build + run lines are in the bench header.

`rtl/floppy_track_decoder.v` is a **verbatim** port (source md5
`6fcd1267e0d1765847c7d1009763848a`); only a provenance header was added. That is
the whole value of the port — this core's encoder is MacPlus's file minus the
format relay (**re-diffed 2026-09-15: every differing line is inside the relay
block**, so Phase 0's inheritance claim still holds even though the two files
are no longer byte-identical), so the decoder is the algebraic inverse of the
exact stream we emit and arrives already validated on a sister core.

**Two independent positive checks**, both riding on
`scripts/gcr_gen_image.py`'s self-identifying pattern (bytes 0..2 of a sector
are track, side, sector):
1. `recovered[0..2]` == the (track, side, sector) the bench is driving — proves
   the decoded PAYLOAD is this sector's data, using no address at all.
2. `recovered[k] == mem[addr + k]` for all 512 — proves `addr` lands on exactly
   this sector. **This is the check Phase 3's committer rides on.** A generic
   counter pattern would let a wrong-address fetch pass it; this one cannot.

**Format neutrality — decided, and it is the opposite of the obvious reading.**
The GCR geometry (`soff`/`spt`, the variable-speed zones) stays INSIDE the
decoder rather than moving to the committer. Putting `addr` in the committer
would force the committer to hold a geometry table per format — i.e. make it
format-AWARE, exactly what the §1 carve-out exists to prevent. So the contract
Phase 3 consumes is **`(sector_valid, sector, addr, buf)`**, with `track`/`side`
as decoder inputs, and stage 2's MFM decoder presents the same tuple while
computing its own flat 18-sector geometry.

**A behavioural difference from the Phase 0 Python decoder, where the RTL is
the one that is right** — recorded because it will look like a bug to the next
reader. Corrupting an ADDRESS field's checksum makes the Python decoder lose
the sector (it pairs an address field with the data field that follows it). The
RTL scans for `D5 AA AD` independently and takes the sector number from the
DATA field, which carries its own checksum — so the sector still decodes and
only `fmt_mark` is suppressed. That independence *is* the §4 property stage 1
rests on: no positional inference anywhere. The bench asserts the RTL behaviour
explicitly (case 6) so nobody later "fixes" it into agreement with Python.

Negative cases, each naming the sector that must vanish while every other
sector survives byte-intact (the Phase 0 standard, not MacPlus's "an error was
reported somewhere near here"): corrupt payload byte → a different VALID GCR
code, corrupt checksum byte → likewise, an invalid nibble, a broken `DE AA`
trailer, a stream cut mid-field, and the address-checksum case above. Corruption
values are taken FROM the captured stream rather than from a copy of the forward
table, so the bench cannot drift from the encoder's table. ★ All negative runs
are **one revolution only** — a 20000-byte capture holds 2+ revolutions, so
corrupting one copy of a sector leaves the other to be "recovered", a test that
passes while proving nothing. Same trap as Phase 0.

★ **`rtl/floppy_track_decoder.v` is deliberately NOT in `files.qip` yet.**
Phase 3 adds it, when it is first instantiated. Adding dead RTL now would
perturb the Quartus warning baseline that §7 defect 1 tells us to diff compile
over compile, for no gain.

★ Bench bug worth remembering (cost one debug cycle): `integer corrupt_idx`
powers up **x**, and `x >= 0` is x, so the injector's ternary fed the decoder x
for the entire run. The symptom was a perfect "the decoder detects nothing" —
zero sectors, zero rejects, zero address marks, on every track — which reads as
a broken DUT rather than a broken bench. An uninitialised `integer` in a
comparison is the same class of hazard as the `#1` edge discipline: it fails
silently and blames the wrong module.

### Phase 3 — IWM write path, volatile writes only
*The "will the ROM cooperate" gate. Structurally cannot touch the user's file.*

**Phase 3a — the handshake — CODE LANDED 2026-09-15, sim gate PASS.** Split out
deliberately: §6.4 says a wrong handshake HANGS the machine, so the handshake
gets its own hardware run with nothing able to reach memory or the file. Sim
gate is `verilator/tb_floppy_write.v`, **55 checks** on Icarus — handshake
shape (busy asserts on accept, clears after exactly 128 cep ticks, one
`decReady` per byte), four silent refusals (write-protected / no disk / CSTIN
set / drive deselected), deselect-mid-byte raising underrun, a media change
abandoning an in-flight byte, and a **full-track round-trip**: all 12 sectors
of track 0 written through the IWM data register and decoded back byte-exact
at the right address.

★ **With the OSD toggle Off — the default — hardware behaviour is identical to
today.** `writeBusy` can never assert (no byte is ever accepted), so `_iwmBusy`
and `_writeUnderrun` read 1 exactly as the old hardwired stubs did, and WRTPRT
reads locked. That is what makes 3a safe to fit and boot.

What is NOT in 3a: any commit path. `wrSecValid/Num/Addr` are produced and
watched, and go nowhere.

Three things worth carrying forward:
- **`writeReq` is a LEVEL, not a pulse.** One CPU access spans several `cen`
  ticks, and floppy.v's `!writeBusyReg` guard is what collapses that to one
  byte. A pulse-shaped bench stimulus would pass while never reaching that
  guard, so the bench holds the level on purpose. (Held longer than a whole
  byte time it would hand over a second byte — unreachable here, since an
  E-paced VPA access is ~1.23 us against a 15.75 us byte time. Recorded rather
  than asserted against.)
- ~~**Placement in `floppy.v` is load-bearing.**~~ **RETRACTED 2026-09-15 — this
  was wrong, and it is recorded rather than deleted because the wrong version
  was reported as a caught bug.** The claim was that putting the write block
  above `driveWriteAddr` would make Verilog implicitly declare it a 1-BIT net
  and silently truncate the 3-bit eject compare. `floppy.v` itself disproves it:
  the `dbg_media` block does exactly that compare ~20 lines ABOVE
  `driveWriteAddr`'s declaration, and it is hardware-validated (2026-08-06, and
  ejects worked on hardware again today). A forward reference to a net
  **declared later in the same module** resolves correctly; a scan found ~82 of
  them across `floppy.v`, `swim.v`, `MacLC.sv` and `dataController_top.sv`, in
  code that ships. Declare-before-use is better style and the blocks were left
  in their moved positions, but it is not a correctness fix.
  ★ The REAL hazard is adjacent and worth keeping: an identifier **never
  declared anywhere** does get an implicit 1-bit net, and that truncates
  silently. Verilator flags it as Warning-IMPLICIT (`selectASC` in `sim.v` is a
  live example); Quartus need not. So the thing to watch is a mistyped signal
  name, not declaration order.
- **The decoder needs an anchor or it does not exist in the fit.** Nothing
  consumes the tuple until Phase 4, so synthesis sweeps the whole decoder away;
  it would then appear for the first time in the same fit as the committer and
  the SDRAM requester, giving a timing failure three candidate causes instead
  of one. `wr_anchor0/1/2` in `floppy.v` pin it, under the same never-fold law
  as MacLC.sv's always-on anchor (§ the 2026-08-04 floppy-cone extension).

**Gate (hardware) for 3a — PASS, 2026-09-15.** Fit `MacLC_5608e02a_phase3a.rbf`
(md5 `31f777b0`). No hang, no crash. With the toggle On and a scratch raw image,
a Finder copy ran to completion and then failed with *"the file couldn't be
verified, because a disk error occurred"*; the file did not land.

★ **The failure was at the VERIFY stage, not the WRITE stage, and that is where
the information is.** Three separate things are confirmed by which error
appeared:
- **WRTPRT unhardwiring works.** A still-locked disk makes the Finder refuse up
  front ("the disk is locked") and never start copying.
- **The handshake works and raises no spurious underruns.** A misbehaving
  `_writeUnderrun` surfaces as a write error mid-copy, not a verify failure at
  the end. The ROM's UNBOUNDED poll loop (§2.1) completed every time — that was
  the hang risk this phase existed to retire.
- **Nothing was committed, as designed.** The verify reads SDRAM, which still
  holds the pre-write contents, so it mismatches.

★ **Consequence for Phase 3b's gate: the guest's own verify is a built-in
oracle.** A Finder copy completes only if every sector decoded byte-exactly —
sector number, address and all 512 payload bytes. So "the copy succeeds" is a
far stronger check than it appears, and no HUD or JTAG fit is needed to read the
decoder's counters. A wrong decode fails in exactly the way just observed.

(The owner expected the file to appear and then vanish on unmount. That is the
**Phase 3b** behaviour — it needs the SDRAM commit for the verify read to find
anything.)

**Phase 3b — commit to SDRAM.** The committer, `wrBufAddr` driven for real, and
the read-after-write the guest's verify depends on. Also lands, now that 3a is
gated:
- **Drop the `!flp_int_raw` term** from `flp_int_wp` (§6.2) — DC42 is writable
  by the owner's ruling, and phases 3a/3b need nothing else for it because
  SDRAM holds normalised sector data whatever the container was.
- **A parameter on `floppy.v` so `floppyExt` elaborates WITHOUT the write
  path.** The Phase 3a fit revealed the cost: `floppy_track_decoder` is
  instantiated unconditionally, so the external drive — which never has media
  and has `writeProtect` tied high — carries a decoder it can never use.
  Quartus reported it as Warning 18550, "implemented as ROM because the write
  logic is always disabled", which also independently confirms the tie-off
  works. It wastes roughly 1 M10K at 92% M10K utilisation. Unlike removing the
  `floppyExt` instance itself (which `410a064` deliberately kept), this changes
  nothing drive-visible.

- Real `writeReq`/strobe/byte from `swim.v` into `floppy.v`.
- Real `_iwmBusy` (assert on CPU write to the data register, clear after one
  byte time) and an honest `_writeUnderrun`, replacing `rtl/swim.v:176`.
- Unhardwire `rtl/floppy.v:241`; drive WRTPRT from a new OSD write-enable
  **defaulting to Off**, ANDed with the latched `img_readonly`.
- Commit decoded sectors to the **SDRAM image only**. No `sd_wr` yet.
- **Stage-2 carve-out — do it now:** latch the emitting sector's identity into
  `swim.v`'s 16-deep staging ring **alongside each delivered byte**. Stage 1
  never reads it; stage 2's anchor is unimplementable without it (§6.1 item 4),
  and widening that ring after stage 1 ships means reopening validated
  read-path code — the one part of the floppy stack that is hardware-proven.
- **Stage-2 carve-out — do it now:** keep the committer format-neutral, taking
  the Phase 2 tuple from *either* decoder. A GCR-shaped committer is rework.

**Gate (hardware):** with a scratch disk enabled, save a file from the Finder;
it reads back correctly and survives an eject/reinsert within the session. Reset
the core — the change must be **gone**.

★ Build the handshake BEFORE anything can commit (§2.1): a wrong handshake hangs
the machine, so this phase's first hardware run is also the hang test.

### Phase 4 — Persistence to SD
Port `rtl/floppy_sd_writer.v`. Add the DC42 offset (§6.2). Gate `sd_wr` with a
`write_ok` backstop as well as the decoder's own condition — belt and braces,
per `../UK101_MiSTer/UK101.sv:304`.

**Status 2026-09-16:** code complete for raw AND DC42 (`9195c0a` + the review
fixes described in §6.2). Raw images HARDWARE-GATED, both halves. DC42 not yet
fitted. `verilator/tb_floppy_sd_writer.v` covers the byte order, the queue, the
ack-timeout re-presentation, the DC42 RMW and checksum rewrite, the partial-
tail refusal, and (sections 10-14) the remount abort and the flush trigger.
The writer exports a 32-bit witness word (`PFSW` in the observer deck): the
DC42 hardware gate should include a sustained large-file copy and read back a
ZERO overflow count, since four SD transactions per sector against the ~10 ms
sector cadence is the one capacity assumption nothing offline can test.

**Gate (hardware + host):** write, eject, remount → the change persists. Then
verify on the PC: the image opens in an emulator, and a byte-level diff against
the pre-write copy shows *only* the intended sectors changed. **The diff is the
important half** — it catches a wrong-LBA bug that "it still boots" would miss.
UK101's attempt-2 post-mortem is what a byte-diff buys you: it located a
263-byte displacement and reconstructed the cause from it.

### Phase 4b — Persistence, second design: SDRAM-sourced, unbounded backlog

**Why (2026-09-16).** The card-sourced writer's 450 KB soak FAILED: the
depth-2 shadow queue overflowed twice and four sectors of the copied
application were wrong on the card while the volume still checked out (§6.2,
review finding). Root cause is the environment, not the RTL: Main opens a
writable image `O_RDWR|O_SYNC`, so each block is a synchronous card write with
bursty latency, against a sector every ~11 ms. Any fixed-depth copy of the
data will overflow on a long enough stall, and it does so silently. **Owner
chose option B**: keep no second copy of the data at all.

**Fallback.** `floppy-write` stays at `ce07e67` (tag `phase4-card-sourced`,
RBF `scratch/phase4/MacLC_ce07e672_phase4dc42.rbf`). This work is on branch
`floppy-write-sdram-src`.

**Design.**
1. **Queue sector NUMBERS, not data.** On `commit_done && write_ok` the
   writer pushes the sector index (`commit_addr[21:9]`) into a FIFO (1024
   deep x 13 bits, 2 M10K). The committer has already landed the data in
   SDRAM, which always holds the NEWEST version, so a sector re-written while
   still queued is simply queued twice and written twice with the latest
   contents — no dedupe, no bitmap, no re-dirty tracking. 1024 pending
   sectors is ~11 s of write backlog; if even that fills, the push is REFUSED
   and a sticky `lost` flag is raised (option C's safety net — visible, never
   corrupting).
2. **Fetch from SDRAM at write time** into ONE 256x16 block buffer, then
   present it to hps_io as before (same output byte swap). Raw: block N =
   sector N. DC42: block N = payload words `N*256-42 .. N*256+213`, i.e. the
   tail of sector N-1 and the head of sector N, both straight from SDRAM; the
   card is never READ any more, so a DC42 sector costs two writes, not two
   reads + two writes. **Block 0's first 42 words are the stripped header**,
   which SDRAM does not have: `floppy_loader.v` now keeps them (captured as
   file block 0 streams past at mount) and exports a small read port.
3. **SDRAM access = the existing Ethernet DMA port, shared.** `rtl/sdram.v`'s
   `eth_*` requester is a proven LEVEL two-phase read/write port that never
   touches `cpu_done`, starts only on idle edges, and is already crossed
   clk_sys -> clk_64 correctly. A small arbiter module (`rtl/eth_port_arb.v`)
   in MacLC.sv grants it per transaction to pds_enet or the floppy writer,
   pds_enet first, lock held from request-rise through ack-fall (a grant that
   flipped with `eth_ack` still high would hand the next client a spurious
   ack), and the muxed bundle is REGISTERED before it reaches the controller
   (pds_enet's own note: combinational depth on that crossing broke hold).
   **`rtl/sdram.v` is not edited.** Bandwidth: one word per idle
   clk_sys-aligned edge, ~0.2 us/word unloaded, so a block fetch is ~50-100 us
   against an 11 ms sector.
4. **Eject flush = SDRAM scan.** Drain the FIFO, then read the whole data
   section from SDRAM accumulating `ror32(sum + word)` (~0.1-0.2 s for
   800K), then write block 0 assembled from the loader's header words with
   36/37 substituted plus sector 0's head from SDRAM. The tag checksum is
   left as stored (tags are never written).
5. **Unchanged from 4:** `write_ok` as the single gate, `file_blocks`
   partial-tail refusal, remount ABORT (now also empties the FIFO), the
   `PFSW` witness word (overflow byte now counts FIFO refusals).

**Gate.** `tb_floppy_sd_writer.v` rewritten around an SDRAM model on the
eth-port protocol + the hps_io model (byte order, raw, DC42 assembly incl.
block 0, flush, refusals, remount abort, FIFO-full refusal, re-written-
while-queued ordering); `tb_eth_port_arb.v` for the arbiter (lock through
ack-fall, no cross-talk of acks); Quartus A&S; then on hardware the SAME 450
KB copy with `PFSW` overflow == 0 and a byte-for-byte fork diff against the
source volume — the test that failed 4.

★ **HARDWARE GATE PASS 2026-09-16 evening** — commit `60d1e95`, fit
`MacLC_60d1e95b_phase4b.rbf` (STA +0.157 ns). The same Speedometer 3.23
folder (450 KB, ~900 sectors) copied onto `Blank800K (DC42).dsk`, then
guest-ejected:
- `PFSW` after the copy `00001800`, after the eject `00001B10`: refusals 0,
  out-of-range 0, flushes 1, idle.
- Written image vs baseline: header words changed = {36, 37} only, data
  checksum stored == recomputed (2f6a8a58), tag checksum and tag section
  untouched, 901 payload sectors changed (MDB/bitmap, catalog, the two
  files) and nothing else.
- **Both forks byte-IDENTICAL to the source on `boot.vhd`**: Speedometer
  3.23 rsrc 409015 B, Machine Records rsrc 41203 B. `hfs_check` VOLUME
  CONSISTENT. The four wrong sectors the card-sourced design produced on
  this exact test are gone.
★ **RAW SOAK PASS, same evening.** The same folder onto the raw
`Blank800Kformatted.dsk` (baseline = the unwritten file): `PFSW` `0000A810`
= refusals 0, out-of-range 0, flushes unchanged at 1 (correct: a raw image
has no header to rewrite, so the eject triggers nothing), idle. 901 sectors
changed, every one inside MDB/bitmap, the catalog extent or a file extent
(a script check, not an eyeball); both forks byte-identical to `boot.vhd`;
`hfs_check` CONSISTENT, and the source image's off-by-one MDB file count was
corrected by the Finder as predicted.

★ **GUEST REMOUNT PASS.** Both written images (the DC42 and the raw) were
remounted on the MiSTer and Speedometer 3.23 launched from each. That is the
plan's original Phase 4 gate statement — write, eject, remount, the change
persists — met for both containers, with the byte diff as the strong half.
**Phase 4 is closed for GCR.** Still to do before PR: stage 2 (MFM/ISM writes).

★ **400K (single-sided) — offline-proven 2026-09-16, not yet on hardware.**
The owner asked. Neither GCR bench had ever run with `sides=0`: both
hard-coded double-sided, and the synthetic image's self-identifying bytes
describe the tuple DOUBLE-sided geometry puts at each address, so it cannot
stand in (under sides=0 every track but 0 reads "payload wrong" while the
address check passes — a bench artefact, not an RTL one). Fixed:
`scripts/gcr_gen_image.py --single` mints the 400K layout (image400.hex) and
`tb_floppy_track_decoder.v +single` runs sides=0, side 0 only, and asserts a
side-1 field is REJECTED. All 80 tracks: 3151 checks PASS; the double-sided
run is unchanged at 6269. The decoder's single-sided address formula is the
encoder's read-side one verbatim (`soff*512`, no doubling). Downstream is
geometry-blind: committer, queue and writer see a payload byte offset;
`file_blocks` = 800 raw / 818 tagged DC42.

★ **OWNER'S RULING, 2026-09-16 (said in that session): 400K writes are NOT a
gate.** The hardware attempt on `EraseMe400K.dsk` failed in the GUEST with
error -4 (`unimpErr`): every 400K image to hand is MFS — fifteen of fifteen —
and System 7.5 mounts MFS read-only, so the Finder refuses the copy before a
sector reaches the core (PFSW showed no 400K writes). 400K HFS volumes are
technically possible but not what anyone has, so the offline proof above is
where 400K support stops. No hardware run is required for the PR.

★ **WRITER DEFECT, found on the MacPlus port and fixed here 2026-09-17 —
the refuse path popped TWICE and lost the sector behind it.** `q_head` is a
registered read of `q_mem[rd_ptr]`, so for one cycle after a pop it still
shows the entry just retired. The out-of-range refusal was the only path
that stayed in `P_IDLE` across that cycle, so it popped again against the
stale head: queue `[X(out of range), Y, Z]` refused X twice, wrote Y, and
dropped **Z unwritten and uncounted** — `dbg[23:16]` blamed the refusal for
it. MacPlus hit this porting the SDRAM-sourced design back (`6f58059`) and
added a one-cycle `P_SKIP`; the same state is now `4'd15` here (numbered
last so the `PFSW` words captured above still decode). Bench section 3 only
ever queued ONE entry — with nothing behind it there is nothing to lose, so
it passed either way. It now queues three behind `loader_busy`; against the
pre-fix RTL that costs 259 checks, against the fix 8005/0.

### Phase 5 — Hardening
Port MacPlus's Phase 5 work and its six-defect review list (§7). Stress the
structures nothing exercises incidentally: commit-queue depth, write-to-one-
drive-while-mounting-the-other, and write-then-immediate-OSD-remount.

### Phase 6 — FORMATTING (GCR *and* MFM) — the sub-project plan

Written 2026-09-18, after the MFM soak and the 720K run closed. **This is the
last item before the PR**: §1's release gate says nothing ships until every
readable format is writable *and* formattable, and every other box is now
ticked. It is ONE phase covering both encodings because they share the two
hard parts — the read-side relay and the sidedness ceiling — and splitting
them would mean building that plumbing twice.

#### What is already built (the Phase 2/3 carve-outs, now cashed in)

Surveyed 2026-09-18, all verified in the tree rather than assumed:

| piece | state |
|---|---|
| GCR decoder's format reporting | **DONE** — `amark`, `amark_sector`, `fmt_mark`, `fmt_ds` all exist… |
| …and they are already wired | `rtl/floppy.v:1003-1006` routes them to `wrSecAmark` / `wrSecAmarkSector` / `wrSecFmtMark` / `wrSecFmtDs`, whose only consumer today is the `wr_anchor1` cone anchor (`:1087`). ★ Corrected in review 2026-09-18: an earlier draft cited `:978-980` as "unconnected stubs" — those are the **MFM** decoder's `amark_*` ports (`amark_cyl` exists only there). The anchor stays when the nets gain a real consumer (never-fold law). |
| IWM write-mode LEVEL in `floppy.v` | **MISSING** — the donor's `wrEnd` needs it (6A.3). `swim.v:215` has `q7`; `floppy.v` has no `writeMode` port |
| `mediaSides` (volume-header sniff) | **MISSING** — `dsk_int_ds` is FILE SIZE (`MacLC.sv:2728`), i.e. the donor's `img800k`, not its `mediaSides` (6B) |
| ISM write-active level in `floppy.v` | `swim.v:510` exports `mfm_wr_active`; **nothing consumes it** — an MFM `wr_end` would need it (6C) |
| `decReady` (the relay's `wr_byte`) | **EXISTS** — `rtl/floppy.v:855`, the same signal MacPlus feeds the relay |
| MFM write decoder's format support | **DONE** — `rtl/mfm_write_decoder.v:25` handles "an ID field seen in this stream, CRC-valid, not yet consumed. That is the FORMAT case", and exports `amark_*` so a caller can police a format against the head |
| Identity-bearing staging ring, format-neutral committer | **DONE** (Phase 3 carve-outs, §1) |
| GCR encoder relay | **MISSING** — ours is MacPlus's file minus it |
| MFM encoder relay | **MISSING** — no equivalent has ever existed |
| Sidedness ceiling | **MISSING** — `rtl/floppy.v:617` is still `wire doubleSidedDisk = diskSides;` with a `// TODO` |

#### 6A — GCR formatting: a PORT, not a design

Donor is **MacPlus master `b340c9f`** (PR #22, which merged `7712c0e`). Diffed
2026-09-18: our `rtl/floppy_track_encoder.v` is byte-for-byte their file minus
the relay — **78 changed lines**, and the relay is a cleanly separable block.

1. **Port the relay into `floppy_track_encoder.v`** (~50 lines + 4 ports):
   `wr_byte` / `wr_mark` / `wr_mark_sector` / `wr_end`, `SECTOR_BYTES` and the
   per-zone `rev_len`, the `relay_armed`/`relay_sector`/`relay_ahead`
   registers, and `STATE_GAP` which restarts the layout `relay_ahead` bytes
   short of the written mark. Take it verbatim; do not "improve" the
   five-bytes-behind-the-D5 arithmetic.
2. **Wire it in `floppy.v`**, mirroring MacPlus `floppy.v:180-183`:
   `.wr_byte(decReady)` (exists), `.wr_mark(wrSecAmark)` and
   `.wr_mark_sector(wrSecAmarkSector)` — the nets already declared at
   `floppy.v:926` and driven by the decoder, which gain the encoder as a
   second consumer beside the anchor — and `.wr_end(wrEnd)`.
3. **Create `wrEnd` — and it needs a NEW INPUT, not just local logic.**
   ★ Corrected in review 2026-09-18; the earlier draft said "writeBusyReg-
   based, a small local addition", which would have broken the relay on
   hardware. The donor bounds the write as a whole with
   `wrBusy = (writeMode && !_enable) || writeBusyReg` (`floppy.v:283`), and
   `writeMode` is IWM **Q7**, passed in from `iwm.v:208`. Our `floppy.v` has
   no such port. `writeBusyReg` alone drops at the end of EVERY 128-cep byte
   and is re-set by the next `writeReq`, so a busy-based `wrEnd` pulses
   between every byte of the track: the relay fires after the first address
   field, restarts the layout mid-format, and disarms. So: add a `writeMode`
   input to `floppy.v`, drive it from `swim.v`'s `q7` register (`swim.v:215`)
   qualified `!ism_mode` exactly as `dataRegWrite` is (`swim.v:247`), tie it
   to 0 on the external-drive instance, and port the donor's
   `wrBusyPrev`/`wrEndD1`/`wrEnd` block (`floppy.v:280-294`) verbatim — the
   two-clock delay so the encoder sees the last mark before the end is part
   of it.

★ **Why the relay exists at all** (§1.1 defect 1, and the reason a naive
format fails on hardware with `fmt1Err`): the ROM requires sector 0 to be the
FIRST address field it sees after the track is written. A free-running read
side will present whatever sector the head happens to be over, and the format
fails. The relay restarts the encoder's layout at wherever the format actually
put sector 0, measured from the address mark the decoder reports.

#### 6B — The sidedness ceiling

One line on MacPlus (`floppy.v:202`), and it encodes a whole defect:

```verilog
wire doubleSidedDisk = drive800k && img800k && (fmtSeen ? fmtDs : mediaSides);
```

Three terms, each a ceiling on the next — **drive mechanism, then file size,
then the medium itself**. On the LC:

- `drive800k` → a **constant 1**: the LC has a SuperDrive and nothing else;
- `img800k` → **exists as `dsk_int_ds`** (`MacLC.sv:2728`: file size 819,200,
  or DC42 format byte 1; `MacLC.sv:2338` passes it in as `diskSides`);
- `fmtSeen` / `fmtDs` → latch from the decoder's **existing** `fmt_mark` /
  `fmt_ds` outputs, already on the `wrSecFmtMark` / `wrSecFmtDs` nets; clear
  on `!_reset || writePathReset` as the donor does (`floppy.v:195`);
- `mediaSides` → **DOES NOT EXIST HERE.** ★ Corrected in review 2026-09-18;
  the earlier draft said it "exists as `dsk_int_ds`", which is the file-size
  term above. The donor's `mediaSides` is a **volume-header sniff in its
  loader** (`floppy_loader.v:60-135` at `b340c9f`): as sector 2 streams in,
  latch the MDB signature (`D2D7` MFS / `4244` HFS), `drNmAlBlks` (word 9)
  and `drAlBlkSiz` (words 10-11); a seven-cycle shift-add gives the volume
  size in 512-byte blocks; `media_ds = !mdb_ok || (vol_blocks > 1200)`, i.e.
  no MDB means double-sided; published with `done`. About 70 lines, and a
  clean block to port even though the loaders differ elsewhere (443 diff
  lines). Our loader already captures sector 0 as it streams
  (`floppy_loader.v:164`), so the pattern is in place; **build it in the
  same file and fit as 6D's loader change** (6D no longer latches words; it
  is a `sec_total` edit).
  ★ Why it is load-bearing and not a nicety: without it defect 2 comes back
  on REMOUNT. In-session, `fmtDs` latches the One-Sided format byte and the
  ceiling holds; the remount clears `fmtSeen`, the fallback is file size,
  and the 819,200-byte file is advertised double-sided again — over a side
  the erase never wrote. The sniff sees the 400K MDB and keeps it single.

★ **The defect this prevents** (§1.1 defect 2): the address field's format byte
was derived from the image file's SIZE, so a One-Sided erase of an 819,200-byte
image formatted side 0 and then advertised the disk as double-sided — letting
the driver build an 800K volume over a side that was never formatted. Every
3.5" diskette is one medium; 400K vs 800K is a formatting CHOICE and nothing
on the diskette records it.

★ Note the interaction with the 400K ruling: the owner ruled 400K *writes* are
not a gate (the guest refuses MFS writes with -4, see the memory note). A 400K
**format** is a different operation and is exactly what this ceiling governs,
so One-Sided erase must still be exercised.

★ **What a One-Sided erase leaves in the file** (checked 2026-09-18 against
`Test disks/Blank800Kas400K.dsk`, an 819,200-byte file holding a 391-block
MFS volume): the erase writes only the sectors the single-sided geometry
addresses, i.e. the FIRST 409,600 bytes, laid out exactly as a 400K image
(`floppy_track_encoder.v:30`: with `sides` low, track t sector s lands at
`(soff(t)+s)*512`). **The upper half is left as it was** — if the disk
previously held an 800K volume with files, their sectors survive there,
unreferenced, exactly as side 1 of a real diskette survives a One-Sided
erase. The new MDB at sector 2 replaces the old one, so no reader follows a
path into the remnant. The file stays readable EVERYWHERE: a raw image is
logical blocks in order, and the encoder serves logical block N from offset
N*512 in both sidedness modes (`(2*soff + side*spt + s)*512` is the standard
double-sided numbering), so any tool sees a 400K volume on an 800K medium.
Gate consequence: an offline diff after a One-Sided erase compares the first
409,600 bytes only and treats the upper half as don't-care.

#### 6C — MFM formatting: the genuinely new work

Not the flux job it sounds like (§1): the LC's MFM path is BYTE-level, so a
guest format is the CPU pushing `00 x12 / A1 A1 A1 (mark) / FE / C H R N /
CRC-16 / 4E …` as plain bytes. The decoding half is **already done**. What is
missing:

0. **★ FIRST, ESTABLISH WHETHER AN MFM RELAY IS NEEDED AT ALL** (added in
   review 2026-09-18). `fmt1Err` is a ROM **GCR**-format behaviour. The MFM
   verify is the Sony driver's whole-track read (`a6e966 → a6f308`, 73-attempt
   budget, `-84 verErr`; `docs/sony_driver_mfm_read_reference.md` §1) and
   whether it is ORDER-sensitive is unknown. Two facts change the design
   space: the ISM write tick IS the encoder's tick (`swim.v:523` derives
   `ism_wr_tick` from the read strobe `mfm_stb_sel`), and the MFM encoder
   free-runs during a write (`floppy.v:472-505` has no write gating), so
   after a format the encoder's position already says "the disk kept
   spinning". A relay is needed only if the driver expects the WRITTEN order.
   Step 0 is therefore a MAME run of a 1.44 MB Erase with the existing tap
   (`verilator/mame/floppy/floppy_tap.lua`, `sonyvars_watch.lua`) and a
   breakpoint on the verify routine, recording: (a) whether the format write
   starts at the index pulse; (b) the gap lengths the driver writes — if its
   gap3 differs from the encoder's pc_dsk 108, the written track is not
   12,422 bytes and a relay's revolution length must be the DRIVER's, not the
   encoder's; (c) whether the verify reads sectors in order. Design from
   that, or skip the relay.
1. **An MFM read-side relay, IF step 0 says so.** `rtl/mfm_track_encoder.v`
   has none. The GCR relay is the model, but the arithmetic differs — MFM is
   9 or 18 sectors of fixed length with no track zones, so `rev_len` becomes
   geometry (`hd`, per step 0b), not a `track[6:4]` lookup. Simpler than the
   GCR version, not a copy of it. `wr_byte` is `mfm_wr_stb`, `wr_mark` /
   `wr_mark_sector` are the MFM decoder's `amark` / `amark_sector` (today's
   real unconnected stubs, `floppy.v:978-981`), and `wr_end` needs
   `swim.v`'s exported-but-unconsumed `mfm_wr_active` plumbed into
   `floppy.v` — there is no MFM write-end signal there today.
2. **ISM format sequencing.** The write engine exists (`rtl/ism_write_engine.v`,
   stage 2); what is unproven is a whole-track write driven by the Sony
   driver's format path rather than its sector-write path. Ground-truth it
   against MAME `swim1.cpp` as stage 2 did — **read the source, not a summary**
   (a paraphrase had `M_MARK` backwards, §8).
3. **Both densities.** 1.44 MB (18 spt) and 720K (9 spt). The 720K run of
   2026-09-18 proved the anchor tracks DD geometry (readings reached 9 and
   never exceeded it), which is the evidence that makes a DD format plausible
   rather than hopeful.
4. **★ Cross-encoding erase must fail cleanly — it is NOT supported** (added
   in review 2026-09-18; the earlier draft did not mention it). On a real
   SuperDrive with DD media the Erase dialog offers both Macintosh 800K and
   DOS 720K (confirm on the bench). Here the encoding is pinned by file size:
   819,200 is GCR, 737,280 is MFM, and hps_io cannot resize a file. Erasing
   an 800K image as 720K puts the driver in ISM mode with `mfm_disk` low, so
   `mfm_spinning` is 0, the write tick never fires, and the engine neither
   pops nor underruns — whether the driver ERRORS or HANGS is unknown. The
   reverse (a 720K image erased as 800K) decodes GCR that the committer mux
   (`wrIsMfm`) ignores, so it should end in a verify error. The IMAGE is
   structurally safe in both directions (only the matching decoder reaches
   the committer); the GUEST behaviour is the open question and is a
   hardware gate: both directions must error out, not hang. If one hangs,
   the fix is upstream (refuse at the driver's density sense), never a
   change to which decoder commits.
   ★ RESOLVED 2026-09-19: 800K-as-720K DID hang (gate 4a below), and
   neither "refuse at the density sense" nor "raise an underrun at the
   write arm" is the fix - see the gate 4a result for why. The engine now
   keeps its byte cadence over a non-MFM disk (`swim.v` `WR_VOID_PERIOD`),
   the guest's write goes into the void, and the ROM's own timeout errors.

#### 6D — Riding along: the DC42 partial final block — FIX IT, not lock it

★★ **REVERSED 2026-09-18 (same day, later): this item was a DOS-in-DC42
write-protect, and the ruling under it ("not supported, do what we can and
document") rested on a premise that is FALSE.** §8.1 said the tail could not
be written because "hps_io writes whole 512-byte blocks, so writing that
partial block would extend the file by 428 B". It does not. Read from Main
itself, not remembered (`../Main_MiSTer/user_io.cpp:3502-3514`, upstream
Sorgelig code from 2021, `4af0d026`/`173d23dd`, so every stock MiSTer runs
it):

```c
uint64_t size = sd_image[disk].size / blksz;      // 1,474,644 / 512 = 2880
if (sz && lba <= size)                            // lba 2880 is ALLOWED
    if (FileSeek(...))
        if (!sd_image_cangrow[disk]) {
            __off64_t rem = sd_image[disk].size - sd_image[disk].offset;
            sz = (rem >= sz) ? sz : (int)rem;     // CLIPPED to the file: 84 B
        }
        if (sz) FileWriteAdv(...);
```

`sd_image_cangrow` is set only by `user_io_file_mount(..., pre != 0)`, the
pre-create path a core uses to have Main make a save file of a given size;
an OSD mount of an existing image passes 0. **So Main writes the partial
block clipped to the file's real end and the file never grows.** On the read
side `FileReadAdv` (`file_io.cpp:693`) returns the short count — 84, truthy,
so the block is "done" — with the rest of Main's buffer left as it was.
The refusal is therefore entirely OURS, in two places, and both are small:

1. **`rtl/floppy_loader.v:199`** — `sec_total <= img_size[40:9]` is FLOOR.
   Make it CEIL: `img_size[40:9] + (img_size[8:0] != 0)`. The extra block
   carries the tail (84 bytes tagless, 340 tagged) and 428/172 bytes of
   Main's stale buffer, which the drain writes past the payload end in
   SDRAM. ★ Check the region has that slack against `sdram` map limits
   before relying on it (a tagged 1.44 MB payload, 1,509,120 bytes, is
   already the largest thing the region holds, and 1,474,560 + 428 is well
   under it — verify, do not assume).
2. **`rtl/floppy_sd_writer.v:200`** — `head_ok` refuses
   `(q_head + 1) == file_blocks` for DC42. Accept it when the file has a
   partial tail (`file_bytes[8:0] != 0`, a new one-bit input beside
   `file_blocks`, derived in `MacLC.sv:2543` next to `flp_file_blocks`).
   The writer sends its full 512-byte buffer; Main clips it. Raw images are
   always 512-multiples, so nothing changes for them. **`head_ok`'s "both
   blocks or neither" rule stays** — the tail block is now writable, so a
   DC42 sector that straddles into it is written whole, the torn-state
   argument is satisfied rather than bypassed.

With both in, **DOS-in-DC42 is SUPPORTED**, the last sector of EVERY tagless
DC42 reads back correctly for the first time (it was silently short by 84
bytes on every mount since Phase 1 — latent for HFS, wrong for DOS), and the
eject-time data-checksum rewrite (`floppy_sd_writer.v`, header words 36/37)
now covers the true payload because SDRAM finally holds it. No header
stripping, no write-protect term, no user-facing limit; the earlier idea of
stripping the 84-byte header automatically is unnecessary and would have
rewritten the user's file behind their back.

Still rides with 6A+6B: same loader file, same fit. Gates in the list below.

#### Order, and why

**6A+6B+6D together, then 6C.** (Revised in review 2026-09-18: 6D was "with
whichever fit happens first"; it now rides with 6B because the `mediaSides`
sniff and 6D's `sec_total` change are the same loader file and the same fit.)

GCR first because it is a port with a known-good donor and an unambiguous
behavioural target, so it establishes the relay/sidedness plumbing against a
reference before the novel work starts. 6B belongs with 6A because the format
byte it depends on only becomes meaningful once a format can write one.

#### Gates

Offline, per commit:
- `tb_floppy_track_decoder` (incl. `+single` for 400K), `tb_gcr_read`,
  `tb_floppy_commit`, `tb_floppy_sd_writer`, `tb_disk_swap`,
  `tb_mfm_write_path`, `tb_swim_ism_arm`, `tb_pds_enet` after any SDRAM edit.
  ★ Added 2026-09-19: **`tb_mfm_format`** (38 checks) after ANY edit to
  `mfm_write_decoder.v`, `ism_write_engine.v`, `mfm_track_encoder.v` or
  `swim.v`'s ISM write path — it is the only bench that drives a whole track
  through the real CPU bus, and the only one that covers a reformat with a
  live anchor.
- ★ Added in review 2026-09-18, benches for files this phase EDITS that the
  list above missed: `tb_floppy_track_encoder` (the relay's home file; it
  already carries the READY_GAP and `#1` edge discipline the relay bench
  should extend), `tb_mfm_write_decoder`, `tb_ism_write_engine`, and
  `tb_floppy_loader` for the sniff and for 6D's tail block (assert the last
  84 bytes of a tagless DC42 reach SDRAM), and `tb_floppy_sd_writer` for
  6D's `head_ok` (the last DC42 sector is ACCEPTED and issues the tail block;
  keep a mutant that still refuses it failing). Note the donor has NO
  benches at all (`../MacPlus_MiSTer/verilator/` holds no `tb_*.v`), so the
  relay has never had one: its only validation was hardware through a
  chained external drive on a Plus. The relay bench below is the first, not a
  port.
- Quartus **analysis & synthesis** as the elaboration check (catches Error
  10028, which Icarus tolerates — CLAUDE.md).
- ★ A **new bench for the relay**: drive a synthetic format stream into the
  decoder and assert the encoder restarts at the written sector. This is the
  one piece with a hardware failure mode (`fmt1Err`) that no existing bench
  covers. **BUILT 2026-09-19: `verilator/tb_floppy_format_relay.v`, 27
  checks** (build command in its header; ~4 minutes, because it has to wait
  out three real relay gaps of ~9,350 disk bytes at 128 cep each).

On hardware, after a fit:
- **GCR**: Erase Disk on a blank 800K, then mount/write/verify with
  `scripts/hfs_check.py` + `scripts/hfs_fork_diff.py`.
  ★ **NOT `gcr_census.py` / `gcr_data_census.py` — this line used to name
  them and they CANNOT be pointed at an image** (corrected 2026-09-19).
  Both parse the GCR byte stream captured by `verilator/tb_gcr_read.v`, and
  `gcr_data_census` additionally requires the SELF-ADDRESSING synthetic image
  from `gcr_gen_image.py`, so it has nothing to say about a real HFS volume.
  The deeper reason: a `.dsk` holds DECODED SECTOR DATA, not the raw track.
  Address fields exist only in the encoded bitstream the core generates on
  read, so there are none in the file to census. Those two tools belong to
  the read-path simulation work (they exonerated the GCR read datapath on
  2026-08-05), not to a format gate.
  **`hfs_fork_diff` is what actually answers the question the census was
  reaching for**: if the format had put an address field in the wrong
  position, sector data would land at the wrong offset, so files written
  afterwards would read back wrong or the volume would fail to walk.
  Byte-exact forks ARE the proof the address fields were right, arrived at
  through the guest instead of through a stream capture.
  ★★ **PASS ON HARDWARE 2026-09-19**, fit `c447fbe9`. Erased
  `Phase6/P6_GCR_Erase800K.dsk` (which was minted 85% full, so the erase had
  to clear 680K of known content), then copied the Microsoft Word 4.0 folder
  onto it. `vol 'P6 Erase800'` 1594 alloc blocks x 512 B, alBlSt 4,
  CONSISTENT. **FORK DIFF: PASS — 3 identical, 0 differ**, the only other
  entry being the Finder's own Desktop. The load-bearing one is Microsoft
  Word's **683,260-byte resource fork in a single 1335-block extent**: a long
  contiguous write across most of a freshly formatted disk, read back
  byte-identical (2 bytes in the `$30-$7D` window, resource DATA exact).
  PFSW `overflow=0 refused=0`, pstate IDLE.
- **One-Sided erase** of an 800K image — the sidedness-ceiling gate. The disk
  must come back 400K, and must NOT advertise itself double-sided — **across a
  remount** (that is the `mediaSides` half of 6B). Byte-diff the first
  409,600 bytes only; the upper half is remnant (6B note).
  ★★ **NEEDS A PRE-7.5 SYSTEM — 7.5.5 CANNOT REACH THIS GATE** (bench,
  2026-09-19). Under 7.5.5 the Erase dialog offers **no One-Sided option at
  all**: a one-sided format produces an MFS volume, and System 7.5 through
  7.6.1 mount MFS READ-ONLY (a write fails `-4 unimpErr`, confirmed on this
  core 2026-09-16). Run it under System 6.0.8 or 7.1. The same blocker
  applies to the Two-Sided-400K gate below, so run the two together — and do
  NOT read either one's failure under 7.5.5 as an RTL defect.
- **Two-Sided erase of a 400K-sized image** (added in review 2026-09-19,
  owner's ruling): the expected result is **a valid single-sided 400K MFS
  volume, exactly as MacPlus produces** — not an error. The Finder offers
  Two-Sided for any DD medium in a SuperDrive, so this is reachable. The
  mechanics are the donor's, verbatim: `diskSides` holds the ceiling at 0,
  so side-0 tracks commit in the single-sided layout, side-1 address fields
  are REJECTED by the decoder (`floppy_track_decoder.v` `(side && !sides)`)
  and never reach SDRAM, and the read side re-emits every address field with
  format byte `$02` (single-sided) — which is what the driver sizes the
  volume from. The one thing this gate actually tests is the LC ROM's Sony
  driver reacting to that contract the way the Plus ROM's does. Check with
  `scripts/hfs_check.py` (MFS, 391 allocation blocks) and confirm the file is
  still 409,600 bytes.
  ★★ **ALSO NEEDS A PRE-7.5 SYSTEM** (bench, 2026-09-19): the expected result
  IS an MFS volume, and 7.5.5 cannot create one — see the One-Sided gate
  above. Deferred together on 2026-09-19.
  ★ **Verify it with `scripts/mfs_check.py`, NOT `hfs_check.py`** — this line
  used to name the latter, which raises SystemExit on any MDB signature that
  is not HFS's `0x4244` (`hfs_check.py:123`) while MFS's is `0xD2D7`, so the
  named tool refused the exact thing the gate produces. `mfs_check.py`
  (2026-09-19, ported from MacPlus `mfs_extract.py` `1009d3c`) walks every
  fork's VABM chain with cycle and range detection; run it with
  `--expect-alblks 391`.
- **One-Sided erase of a 400K-sized image** — the NATIVE 400K cell, added
  2026-09-19 when the owner asked whether it was covered. It was not, and it
  is not mere completeness: **it is the control that makes the gate above
  readable.** The GCR matrix is {800K, 400K} x {One-Sided, Two-Sided}; gate 1
  is native 800K, the One-Sided-800K gate is the 800K conflict, and the
  Two-Sided-400K gate is the 400K CONFLICT — `diskSides` is 0 for a 409,600 B
  file so `doubleSidedDisk` (`floppy.v:1020`) clamps to single-sided whatever
  the format asked. This cell is the same path with NOTHING TO CLAMP, file
  and format agreeing. Run both and compare: the clamped result should be
  structurally indistinguishable from the unclamped one (volume name and
  timestamps aside), which is a far stronger statement of "exactly as MacPlus
  produces" than "it is valid MFS with 391 blocks" on its own.
  Image: `Phase6/P6_OneSided400K.dsk`. Same pre-7.5 System requirement.

★★ **ALL THREE SIDEDNESS GATES PASS ON HARDWARE 2026-09-19**, fit `c447fbe9`,
run under **System 7.1** (the MacPlus `mac_80mb.vhd`, vol `System 7.1 80MB`,
77 files — a small 7.1 volume boots the LC fine; base 7.1 needs no System
Enabler for a 1990 machine). Verified with `scripts/mfs_check.py
--expect-alblks 391`; all three volumes MFS CONSISTENT, every VABM chain
clean, 391 alloc blocks x 1024 B, alBlSt 16.

- **Native 400K One-Sided (the control)**: `vol 'P6 One400'`, 1 file
  (Finder's Desktop), 390 free. This is the reference.
- **Two-Sided erase of the 400K image**: `vol 'P6 Two400'` — **28 differing
  bytes in 409,600 against the control**, in 4 sectors (2, 4, 16, 798).
  EVERY geometry field identical: drNmAlBlks 391, drAlBlkSiz 1024, drAlBlSt
  16, drDirSt 4, drBlLen 12, drClpSiz 8192, drFreeBks 390, drNmFls 1,
  drNxtFNum 2. The only MDB differences are drCrDate/drLsBkUp, 144 s apart
  — the gap between the two erases. Sectors 2 and 798 differ by the same 7
  bytes each (the MDB and its backup copy carrying those timestamps), 4 is
  the directory entry's dates and 16 the Desktop fork's resource header.
  **The clamped result is indistinguishable from the unclamped one** — which
  is what the control was added for, and a far stronger result than "valid
  MFS with 391 blocks".
- **One-Sided erase of the 800K image**: `vol 'P6 OneSide'`, file still
  **819,200 B** (hps_io cannot resize — correct). Lower 409,600 B differs
  from the native 400K format by 140 bytes in the SAME four sectors — volume
  name plus timestamps. Guest after a REMOUNT: **390K available**, which is
  390 free blocks x 1024 = 399,360 B exactly, matching `mfs_check`'s
  `free 390`; a double-sided mount would have said ~790K. The `mediaSides`
  half of 6B holds across the remount.
  ★ **The upper half is remnant, and "remnant" was MEASURED, not assumed:**
  1133 `P6 ... SECnnnnnn` markers intact, 70.4% nonzero, and only 4 sectors
  of 800 changed — 1365, 1366, 1369, 1598. Those are structures of the OLD
  HFS volume (1598 still carries its `BD` signature and old `drNmAlBlks`
  063a = 1594), i.e. the Finder writing a `Desktop` file on the old volume
  when it was mounted BEFORE the erase. Corroborated exactly: mounting the
  identically-minted `P6_Cross800K.dsk` earlier the same day changed
  `2-3, 1365-1366, 1369, 1598`, and the upper-half subset matches sector for
  sector. **Nothing the erase did reached above 409,600.**
- Probes throughout: PFSW `overflow=0 refused=0`, pstate IDLE.
- **Cross-encoding erase** (6C.4): an 800K image erased as DOS 720K and a
  720K image erased as Macintosh 800K must both END IN AN ERROR DIALOG, not a
  hang, and the failed format must not damage the image.
  ★ **NOT "byte-identical afterwards" — that criterion was unachievable and
  is corrected here (hardware, 2026-09-19).** Mounting an HFS volume makes
  the Finder write a `Desktop` file, and mounting a FAT volume through PC
  Exchange writes `DESKTOP` + `FINDER.DAT` + `RESOURCE.FRK/DESKTOP`. No
  mounted image can ever be byte-identical, so an md5 check fails this gate
  forever whatever the core did. Judge it the way `hfs_fork_diff.py` already
  does: **payload byte-identical, Finder-generated files excused.** Measured
  on the 2026-09-19 run: 6 of 1600 sectors changed on the 800K (MDB
  `drNmFls` 1->2, `drNxtCNID` 17->18, `drFreeBks` 231->228, `drAllocPtr`
  ->1365, plus the alt-MDB mirror at 1598) and 9 of 1440 on the 720K (FATs,
  root dir, and the new files' data at 614-619) — with `FILLER.BIN`'s whole
  307,200-byte span at sectors 14-613 bit-identical.

  ★★ **RESULT 2026-09-19, fit `c447fbe9`: the two directions do NOT behave
  alike. 720K-as-800K PASSES; 800K-as-720K HANGS.**
  - *720K erased as Macintosh 800K* — PASS. "Erasing the disk failed"
    dialog, PISM `write:idle arm=0 anchor=sector 3`, CPU back in RAM, image
    undamaged.
  - *800K erased as DOS 720K* — **FAIL: the machine hangs**, exactly as
    6C.4 feared. Probed: PISM `write:ACTIVE arm=1 anchor=INVALID` (armed
    with no anchor) while the CPU spins in a two-instruction ROM loop at
    `$A6F132`/`$A6F134` re-reading the IWM at `$F17E00`, value never
    changing — the ROM's UNBOUNDED write-handshake poll. Chain: the file is
    819,200 B so size pins the encoding to GCR and `mfm_disk` is 0 ->
    `mfm_spinning` 0 (`floppy.v:483`) -> the write tick never fires -> the
    engine neither pops nor underruns -> no handshake -> poll forever.
    PFSW stayed `pstate=IDLE` with refusals 0, and `wrIsMfm = mfm_disk = 0`
    keeps the MFM decoder away from the committer, so the image is safe.
  - ★ **On the fix, 6C.4's "refuse at the driver's density sense" is the
    wrong place.** `floppy.v:307` reports `is_2m = ~mfm_hd` (generic DD
    media), which is HONEST — a real SuperDrive with real DD media does
    offer DOS 720K, because magnetic media is encoding-agnostic; our
    constraint is peculiar to us (hps_io cannot resize a file, so size pins
    the encoding). That field is also the one the 2026-08-03 hardware work
    fixed after an inversion and its comment says "Do NOT 'fix' this back",
    and narrowing it would endanger the legitimate 720K path this same gate
    list still has to pass. **Refuse at the WRITE-ARM point instead**: when
    the ISM write engine is armed while `mfm_disk` is 0, raise the
    underrun/error the driver already handles. That still refuses on
    density, changes neither which decoder commits nor the drive ID, and
    turns the hang into the error the gate asks for.
  - ★★ **CORRECTED, same day: the write-arm underrun would NOT have
    released the guest either.** `releases/boot0.rom` disassembled at the
    probed PC: the loop at `$A6F130` is `move.b (a4),d0 / bpl.b` on ISM
    Handshake (`$F17E00` = reg 7). It tests b7 - FIFO SPACE - and nothing
    else: not b5 (error), not the mode register; the `dbra d3` (#$34BC =
    13,500) bounds BYTES pushed, not polls. An underrun clears ACTION but
    leaves the two primed `$4E` bytes in the FIFO, so b7 stays 0 and the
    poll never exits - the state `tb_swim_ism_arm` §6 ends in, and the
    hang its own arm-edge comment describes. **THE FIX (swim.v, "the void
    cadence"):** when the SELECTED drive's disk is not MFM, a local timer
    at the DD byte time (`WR_VOID_PERIOD` = 259 cep = 32 us) paces the
    engine instead of `floppy.v`'s `mfm_stb`, which needs `mfm_spinning`
    and so `mfm_disk`. The engine pops every byte-time, b7 returns every
    byte, the ROM writes its gap into the void, and after 13,500 bytes
    (~0.43 s) with no index pulse its own timeout takes the error exit
    (`bra $a6f2ec`). Nothing commits: `wrIsMfm` = 0 keeps the MFM decoder
    off the committer, exactly as before. The two tick sources are
    exclusive by `diskMFM`, so an MFM disk is never double-ticked. This is
    the mirror of 4b, where the GCR byte clock never depended on the disk
    type and the write into the void failed at its verify.
    Benches: `tb_swim_ism_arm` §7 (12 checks; reproduces the hang against
    the unfixed RTL - 6 FAIL - and passes with it), `tb_mfm_format` §5
    (which had ASSERTED the hang as expected - flipped). Expected guest
    outcome: the same "Erasing the disk failed" class as 4b, within about
    half a second; the wording is the hardware gate's to record.
    ★★ **HARDWARE GATE PASS 2026-09-19, fit `a2df9a78`
    (`scratch/phase6/MacLC_a2df9a78_phase6_4a.rbf`; STA met setup +0.567 /
    hold +0.247, 0 critical warnings, loop gate 0/0). BOTH directions,
    on the same fit, since the engine's tick source changed:**
    - *800K erased as DOS 720K* (4a): **errors out, no hang** - the
      machine comes back. `P6_Cross800K.dsk` afterwards: `hfs_check`
      VOLUME CONSISTENT; `hfs_fork_diff` vs the `.baseline` twin =
      Marker.bin (696,320 B) IDENTICAL, only the Finder's `Desktop`
      added; the 6 differing sectors are MDB/bitmap/catalog/alt-MDB,
      i.e. a mount, not a write.
    - *720K erased as Macintosh 800K* (4b, re-run): still errors out.
      `P6_Cross720K.img`: `fat_diff` lists FILLER.BIN (307,200 B) plus
      the PC Exchange trio (DESKTOP, FINDER.DAT, RESOURCE.FRK/DESKTOP);
      FILLER.BIN's 600 sectors byte-identical to the baseline; the 9
      differing sectors are the two FATs, the root directory and the
      three new files' clusters.
    Images in `C:/temp/Mac/Test disks/Written/Cross/`. **Gate 4a is
    CLOSED; Phase 6 has no open hardware gate.**
- **6D tail gate**: fill a DOS 1.44 MB DC42 to the LAST cluster (mint it with
  a known tail-cluster file), `scripts/fat_diff.py` byte-exact including that
  file, `refused == 0` throughout, then remount and re-verify the tail sector
  survived; re-run the HFS DC42 short soak because the writer changed; check
  the DC42 header data checksum offline after eject.
  ★★ **PASS ON HARDWARE 2026-09-19, fit `c447fbe9` — BOTH HALVES OF 6D.**
  Images: `Phase6/P6_DOS1440_tail (DC42).img` (TAIL.BIN pinned to cluster
  2848) and `..._fill (DC42).img` (empty), `scripts/mint_phase6_images.py`.
  - **6D.1, the loader CEIL** — TAIL.BIN copied off to SCSI and compared
    byte-for-byte: exact, including the 84-byte signature. Those bytes are
    the ones no pre-6D build could load (the old FLOOR gave 2880 blocks =
    file bytes 0..1,474,559, which after the 84-byte header stops at payload
    byte 1,474,475). Its `TEXT/dosa` type confirms it came off the FAT12
    DC42 and not from elsewhere.
  - **6D.2, the writer's partial-tail acceptance** — needed a disk filled to
    ZERO free clusters; at "5K free" the 9 remaining clusters were the TOP
    ones and the tail was never touched. ★ Note for a re-run: a fill that
    stops "nearly full" does NOT exercise this, and neither does the
    pre-placed TAIL.BIN (the minter writes that on the PC; the core only
    reads it). Filled to 0 free: cluster 2848 = sector 2879 allocated
    `0xFFF`, and file bytes 1,474,560..1,474,643 — the partial block — went
    from all-zero to 22 changed bytes of COHERENT data (a readable `vers`
    resource, `7.1#7.1, (c) Apple`), with sector 2879 carrying 425 nonzero
    bytes of real text. First time this core has ever written those 84 bytes.
  - **The file did not grow**: 1,474,644 B in, 1,474,644 B out. That is the
    premise 6D was reversed on, now confirmed on hardware — Main clips the
    partial write to EOF, so `head_ok`'s "both blocks or neither" rule passes
    sector 2879 through as two blocks and the writer's full 512-byte buffer
    is truncated host-side.
  - Throughout: PFSW `overflow=0 refused=0`, `flushes=3`, pstate IDLE; PISM
    idle with a valid anchor. DC42 data checksums `bf80c6bc` / `3a570712`,
    stored == recomputed — and they now cover the true payload.
  - 32 comparable files byte-identical against the 2026-09-18 soak volume.
    `INITPicker 2.01` differed by 7 bytes (6 in the `$30-$7D` window, 1 at
    fork offset `$12600`) — fingerprints 1 and 3 of the resource-fork note,
    the SAME byte as 2026-09-18 and in the same direction; both DC42 copies
    came via the backup folder while the raw copy came from `boot.vhd`, so
    that is the copy chain, not the DC42 path.
  ★ `fat_diff.py` reports FAIL when the target holds a file the source lacks
  — comparing against the soak volume flags TAIL.BIN that way. Read the
  per-file lines, not the headline, when the source is not the true origin.
- **MFM**: format a blank 1.44 MB, then the short soak (fill / remount);
  `scripts/hfs_fork_diff.py`. Then a 720K DOS format verified with
  `scripts/fat_diff.py`. ★ **AND a DOS 1.44 MB format** — this list asked
  only for 720K DOS and that was a GAP (spotted at the bench 2026-09-19).
  The combinations that physically exist are a 2x2 with one impossible cell:
  HD+HFS = Mac 1.44, HD+FAT = **DOS 1.44**, DD+FAT = DOS 720K, and DD+HFS
  does not exist because the Mac formats DD media as 800K GCR (section 8).
  DOS 1.44 is not redundant with either of the others: the DOS path is
  driven by **PC Exchange** (its formatter stamps OEM `PCX 2.0` in the boot
  sector) while the Mac path goes through the Disk Initialization package,
  so DOS 1.44 is PC Exchange's formatter at HD density — a pairing neither
  other run exercises.
  ★★ **ALL THREE PASS ON HARDWARE 2026-09-19, fit `c447fbe9`.**
  - **Mac 1.44 (6a)**: `vol 'P6 MFM1440'` 2874 alloc blocks x 512 B,
    alBlSt 4, CONSISTENT; 2839/2880 sectors rewritten. Soak: 34 files
    copied back, volume CONSISTENT, 32 files fork-identical, only
    `INITPicker 2.01` differing by 4 bytes (3 in the `$30-$7D` window, 1 at
    `$12600` — the same byte and direction as 2026-09-18, and the source
    folder is literally named `Soak files backup`, which is exactly the
    provenance the resource-fork note pins it on).
  - **DOS 720K (6b)**: 1440 sectors, 2 spc, 2 FATs x 3, 112 root, **9 spt**,
    2 heads, media `0xF9`; 1430/1440 rewritten.
  - **DOS 1.44 (6c)**: 2880 sectors, 1 spc, 2 FATs x 9, 224 root, **18 spt**,
    2 heads, media `0xF0`; 2853/2880 rewritten, last sector 2879 included.
  - ★ **THE EVIDENCE THAT THE FORMAT REACHED THE SURFACE IS THE `0xF6`
    FILLER**, not the fact that the volume mounts. `0xF6` is the standard
    IBM/MFM data-field filler written during a low-level format, and it
    covers essentially every free sector on all three disks (2810 / 1410 /
    2835). A filesystem merely written over the old surface would leave the
    previous contents in the free area; these disks do not. Check this on
    any future format gate — it distinguishes "formatted" from "a new
    directory written on stale media" in one command.
  - Probes on all three: PFSW `overflow=0 refused=0`, pstate IDLE; PISM
    idle, arm=0, anchor valid. ★ `flushes` did NOT advance on the raw-image
    runs while it advanced on each DC42 eject — correct, not a miss: the
    eject flush exists to rewrite the DC42 header checksum (words 36/37)
    and a raw `.dsk` has no such header.
  - **No MFM read-side relay was needed** (6C.0's open question): the write
    side laid down complete, correctly-paced tracks at both densities.
- PFSW `overflow`/`refused` == 0 and PISM anchor valid throughout, as in §8.1.

#### Risks and watch-outs

- ★★ **Formatting WRITES ADDRESS FIELDS, so a positional error is the
  DESTRUCTIVE failure mode, not the safe one** (§6.4). The 2026-09-18 soak is
  the mitigating evidence — zero surviving-file sectors touched across two
  deletes and two refills, and the anchor valid at every probe on both HD and
  DD — but a format is the first operation that can make a disk unreadable
  rather than merely wrong.
- **There is no volatile mode** (§8.1). A format on hardware goes straight to
  the user's file. Work on scratch copies with `.baseline` twins, as the soak
  did.
- **Do not re-cap the TG68 kernel or touch `sys/`** if timing tightens; §
  CLAUDE.md. Reconcile from our side.
- The `USE_DBG_OBSERVER` probe deck must stay ON for the dev fits (PISM/PFSW
  are the witnesses) and be commented for the PR branch.

#### Effort

6A+6B is mostly transcription against a verified donor — small. 6C is real
design work, but bounded: the decoder exists, the engine exists, and the
relay has a worked example one directory away. The largest single unknown is
the Sony driver's format sequence, which is a MAME question, not an RTL one.

#### ★★ 6A + 6B + 6D: BUILT AND OFFLINE-GATED 2026-09-19 (NOT yet on hardware)

All three landed in one fit, as the order above calls for. What is in the
tree:

**6A — the GCR format relay.** `rtl/floppy_track_encoder.v` is now
byte-for-byte MacPlus `b340c9f` plus our own header note; the relay went in
verbatim, five-bytes-behind-the-D5 arithmetic and all. `rtl/floppy.v` wires
`.wr_byte(decReady)`, `.wr_mark(wrSecAmark)`, `.wr_mark_sector`, `.wr_end`
through four module-level nets (the write path lives inside the
`WRITE_SUPPORT` generate, the encoder does not; the `no_wrpath` branch ties
them off). `wrEnd` is the donor's `wrBusyPrev`/`wrEndD1` block over
`wrBusy = (writeMode && !_enable) || writeBusyReg`, and **`writeMode` is a
new `floppy.v` input** driven from `swim.v`'s registered `q7` qualified
`!ism_mode` (`iwmWriteMode`), tied 0 on the external drive.

**6B — the sidedness ceiling.** `doubleSidedDisk` is now
`diskSides && (fmtSeen ? fmtDs : mediaSides)`; the drive term is dropped
because the LC has only a SuperDrive. `fmtSeen`/`fmtDs` latch the GCR
decoder's existing `fmt_mark`/`fmt_ds` and clear on `writePathReset`.
`mediaSides` is new, threaded `floppy_loader → MacLC.sv → dataController_top
→ swim.v → floppy.v`; the loader's sniff is the donor's MDB block (sector 2,
`D2D7`/`4244`, `drNmAlBlks × drAlBlkSiz`, seven-cycle shift-add, >1200 blocks
= double-sided) **plus a DC42 offset the donor has no need of** — the
84-byte header puts guest sector 2's MDB at words 42/51/52/53 of file block
2, and reading it at the raw offset would call every DC42 400K image
double-sided. `sim.v` hardwires `mediaSides` to 1 (no loader there); noted in
`docs/verilator_differences.md`.

**6D — the DC42 partial tail block.** `floppy_loader.v`'s `sec_total` is
CEIL (`img_size[40:9] + |img_size[8:0]`), and `floppy_sd_writer.v` takes a
new `file_tail` input beside `file_blocks` so the limit includes the partial
block. `head_ok`'s "both blocks or neither" rule is untouched — the
straddling sector is now written WHOLE rather than refused. Region slack
checked, not assumed: the floppy region is `$600000-$6FFFFF` = 1M words and
the largest payload it holds (a tagged 1.44 MB DC42, 736.9K words) leaves the
214 words of Main's stale buffer far inside it.

**Offline gates, all green on the final tree** (Icarus 12.x; Verilator is not
installed on this host, so `tb_floppy_loader` and `tb_disk_swap` were run
under Icarus with their dependencies listed explicitly):

| bench | result |
|---|---|
| `tb_floppy_track_encoder` + `gcr_decode_track.py` | PHASE 0 GATE: PASS |
| `tb_floppy_track_decoder` | PASS 345 / `+single` PASS 189 |
| `tb_floppy_write` | PASS 55 |
| `tb_floppy_commit` | PASS 17 |
| `tb_floppy_sd_writer` | PASS 8523 (was 8005; section 8 REVERSED for 6D) |
| `tb_floppy_loader` | PASS 34 (was 22; new sections 5 and 6) |
| `tb_mfm_write_decoder` / `tb_ism_write_engine` | PASS 153 / 22 |
| `tb_mfm_write_path` / `tb_swim_ism_arm` / `tb_disk_swap` | PASS 11 / 27 / PASS |
| **`tb_floppy_format_relay`** (new) | **PASS 18** (27 after the 2026-09-19 review added cases 5-7, the whole-revolution WRAP path; all pass, gaps exact to the byte) |
| Quartus Analysis & Synthesis | Successful, 0 errors |

★ **`+single` needs its own image**: `vvp tb_dec.vvp +single` alone fails 29
of 189, because the default `+imghex` is the 800K image. Generate with
`python scripts/gcr_gen_image.py --hex --single` and pass
`+imghex=scratch/gcr_phase0/image400.hex`. That is a bench-invocation trap,
not a regression — it fails identically on the pre-6A tree.

**Mutation-tested, every new check** (the memory note on false PASSes
applies; each mutant was built from the real file by substitution and
confirmed to differ):

| mutant | caught by |
|---|---|
| `sec_total` back to FLOOR | `tb_floppy_loader` §5, 6 failures |
| sniff reads the MDB at the raw offset (no DC42 +42) | `tb_floppy_loader` §6(f) |
| `media_ds` pinned to 1 | `tb_floppy_loader` §6(b)(e)(f) |
| `head_ok` back to `< file_blocks` | `tb_floppy_sd_writer` §8 |
| relay inert (`wr_end` tied 0) | `tb_floppy_format_relay`, 8 failures |
| `wrBusy = writeBusyReg` (no `writeMode`) | `tb_floppy_format_relay` §4 only |

★★ **THE LAST ROW IS THE FINDING, and it nearly went the other way.** With
bytes written back to back the drive is never idle at a `cep` boundary, so a
`writeBusyReg`-derived `wrEnd` never fires mid-track and the mutant passed
the first three relay cases outright. It is caught only by §4, which stalls
the guest mid-format for four byte-times — an interrupt in the ROM's write
loop. So `writeMode` IS load-bearing, but its failure mode is a STALLED
format, not an ordinary one; a bench that only writes at full rate proves
nothing about it. Do not simplify §4 away.

★ Two bench traps worth keeping in mind for 6C, both of which cost time here:
the encoder lays sectors out with a **2:1 interleave** (`STATE_WAIT`:
0 2 4 6 8 10 1 3 5 7 9 11 on a 12-sector track), so the k-th address field is
not sector k; and `driveTrack` resets to **0**, so a bench that picks a track
for its geometry without seeking there runs its own encoder and decoder on a
different `spt` than the drive.

**What is NOT done:** none of it has been on hardware. The Phase 6 hardware
gates above are all still open — GCR Erase, the One-Sided erase across a
remount, the 6D tail gate, the DC42 short soak re-run.

#### ★★ 6C: MFM FORMATTING ALREADY WORKED — 2026-09-19, NO RTL CHANGE

★ **The headline: a whole-track MFM format needed no new RTL.** This section
was written before `rtl/mfm_write_decoder.v` existed; by the time it came to
be built, Stage 2 had already supplied every piece. The decoder's priority-1
path ("an ID field seen in this stream, CRC-valid, not yet consumed — that is
the FORMAT case") places each sector from the ID the guest itself just wrote;
`rtl/ism_write_engine.v` is format-agnostic (it streams bytes and knows
nothing of fields); and the committer mux was already there. What was missing
was **evidence**, so 6C is delivered as one new bench and a design decision,
not as a patch.

**`verilator/tb_mfm_format.v` — 38 checks, PASS.** A whole track written the
way the guest writes one: over the real CPU bus, through `swim.v`'s register
file, FIFO and handshake, `ism_write_engine`, `floppy.v`, the MFM decoder and
the committer. The bench supplies only the CPU, an SDRAM model and the track
bytes. ★ Those bytes are **built in the bench from the MAME pc_dsk tuple, not
taken from `mfm_track_encoder.v`** — sourcing the write side from the read
side's encoder would test the decoder against its own inverse twice and hide
any disagreement about what a real IBM track is.

| section | what it establishes |
|---|---|
| 1 | HD 18 spt: 18 ID+DATA pairs back to back — 18 commits, in order, each at its own byte offset, payload byte-exact, 0 rejects |
| 2 | **no anchor was available at any point** (`ism_anchor_ok` never rose), so every sector was placed by its own in-stream ID |
| 3 | the write ends the way a real one does: the starved engine raises 0x01 and clears ACTION itself |
| 4 | DD 9 spt: the same at the 720K geometry (6C.3) |
| 5 | cross-encoding: an MFM write to a GCR-mounted disk commits nothing and reaches SDRAM not at all (6C.4, image-safety half) |
| 6 | **REFORMAT: a stale anchor must not steer the format** |

★ **§6 is the one that was missing from every earlier plan draft.** §1 and §4
format with no anchor, which is what an *unformatted* disk gives you. Erasing
a disk that already holds a volume does not: the driver reads it first, and
the anchor **survives the switch to write mode by design** — `swim.v:1247`
clears it only on a READ-ARM rising edge. A decoder that preferred the anchor
over the in-stream ID would stack all eighteen sectors on one block, and the
disk would come back with one good sector and seventeen holes. Reformatting
an already-formatted disk is the *common* case, so this is not an edge.

**Mutation-tested**, and the two cases fail differently, which is the point:

| mutant | §1/§4 | §6 |
|---|---|---|
| decoder ignores the in-stream ID (anchor only) | 0 accepted, **18 rejected** | 18 commits, **all at the anchor's block** — wrong addresses, missing payload |
| an ID is never consumed (`id_armed` not cleared) | survives — every data field in a format has its own ID immediately before it | survives |

The second mutant surviving is correct division of labour, not a gap: it is
only observable when a data field arrives with NO preceding ID, which is
`tb_mfm_write_decoder` §8 — and it fails there (2 failures). Do not "fix" it
by adding a case here.

#### 6C.0 — THE RELAY DECISION: **NO MFM RELAY. Skipped deliberately.**

Step 0 asked whether an MFM read-side relay is needed. The MAME runtime run
it specifies is **not available on the Windows dev host** (the tooling in
`verilator/mame/` targets the macOS box — `/opt/homebrew/bin/mame`,
`/private/tmp/goodroms`). Decided on the other evidence instead, and the
argument is strong enough to record rather than defer:

1. **`fmt1Err` is a GCR-only convention.** The GCR relay exists because the
   ROM requires sector 0 to be the first address field after the format. IBM
   MFM has no such rule: every sector self-identifies in its ID field
   (`C H R N`), so the driver locates any sector by searching for it.
2. **The MFM verify is a WHOLE-TRACK READ** with a 73-attempt budget
   (`a6e966` → `a6f308`, `docs/sony_driver_mfm_read_reference.md` §1). A
   whole-track read that budgets 73 attempts is by construction indifferent
   to where the head happens to be.
3. ★★ **A relay would actively endanger a working path.** The MFM encoder's
   `oindex` is positional — high during gap 4a, once per revolution — and
   `rtl/mfm_track_encoder.v`'s own header records that **"the driver verifies
   drive speed via the index period, so the preamble length is load-bearing,
   not cosmetic"**. A relay restarts the layout mid-revolution, which emits a
   short index period. The MAME capture has the driver polling that sense 7 M
   times per session. So an unnecessary relay does not merely fail to help:
   it can break the drive-speed check on the HW-validated 1.44 MB and 720K
   READ paths.

**The risk is asymmetric and that decides it.** Building a relay we do not
need can break working reads; not building one costs, at worst, a `-84
verErr` at the hardware gate — non-destructive, diagnosable, and with a
known remedy. `swim.v` already exports `mfm_wr_active` for a `wr_end`, and
it is deliberately left unconsumed: adding a dangling net in `floppy.v` now
would buy nothing.

★ **If the MFM format gate DOES fail on hardware**, in this order: (a) confirm
it is `-84` from the verify and not an underrun or a `$142` code from
somewhere else; (b) run step 0's MAME experiment on the macOS box to get the
driver's own gap3 and revolution length — **a relay's `rev_len` must be the
DRIVER's, not the encoder's 12,422**, since the driver's gaps need not match
`pc_dsk`; (c) only then build it, and re-gate the MFM READ path (the soak and
the 720K run) afterwards, not just the format.

**Still open for 6C, and they are hardware questions, not RTL ones:** format
a blank 1.44 MB and a 720K DOS disk on the bench, then the short soak; and
the cross-encoding GUEST behaviour — both directions must ERROR, not hang.
The reverse direction of §5 (a GCR write to an MFM-mounted disk) rests on the
same single `wrIsMfm` mux read the other way and is not separately benched;
a defect in that ternary would break every MFM test above.

---

## 6. LC-specific hazards

### 6.1 Two formats — and MFM has no free sector number

An Apple GCR data field self-identifies (§4). **An IBM MFM data field does
not.** The ISM writes only the data field, after the ID field has already passed
under the head, so the write target must be derived from position.

**UK101 has already solved this exact class of problem**
(`../UK101_MiSTer/SAVE_AND_DISK_PLAN.md:411`, "three answers, and a byte-diff
that settled it"). Its conclusions transfer directly and should be treated as
the starting design for stage 2, not rediscovered:

1. **Do not write at the live rotational position** (attempt 1). `.65D` is a
   gap-free format, so a rotational write address stored the idle byte-times as
   real bytes — it wrote the physical inter-record gap that real media has and
   the file does not (22 bytes, ERR #2). *LC analogue:* our images are likewise
   sector images with no gaps. We are structurally safer because we commit
   **decoded data fields** rather than captured raw bytes — but the same trap
   returns the moment anyone proposes capturing the raw stream.
2. **Do not use a cumulative counter** (attempt 2). `read_ptr` was reset only by
   a seek while the DOS re-anchored to the index hole before every access, so it
   was an odometer, not a position. ★ Note the **severity inversion** recorded
   there: attempt 1 failed *safely* (consistent misplacement, caught by the
   DOS's own verify); attempt 2 failed *catastrophically* (arbitrary
   misplacement, straight through to the media, destroying an unrelated sector
   header). A more plausible-sounding fix produced a far more destructive bug.
3. **Anchor to the last byte actually DELIVERED to the guest** (attempt 3):
   set the write pointer to one past the head on every delivered byte, +1 per
   accepted write, 0 on seek/mount. *LC analogue:* the anchor is **the ID field
   most recently delivered to the guest** — which is what the driver itself used
   to decide to write. `rtl/mfm_track_encoder.v` knows exactly which sector it
   is emitting, so latch that at the delivery strobe.
4. **Anchor to the byte RECEIVED, not the live head** (hardening, `08d6fc5`).
   UK101's `rx_latch` is filled at `rot_div == 4` of a byte-time, so a poll
   landing past the boundary receives byte P−1 while the live head already says
   P — a one-byte shift, fatal to the verify-reread and intermittent. Fixed by
   capturing the position alongside the byte in the same cycle. *LC analogue is
   direct and worse:* `floppy.v` delivers through `mfm_byte`/`mfm_mark`/
   `mfm_stb` into `swim.v`'s **16-deep staging ring**, so the delivered byte and
   the encoder's live position are separated by more than one byte-time by
   design. Capture the sector identity **into the ring alongside the byte**.
5. **Reset on seek/mount makes FORMAT correct for free** — now load-bearing
   rather than a curiosity, since formatting is in scope (§1).

★ Method note carried over: UK101's replay simulator could not see defect 4
either way, because its reads are atomic. That one came from reading the RTL
against the hardware model. A byte-exact replay and an RTL read catch different
classes of fault; stage 2 needs both.

### 6.2 Block-device conversion is messier here than on MacPlus

- **DC42 is detected mid-download-stream and its 84-byte header is NOT
  sector-aligned** (`MacLC.sv:2529` subtracts 42 words). **DECIDED 2026-09-14,
  owner's call:**
  1. **Load normalises.** The 84-byte header is stripped while streaming, so
     SDRAM holds pure sector data and guest sector N is at SDRAM offset N*512.
     Everything downstream of SDRAM is then format-agnostic. This is right under
     either write policy, so it is not a decision the write side can regret.
  2. ~~**Stage-1 writes are RAW IMAGES ONLY**~~ **REVERSED 2026-09-15 — DC42 IS
     WRITABLE.** Owner's ruling, taken live and unambiguously: every format we
     can read, we can write. Dani's question on the forum was exactly "which
     file formats will you support writing", and the answer given is "all
     currently supported formats" — so this is now a commitment, not a
     preference.

     ⚠ **Provenance note, because it matters for how much weight the old
     decision carried.** §6.2 and commit `4007848` both recorded the raw-only
     choice as "owner's call, 2026-09-14". On 2026-09-15 the owner said he had
     no memory of discussing it. It cannot be verified either way from here —
     both records are a previous session's own claim. **Lesson: do not write
     "owner's call" into a doc or a commit message unless the owner actually
     said it in that session.** An unverifiable attribution is worse than none,
     because it silently converts a proposal into a settled decision that
     nobody feels able to revisit.

  3. **What DC42 writes actually cost.** The load-normalises decision (item 1)
     does most of the work for free: SDRAM holds pure sector data, so guest
     sector N is at SDRAM offset N*512 **whatever the container was**.
     Therefore:
     - **Phases 3a/3b need NOTHING.** Volatile (SDRAM-only) writes are already
       container-agnostic. DC42 works there the moment the write-protect term
       is dropped.
     - **Only Phase 4 — the SD write-back — is affected.**

     And the misalignment is far more tractable than "84 is not a multiple of
     512" suggests, because the offset is CONSTANT. Guest sector N sits at file
     byte `84 + N*512`; dividing by 512 gives block N with a remainder of
     exactly 84, for every N. So a DC42 sector write is always:
     - bytes 84..511 of **block N** (428 bytes), and
     - bytes 0..83 of **block N+1** (84 bytes).

     One fixed 428/84 split, never a variable one. The RMW is a known shape, not
     a general case.

  4. **The real work is the partial-failure window, and the header checksums.**
     - *Partial failure*: block N lands and block N+1 does not, leaving a sector
       torn across two blocks. It reads back self-consistently, which is the
       dangerous kind. Needs the same never-retire/re-present discipline §7
       item 2 demands of the SD writer.
     - ★ **The DC42 header carries data and tag checksums, and they cannot be
       updated incrementally.** The algorithm is `sum = ror32(sum + word)` over
       the whole payload — every word's contribution depends on its position, so
       changing one sector invalidates the running sum from there on.
       `scripts/mk_dc42.py` implements it and was verified against four
       known-good images. Three options, to be decided before Phase 4:
       (a) leave the checksums stale — most emulators never check them, but
           `mk_dc42.py`'s own verifier and real DiskCopy would flag the image;
       (b) recompute on eject/unmount by re-reading the payload (819200 bytes
           for an 800K image — cheap, and it happens once per session);
       (c) zero the fields.

  ★ **DECIDED 2026-09-16 — option (b): in-container read-modify-write, with
     the header's DATA checksum recomputed on the guest's eject.** Owner's
     choice, taken in that session. Implemented in `rtl/floppy_sd_writer.v`
     (commit `9195c0a`, reviewed and corrected the same day — see below).

     **The neighbour bytes come from the CARD, not from SDRAM.** An earlier
     draft of this paragraph argued the opposite (SDRAM holds the whole
     normalised payload, so assemble each block locally); the code does not
     do that, and the reasons are the writer's LC addition 2:
     - sourcing from SDRAM would make the writer a FIFTH requester on
       `rtl/sdram.v`, the most invariant-laden file in the core (§6.3), for
       the sake of one extra SD read per block against a sector rate of one
       per ~10 ms;
     - the card is the more CORRECT source. If the user turns Floppy Write
       off and later on again, SDRAM has moved on but the file has not;
       reading the neighbour bytes back from the very block about to be
       rewritten means each write changes only the sector it was for, and
       never smuggles in sectors the user chose not to persist.
     So each DC42 sector is four SD transactions: read N, write N patched,
     read N+1, write N+1 patched. The read side reuses `sd_rd`/`sd_buff_wr`
     exactly as `floppy_loader.v` does, and the slot's `sd_lba`/`sd_rd`/
     `sd_wr` are muxed between loader and writer in `MacLC.sv`.

     **The checksum is recomputed by re-reading the file from the card** on
     the guest's eject (the only moment the file is still mounted and the
     guest has finished with it): pass 1 scans blocks 0..last-data-block
     accumulating `sum = ror32(sum + word)` over the data section, pass 2
     re-reads block 0 and writes it back with words 36/37 substituted. The
     TAG checksum is left as read — the tag section is never written, so it
     is still right. ~1600 reads for an 800K image, once per session.

     **Documented limits:** the file's final PARTIAL block is refused (hps_io
     writes whole blocks; a tagless DC42 therefore never persists the 84-byte
     tail of its last sector — and, symmetrically, the loader never LOADS it,
     an older gap now documented in both modules); an OSD-first unmount skips
     the checksum rewrite, leaving a stale checksum over correct data.

     ★ **REVIEW FINDING, 2026-09-16 — the ported remount interlock was a
     corruption path here, fixed before any fit.** MacPlus's writer clears
     the queue on `img_mounted` but leaves the FSM running, which is safe when
     a sector is ONE request. Here a sector is four and the flush ~1600, and
     the later steps are issued from states that never consult `valid`.
     `sd_ack` is per SLOT, so once the loader starts streaming the new image
     its acks walk the writer's FSM forward until it raises `sd_wr` against
     the loader's LBA — the old sector, or the old header block with a
     garbage checksum, written into the NEW image. Reproduced in Icarus in
     both forms (mid-RMW and mid-scan) and pinned by bench sections 10-11.
     Fix: the mount pulse now ABORTS the FSM (safe because Main is single-
     threaded and finishes any captured transfer before it can send a mount),
     and `MacLC.sv` masks the slot's `sd_wr` while the loader owns it. Two
     smaller trigger defects fixed alongside: the flush was gated on the
     toggle's CURRENT state (write, switch off, eject → stale checksum) and on
     `dirty`, which is set when a block lands, not when a sector is queued
     (eject racing the session's only write → no flush). Sections 12-14.
     ⚠ **Lesson for stage 2 and for the MacPlus port-back (§10):** an
     interlock inherited from a one-request design must be re-derived for a
     multi-request one. "Theirs unchanged" is a claim about the text, not
     about the invariant.

     ★ Why NOT (d), normalise-the-file, on reflection: it needs a forked Main
     for truncate, which would be a SECOND Main dependency after ethernet — a
     stock-Main user would silently get no DC42 write — and it rewrites the
     user's archived DiskCopy file into a raw image, which is a surprising
     thing to do to it.

  5. ★ **HOW is explicitly NOT DECIDED (owner, 2026-09-15).** Only *that* DC42
     becomes writable is settled. Everything in items 3-4 is the cost of ONE
     approach — writing back in place, in the container — and a different
     approach may not pay it at all. The owner's own suggestion:

     - **(d) Normalise the FILE on first write: strip the header and leave a
       plain raw image.** Sector N then lands at N*512, so there is no RMW, no
       torn-write window, and no checksum problem — all of items 3-4 evaporate.
       The load path already normalises into SDRAM (item 1), so the core
       already holds exactly the bytes such a file needs.
       Open question that decides its feasibility: **the file has to get 84
       bytes shorter** (19284 for an 800K image with tags), and `hps_io`'s block
       interface writes blocks — it has no truncate, and no create. So this
       likely needs Main-side support, which is a different kind of cost, not a
       smaller one. Check before choosing it. A variant that avoids truncation —
       rewriting in place and leaving a stale tail — makes the file's size stop
       matching its content, which is its own trap given how much of this core's
       geometry logic keys off size.

     Decide between (a)-(d) at the start of Phase 4, not before: Phase 4 is the
     first phase that touches the user's file, and by then the write path will
     have been proven on hardware.
     - *Tags*: the guest's GCR stream carries the 12 tag bytes per sector and the
       decoder currently drops them. A DC42 with a tag section has somewhere to
       put them. Writing them is optional; NOT writing them leaves the tag
       section stale, which is another reason (b) above must recompute the tag
       checksum too, or leave both stale consistently.

  ★ Consequence for Phase 3: `flp_int_wp` in `MacLC.sv` currently reads
  `~status[14] || flp_int_ro || !flp_int_raw`. **The `!flp_int_raw` term comes
  out** — it is the reversed decision, and it is the only code implementing it.
  Left alone until the in-flight Phase 3a fit finishes (no edits during a
  build); it lands with Phase 3b. `raw_img` stays plumbed, because Phase 4 needs
  to know which layout to write.
- **The media-change machinery is all keyed off download start/end** —
  `DSK_EMPTY_CY` (`MacLC.sv:2434`), CSTIN, `disk_switched`, and the `.dsk`/
  `.img` index-nibble compare — and must be re-derived from
  `img_mounted`/`img_size`. That machinery is hardware-validated and was
  expensive to get right (the 2026-08-06 System 6.0.8 install gate). Treat any
  change to it as a regression risk in its own right and re-run
  `verilator/tb_disk_swap.v`.

### 6.3 SDRAM plumbing is EASIER here — use the right pattern

MacPlus lost two hardware gates to `sdram.v`'s two-phase RAS/CAS sampling: a
combinational or pulsed handshake tore down after RAS committed but before CAS
latched column and data (once on the address mux, once on the data mux — where
drive 1 "worked" only by being the ternary's default branch).

This core already has the correct pattern in two proven requesters: the download
port (`rtl/sdram.v:106`) and the ethernet DMA (`rtl/sdram.v:129`), both
documented as LEVEL, not pulse. **Copy one of those. Do not build a new
extra-slot requester** — and note that the floppy read window and the download
slot are already the SAME slot (`flp_ok = !dio_download && flp_present`,
`rtl/addrController_top.v:357`), a hazard that has bitten this core before.

### 6.4 The failure mode is harsher

See §2.1. On MacPlus a bad handshake meant a failed write; here it hangs the
machine. Hence: handshake first, OSD write-enable defaulting Off, and test only
against copies of images.

---

## 7. Inherited defects to pre-empt (MacPlus Phase 5 review)

All six were real, found in one review pass, and every one is a class this port
can reproduce:

1. **Async reset assigned a live signal** → latch inside a combinational loop,
   untimed, feeding the decoder's reset. A glitch abandons a field in progress
   and the write path signals no error, so the guest believes a sector landed
   that never did. *Diff the Quartus warning count against the previous compile
   every time* — this one sat in the log as 57 → 65 and was never examined.
2. **SD-writer ack timeout retired the queue entry.** `hps_io` captures `sd_lba`
   in one command and raises `sd_ack` in a later one, gap unbounded from the
   core's side. Re-present, never retire; retries must be idempotent.
3. **Writes accepted during an image reload.** CSTIN still reads "disk present"
   across a swap, so a field completing then commits the departing disk's sector
   into the newly mounted image — in SDRAM and then into the file.
4. **Bounds check and the address it protects evaluated a field apart.**
   Validate-and-commit must be atomic in one state.
5. **No LBA bounds check against the mounted image size.**
6. **One wire used as an async reset in one module and a sync reset in the
   next.**

Plus the testbench hazard that appeared four separate times: driving `ready = 0`
at zero delay after `@(posedge clk)` lets simulator process ordering decide what
the DUT sees. Use the `#1` discipline throughout, and pulse `ready` SPARSELY — a
continuously-asserted `ready` starves the encoder's address settle time and
silently produces a self-consistent but wrong byte stream.

---

## 8. Stage 2 — MFM/ISM writes

★ **PIECE 1 OF 3 LANDED 2026-09-17: the MFM write decoder.**
`rtl/mfm_write_decoder.v`, the algebraic inverse of `mfm_track_encoder.v`, with
`verilator/tb_mfm_write_decoder.v` as its gate (**147 checks, 0 failures**;
build command in the bench header). It parses the decoded byte stream plus the
mark bit — no PLL, no bit windows — and recovers a CRC-valid 512-byte payload
through the same `buf_addr`/`buf_data` registered read port
`floppy_write_committer.v` already drives, so the committer needs no change.

The anchoring rule from §6.1 is implemented as a PRIORITY, not a guess:
an in-stream CRC-valid ID field (the format case) names the sector; otherwise
`anchor_sector`, an INPUT, does; with neither, the field is refused. One ID
arms exactly one data field. `addr` is built from the PHYSICAL `track`/`side`
inputs with only the sector number taken from the field —
`floppy_track_decoder.v`'s rule — so an ID claiming another cylinder cannot
reach another track; `amark_cyl`/`amark_head` are exported for a caller that
wants to police a format, and steer nothing.

★ **The bench was mutation-tested, and that is what made it worth having.**
Eleven mutants, one per property it claims to police (bounds check removed, ID
never disarmed, address taken from the ID's cylinder, anchor preferred over the
ID, data CRC unchecked, sector off-by-one, committed with no identity source,
ID CRC unchecked, short A1 run accepted, F8 rejected, any address mark
accepted). **Nine were written first and one SURVIVED** — nothing tested the
"three A1s or refuse" guard — so section 11 was added for it and for the
address-mark cases. All eleven are killed now. A bench that passes first time
against its own author's RTL has proved nothing until something has been broken
under it.

★ **PIECE 2 OF 3 LANDED 2026-09-17: the ISM write engine.**
`rtl/ism_write_engine.v` + `verilator/tb_ism_write_engine.v` (**22 checks, 0
failures**, 8 mutants all killed), instantiated in `swim.v` behind
`ism_write_active`. Ported from MAME `swim1.cpp`'s `ism_sync()` write branch,
reduced to BYTES — we model no flux layer, exactly as the read path does not,
so MAME's Tss encoder and TIME0/TIME1 pacing have no counterpart and the byte
cadence arrives as a `tick`.

It is its OWN module rather than more lines in `swim.v`, which is 1200 lines of
delicate read semantics; everything else in this path is a small module with
its own bench, and driving the engine through `swim.v` would mean spinning a
whole drive to test one state machine.

Three MAME semantics that had to be read from the source, not guessed — the
reference doc covers the register map and the handshake inversion but not what
the engine DOES with the FIFO:
- **One CRC token emits TWO bytes.** The guest pushes one token (reg 2); MAME
  keeps the `M_CRC` flag in the shift register so the next byte-time emits
  `crc >> 8` again, which by then holds the low half, because
  `crc16(C, C>>8) == (C & 0xff) << 8`. One token, one pop, two bytes.
- **A mark byte IS written.** It just does not feed the CRC, and it resets it
  to `0xCDB4`. `mfm_write_decoder.v` seeds at every A1 and feeds only from the
  address mark onward — the two must agree or every field we write fails its
  own CRC, which is what bench section 4 (engine -> decoder round trip) exists
  to catch.
- **Write underrun is error `0x01`**, not the read side's `0x04`, and the
  engine clears ACTION so the write stops itself. Guarded by MAME's
  `&& !m_ism_error`, so only the first error latches; `swim.v` applies that
  guard because it owns the error register. Nothing reaches the medium on a
  starved tick — a torn field is refused on CRC, a field with one wrong byte
  written into it is silent corruption.

★ **The byte-time tick EDGE-DETECTS `mfm_stb`, and that is not cosmetic.**
`floppy.v`'s `mfm_stb` is a LEVEL one cep period wide — its clear sits inside
`if (cep)` — **measured at 4.00 clk cycles per delivery**
(`scratch/mfm/tb_stbwidth.v`). Driving the engine from the level would write
every byte four times over. ‼ The same measurement raises an UNRESOLVED
question about the READ path, where `stage_push` is consumed at full clk rate
from the same level; it is filed as its own task, not touched here, because
reads demonstrably work and the likeliest answer is that the analysis is wrong.

★ **PIECE 3 LANDED 2026-09-17: the identity-bearing ring, and the wiring.**
The chain is now continuous: `mfm_track_encoder.v` exports `osector` (1-based,
as the ID field's R byte); `floppy.v` latches it as `mfm_sector` BESIDE the
delivered byte; `swim.v` carries it in the staging ring's free bits `[15:11]`
and latches `ism_anchor_sector` on the CPU's POP — the byte the driver actually
has in its hand, never the live head. §6.1's rule, implemented where it
belongs. A read-arm invalidates the anchor, because the sector it names belongs
to a revolution that is over.

`floppy.v` now runs TWO DECODERS INTO ONE COMMITTER, muxed on the medium. A
drive is GCR or MFM, never both, and the Phase 3 format-neutral carve-out meant
`floppy_write_committer.v` needed NO change to accept MFM sectors — it sees a
22-bit byte offset and a 512-byte read port and never learns what encoded them.

Gate: `verilator/tb_mfm_write_path.v` (**11 checks, 0 failures**), the whole
path through `floppy.v` — anchor, decoder, committer — with all four mutants
killed (osector off by one, anchor not latched with the byte, decoder fed the
LIVE head, committer fed the GCR decoder). GCR regressions unchanged:
`tb_floppy_commit` 17, `tb_floppy_track_decoder` 345, `tb_floppy_write` 55,
`tb_floppy_sd_writer` 8005.

★ **THE BENCH WAS WRONG THREE TIMES BEFORE IT WAS RIGHT, and every version
passed.** Worth recording, because each failure is one this project will meet
again:
1. **Tautological.** It set `wr_anchor = delivered_sector`, so pinning
   `mfm_sector` to a constant moved the expectation with the thing under test.
   The tag is now audited against the ID fields in the DELIVERED STREAM itself
   (`A1 A1 A1 FE C H R N`, parsed in the bench) — 9 fields, 0 mismatches.
2. **Not actually testing its headline claim.** A write is ~8 byte-times; a
   sector is 682. The head never moved, so "delivered" and "live" were
   indistinguishable and a decoder wired to the wrong one passed. The bench now
   WAITS for the head to leave the anchor's sector.
3. **It hung instead of failing.** That wait was unbounded, so the very mutant
   meant to catch a broken tag span forever. It is bounded now. A bench that
   hangs on a defect reads as a slow run, not a result.

★ **`dskReadAck` IS SAMPLED ON `cen`, NOT `cep`** (`floppy.v:386`). The bench
pulsed it one clock after `cep`; the pulse was low again by the sampling edge,
so no payload fetch ever completed and the drive delivered exactly **206
bytes** — the 146-byte track preamble plus sector 1's ID field and gaps — then
stalled forever on its first payload byte. If a floppy bench stops making
progress, check `mfm_needs_data` and `mfm_fresh` in the DUT first.

★ **`floppy.v`'s byte cadence is now a parameter** (`MFM_PERIOD_HD`/`_DD`,
defaults 129/259 = the real 16us/32us; no synthesised instance overrides them,
same technique as `floppy_sd_writer.v`'s `ACK_TIMEOUT_BITS`). At the real
cadence one sector is ~352k clocks, so an Icarus bench that must watch the head
cross a sector boundary cannot afford it; at 7 a sector is ~19k.

★ **THE CPU-SIDE BENCH LANDED 2026-09-17: `verilator/tb_swim_ism_arm.v`**
(**27 checks, 0 failures**). It drives the SWIM over the CPU bus the way the
Sony driver does — the IWM→ISM switch (offset-0xF, bit6 pattern 1,0,1,1), the
Mode SET/CLEAR registers, Handshake polling, FIFO pushes through regs 0/1/2 —
and section 5 does the real sequence: read an ID field, arm, write a data
field, and check it lands at the sector whose byte the CPU actually POPPED.

**It found three RTL defects that none of the other three benches could reach,
because all of them start downstream of the guest:**
1. **The staging ring kept feeding the FIFO during a write.** `stage_drain`
   had no read/write qualifier, so bytes staged during the read phase drained
   into the CPU FIFO once the engine was armed and put **stale read data on the
   medium** behind the guest's own bytes. Now gated on `!ism_write_arm`, and
   the ring is emptied on the write-arm edge.
2. **`ism_write_engine`'s `q_pop` was combinational, and it raced.** `q_pop`
   moves the caller's FIFO level, which IS `q_empty`, which is a term of
   `q_pop`. Not a true loop — there is a register in the ring — but whether the
   block that acts on the pop sees it on the edge that produced it came down to
   evaluation order, and in Icarus it lost: a sibling `always` block counted
   **29,721 pops while the block that acts on them counted ZERO**, so the FIFO
   never drained and one stale byte was re-emitted 29,689 times. `q_pop` is
   REGISTERED now. The latency costs nothing (the next tick is a whole
   byte-time away) and the handshake is unambiguous in any scheduler.
3. **The write-arm edge cleared `ism_fifo_pos`**, throwing away exactly the
   bytes the driver had PRIMED. The first tick underran, ACTION was cleared,
   and the guest then polled Handshake b7 forever against an engine that had
   already disarmed. The ring is emptied on that edge; the CPU FIFO is not.

★ **REVIEW 2026-09-17 — DEFECT 2 ABOVE WAS FIXED BY LUCK, NOW BY DESIGN.**
Registering `q_pop` worked because swim.v's FIFO block runs on `cen` (one clk
in four) and the registered pulse — tick the clk after `cep`, pop one later —
landed exactly on `cen`. Nothing stated or checked that. A mutant delaying the
pop by ONE more clk failed 8/27 in `tb_swim_ism_arm`: 22,475 bytes to the
medium for a 528-byte field, nothing committed, and the underrun that should
have stopped it lost too, so the engine streamed a stale byte forever. swim.v
now holds both pulses in pending bits (`ism_wr_pop_p`/`ism_wr_unr_p`) that the
`cen` block consumes and clears, so the handshake is phase-independent; the
delayed-pop mutant is kept in the bench header as an INVARIANCE check that
must PASS. Also noted, not fixed: the engine drops a pending second CRC byte
if WRITE is cleared between the two (real silicon finishes its shift
register) — wait for the Sony driver's actual end-of-write sequence on
hardware before guessing; the decoder's reject counter is the witness.

★ **FIRST HARDWARE RUN 2026-09-17: PASS, BYTE-EXACT.** Fit `4d3029a1`
(STA met +0.248 ns, Stage 2 pieces 1-3 + the pending-latch fix + the PISM
witness). The guest copied the Speedometer 4.02 folder (~760 KB of forks, 4
files) from the SCSI boot volume onto a writable 1.44 MB raw image (the Quark
installer disk, 917 KB free) and ejected. Offline: `hfs_check.py` walks the
written image clean; 1,577 sectors changed against the baseline, all inside the
MDB/bitmap/catalog/extents nodes and the copied files' extents; every fork is
byte-identical to the LIVE `boot.vhd` source (resource forks after the usual
$30-$7D header mask). JTAG at the end of the session: PFSW refused=0
overflow=0, PISM engine idle with a VALID anchor (sector 16) — the
"armed with no anchor" refusal never fired. ★ The first comparison was against
an August backup of the vhd and showed 9 differing chunks in the app's
resource MAP; those were the app having rewritten its own fork on 09-15
(handle fields at 12-byte stride), not the write path — the tells for a
write-path fault are a chunk equal to the BASELINE (unwritten) or to a
DIFFERENT source chunk (misplaced), and neither occurred. Compare against the
live source, and classify before blaming the RTL.

★ **SAME EVENING — READ CONTROL + DOS DISKS, ALL ON FIT `4d3029a1`, ALL
BYTE-EXACT.** The read-regression control the plan demanded (Stage 2 touched
swim.v's FIFO/ring, which reads share) is CLOSED: a Finder copy of the whole
System 7.5.5 Update 1 disk (24 files, 1,377,630 fork bytes) matches its DC42
image exactly. ★ First run of it was accidentally on the old phase4b fit; it
was redone on `4d3029a1` — check PISM when in doubt, the old fit has no PISM.
**DOS 1.44 MB disks (PC Exchange 2.x under 7.5.5):** READ — Outrun.img, 57 of
57 visible files byte-identical to a 7-Zip extraction of the image (the 3
hidden/system DOS files and a 0-byte stray are not shown by PC Exchange);
WRITE — Apple File Exchange 7.0 copied onto Outrun.img: 7-Zip integrity test
OK (67 files), all 61 original files unchanged, and the 258,097-byte resource
fork PC Exchange wrote into `RESOURCE.FRK` is byte-identical to the source
(PC Exchange writes forks raw, so no header mask needed; it also wrote
FINDER.DAT + DESKTOP). That is a SECOND filesystem client with its own access
pattern through the same MFM path, and the first PC disk this core has ever
read or written. ★ **Apple File Exchange 7.0 does NOT work under 7.5.5 on this
core** — "cannot read this disk" on DOS AND Mac MFM disks, on the old fit too
— a guest-software incompatibility, not a drive fault (the Finder read the
same disks perfectly). Use PC Exchange 2.x (Custom Install from a 7.5 CD; the
1.0.x copies on the boot volume are 7.1-era). 720K images are DOS-only by
construction (no HFS 720K format exists) and are still UNTESTED on hardware.
PC-side oracles: 7-Zip reads FAT images directly; `machfs` (pip) builds HFS
images with resource forks from PC files (used to deliver PC Exchange 1.0.4).

★ **A DRIVER MUST PRIME THE FIFO BEFORE SETTING WRITE.** An engine armed
against an empty FIFO underruns on its very next byte-time and stops itself —
correct behaviour, and the reason defect 3 above was fatal rather than
cosmetic. The bench does what the driver does: clear the FIFO (Mode bit0),
push two bytes, then set ACTION+WRITE together.

★ **AND FOUR BUGS IN THE BENCH.** It primed while read deliveries were still
flowing into the FIFO; it watched a STICKY error register the read phase had
already tripped; it did not wait long enough for the committer (256 words
through a 3-state-per-word fetch is ~1000 cycles after the last byte); and,
worst, it **pushed blind when its poll gave up** — the byte it silently dropped
was the CRC TOKEN, so the field went out with no CRC, the engine underran where
the CRC belonged, and the decoder never completed a field: no reject, no
commit, nothing to see. That give-up is a hard assertion now.

**Still ahead for stage 2:** MFM FORMATTING (§1 — the decoder accepts in-stream
ID fields already, so this is ISM sequencing, not new decoding); sector writes
are HARDWARE-VALIDATED as of 2026-09-17 (above): Mac HFS write, whole-disk
HFS read control, DOS read AND write via PC Exchange — one trial each; a
larger soak (fill the disk, remount, delete, refill) and a 720K (DD MFM) run
are still owed before PR.

### 8.1 The MFM soak — procedure (written 2026-09-18, not yet run)

**What this adds over 2026-09-17.** That day proved the MFM write path works
once. Six things it did not touch, each of which the soak does:

1. **Queue pressure.** The writer's sector FIFO is 1024 deep
   (`floppy_sd_writer.v`, `QDEPTH_BITS=10`). The GCR soak that closed Phase 4
   was 901 sectors — never within 100 of the limit — and MFM feeds that queue
   faster (500 kbps, 18 sectors/track). A full 1.44 MB fill is ~2 800 sectors
   and is the first test that can reach the refusal path at all.
2. **Whole-medium anchor coverage.** A 760 KB copy lands on low tracks. A fill
   reaches track 79 and both sides — the first exercise of the positional
   anchor across the entire medium. This matters out of proportion to its size
   because **formatting writes address fields**, so an anchor that is wrong at
   high track numbers turns the next phase from a safe failure into a
   destructive one (§6.4).
3. **Delete and refill — never done on MFM in any form.** Sectors written once
   get written again (the writer's re-commit-while-queued ordering has bench
   coverage and no hardware), allocation becomes scattered instead of bulk
   sequential, and catalog/bitmap sectors are hit repeatedly rather than once.
   It is also what produces **forks spanning more than three extents**, which
   is why the gate tool had to walk the extents-overflow tree.
4. **Guest remount on MFM.** GCR got the full write → eject → remount → launch.
   No MFM disk this core wrote has ever been remounted.
5. **The known end-of-write CRC hazard.** `a15242f` recorded it and
   deliberately left it: the engine drops a pending second CRC byte if WRITE
   is cleared between the two. One folder copy is a handful of end-of-write
   sequences; fill/delete/refill is thousands, across far more varied driver
   timings. This is the defect the soak is most likely to surface. **Its
   signature is specific** — one sector bad, so exactly one file differs in
   the fork diff, while `hfs_check` still says CONSISTENT and PFSW is clean.
   If that is what comes back, do not go looking elsewhere first.
6. **DC42 at 1.44 MB.** GCR was gated on raw *and* DC42; MFM has only ever
   been written raw. The DC42 half also exercises the eject-time checksum
   rewrite over a ~2 880-block SDRAM scan, nearly double the GCR one — and
   that scan is what the remount-abort guard protects.

**No rebuild.** The soak runs on `scratch/mfm/MacLC_4d3029a1_stage2.rbf`
(md5 4d3029a1, STA +0.248), which already carries PISM and PFSW. If anything
forces a refit, the single-trial results of 2026-09-17 must be re-taken first —
they are not transferable to a new netlist.

★ **There is no volatile mode** (see the session note of 2026-09-17): one OSD
toggle drives both WRTPRT and `write_ok`, so every write lands in the user's
file immediately. Hence the baselines below; work only on scratch copies.

#### Images (minted 2026-09-18, in `C:/temp/Mac/Test disks/MFM/`)

| file | size | notes |
|---|---|---|
| `Blank1440K.dsk` | 1 474 560 | raw; HFS `Blank1440K`, 2874 alloc blocks × 512 B, alBlSt 4, non-bootable |
| `Blank1440K.baseline.dsk` | 1 474 560 | pristine copy — restore from this between runs |
| `Blank1440K (DC42).dsk` | 1 474 644 | 84-byte header + payload, tagless (1440K DC42 carries no tag section) |
| `Blank1440K (DC42).baseline.dsk` | 1 474 644 | pristine copy |

★ Do not confuse `Test disks/MFM/` (these scratch SOURCES) with
`Test disks/Written/MFM/` (RESULTS — where 2026-09-17's written `EraseMe.img`
and its companion `mac_80mb.vhd` live). Put each run's written image in the
second, so a later session can still tell which was which.

Re-mint with `machfs` (`Volume.write(size=1474560, bootable=False)`, write in
**binary** — see the line-endings trap) then `python scripts/mk_dc42.py
"Blank1440K.dsk" "Blank1440K (DC42).dsk"`, which verifies its own output
against the core's detection rule.

★★ **A DOS FILESYSTEM IN A TAGLESS DC42 IS UNSAFE — DO NOT SUPPORT IT**
(found 2026-09-18, by asking why a 720K DC42 would exist at all).
`floppy_sd_writer.v`'s `file_blocks` refuses the final PARTIAL file block, so
a tagless DC42's last 84 bytes are unwritable. That is latent for HFS, which
reserves its final sectors — empirically confirmed: sector 2879 was never
written in either 1.44 MB soak run, and the volume ends 1 024 B short of the
medium. **FAT leaves no such slack.** A 720K FAT12 volume is 1 440 sectors and
uses every one: cluster 714 covers sectors 1438–1439, so a file landing there
cannot be written. A 1.44 MB DOS DC42 has the same defect and is the more
plausible artifact for a user to own.
★ **Precisely what happens, because the design is better than "truncation":**
`head_ok` (line ~200) requires BOTH file blocks a DC42 sector touches to be
writable, deliberately — "or the sector would land half-written, the torn
state that reads back self-consistently". So the sector is refused WHOLE, not
written short, and **`dbg_refused` counts it** (PFSW[23:16], the out-of-range
field). The loss is therefore invisible to the GUEST — which believes the
write succeeded while the sector keeps its old content — but plainly visible
to us in any gate that reads PFSW. That is the right failure shape; it is
still data loss, which is why the format stays unsupported.
~~Not cheaply fixable: hps_io writes whole 512-byte blocks, so writing that
partial block would extend the file by 428 B and the loader's own
`84 + dsz + tsz == size` check would then reject the image on reload.~~
★★ **WRONG, and RETRACTED later on 2026-09-18** — Main clips a write to the
file's real end unless the core asked for growth (`user_io.cpp:3508-3511`,
upstream since 2021), and no `84 + dsz + tsz == size` check exists in our
loader (it detects DC42 by name length + magic only). The fix is two small
edits on our side and DOS-in-DC42 becomes SUPPORTED — **see Phase 6D**, which
supersedes the ruling and the TO DO below.
~~★ **OWNER'S RULING, 2026-09-18: DOS-in-DC42 IS NOT SUPPORTED, at EITHER size
(720K or 1.44 MB).**~~ **Reversed the same day once the Main source was read.**
Until 6D lands, 720K and DOS gating uses RAW images; DC42 is exercised at
1.44 MB with HFS, where the soak proved it safe.

★★ **720K DOS IN DC42 - GATED ON HARDWARE 2026-09-19, BOTH HALVES.** The
ruling above was retracted on a READING of Main's source; it is now retracted
on evidence. 6D's CEIL was gated at 1.44 MB only, so the DD cell - the one this
section's worked example is about, cluster 714 = sectors 1438-1439 - had never
been run. Fit `82ab9d68` (the probes-off PR build). Images minted by
`scripts/mint_720k_dc42.py`: tagless 720K FAT12 in DC42, 737,364 B, each with
a `.baseline` twin. Deterministic - both images below re-minted byte-identical
afterwards and reproduced their diffs exactly.

- **Writes land, and disturb nothing** (`P6_DOS720K_nearfull`, 12 low clusters
  free plus the tail): two files copied in, both **byte-exact against the
  source volume** (`fat_diff` 2 identical / 0 differ); `FILLER.BIN`'s 700
  clusters **0 of 1400 sectors changed**; **22 of 1440** sectors changed in
  total - the two FATs, the root directory and the new files' own clusters,
  nothing else. DC42 data checksum `8a0dfd80` stored == recomputed.
- **The PARTIAL FINAL BLOCK IS WRITABLE** (`P6_DOS720K_lastfree`, only cluster
  714 free): **PC Exchange placed `FINDER.DAT` at cluster 714 at MOUNT**,
  713/713 clusters allocated, sectors 1438 AND 1439 changed, and the last 84
  bytes of the payload went **all-zero -> 27 nonzero bytes**. The file did not
  grow (737,364 B in and out), so Main clipped the write to EOF exactly as 6D
  predicted. `FILLER.BIN` untouched; 5 payload sectors changed in all (3, 6, 7,
  1438, 1439). DC42 checksum `4161566f` rewritten and correct.

★★ **METHOD WARNING, and it nearly cost the result.** `lastfree` was built with
cluster 714 as the ONLY free cluster, so that a copied file would be forced into
the tail. On hardware the Mac reported the disk COMPLETELY FULL and refused
every file, which reads like a mis-designed image and was written off as one. It
was the opposite: **PC Exchange writes DESKTOP / FINDER.DAT / RESOURCE.FRK at
MOUNT** (3 clusters on the 720K gate, sectors 614-619), so with a single free
cluster it had nowhere to put `FINDER.DAT` except the tail. The "disk full"
message WAS the pass. **Pull the image off the card and diff it before judging a
bench run by what the guest said.**

##### ~~TO DO — enforce the ruling in RTL~~ SUPERSEDED by Phase 6D (2026-09-18):
##### fix the tail, do not lock the disk. Kept for the record; do not build.

Documentation does not protect a user, and `dbg_refused` protects the
developer, not them. Enforcement turns an invisible corruption
at the end of a full disk into a visible, understandable "the disk is locked".
Roughly twenty lines:

1. **`rtl/floppy_loader.v`** — two 16-bit latches off the drain loop, which
   already computes the payload word address
   (`wr_addr <= base_addr + (dc42 ? file_word - DC42_HDR_WORDS : file_word)`):
   payload **word 255** (bytes 510–511, the FAT boot signature) and **word
   512** (bytes 1024–1025, the HFS MDB signature). A comparator and a register
   each. ★ Verify the constants against a real image rather than reasoning
   them out: the loader's internal convention puts the EVEN byte in the HIGH
   half (`sw_data`), so the byte order is not the obvious one.
2. **`MacLC.sv:2576`** — one added term on
   `assign flp_int_wp = ~status[14] || flp_int_ro;`. That is the whole
   enforcement: the comment below it records that `write_ok` is derived from
   `~flp_int_wp` and decided "HERE and nowhere else", so a single term reaches
   BOTH the guest's WRTPRT and the card gate, and they cannot disagree.

```
dos_dc42 = is_dc42 && (dc42_fmt == 2 || dc42_fmt == 3)   // tagless: 720K/1440K
                   && boot_sig == 16'h55AA               // a FAT boot sector
                   && mdb_sig  != 16'h4244;              // and not HFS
```

★★ **DETECT DOS POSITIVELY — never infer it from "not HFS".** A blank or
freshly formatted DC42 has no MDB yet, so a negative rule would write-protect
precisely the disk that is about to be formatted. **MFM formatting is the very
next work item**, so a negative rule collides with it on day one.

**Do it WITH the formatting phase.** It touches the same two files, formatting
needs a new fit anyway, and building it alone would invalidate fit 4d3029a1 —
on which the entire soak above was run — for no gain. Gates when it lands:
`tb_floppy_loader`, `tb_floppy_sd_writer`, Quartus A&S, and a mount test of a
DOS DC42 (write-protected), an HFS DC42 (writable) and a BLANK DC42
(writable, or formatting is dead on arrival). If DOS-in-DC42 is ever to be
supported, the fix is upstream of the writer (refuse the mount, or teach the
loader to carry the tail), not a tweak to `file_blocks`. ★ And that is what
6D does: the loader carries the tail (CEIL `sec_total`) and `head_ok` admits
the tail block because Main clips the write — not a loosening of the
both-blocks-or-neither rule, which still holds.

★ **The tagless-DC42 tail is latent here, and that was checked, not assumed.**
`floppy_loader.v:194` never loads the last 84 bytes of a tagless DC42's final
sector and `floppy_sd_writer.v` refuses the matching block, so sector 2879's
tail is volatile by construction. This volume's allocation area ends at byte
1 473 536, leaving 1 024 bytes of slack, so the tail sits outside it. **A
differently-minted image could put live data there — recheck the span if the
image is ever re-made with other parameters.**

#### Witnesses

- `scripts/pfsw_probe.tcl` — `decode` (PFSW: refusals, out-of-range, flushes,
  idle) and `decode_ism` (PISM: `wr_active`, `wr_arm`, `anchor_ok`,
  `anchor_sector`; it flags "armed with no anchor" and "anchor off the medium"
  itself). The JTAG chain is live; an empty read means a probes-off fit, which
  4d3029a1 is not.
- `scripts/parse_hud.py` — HUD rows 7 (media), 8 (SCAN-WITNESS), 9 (the ISM
  write bits), if the HUD is wanted as a second opinion.
- `scripts/hfs_fork_diff.py` — **the strong half of the gate** (new, 2026-09-18;
  ported from MacPlus `e45a231` onto this repo's `hfs_check.py`). Whole-volume,
  container-detecting, masks the File Manager's rsrc `$30..$7D` bytes.
- `scripts/hfs_check.py` — structural consistency. **Necessary, never
  sufficient:** it reports CONSISTENT on a volume with a corrupt sector inside
  a file. Demonstrated 2026-09-18 — one flipped byte in a resource fork,
  `hfs_check` CONSISTENT, `hfs_fork_diff` FAIL.

#### Procedure

Restore both scratch images from their baselines first. Read PFSW **before
ejecting** (queue state) and **after ejecting** (flush) at every stage, and
record both. Do the whole sequence on the raw image, then repeat it on the
DC42 one.

**A — fit identity and read smoke check, write toggle OFF.** Two minutes, and
deliberately NOT a gate. The full read-regression control is already **closed
on this exact fit** (2026-09-17: the whole System 7.5.5 Update 1 disk, 24 files
byte-exact) and the soak does not rebuild, so there is nothing to re-gate.
What this step is for is the mistake that actually cost an hour that day —
running against the OLD phase4b fit by accident.
- **Read PISM first. If it comes back empty you are on the wrong RBF**: the
  phase4b fit has no PISM probe, and that is the fastest way to tell the two
  apart.
- Then mount a **POPULATED** 1.44 MB image and copy a file off it.
  `Test disks/Written/MFM/EraseMe.img` serves — Speedometer 4.02, ~760 KB, and
  every fork on it is extractable on the PC with `hfs_fork_diff.py` if the copy
  needs checking.
- ★ **Not the blank scratch image**: there is nothing on it to read. Mount that
  one for B.

**B — FILL.** Toggle write On. Copy from `boot.vhd` until the Finder refuses
for lack of space — a disk-full dialog is the expected end of this step, not a
failure. Use a **mix of large applications and many small files**: the large
ones build long extents, the small ones churn catalog and bitmap sectors.
Record what was copied. Then guest-eject.
→ PFSW refusals 0, out-of-range 0; PISM anchor valid throughout.
→ `hfs_fork_diff.py <written> E:/games/MacLC/boot.vhd` = PASS.
→ `hfs_check.py <written>` = CONSISTENT.

**C — REMOUNT.** Remount the written image on the MiSTer, guest-eject-first as
always (§ media changes). The volume must mount, list, and **launch an
application off it**. This is the half of the Phase 4 gate statement that the
byte diff cannot give.

**D — DELETE.** Delete roughly half the files, mixing large and small, and
**empty the Trash** — on a floppy the Trash is a move, so nothing is freed
until it is emptied. Guest-eject.
→ PFSW clean as above.
→ `hfs_fork_diff.py` PASS on what remains; `hfs_check.py` CONSISTENT.

**E — REFILL.** Copy in a **different** set of files, into the freed and now
fragmented space, until full again. Guest-eject.
→ PFSW clean; fork diff PASS; `hfs_check` CONSISTENT.
→ Expect forks spanning >3 extents by now; the gate tool compares them rather
  than skipping them, so they must come back IDENTICAL like the rest.

**F — the DC42 run.** Repeat A–E on `Blank1440K (DC42).dsk`. Additionally:
`hfs_fork_diff.py` prints the stored vs recomputed DC42 data checksum on
every invocation — it must read OK **after** the eject, and the only header
words that may differ from the baseline are {36, 37} (the checksum), as in
Phase 4.

#### ★★ RESULT: THE MFM SOAK PASSED, BOTH CONTAINERS (2026-09-18, fit 4d3029a1)

| phase | raw `Blank1440K.dsk` | DC42 `Blank1440K (DC42).dsk` |
|---|---|---|
| A fit identity + read smoke | PASS | PASS (first 1.44 MB DC42 ever mounted) |
| B fill | PASS — 2 814/2 880 sectors, **cyl 0–79** | PASS — 2 791 sectors, **cyl 0–79** |
| C remount + launch | PASS (Word 4.0) | PASS (Puzzle) |
| D delete | PASS — 32 sectors, all metadata | PASS — 33 sectors, all metadata |
| E refill | PASS — **12 extents, 9 in overflow**, byte-exact | PASS — **10 extents, 7 in overflow**, byte-exact |

- **Every probe, every phase: `overflow=0`, `refused=0`, `pstate=IDLE`, PISM
  anchor valid, `arm=0`, no alarms.** The 1024-deep queue was never stressed.
- **Zero surviving-file sectors changed** in either delete or either refill —
  the strongest evidence the positional anchor places sectors correctly.
- **The >3-extent coverage arrived**: a 409 015 B resource fork shattered
  across 12 (raw) and 10 (DC42) non-contiguous runs of a nearly-full disk
  reassembled byte-identical both times. Predicted before each run from the
  free-space bitmap (">=8 extents, >=5 in overflow") and met both times.
- **DC42 specifics all clean**: header bytes changed = **{36,37} only** (the
  checksum) out of 84, stored checksum recomputed OK at every stage, tag
  checksum and dataSize untouched, and **sector 2879 never written** — the
  tagless-DC42 unwritable tail stayed latent on a real full disk.
- **`flushes` tracked ejects exactly: 4 ejects, 4 increments.** On raw it
  correctly never moved (gated on `dc42`).
- Two fork differences, both benign and both characterised: `INITPicker 2.01`
  (1 byte) and `Puzzle` (42 B in 12 runs, longest 7 B — caught before/after
  running it, so its self-modification is demonstrated, not assumed). Neither
  is sector-shaped. See the memory note on resource-fork fingerprints. ★ The
  gate tool was NOT loosened to excuse them: its one-byte-in-resource-data
  mutant must keep failing, or it is blind to the defect it exists to find.

#### ★★ 720K DD MFM: PASSED 2026-09-18 (same fit, raw image, DOS/FAT12)

720K is **DOS-only by construction**, so this used `scripts/fat_diff.py` (new)
rather than the HFS tools, and a minted `Test disks/MFM/Blank720K.img` —
no 720K image existed anywhere on the machine.

| phase | result |
|---|---|
| A mount, write OFF | PASS — badged DOS, **713K free matching the FAT12 free space to the byte** |
| B fill | PASS — 64 files, 702 KB, **1 387/1 440 sectors, cylinders 0–78**, 29 files verified byte-exact |
| C remount + launch | PASS — Puzzle ran off it via PC Exchange |

- `overflow=0`, `refused=0`, `pstate=IDLE` at every probe.
- ★ **The anchor tracked DD geometry**: readings 3, 9, 4 — it reached 9, the DD
  maximum, and never exceeded it, where the same day at HD it read 11, 14, 16
  and 18. That was the main thing this phase existed to test.
- Cylinder 79 unwritten is the FILESYSTEM, not a refusal: the fill stopped at
  702 of 713 KB so FAT never allocated that far. On a RAW image every sector
  including 1439 is writable — the unwritable tail was purely the DC42
  container's partial final block.
- The one file that differed, `INITPicker 2.01`, differs by the **same single
  byte ($12600, 00 vs 28)** as on the 1.44 MB DC42 disk. Those two writes used
  different data rates, geometries, filesystems AND containers, so a timing or
  staging race cannot produce the identical byte at the identical offset — it
  is inherited from the shared backup folder both copies came from. This
  retroactively exonerates the DC42 run's byte as well.

★ **Three defects in `fat_diff.py` found while using it, all of which would
have produced false results** — recorded because the next person will write
something similar: (1) `RESOURCE.FRK` and `FINDER.DAT` exist in EVERY folder,
not just the root, so anchored `startswith` checks miss the nested ones and
content-matching then pairs `FINDER.DAT` with any source file of the same
length; (2) **the $30..$7D exemption DOES apply on DOS disks** — PC Exchange
presents a DOS file as a Mac file with a resource fork, so PBOpenRF writes the
File Manager's directory copy exactly as on HFS (measured: 8–10 bytes per
file, all inside the window, none in data); (3) matching by NAME alone picked
the wrong `README` and reported a difference while the real source sat in the
length-matched set — name and length candidates must be MERGED, not tried in
sequence.

Still owed before a PR: **MFM formatting**.

#### ★ Open item: the spontaneous eject — "UNRESOLVED, PROBABLY OK" (owner's
#### ruling, 2026-09-18)

Seen twice during the soak, on the raw disk and again on the DC42 one: a
mounted floppy goes OFF LINE with nobody touching the mount, and the next
access raises the guest's "please insert the diskette" prompt. Re-inserting
fixes it and nothing is lost. Both times an application (Word 4.0) was running
**off the floppy**, on a disk with almost no free space.

What the instruments established:
- **It is a real eject, not a media-change glitch.** On DC42 `flushes` went
  0 -> 1 with no user eject, so a `diskEject` pulse reached the writer and the
  header checksum was rewritten. (On RAW there is NO witness at all —
  `flush_pending` is gated on `dc42` at `floppy_sd_writer.v:251` — which is why
  the first occurrence could not be classified.)
- **It fires once, not repeatedly**: 5 probes over 2 minutes held at 1.
- **It is not spontaneous decay**: a 4-probe, 3-minute idle control with the
  motor off and a disk mounted showed ZERO ejects and zero blocks.
- **The symptom is textbook documented behaviour for an `_Eject` call.**
  Inside Macintosh: Files (Volume Manipulation) — `Eject` flushes the volume,
  places it OFF LINE and ejects it; the volume control block stays in memory;
  a later call raises the disk switch dialog; and on re-insertion the File
  Manager mounts the volume **and reissues the original call**. That last
  clause predicts exactly the single block that landed the instant the disk
  came back. Apple's own guidance is to eject "whenever your application is
  finished with a disk" — sanctioned practice that almost never fired in 1989
  because Word normally ran from a hard disk.

★ **APPLICATION CONTROL, 2026-09-18:** the same DC42 disk, same near-full
state, same mount, running **Puzzle** instead of Word — `flushes` did NOT move
(held at 2), while the floppy was genuinely exercised (anchor moved, 4 blocks
landed). A core-side phantom would not care WHICH application is running; a
misdecoded phases-walk depends on ISM access patterns, not on who opened the
file. One trial each, and Puzzle (13 KB, no temp files) does far less disk
work than Word (683 KB, autosave, scratch), so it is not proof — but it moves
"Word issued the call" from plausible to leading.

What is NOT established: that WORD issued the call rather than our ISM path
fabricating the same pulse (the phases-walk phantom-eject class, whose
`(!ism_active || ism_sel)` qualifier predates stage 2 and has never seen MFM
write traffic). `flushes` counts the pulse, not its origin. No Word-specific
documentation was found — the 4.0 User's Guide is a command reference and the
companion *Getting Started* volume is not online.

★ **HOW TO SETTLE IT, when someone picks this up:** run MAME `maclc` with the
same image and launch Word off it (`docs/mame_compare.md`). If MAME ejects
too, it is guest software and this closes. Offline, no hardware time, no
refit. The alternative — enabling `USE_DBG_HUD` for row 7's media witness —
costs an authorised compile AND breaks the soak's same-fit property, so
prefer MAME.

#### Pass criteria (all of them)

1. PFSW refusals 0 and out-of-range 0 at every read, both images.
2. PISM: no "armed with no anchor", no "anchor off the medium", at any point.
3. `hfs_fork_diff.py` PASS after B, D and E, both images.
4. `hfs_check.py` CONSISTENT after B, D and E, both images.
5. The guest remounts each written image and launches an application from it.
6. DC42: data checksum recomputes OK after eject; header diff = words {36,37}.
7. No write-error dialog in the guest that is not explained by disk-full.

A refusal the guest **notices** (an error dialog) and silent corruption are
different failures with different causes — record which one happened. And per
the CD-attach ruling, one bad boot is not a verdict: retry before blaming the
build.

★ Afterwards, check the SD card: an unclean MiSTer shutdown sets the exFAT
dirty bit on E: and it has recurred through this whole project.


Design starting point is §6.1, from UK101. **The anchoring design question is
answered.** What remains is implementation against this core's structures, plus
two pieces UK101 never had to build:

- an **MFM decoder** — **DONE 2026-09-17**, see above — the algebraic inverse
  of `rtl/mfm_track_encoder.v`, a
  second decoder, not a parameterisation of the GCR one. ★ 2026-09-15: this is
  a BYTE-stream parser plus CRC-16-CCITT, not a flux decoder — see §1, which
  also brings MFM formatting into scope and re-rates this work downward;
- an **ISM write engine, which does not exist at all today**: `rtl/swim.v:376`
  gates `ism_arm` with WRITE explicitly off, so Mode b4 is a no-op (§2.4).

Plus the ISM's inverted write handshake, still to be ground-truthed against
MAME (below). If the Phase 3 carve-outs (§1) landed, the ring already carries
sector identity and the committer already accepts the tuple, so stage 2 is
decoder + engine + handshake rather than a re-plumb.

**Other MiSTer cores with IBM 1.44MB write do not help.** Surveyed 2026-09-07.
`u765.sv` (Amstrad CPC, ZX +3, ao486) and `fdc1772.v` (Atari ST, BBC — a copy is
local at `../BBCMicro_MiSTer/rtl/fdc1772/`) are **controller** models: the guest
issues WRITE SECTOR with C/H/R/N as explicit command parameters and the model
writes to a sector image. `fdc1772.v:1028` is literally `sector <= cpu_din`, and
`sd_lba` is arithmetic on track/side/sector (`:108`). Neither ever decodes an MFM
bitstream.

The SWIM ISM is not a controller in that sense — bytes go wherever the head is,
and nobody tells the hardware which sector that is. The one hard problem is
precisely the problem those cores never have to solve, so their code cannot
donate an answer. UK101's can, because UK101's drive is dumb in the same way.

What *would* transfer from them (CRC-CCITT, gap/sync/address-mark layout) we
already own in `rtl/mfm_track_encoder.v`, MAME-grounded and validated against a
real capture. The decoder wants to be the algebraic inverse of OUR encoder
anyway — the method that worked on MacPlus. Lifting GPL RTL would also set the
licence of the combined work, for no gain.

**The remaining prior art is MAME's `swim1.cpp`/`swim2.cpp`** for the ISM's
write-mode semantics (what Mode b4 does to the engine, how the handshake
inverts, where the write splice falls) — already this project's ground truth via
`docs/swim_ism_read_reference.md` and the `verilator/mame/` toolchain.

---

## 9. Effort

| Stage | Estimate |
|---|---|
| Stage 1 — GCR write (phases 0–5) | ~3 weeks |
| Stage 2 — MFM/ISM write | +1–3 weeks |
| Formatting, GCR | +2–4 days — port of `7712c0e`'s floppy half (§1.1) |
| Formatting, MFM | +3–5 days — decoder extension + ISM format sequencing |
| DC42 write-back (Phase 4) | +2–3 days — the fixed 428/84 two-block RMW, the torn-write guard, and a checksum policy (§6.2 item 4). Added 2026-09-15 when DC42 writes came into scope. |

★ The release gate (§1) means the deliverable is the SUM of those rows, not the
first of them. Formatting entered the table on 2026-09-15; it was previously
listed as out of scope, on a false reading of MacPlus (§1).

Stage 1 is below MacPlus's 3–4 weeks because the decoder, committer and
SD-writer port over and the validation matrix is smaller (§3); it is not lower
still because Phase 1's media-change rework (§6.2) is new work MacPlus never had
to do. Stage 2's range narrowed once UK101's anchoring work was found, but only
the design question closed: the MFM decoder, the absent ISM write engine and the
handshake are all still ahead (§8). The **bottom** of that range assumes the
Phase 3 carve-outs (§1) landed; without them, add the read-path rework back.

---

## 10. Worth porting BACK to MacPlus

Noted while scoping; owner asked.

- **DiskCopy 4.2 support** — MacPlus has **no DC42 handling at all**: the only
  mention in its tree is `readme.md:34` telling users to convert externally,
  with a link to a converter and `releases/bin2dsk.sh` shipped for the purpose.
  This core reads DC42 natively (`MacLC.sv:2529`, and from Phase 1 in
  `rtl/floppy_loader.v`).

  Transfers essentially unchanged, being file-format logic rather than machine
  logic: detection on the RAW delivered word (name length `d[7:0]` at word 0 in
  1..63; magic `d == 16'h0001` at word 41 — NOT the byte-swapped word, see the
  2026-09-14 bug), the reason raw images cannot false-trigger (byte 0 of a
  bootable HFS floppy is `'L'` = 76 > 63, or `$00` blank), the 42-word strip,
  and the format byte at word 40 as the geometry discriminator — **with its
  reason: tags trail the sector data, so payload size lies** (an 800K DC42 is
  838400 payload bytes, not 819200, and matches no size test).

  Does NOT transfer: our SDRAM download-port choice (MacPlus drains via the
  extra slot), the 13-bit `sd_buff_addr` (theirs is 8-bit), and DC42 formats
  2/3 — a Plus is 400K/800K GCR only, so only formats 0 and 1 are meaningful.

  ★ **SAFETY: on MacPlus the DC42 read support and the "DC42 presents
  write-protected" gate MUST land in the SAME commit.** Here the two are
  comfortably sequential because no write path exists yet. MacPlus already
  SHIPS floppy writes, so DC42 detection landing alone means the first write to
  a mounted DC42 image is placed 84 bytes off — corrupting the user's file, and
  doing it silently, because a read back through the same wrong offset looks
  self-consistent. Port `raw_img` (or an equivalent) at the same time.
- **The MAME comparison toolchain** — MacPlus has none.
- **The MAME-grounded `SWITCHED` semantics**, implemented and hardware-validated
  here, which answer the exact open risk MacPlus's own Phase 5 flagged as
  untested.
