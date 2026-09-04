# Handoff: I-Cache 32-bit / 256-color Finder crash — the fix (for the Pocket port)

**Do not edit the Pocket tree from the MiSTer repo.** This is a self-contained
description of the bug, the exact one-line fix that worked on MiSTer hardware,
the mechanism, the repro, and the gates — enough to apply and verify the
equivalent change on the Pocket.

## Symptom

MacLC I-cache release crashes the Finder (Illegal Instruction / Bus Error, wild
jumps into `$079xxxx`, heap-intact control-flow smash) — on BOTH MiSTer
(`MacLC_20260819.rbf` = 65332d3b) and the Analogue Pocket port. Because it
appears on two independent boards/fitters, it is a **functional defect in the
shared RTL**, not per-fit placement noise. Prince of Persia 2 fails to launch
(6.0.8 and 7.1) is the same defect.

## The crashing configuration (how to reproduce)

The crash only expresses with the video at **8 bits/pixel (256 colors)** AND
**32-bit addressing ON**. In 1-bit (black&white) it does NOT express — this is
why it was so hard to reproduce (a PRAM reset to 1-bit silently hid it).

1. Guest (System 7.5.5): Monitors control panel → **256 colors**; Memory
   control panel → **32-bit addressing ON**.
2. **Special ▸ Shut Down** (this is what writes 8bpp+32bit to PRAM/NVRAM;
   in-core Restart is separately broken on this core, do not rely on it).
3. Reboot into the core (MiSTer: OSD ▸ Reset & Apply, on a build whose OSD
   does not wipe NVRAM).
4. Open a few Finder windows / normal window traffic.
   → the release bombs; the fixed build stays clean.

NVRAM note: color depth + 32-bit persist ONLY through a clean Shut Down. A
core reload / FPGA reconfig alone cold-boots and, if PRAM was never written,
comes up 1-bit (non-crashing) — that will look like "can't reproduce."

## THE FIX (one line)

In `fetch_cache` instantiation, change the cache-enable from a hardwired
constant to a **non-constant net that still evaluates to 1**:

```verilog
// release (crashes):
.enable ( 1'b1 ),

// fix (stable):
.enable ( ~status[11] ),   // status[11] defaults 0 -> enable = 1
```

That is the ONLY functional difference between the crashing release
(65332d3b) and the stable build. The enable VALUE is unchanged (1 in both);
the DTACK hit-answer path is `icache_hit` direct in both. Verified by exact
diff of `MacLC.sv` at release commit `454429e` vs the fix.

### Pocket equivalent

Feed the Pocket's `fetch_cache .enable` a **non-constant '1'** — e.g. an APF /
interact config bit that defaults to enabled, mirroring `~status[11]`. Do NOT
hardwire `1'b1`. If there is no convenient config bit, the intent is "keep the
internal `enable_r` register real (un-folded)": either drive `.enable` from any
real (non-constant) always-1 input, or add a synthesis-preserve attribute to
`enable_r` inside `fetch_cache.sv`.

## Why it works (mechanism — read this before assuming it's placement luck)

Inside `fetch_cache.sv`, `enable` is registered (`enable_r <= enable`) and
`enable_r` is in the fanin of both:
- `hit <= enable_r` (the registered hit output → `_cpuDTACK` hit answer + the
  CPU din mux), and
- `hit_now_comb = enable_r && …` (→ `sdram_oe` request suppression).

With `.enable(1'b1)`, the fitter constant-folds `enable_r` and the `enable_r &&`
terms, collapsing the hit / hit_now cones into a structure whose fast hit
answer races a downstream consumer (the crash). With `.enable(<non-constant
1>)`, `enable_r` stays a real register in those cones; the hit-answer and
request-suppression paths synthesize into a structure that does not race.
Functionally identical (enable = 1 either way) — the fix is **structural**
(it changes how the hit/DTACK/suppression logic is built, not what it computes).

**Honest caveat:** because the fix is structural rather than a root-cause logic
change, its robustness on a *different* fitter/placement is not guaranteed by
the value change alone. VERIFY on the Pocket with the repro above. On MiSTer,
a second-seed build is recommended to confirm it is functional and not a
placement coincidence (in progress).

## Provenance (MiSTer)

- Crashing release: `MacLC_20260819.rbf` = md5 `65332d3b`, commit `454429e`
  (`.enable(1'b1)`).
- Stable delay-select build (has the fix + extra debug delta): `MacLC_dlysel.rbf`
  = md5 `c3c9ca50`, commit `eef20ac` — user-confirmed stable in the crashing
  config on hardware.
- Isolated fix build (release + ONLY `.enable(~status[11])`): `MacLC_varA.rbf`
  = md5 `8896c2b2`, commit `ad53af0`, seed 4, STA met (worst slack +0.627) —
  user-confirmed working in the crashing config on hardware.

## Gates (offline, run before trusting any variant)

From `verilator/` (Verilator 5.x):
- `tb_icache_transient` — truth invariant (every CPU-consumed word == memory).
  PASS = 747 checks, 0 errors.
- `tb_icache_seam` — done-birth discipline; run normal (PASS) AND negative
  control `+define+SDRAM_NO_DONE_LEVEL_FIX` (must FAIL).
- `tb_fetch_cache` — hit data currency; run normal (PASS) AND
  `+define+FETCH_CACHE_HOSTILE_RDW +define+FETCH_CACHE_NO_RDW_FIX` (must FAIL).

Hardware gate: the 8bpp+32bit repro above (crashes release, survives fix), plus
per-fit video/boot/icon gates and Speedometer ≈ 3.59 Benchmark Mix (~97% — the
fix keeps the immediate hit answer, so no perf regression).
