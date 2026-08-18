# Speedometer 3.23 — MacLC core vs physical hardware

Physical-hardware rows are the same reference set as
`docs/Speedometer_3-03_Benchmarks.md`, extended with the Performa 600 column
set from `MacIIvi_MiSTer/docs/Speedometer_3-23_Benchmarks.md` (that sheet also
carries its own core rows; this one is MacLC only).

**Core row provenance:** MacLC core on the bench, guest reports Mac LC /
MC68020 / no FPU / Mac II AMU / 10240K physical / ROM $067C 512K — an
apples-to-apples match for the physical Mac LC rows. Captured 2026-08-17 at
640x480; the capture does not stamp the RBF, so pin the build hash here when
known. **Provenance settled 2026-08-18:** this row predates the CPU-perf
mission entirely — the file arrived untracked and was first committed as
`cfd62ec`, when the branch tip was `a43d5e0` (the `MacLC_20260815.rbf`
release), so the build was almost certainly that release (inferred from the
tip, not stamped by the capture). Phase A of the mission was
`ifdef SIMULATION`-only instrumentation and never entered a bitstream, so the
only mission change ever measured on hardware is Phase B (row below).

Ratio columns are Speedometer's own: CPU tests are Mac Classic = 1.0, color
tests are Mac II = 1.0. Higher is better for KWhetstones/Dhrystones and for
every `(Rat.)` column; lower is better for every `(sec)` column.

| Run                          | Computer  | CPU     | MMU Type    | Physical RAM (K) | Logical RAM (K) | KWhetstones/sec (Abs.) | KWhetstones (Rat.) | Dhrystones/sec (Abs.) | Dhrystones (Rat.) | Towers (sec) | Towers (Rat.) | Quick Sort (sec) | Quick Sort (Rat.) | Bubble Sort (sec) | Bubble Sort (Rat.) | Queens (sec) | Queens (Rat.) | Puzzle (sec) | Puzzle (Rat.) | Permutations (sec) | Permutations (Rat.) | Fast Fourier (sec) | Fast Fourier (Rat.) | F.P. Matrix (sec) | F.P. Matrix (Rat.) | Int. Matrix (sec) | Int. Matrix (Rat.) | Sieve (sec) | Sieve (Rat.) | Benchmark Mix Average (Mac Classic=1.0) | Monochrome (sec) | Monochrome (Rat.) | Two Bit (sec) | Two Bit (Rat.) | Four Bit (sec) | Four Bit (Rat.) | Eight Bit (sec) | Eight Bit (Rat.) | Color Benchmark Average (Mac II=1.0) |
|:-----------------------------|:----------|:--------|:------------|-----------------:|----------------:|-----------------------:|-------------------:|----------------------:|------------------:|-------------:|--------------:|-----------------:|------------------:|------------------:|-------------------:|-------------:|--------------:|-------------:|--------------:|-------------------:|--------------------:|-------------------:|--------------------:|------------------:|-------------------:|------------------:|-------------------:|------------:|-------------:|----------------------------------------:|-----------------:|------------------:|--------------:|---------------:|---------------:|----------------:|----------------:|-----------------:|-------------------------------------:|
| **MacLC core (68020) 640x480 — 2026-08-17** | Mac LC | MC68020 | Mac II AMU |            10240 |           10236 |                 30.303 |              4.151 |              2252.252 |             2.311 |        4.517 |         2.303 |            3.433 |               2.5 |              4.85 |              2.784 |        3.467 |         2.202 |          8.6 |         2.568 |              8.367 |               2.219 |             68.583 |               2.853 |            37.433 |              2.888 |             3.867 |              3.651 |      11.017 |        2.828 |                                   2.771 |             38.9 |             0.838 |            43 |          0.906 |         46.733 |           0.983 |          55.267 |            1.024 |                                0.937 |
| **MacLC core + Phase B&C (demand-start SDRAM) 640x480 — 2026-08-18** | Mac LC | MC68020 | Mac II AMU |            10240 |           10236 |                 33.167 |              4.543 |              2516.778 |             2.583 |        4.167 |         2.496 |            3.067 |             2.799 |            4.367 |              3.092 |        3.183 |         2.398 |         8.05 |         2.743 |              7.633 |               2.432 |               62.6 |               3.126 |            34.167 |              3.164 |             3.517 |              4.014 |       9.117 |        3.417 |                                   3.067 |           35.033 |             0.931 |        38.983 |          0.999 |         42.567 |           1.079 |          50.783 |            1.115 |                                 1.03 |
| **MacLC core + Phase B (bus FSM) 640x480 — 2026-08-18** | Mac LC | MC68020 | Mac II AMU |            10240 |           10236 |                 30.165 |              4.132 |              2242.152 |             2.301 |         4.55 |         2.286 |            3.433 |               2.5 |             4.883 |              2.765 |        3.467 |         2.202 |         8.617 |         2.563 |              8.417 |               2.206 |             68.883 |               2.841 |            37.617 |              2.874 |             3.933 |              3.589 |       11.05 |        2.819 |                                   2.756 |               39 |             0.836 |        43.183 |          0.902 |           46.7 |           0.983 |          55.567 |            1.019 |                                0.935 |
| Mac LC (68020) 640x480       | Mac LC    | MC68020 | Mac II AMU  |            10240 |           10236 |                 34.924 |              4.784 |               2298.85 |             2.359 |         4.45 |         2.337 |             2.55 |             3.366 |              3.25 |              4.154 |          2.3 |         3.319 |        6.183 |         3.571 |              6.117 |               3.035 |             59.467 |               3.291 |            32.767 |                3.3 |               3.1 |              4.554 |         4.9 |        6.357 |                                   3.702 |           28.733 |             1.135 |        31.817 |          1.224 |         35.183 |           1.305 |          42.433 |            1.334 |                                1.249 |
| Mac LC (68020) 512x384       | Mac LC    | MC68020 | Mac II AMU  |            10240 |           10236 |                 34.965 |              4.789 |               2307.69 |             2.368 |         4.45 |         2.337 |            2.533 |             3.388 |             3.233 |              4.175 |          2.3 |         3.319 |        6.167 |         3.581 |                6.1 |               3.044 |             59.333 |               3.298 |              32.7 |              3.306 |             3.067 |              4.603 |       4.883 |        6.379 |                                   3.715 |           28.617 |              1.14 |        31.583 |          1.233 |         34.967 |           1.313 |          42.217 |            1.341 |                                1.256 |
| Mac LC II (68030) 512x384    | Mac LC II | MC68030 | MC68030 MMU |            10240 |           10233 |                 48.622 |               6.66 |                2608.7 |             2.677 |        4.383 |         2.373 |            2.367 |             3.627 |              2.75 |              4.909 |        1.933 |         3.948 |         4.45 |         4.963 |              5.033 |               3.689 |             44.233 |               4.424 |            23.867 |               4.53 |               2.8 |              5.042 |       4.567 |        6.821 |                                   4.471 |           28.217 |             1.156 |        31.383 |          1.241 |         35.383 |           1.298 |              44 |            1.286 |                                1.245 |
| Mac LC II (68030) 640x480    | Mac LC II | MC68030 | MC68030 MMU |            10240 |           10233 |                  48.74 |              6.676 |                2566.3 |             2.633 |        4.383 |         2.373 |             2.35 |             3.652 |             2.733 |              4.939 |        1.933 |         3.948 |          4.5 |         4.907 |              5.017 |               3.701 |             44.067 |               4.441 |            23.717 |              4.559 |             2.817 |              5.012 |       4.567 |        6.821 |                                   4.471 |           28.383 |             1.149 |        31.733 |          1.227 |         35.817 |           1.282 |          44.317 |            1.277 |                                1.233 |
| Mac II (68020) 512x384       | Mac II    | MC68020 | Mac II AMU  |             8192 |            8192 |                 53.715 |              7.358 |                2822.2 |             2.896 |        3.617 |         2.876 |            2.267 |             3.787 |             3.167 |              4.263 |        2.133 |         3.578 |        5.317 |         4.154 |              5.267 |               3.525 |             39.683 |               4.931 |              22.5 |              4.805 |              2.65 |              5.327 |         4.8 |         6.49 |                                   4.499 |           26.617 |             1.225 |        30.267 |          1.287 |         35.033 |           1.311 |          44.733 |            1.265 |                                1.272 |
| Mac II (68020) 640x480       | Mac II    | MC68020 | Mac II AMU  |             8192 |            8192 |                  53.05 |              7.267 |               2811.62 |             2.885 |        3.633 |         2.862 |            2.283 |             3.759 |             3.167 |              4.263 |        2.133 |         3.578 |        5.317 |         4.154 |              5.283 |               3.514 |             39.933 |                 4.9 |              22.7 |              4.763 |             2.667 |              5.294 |       4.817 |        6.467 |                                   4.475 |           26.667 |             1.223 |        30.517 |          1.276 |         35.367 |           1.298 |          45.083 |            1.255 |                                1.263 |
| Performa 600 (68030) 640x480 | Mac IIvx  | MC68030 | MC68030 MMU |            20480 |           20468 |                 67.796 |              9.287 |              3978.779 |             4.083 |        2.883 |         3.607 |              1.5 |             5.722 |             1.633 |              8.265 |        1.217 |         6.274 |        2.467 |         8.953 |              3.617 |               5.134 |              32.75 |               5.975 |            16.833 |              6.423 |              1.55 |              9.108 |       2.433 |       12.801 |                                   7.136 |            20.35 |             1.603 |        23.417 |          1.663 |         27.483 |           1.671 |          36.467 |            1.552 |                                1.622 |

## ★ Phase B+C (demand-start SDRAM, branch `cpu-phase-c-fix`) — +10.7%

Measured on hardware 2026-08-18, same bench/guest/config, RBF md5
`b9ed35136d5ef2994589d6a77bb64088` (seed 4, STA met +0.149 ns).

| Suite | Baseline | Phase B | **Phase B+C** | vs baseline | share of a real Mac LC |
|:--|--:|--:|--:|--:|--:|
| Benchmark Mix | 2.771 | 2.756 | **3.067** | **+10.7%** | 74.9% → **82.8%** |
| Color Benchmarks | 0.937 | 0.935 | **1.030** | **+9.9%** | 75.0% → **82.5%** |

**Every single test improved** (+6.6% to +17.5%), and the prediction held: the
bus-cycle histogram forecast ~+12% cycles/sec, the mix measured **+11.3%** over
Phase B. Cycle lengths went completely flat (100% of fetches at exactly 8
ticks) instead of the baseline's 75%-at-8 with the rest paying 10/12/14 for
slot misalignment.

Two tests now BEAT a physical Mac LC — Dhrystones 109.5% and Towers 106.8% —
and 8-bit colour (1.115) is past a Mac II. Floating point sits at ~95%.

**Where the remaining ~17% lives — exactly where the mission's opening
analysis predicted.** The worst tests are still the tight-loop ones that fit
inside a real 68020's 256-byte on-chip instruction cache, which this core does
not have:

| test | share of a real Mac LC |
|:--|--:|
| Sieve | 53.7% |
| Queens | 72.3% |
| Bubble Sort | 74.4% |
| Puzzle | 76.8% |

That is the I-cache deficit, not the bus — the bus work is done. Ladder item 3
(`rtl/fetch_cache.sv` on branch `i-cache`, shadow-measured at 87.7% hit at
256 B / 96.0% at 1 KB) is now the single dominant remaining item, and it
targets precisely these tests. Note it must be re-evaluated against the NEW
7-tick-flat memory path, not the old 8-14 tick one.

## Phase B (collapsed bus FSM, commit 2791e6a) — NO measurable change

Measured on hardware 2026-08-18, same bench/guest/config as the baseline row.

| Suite | Baseline (08-17) | Phase B (08-18) | change |
|:--|--:|--:|--:|
| Benchmark Mix | 2.771 | 2.756 | -0.54% |
| Color Benchmarks | 0.937 | 0.935 | -0.21% |

Every individual test lands within +0.07% / -1.71%, i.e. **run-to-run noise**
(all tests ran at Itr. = 1). **This confirms the Step-0 model rather than
contradicting it.** The bus-cycle histogram predicted exactly this: Phase B
shortens the CPU's state machine, but RAM/ROM/VRAM still took DTACK only at
cpu-slot starts, so memory cycles stayed pinned at the mod-4 slot floor
(sim: ROM fetch 8.93 ticks before AND after; the boot executed
cycle-for-cycle identically, 2,944,491 vs 2,944,483 cycles). Phase B's gains
were confined to the immediate-DTACK paths (IO 5 ticks, RAM writes 6), which
are a negligible share of traffic.

**The entire win lives in Phase C** (demand-start SDRAM, which breaks the
slot quantization: reads 8→7 ticks flat, writes→6, +25.4% cycles/sec in sim)
— currently blocked on the hardware corruption bug documented in
`docs/CPU_Perf_Resume_2026-08-18.md`. Phase B remains a necessary
prerequisite, not a win in itself.

**Side benefit — the frozen-menubar-clock worry is settled for benchmarking:**
these absolute times match the baseline within 0.5%, so the 60 Hz
TickCount/Time Manager path (`tick_60hz` → VIA1 CA1) is demonstrably healthy.
Only the 1 Hz time-of-day path (`onesec` → CA2) is suspect, and it does not
feed Speedometer.

## Headline: the core runs at ~75% of a real Mac LC

| Suite                          | Core  | Physical Mac LC | Core / real LC |
|:-------------------------------|------:|----------------:|---------------:|
| Benchmark Mix (Classic = 1.0)  | 2.771 |           3.702 |         74.8% |
| Color Benchmarks (Mac II = 1.0)| 0.937 |           1.249 |         75.0% |

Both suites land within 0.2 points of each other — the deficit is uniform, not
a video-only or CPU-only artifact. For scale against the rest of the reference
set: physical Mac LC II and Mac II are 1.61x and 1.62x the core's CPU mix, and
the Performa 600 is 2.58x.

## Per-test gap to a physical Mac LC (640x480)

Core time ÷ physical time; rate tests (KWhetstones, Dhrystones) inverted so
that ">1x slower" always means the core is behind.

| Test          |   Core | Mac LC | Core is |
|:--------------|-------:|-------:|--------:|
| Sieve         | 11.017 |  4.900 | **2.25x slower** |
| Queens        |  3.467 |  2.300 |  1.51x slower |
| Bubble Sort   |  4.850 |  3.250 |  1.49x slower |
| Puzzle        |  8.600 |  6.183 |  1.39x slower |
| Permutations  |  8.367 |  6.117 |  1.37x slower |
| Quick Sort    |  3.433 |  2.550 |  1.35x slower |
| Int. Matrix   |  3.867 |  3.100 |  1.25x slower |
| Fast Fourier  | 68.583 | 59.467 |  1.15x slower |
| KWhetstones/s | 30.303 | 34.924 |  1.15x slower |
| F.P. Matrix   | 37.433 | 32.767 |  1.14x slower |
| Dhrystones/s  |2252.252|2298.850|  1.02x slower (par) |
| Towers        |  4.517 |  4.450 |  1.02x slower (par) |
| Monochrome    | 38.900 | 28.733 |  1.35x slower |
| Two Bit       | 43.000 | 31.817 |  1.35x slower |
| Four Bit      | 46.733 | 35.183 |  1.33x slower |
| Eight Bit     | 55.267 | 42.433 |  1.30x slower |

## Reading of the shape

- **The deficit is concentrated in tight-loop tests.** Sieve (2.25x), Queens
  (1.51x) and Bubble Sort (1.49x) are the three whose inner loops are small
  enough to sit entirely inside a real 68020's 256-byte on-chip instruction
  cache — which the core does not have. Sieve is the extreme case and is the
  single worst test on the sheet.
- **Call-heavy and library-heavy code is already at parity**: Dhrystones and
  Towers are 1.02x, i.e. within run-to-run noise of the real machine. Where
  the working set is too big for a real LC's I-cache to help, the core keeps up.
- **Floating point sits mid-pack at ~1.15x** (Whetstone, FFT, F.P. Matrix).
  Both machines are FPU-less, so this is the SANE software path and it tracks
  the general bus tax rather than any FP-specific defect.
- **QuickDraw is a flat ~1.30–1.35x across all four depths.** Flatness across
  bit depth points at per-access cost, not pixel volume — and it matches the
  CPU-side average almost exactly, consistent with a single shared cause
  (instruction-fetch latency) rather than two independent ones.

The 2026-07-07 fetch-cache measurement session reached the same conclusion
from the other direction: instruction fetches were 43% of wall time at ~6.15
clk_sys each, and a shadow model on the live fetch stream hit 87.7% at 256 B /
96.0% at 1 KB. See `docs/resume_icache_corruption_2026-07-07.md` on branch
`i-cache` (module `rtl/fetch_cache.sv`), which is parked on a disk-corruption
blocker.
