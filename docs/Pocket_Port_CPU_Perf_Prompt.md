# Resume prompt — port the CPU-performance mission into the Pocket core

Paste everything below into a fresh session opened in `C:\Temp\mistercore\MacLC_Pocket`.
Source of truth for every change: `C:\Temp\mistercore\MacLC_MiSTer`, branch
**`cpu-icache`** (pushed). Read `docs/CPU_Perf_Log.md` there first — it is the
running log, entries are dated, and most entries carry an explicit
**"Pocket port:"** paragraph naming which half is core RTL and which half is
top-level glue.

---

## The mission you are adopting

Between 2026-08-17 and 2026-08-19 the MiSTer MacLC core went from **74.9% to
97.0% of a physical Mac LC** on Speedometer 3.23 (Benchmark Mix 2.771 →
**3.591**; Colour 0.937 → **1.179**, i.e. 94.4%). Six of the twelve Mix tests
now BEAT the real machine. Nothing was overclocked — the CPU is still
C15M ≈ 15.67 MHz. The entire gain came from removing memory-access latency
that the original design imposed on the 68020.

Three independent layers produced it. Ported in order they compound; each is
separately shippable, and **Layer 3 is where most of the win is**.

| Layer | What | Measured on MiSTer |
|:--|:--|:--|
| B — bus FSM | collapse the 68k bus walker | ±0% alone (prerequisite) |
| C — demand-start | memory access starts on demand, not on a slot boundary | **+10.7%** mix |
| I-cache | 1 KB instruction cache, hits answer early AND stay off the bus | **+17.1%** on top |

The scoreboard with every per-test number is
`docs/Speedometer_3-23_Benchmarks.md` (source repo), and the archived
screenshot of the final hardware run is `docs/speedometer_20260819_icache.png`.

---

## Where the two trees actually stand (verified 2026-08-19)

The Pocket fork sits at **exactly the pre-mission state**, which is the best
possible case — the mechanisms transfer without re-derivation:

| | MiSTer (`cpu-icache`) | Pocket (`main` @ 712cbe3) |
|:--|:--|:--|
| `rtl/tg68k/tg68k.v` | Phase-B FSM + `addr_early` | **old 8-state walker**, no `addr_early` |
| memory controller | `rtl/sdram.v`, demand-start + `dl_*` port | pre-Phase-C slot machine |
| **live controller file** | `rtl/sdram.v` | ★ **`src/fpga/core/pocket_sdram.v`** |
| `rtl/fetch_cache.sv` | present, always-on | absent |
| core top | `MacLC.sv` | `src/fpga/core/mac_lc_pocket.sv` |
| offline sim | `verilator/` + TBs | `verilator/` exists (Makefile, check_boot.sh) |

### ★★★ Trap #1, before you touch anything
`MacLC_Pocket/rtl/sdram.v` **exists but is NOT instantiated.** The live
controller is `src/fpga/core/pocket_sdram.v` (a fork of the same file, ~4 KB
larger, carrying Pocket-specific timing from commit 712cbe3). Editing
`rtl/sdram.v` is a silent no-op that will cost you a fit cycle. Confirm with
`grep -n "pocket_sdram\|sdram sdram" src/fpga/core/mac_lc_pocket.sv`.

### ★ Which reference file to copy from
The Pocket top wires memory as `ram_din / ram_addr / ram_ds / ram_we / ram_oe /
ram_do_raw`. That is the **`verilator/sim.v` naming**, not `MacLC.sv`'s
(`sdram_*`). So for top-level glue, diff against **`verilator/sim.v` +
`verilator/sim_ram.v`** in the source repo — they are a complete worked example
of the same port onto the same naming, including the demand handshake and the
download port. Use `MacLC.sv` only for the FPGA-specific parts (request-bundle
registration, clock domains).

---

## Layer 1 — Phase B: collapse the bus FSM

**File: `rtl/tg68k/tg68k.v`** (pure core RTL, no framework coupling).
Source commit **`2791e6a`**; current shape is what you want to copy wholesale.

The old walker steps `s_state` once per tick: AS at s1-phi1, DTACK sampled ONLY
at s4-phi2, latch at s6, clkena at s7 — a fixed ≥8-tick cycle regardless of how
fast memory answered. Replace with `S_IDLE / S_WAIT / S_TAIL1 / S_TAIL2 /
S_ENDC`:

- AS + RW + UDS/LDS assert at IDLE-exit (first edge after the kernel presents
  the access, either phi phase) — one tick earlier, and write strobes now
  assert WITH AS.
- `S_WAIT` exit is sampled **every tick**: `berr_held | ~dtack_n | (phi2 & xVma)`.
- `S_TAIL1/2` reproduce the old s4→s6 spacing exactly. **Do not shorten them** —
  every async responder (SCSI DREQ, and on Pocket whatever the blockdev path
  acks with) depends on that exit→sample distance.

**Four invariants that must survive — all four are load-bearing:**
1. `clkena` may never pulse on two consecutive `clk_sys` ticks. The FSM gets
   this from `!clkena_d` on internal (busstate==01) steps; the old walker got
   it free from clocking only at phi1. **Your SDC's kernel multicycle depends
   on it** (see Layer 1b).
2. `tg68_din_r` latches one full tick before `clkena` — it is a deliberate STA
   register boundary keeping the memory-mux→kernel-datapath cone out of a
   single period.
3. `berr_hold` spans the whole cycle (AS deasserts at S_TAIL2 but the kernel
   samples berr at S_ENDC).
4. The E/VMA block keys on `s_state != 0`, so `S_IDLE` must remain `3'd0`.

**Also add the `addr_early` output** — `assign addr_early = tg68_addr;` (the
kernel's combinational address). Layer 3 cannot work without it; see Trap #2.

Expect **no measurable Speedometer change from Layer 1 alone** (MiSTer measured
−0.5%, i.e. noise). It is a prerequisite, and it is the layer that must boot
perfectly before you go on. Ship/validate it on its own.

### Layer 1b — constraints
Find the Pocket's `.sdc` and port the *reasoning*, not the text. Two entries
matter, both already in `MacLC.sdc` with full derivations:
- the TG68 kernel multicycle (setup 2 / hold 1 on `*TG68KdotC_Kernel*`),
  justified by invariant 1 above;
- the `periph_din_reg` multicycle, justified by E-paced VPA reads being ≥5
  ticks from address-settle to latch.

---

## Layer 2 — Phase C: demand-start memory service

**Files: `src/fpga/core/pocket_sdram.v` (the live one) + `mac_lc_pocket.sv`.**
Source commits: `f13d936` (engine), then the four corrections that made it
correct — `c7291b3`, `4f24246`, `bf6b41a`, `93d5ea5`.

The old controller serves the CPU only at bus-slot boundaries, so every access
is quantized to ≥8 ticks (the "mod-4 slot floor"). Demand-start makes
`oe/we + addr/din/ds` a **level request held for the whole AS-low window** and
starts the access at the next `clk_64` edge. Reads land 7–8 ticks *flat*;
writes post in 6. Free bonus on MiSTer: VPA peripheral accesses dropped from
avg 62 → 36 ticks because the old 8-tick grid was resonant with the 40-tick E
period.

New controller ports (copy the current `rtl/sdram.v` port block verbatim — its
comments are the specification):
- `cpu_done` / `cpu_dout` — completion + **private** held read data
- `flp_win` / `flp_addr` / `flp_guard` — floppy fetch windows, priority, with
  `flp_addr` **deliberately unregistered** (see Law 4 commentary in the file)
- `dl_req` / `dl_slot` / `dl_addr` / `dl_din` / `dl_ack` — the **dedicated
  download port** (Law 3 — do not skip this, see below)

**Top-level, on the FPGA side:** register the *entire* request bundle
(`addr/din/ds/oe/we/flp_win/flp_guard`) in `clk_sys` before it reaches the
controller. This is not optional and not stylistic — see Trap #3.

**DTACK becomes:** SDRAM-backed targets ack via `~cpu_done`; ROM *writes* are
excluded and take the immediate ack-and-discard path; VPA peripherals stay
E-paced. Copy the `_cpuDTACK` ternary chain from `MacLC.sv` and adapt the
Pocket's target names.

---

## Layer 3 — the I-cache (the big win)

**File: `rtl/fetch_cache.sv`** — drop-in, framework-independent, ~280 lines
including the derivations. Source commits `319b17e`, `3555080`, `fb11cd1`,
`11e865c`, **`7a49327`**.

1 KB (`LOG2_WORDS=9`), direct-mapped, **word-granular** (no lines — a fill
captures exactly the word the missed fetch returned; loop re-execution hits
identically to a lined cache after the first iteration). Coherency is all
hardware: unconditional write-snoop invalidate on the indexed entry (QuickDraw
*builds blit code at runtime* — this is load-bearing, not hygiene) plus an O(1)
generation flush on mapping changes (ROM overlay, download active).

**Glue — four connections in the top:**
```verilog
_cpuDTACK   = ... icache_hit ? 1'b0 : ...      // hit answers immediately
cpu_din     = ... icache_hit ? icache_data : ...
ram_oe      = (!_ramOE || !_romOE) && !icache_hit_now;   // ★ hits are bus-silent
.cpuAddr    ( tg68_a_early[23:0] )              // ★ EARLY address, not addr
```
Measured on MiSTer: **98–99% hit rate** on a real boot, ROM fetches **8 → 6
ticks flat** (93% at exactly 6).

---

## The seven laws — this is the port's actual risk list

Every one of these was a real defect that reached hardware, and every one is
reachable on the Pocket because it shares the architecture. They are ordered as
they were found; each cost between an hour and a day.

**Law 1 — a completion signal belongs to its requester alone.**
`cpu_done` may only be set by the CPU's own request and cleared by its own
level. Twice this was violated: `sdram_oe` once included floppy-window terms
(a window bridging the AS gap held `done` → stale reads + lost write acks), and
the download's posted-write ack once landed in `cpu_done` (which *is* the CPU's
DTACK) → the CPU completed reads it never issued. Symptom of the second:
mounting a floppy bombs the guest with random illegal-instruction /
coprocessor-not-installed errors while booting works fine (the boot ROM
download is immune only because the CPU is held in reset for it).

**Law 2 — every access class the engine does NOT serve must still be
terminated.** ROM-region *writes* assert neither `oe` nor `we`; the old slot
machine acked everything at slot start, demand-start doesn't. The LC ROM's
device probe byte-writes into ROM space, got no ack, no VPA, no BERR — and the
machine sat in `S_WAIT` forever. Enumerate your unserved classes and
ack-and-discard them. (MAME confirms the hardware discards ROM writes silently:
`v8.cpp` maps `0x000000-0x0fffff` read-only with no bus error.)

**Law 3 — after demand-start, EVERY CPU-vs-non-CPU shared mux is a bug.** The
old design's slot alignment made them safe *by construction*; removing it
removed that guarantee everywhere at once. Three separate defects, each with a
different symptom, each only visible after the previous was fixed:
- shared **request nets** (download on the CPU's `oe/we/addr/din/ds`) → mount
  **bombs** the guest → fix: the dedicated `dl_*` port;
- shared **address + data strobes** (a floppy window switches `memoryAddr` to
  the image address and forces both strobes — safe only because a window also
  blocks CPU starts, which downloads suppress) → mount **freezes** the guest
  with a sprayed framebuffer → fix: gate `dskReadAck*`/`flp_guard` on
  `!dio_download` **inside `addrController_top.v`**, not at the top;
- shared **read data** (`sdram_do → memoryDataIn → cpuDataOut` muxed to the
  floppy byte for the whole window) → **boot hang** once windows fire every
  rotation → fix: the floppy byte gets its own `dskReadDataIn` wire.
★ The Pocket top has the same `ioctl_download`/`ioctl_wait`/`dio_download`
plumbing, so all three apply. Audit every net the CPU shares with the
download, the floppy encoder, and video before you fit.

**Law 4 — don't "optimize" a handshake's ack rate.** Phase C added a gate
delivering one ack per floppy address change. `floppy.v`'s MFM loop sets
`mfm_ack_skip` on every delivered byte and therefore needs **two acks per
byte**; GCR leans on repeated acks the same way. Both encoders were written
against the continuous every-rotation acks the pre-Phase-C design gave. The
gate was reverted; the bandwidth it saved was recovered instead with an
`flp_present` input (windows only run when a disk is actually inserted — the
GCR encoder free-runs otherwise, so every diskless boot was paying for windows
nobody read: **+17.4% instructions** in the sim harness).

**Law 5 — a continuous-lookup cache on inferred BRAM needs explicit
read-during-write immunity.** `tag_ram`/`data_ram` are read every clock while
the snoop and fill write them. M10K RDW behaviour is not guaranteed to match
Verilog's non-blocking semantics, so silicon can return the NEW tag beside
STALE data — a hit carrying the wrong instruction word. Sim, STA and every
testbench passed; hardware hung. Fix by construction (`rdw_collide` forces a
miss when the entry read this cycle was also written this cycle), never by
timing margin — the original margin argument was valid for the old 8-tick cycle
and was quietly invalidated by Layer 1.

**Law 6 — if a requester can ABANDON a transaction, guard the completion's
birth.** A cache hit answers early and the bus FSM walks on, leaving an
in-flight transaction nobody is waiting for. If occupancy (a floppy window, a
download word, a refresh) delays that transaction's start, its `done` can be
born *after* the request level dropped and land inside the NEXT cycle's wait
window — false DTACK plus the previous access's data. Fix: `cpu_done` may only
be **born** while its request level is up (`&& oe` on the early-done set —
`oe`, not `oe||we`, or a rising write level legitimises a stale read done).
This is the defect that made the I-cache hang the machine for a month.

**Law 7 — an abandoned transaction still costs bandwidth.** Law 6 makes
abandonment *safe*; it does not make it *free*. The controller stays busy
finishing the phantom and the next access stalls behind it. Fingerprint on the
benchmark — and this is how it was finally caught: **tight loops UP while
software-FP tests go 4–6% BELOW cache-off, in the same run** (Sieve +21%,
KWhetstones/FFT/F.P.Matrix each net negative). Fix: the cache exports
`hit_now`, a **per-access snapshot** verdict that gates the memory request, so
a hit never starts a transaction at all.
★ `hit_now` must be a snapshot, not the live verdict: `lookup_match` can RISE
mid-access (an RDW-forced miss refills and matches a cycle later), and a live
gate would drop the request level mid-transaction — which, with Law 6's guard,
means a `done` that can never be born and a CPU that waits forever. Take it
combinationally on the AS-fall edge (the same edge `hit` registers, so gate and
answer can never disagree), latch it for the access, clear at AS-rise.

---

## Traps

**Trap #2 — the early address.** Phase B registers `addr` and asserts AS on the
*same* edge. Feed the cache the registered `cpuAddr` and its correspondence
guard (`rd_idx_d == idx`) rejects every fetch: **100% miss, completely
silently** — no error, no hang, just no speedup. It must get
`tg68_a_early` = the kernel's combinational output, which settles a full tick
earlier and is stable for the whole access. (If you port Layer 3 *without*
Layer 1, the old walker provides a pre-AS address for free and plain `addr`
works — but then re-verify the guard by watching the sim hit counters.)

**Trap #3 — never put a multicycle on the memory request paths.** An earlier
attempt credited them 2 destination periods on a plausible-sounding argument
about the start gate. STA on the post-fit netlist disproved it:
`slack -6.710 ns, WINDOW 15.381 ns, tg68k|addr[16] -> sdram|sd_addr[12]` — the
capture window is ONE `clk_64` period while the V8 address-translation cone
needs ~22 ns. The constraint was hiding a 6.7 ns violation, the controller was
latching half-settled row/column addresses, and the guest bombed with F-line
errors *after* passing every offline gate. The fix is structural (register the
bundle in `clk_sys`, Layer 2). If these paths fail, fix the pipelining.

**Trap #4 — the sim can be structurally blind.** `verilator/sim_ram.v` is
immune to the Law 6 defect by construction (clear-priority `else if`,
level-gated set, no delayed start), which is precisely why every offline gate
passed while silicon hung. When an offline model and hardware disagree, suspect
the model's *shape*, not just its parameters. Likewise, until 2026-08-18 the
sim could only queue downloads at startup with the CPU in reset, making the
entire Law 3 bug class invisible; `--mount-floppy0-at <frame>` was added to fix
that and is what finally reproduced it offline.

**Trap #5 — per-fit marginality is permanent.** Same RTL, different fitter
seed, different hardware outcome. On 2026-08-19 alone: seed 4 drew a −0.389 ns
hold violation on the request-bundle crossing, seed 7 drew −0.036 on a
cd_audio MLAB, and a *timing-met* seed-7 fit produced displaced, chroma-corrupt
video on hardware. Gate **every** fit on real video + a boot, never on STA
alone, and never conclude from one boot.

---

## Gates — run these, they each caught something real

Port these testbenches from `MacLC_MiSTer/verilator/` (the Pocket already has a
Verilator harness, `check_boot.sh` and a `cpu_trace.log` flow):

| TB | Catches | Note |
|:--|:--|:--|
| `tb_fetch_cache.v` | cache coherency (self-modifying code, zero-gap write/fetch, index aliasing, generation flush) | 958 hit-data checks; **fault injection** via `+define+FETCH_CACHE_HOSTILE_RDW` proves the Law 5 guard isn't vacuous |
| `tb_icache_seam.v` | Law 6 stale-done, against the **REAL** controller | uses a TB-only `TB_NO_TRISTATE` pin split so Verilator can compile the real `sdram.v` — port that trick to `pocket_sdram.v`; negative control `SDRAM_NO_DONE_LEVEL_FIX` must FAIL |
| `tb_dl_cpu_seam.v` | Law 3 download-vs-CPU seam | fails 3/10 reads against pre-fix wiring |
| `check_boot.sh` + `bus_hist.log` | boot progress + per-class cycle histogram | `scripts/bus_hist_report.py` is the measurement that made all of this tractable — port it first, it is how you'll know each layer worked |

★ **The unit TBs do not cross module boundaries.** All four floppy TBs
instantiate the encoder/SWIM directly and never touch `addrController_top` or
the controller — and *every* defect in Law 3 lived in exactly that seam while
every TB passed. Test the seams, not just the modules.

---

## How you'll know it worked

Run Speedometer 3.23 in the guest and compare against
`docs/Speedometer_3-23_Benchmarks.md`. Targets, on the assumption the Pocket's
memory system behaves like MiSTer's:

- **Layer 1**: no change (±1%). Boots clean. That's success.
- **Layer 2**: Mix ≈ 2.77 → ≈ 3.07, every test improves 6–17%, fetch cycle
  lengths go *flat* (100% at one length instead of 75% + a slot-miss tail).
- **Layer 3**: Mix → ≈ 3.59, Colour → ≈ 1.18. Sieve, Queens, Bubble Sort move
  most (they're the tight loops a real '020's on-chip cache serves).
  **If FP tests regress while loops improve, you have Law 7** — check the
  request gate before anything else.

Residual after all three on MiSTer: Sieve 67.6% and Queens 86.2% of a real LC —
working sets that defeat a 1 KB direct-mapped word-granular cache. A lined or
larger cache is the next mission's shape, not a bug.

---

## Read these first (source repo, branch `cpu-icache`)

1. `docs/CPU_Perf_Log.md` — the running log; every entry has a "Pocket port"
   note saying which half is core RTL. **Start here.**
2. `docs/Speedometer_3-23_Benchmarks.md` — the numbers and the physical-LC
   reference rows.
3. `rtl/fetch_cache.sv` — the module header is the design rationale.
4. `rtl/sdram.v` port block — the comments ARE the specification for Layer 2.
5. `verilator/sim.v` + `verilator/sim_ram.v` — the worked example in the
   Pocket's own `ram_*` naming.
6. `rtl/tg68k/tg68k.v` — Layer 1, copy wholesale.

Commits, in dependency order:
`2791e6a` → `f13d936`, `c7291b3`, `4f24246`, `bf6b41a`, `93d5ea5` →
`451f11f`, `f46f86f`, `f5035ec`, `7c0190e`, `4c6007e` →
`319b17e`, `3555080`, `fb11cd1`, `11e865c`, **`7a49327`**.

Released MiSTer build for reference: `releases/MacLC_20260819.rbf`
(md5 `65332d3b736756199d7c4c8351276bde`, seed 4, STA met +0.251 ns).

---

## One last piece of method

Two of the three biggest wins this mission came from **cheap measurements, not
reasoning**: a 10-minute A/B against the previous release (which nobody had
ever run) located a regression class in minutes, and a fault-injected testbench
settled in seconds what two rounds of careful reasoning had gotten wrong. Both
reasoning-only "fixes" attempted that day introduced regressions. The final
defect was found by a *user reading a benchmark table*, not by analysis.
Measure first.
