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
| `-67 noAdrMkErr` | `a6ee40`, taken at `a6ee76` | the ID primitive's **20000-poll budget expired** hunting for `A1 A1 A1 FE` — the class every *delivery outage / dry hunt* falls into. Retries via SonyVars+43 (seed +42 = **8**), so it posts `FFBD` only after 8 straight timeouts. |
| `-69 badCksmErr` | `a6eed0`, via the `a6ef78` verdict tail | the ID field's **CRC/error verdict failed** — the class a corrupt-but-delivered ID falls into. Same +43 retry wrapper. |
| `-65 offLinErr` | `a6c866`, `a6cdb4` | **benign.** A drive-state byte `< 2` at driver *entry* — it never touches the disk. The Mac polls both drives and the LC has one, so routine polling of the absent second drive posts this constantly. **Not a read failure.** |
| `-84 verErr` | `a6f356` | format/verify budget exhausted (not the copy path) |
| `-83 fmt2Err` | `a6e7dc` | posted literally during mount speed calibration — expected |

★ **Consequence (2026-08-05 pm): a delivery outage or a CRC-bad ID CANNOT
produce `-81`.** Those classes are owned by `-67`/`-69`. A dialog showing
`FFAF` means the stream was serving **CRC-good, right-cylinder/head IDs the
whole time** and the target simply was never among the ones the driver
consumed.

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

### 4b. The budget numbers + the inter-attempt SLEEP (2026-08-05 pm)

Measured **live in MAME 0.264** (`verilator/mame/floppy/sonyvars_watch.lua`,
watching SonyVars through a whole 1.44 MB System 6.0.8 floppy boot):

- **`+46` (the `-81` seed) = `0x40` = 64 unwanted IDs ≈ 3.5 revolutions.**
- `+42` (ID-error retry seed) = 8, `+48` (outer) = 8, `+62` = 100 (GCR sleep
  amount; the MFM path uses the literal 75 — `a6d396`).
- MAME's **deepest healthy scan consumed 17 of 64** — exactly the
  one-revolution physics bound (enter just after the target ⇒ 17 unwanted IDs
  before it comes around). It never spent one ID more.
- MAME posts **zero** `$142` writes across the whole boot.

So a real `-81` requires ~64 consecutive CRC-good unwanted IDs = **the target
skipped on at least 3 consecutive revolutions** — a systematic, revolution-
periodic skip, not bad luck.

**The scan is not a busy-poll walk — it SLEEPS between attempts.** On every
unwanted, uncached ID (`a6d388`): `d0 = SonyVars+62`, or **75 if MFM**
(`a6d390`–`a6d396`, testing the +17-indexed MFM flag), then `a6d592`:
`SonyVars+20 -= d0`, arm a timer task (SonyVars+280, callback `a6d5ca`) for
`d0/10` units via the vector at low-mem **`[$568]`**, and block until the
callback (`a6d3f2`). The mask is **opened during the sleep**
(`andiw #$F8FF,%sr` at `a6d58c`; same pattern at `a6d226`/`a6d368`), so
interrupt service directly adds to wake latency. Nominal intent: sleep ~7.5 ms
so the unwanted sector's data field (~8.5 ms) passes, wake, re-arm, catch the
next ID ~10.9 ms after the last one.

That makes the attempt cadence **timer-paced against disk-paced 11.1 ms sector
slots — a stroboscope**. The wake→re-arm has ~3.4 ms of margin before the next
ID's sync run; a wake that is consistently later than that catches the sector
AFTER next instead — a stride-2 walk. **18 sectors being even, a stride-2 walk
closes into two disjoint 9-sector cycles and the target's parity class is
never sampled again** — burning all 64 budget units on the same 9 unwanted
IDs with every payload byte-exact and no error bit set. This is the standing
suspect for the residual copy failures; the SCAN-WITNESS (§6) measures it
directly (run ≈ 64 + single-parity at the `-81` instant = confirmed).

Note our emulation timing side: E is +3.7% fast (sleeps run *short*, the safe
direction) and the MFM rotation is 198.75 ms/rev (+0.63% fast) — but both are
**crystal-locked with zero wobble**, unlike a real drive's ±1.5% mechanical
variation, so any phase relationship that does arise **persists** instead of
self-healing within a revolution or two.

Other notes on the primitives:

- Every read loop is **b7-guarded** (`a6ee70`, `a6ef1c`, `a6ef36`/`a6ef42`,
  `a6ef7a`/`a6ef86`); there is no unguarded armed pop anywhere in the engine.
- The ID primitive **re-arms internally** on a mismatch (`a6ee82`), sharing a
  20000-poll budget. Catching a data mark (`FB` where `FE` was wanted) therefore
  costs nothing from the caller's budget.
- **The internal re-arm is a full mode cycle** (`a6ee46`): read Error,
  `ModeClr $18`, `ModeSet $01` + `ModeClr $01` (**an explicit CLRFIFO
  pulse**), read Error, `ModeSet $08`. Two consequences: (a) after a free
  `FB` catch the armed stream is cut within ~2–3 payload bytes — a
  fully-streamed data field always means the driver was consuming it; (b) the
  ROM clears the FIFO itself before EVERY arm, so `swim.v`'s F8 arm-edge FIFO
  clear is redundant for this driver (MAME/Snow reset only the shifter/sync
  on the arm edge; the Snow cross-check confirms `ism_fifo.clear()` happens
  only on the explicit mode-bit-0 write).
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
  counts. **Rows 7/8 are the SCAN-WITNESS (2026-08-05 pm,** replacing the
  ID-WITNESS/ratio whose job ended with the interleave verdict**)**: row 7
  latches `{run, hunt_ms, par, gap_us}` at the exact cycle the driver posts
  `0xFFAF` to `$142` — `run` ≈ the budget actually burned (≈64 confirms §4b,
  ≈17 refutes it), `par` = which sector-number parities the burn saw (one
  parity = the stride-2 stroboscope), `gap_us`/row 8's
  `{stall_us, stall_cnt}` = delivery-side starvation (the MFM byte engine's
  SDRAM stall was previously uninstrumented — `miss_cnt` is GCR-only).
  Row 8 low byte counts the `-81` posts the latch has seen.
  ★ **The HUD must be switched off in `MacLC.qsf` before any release fit.**
- **`verilator/mame/floppy/sonyvars_watch.lua`** — MAME-side ground truth:
  logs the SonyVars retry seeds on change and every `$140-$143` write with
  the posting PC. This is how the 64-ID budget and the healthy-scan depth
  were measured; rerun it whenever a new theory needs the driver's actual
  numbers.
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

## 7. RESOLVED (2026-08-05 evening): VIA timers ran 2.0× slow — the sleep
## stroboscope confirmed and root-caused

**The SCAN-WITNESS run (build `ae5bbd47` = `606224b`, SEED 2) confirmed the
§4b stroboscope on every one of 5 failure dialogs, with the identical latch:**

| witness | value | reading |
|---|---|---|
| `run` | **130** | 2 retry passes (SonyVars+45 seeds 2) × the 64-ID budget: the scan crossed **7 revolutions** without its target |
| `par` | **ODD only** | the whole 130-ID burn saw one parity class — a perfect stride-2 lock. (Always the complement of the unreachable class: odd wanted sectors still matched the bitmap mid-call, so the failing calls are exactly those whose *remaining* wanted set was all-even.) |
| `hunt` | **8 ms** | the last armed window waited 8 ms ⇒ re-arm landed ~3 ms past the straddled ID's sync ⇒ total sleep+dispatch ≈ 13.5 ms vs the intended ~6.75 |
| `gap`/`stall` | 10 µs / **0** | delivery never starved; **zero MFM SDRAM stalls all run** — the fetch-contention suspect is dead at the source |

**Root cause: `rtl/via6522.sv` prescaled T1/T2 by 2 on top of enables that are
already at phi2 rate.** The TG68 is instantiated with `E_div=1` (E = CPU/20 ≈
812.5 kHz = the V8's real VIA clock C15M/20 = 783.36 kHz, +3.7%), but the
prescaler (1850a7f, 2026-06-05) assumed E = CPU/10 — true only of the March
`status_turbo` wiring. Net: **every VIA timer interval since June ran 2.0×
long.** The Time Manager (VIA1 T2; unit = 16 ticks — `a0afbe` reads T2C-H/L
and `asr #4`; ms→unit constant 0xC3D70A3E at `a0af30`; vector `[$568]` =
`a0af1a`) doubled the §4b sleep from ~6.75 ms to ~13.5 ms, planting every
re-arm ~3 ms past the next ID — stride-2, 9-sector cycle, `-81`.

Fix: count on every falling enable (`timer_tick = 1'b1`), history + do-not-
reintroduce note in `via6522.sv`. A real LC survives its own late-ish wakes
because 7.5 ms + dispatch still lands inside the ~10.9 ms slot — only the 2×
stretch pushed it over, and the crystal-locked zero-wobble rotation made the
resulting phase lock permanent instead of self-healing.

Expected side effects of the fix (VIA-timer clients, all previously 2×): any
Time-Manager-paced delay, T2 delay loops (TattleTech CPU reports read 2× the
true speed while the bug lived), TimeDBRA-calibrated spinwaits.

`tb_ism_sony` passes 145/145 with a FIXED modeled inter-attempt latency — a
phase-locked cadence cannot fail in a testbench that never sleeps on a real
timer, which is exactly why this stayed hardware-only for so long.
