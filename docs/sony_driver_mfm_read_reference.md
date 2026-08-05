# Sony driver (ROM) MFM read path — behavioural reference

Companion to [`swim_ism_read_reference.md`](swim_ism_read_reference.md), which
documents the SWIM **hardware** registers from MAME. This documents the **boot
ROM's Sony driver** — what the software actually does with those registers, and
what each error code the guest sees really means.

Derived by disassembling `releases/boot0.rom` (2026-08-05). Addresses are ROM
PCs as MAME reports them. Regenerate the disassembly with:

```bash
wsl.exe -e bash -lc '~/repos/Retro68-build/toolchain/bin/m68k-apple-macos-objdump \
  -D -b binary -m m68k:68020 --adjust-vma=0xa00000 releases/boot0.rom > rom_full.asm'
```

**Why this file exists:** three separate theories about the floppy copy failure
were built and demolished because this layer was not understood. Read §4 before
forming a fourth.

---

## 1. Which routine actually reads a file

| routine | role | used by |
|---|---|---|
| `a6d13a` → `a6d15c` | single/multi-sector read: scan ID fields, read the wanted one | **the Finder / File Manager — this is the file-read path** |
| `a6e966` → `a6f308` | whole-track read, 73-attempt budget, sweeps `d6=79` tracks | FORMAT / VERIFY only — **not** used by a normal copy |
| `a6e9c2` | the GCR twin of `a6f308` | GCR (400/800K) disks |
| `a6e162` | read the next ID field (dispatches GCR/MFM) | both paths |
| `a6ee26` | MFM ID-field primitive (`A1 A1 A1 FE`, then C H R N) | via `a6e162` |
| `a6eee8` | MFM data-field primitive (`A1 A1 A1 FB`, then 512 + CRC) | via the callers |

`a6e9aa` dispatches to MFM (`a6f308`) when SonyVars+17 bit7 is set; otherwise
the GCR twin. **Do not confuse `a6e9c2` with `a6f308`** — they have nearly
identical structure. The whole `a6e2xx`–`a6e6xx` denibblize region is GCR.

## 2. `$142` — the result-code channel

The driver's common exit posts its result to low memory `$142`:

```
a6cb64:  tstw %d0
         beqs  skip
a6cb68:  movew %d0,0x142      ; ONLY when nonzero
```

Same shape at `a6c746`. Consequences:

- **Every `$142` word-write is a FAILED driver call.** Successes write nothing,
  which is why a watcher sees `nonzero_count == all_count` by construction.
- `a6ea60` (`movew %d0,$142`, unconditional, once per attempt) lives in the
  **format/verify** path only — a Finder copy never executes it.
- `$142` is also used as a byte-sized "done" flag by `a6ea6c`/`a6ea7c`. Require
  **both** byte strobes when watching, to catch only the word writes.

## 3. Error codes — what they actually mean

| code | origin | meaning |
|---|---|---|
| `-81 sectNFErr` | `a6d3a6`, reached via `a6d388` | **the wanted sector never turned up** before the give-up budget ran out — see §4 |
| `-80 seekErr` | `a6d3b2`, from the `a6d166` compare | the ID's **cylinder or head** did not match |
| `-65 offLinErr` | `a6c866`, `a6cdb4` | **benign.** A drive-state byte `< 2` at driver *entry* — it never touches the disk. The Mac polls both drives and the LC has one, so routine polling of the absent second drive posts this constantly. **Not a read failure.** |
| `-84 verErr` | `a6f356` | format/verify budget exhausted (not the copy path) |
| `-83 fmt2Err` | `a6e7dc` | posted literally during mount speed calibration — expected |

★ **The head rides in bit 11 of the compared word.** `a6eea6` does
`bset #11,%d1` when the ID's H byte is nonzero, and `a6d166` compares the whole
word against SonyVars+22. So a **wrong head or cylinder surfaces as `-80`, not
`-81`**. If you are looking at `-81`, cylinder and head were both correct.

## 4. How `-81` is actually produced (the important part)

Inside `a6d15c` the driver loops:

1. `a6e162` reads the next ID field → `d1` = track (+ head in bit 11), `d2` = sector.
2. `a6d166`: cylinder/head mismatch → `-80`.
3. `a6d17e` `btst %d2,%a1@(34)`: is this sector **wanted**?
   - **Wanted** → `a6d22e` reads its data field. Done.
   - **Not wanted** → `a6d184`:
     - if the track **cache** is enabled (SonyVars+256), the sector is read into
       the cache (`a6d1be`) and control loops to `a6d156`, **which RESETS the
       retry counter** (`moveb %a1@(46),%a1@(47)`) — a cached scan may walk the
       whole track freely;
     - otherwise → `a6d388` → `a6d3a6` `moveq #-81` → `subqb #1,%a1@(47)` →
       retry at `a6d15c`.

**So the give-up budget at SonyVars+46/47 is spent per UNWANTED SECTOR ID
ENCOUNTERED — not per revolution, and not per error.** `-81` means "scanned
past too many unwanted sectors without the target appearing". It is a
scan-efficiency failure, not a data-integrity one.

This is the single most important fact in this file, and the one that makes
sector interleave actively harmful — see §5.

Other notes on the primitives:

- Every read loop is **b7-guarded** (`a6ee70`, `a6ef1c`, `a6ef36`/`a6ef42`,
  `a6ef7a`/`a6ef86`); there is no unguarded armed pop anywhere in the engine.
- The ID primitive **re-arms internally** on a mismatch (`a6ee82`), sharing a
  20000-poll budget. Catching a data mark (`FB` where `FE` was wanted) therefore
  costs nothing from the caller's budget.
- The per-field verdict is ONE handshake sample at the CRC-low byte, tested
  `d5 & 0x22` (`a6ef86`/`a6ef96`): b5 = error pending, b1 = running CRC ≠ 0.
- Reads run **interrupt-masked**; every exit path disarms via `ModeClr 18`
  (`a6ef9e`).
- The session teardown/init probes Data/Mark **disarmed** (`a6ea9e`, `a6eaf0`,
  `a6eb64`). Our RTL must not pop there — see `swim.v`, commit `c372f97`.
- VIA1 **PA7 is polled in every slow-path loop iteration** (`tstb %a5@` with
  `a5 = [$1D4]+$1E00` = VIA ORA). It is the SCC Wait/Request input and **must
  read 1**; ROM `a49ec8` sets `DDRA=$38` making it an input. See `dataController_top.sv`.

## 5. Theories that were tested and are DEAD

Each of these looked strong and cost real time. Do not re-open without new
evidence that specifically addresses the refutation.

| theory | refuted by |
|---|---|
| **Mark-hunt window / Handshake b7 dishonest** | MAME and Snow implement the same drop-until-first-A1 hunt. b7 is honest. |
| **Verdict poisoning via b1** (CRC of a newer FIFO entry) | Measured exactly 0 on hardware. The 16-deep staging ring is exonerated (`pop_at_depth2 = 0`). |
| **Verdict poisoning via b5** (latched `ism_error`) | Underrun onsets stayed **flat** (3,3,3,3,3) across eight failing dialogs — files fail with no error[2] involvement. Part of the b5 count was the mount self-test, which reads handshake with errors pending *by design*. |
| **Wrong head / wrong cylinder served** | Would produce `-80`, not `-81` (§3). HUD row 7 also shows C/H/N matching the live position. |
| **Track layout corrupt at some cylinders** | `verilator/tb_mfm_idcensus.v`: 160 positions × 2 revolutions, **5760 IDs, 0 errors** — every position serves exactly sectors 1..18 with correct C/H/N, good CRCs and a DAM after each ID. |
| **1:1 sector layout / the 1.92 ms timing cliff** | The cliff is real in sim (1.00 ID/sector at 1.93 ms → 18.00 at 2.18 ms) **but the driver is nowhere near it**: measured 1.12 ID fields per data field on hardware. Adding 2:1 interleave forced an extra unwanted sector on every read (ratio → 3.15) and **doubled** the errors, 6–8 → 14. Reverted in `8077605`; see the note in `mfm_track_encoder.v`. |

## 6. Instruments available (use these, don't rebuild them)

- **`USE_DBG_HUD`** (`MacLC.sv`, macro in `MacLC.qsf`) + **`scripts/parse_hud.py`** —
  12 rows of binary pixels, top-left, decoded from a screenshot. JTAG is dead on
  this board, so this is the only in-system probe. Row 5/6 = `$142` codes and
  counts, row 7 = last ID served {C,H,R,N}, row 8 = {ID fields, DATA fields}
  served. ★ Row 8's ratio is a **relative** metric (it compares builds); it
  cannot be inverted into a miss rate, because a skipped sector's ID-hunt also
  streams that sector's data field.
  ★ **The HUD must be switched off in `MacLC.qsf` before any release fit.**
- **`verilator/tb_ism_sony.v`** — models the driver instruction-for-instruction
  (poll budgets, the `d5 & 0x22` verdict, E-paced accesses, teardown probes).
  `run_track_scan` + `+postgap=N` measures scan efficiency with no artificial
  jitter; `+stallbyte=511 +stalllen=2500` reproduces verdict poisoning.
- **`verilator/tb_mfm_idcensus.v`** — full-disk ID census, seconds to run. The
  standing regression for any encoder change; order-agnostic, so it validates
  layout permutations automatically.
- **`scratch/hfs_ls.py <img>`** — lists a disk image's files and 512-byte
  extents offline, for mapping a failing filename to cylinders.
- **`scripts/dialog_gate.py`** — distinguishes a real Finder error dialog from
  the desktop (keys on the alert triangle; an earlier lavender-track test
  over-counted 3×).

## 7. Current state (2026-08-05)

The copy still fails, ~6–8 files per whole-disk copy, **non-deterministically**
(two identical runs failed on disjoint file sets). Established: payloads are
byte-exact, no error bit is set anywhere, cylinder/head/size are always correct,
`miss_cnt = 0`, `ovr = 0`. Per §4 the failure is that the wanted sector does not
appear before the budget expires — a **timing** fault in rare late arms, not a
format or data fault.

Suspects not yet excluded: SDRAM fetch contention at track boundaries; the
`ism_arm` rising-edge FIFO clear racing a delivery; driver-side latency between
the ID verdict and the data-primitive arm. `tb_ism_sony` passes 145/145, so the
effect is **hardware-only** — instrument it, don't simulate it.
