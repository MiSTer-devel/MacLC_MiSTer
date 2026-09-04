# RESUME — floppy reads BROKEN (open), I-cache ready to test

Paste this as the opening prompt of a session in this repo
(`C:\Temp\mistercore\MacLC_MiSTer`). Branch: **`cpu-icache`** (it carries
everything — Phase B+C, the floppy fixes, and the I-cache).
Read **`docs/CPU_Perf_Log.md`** for full mechanisms; the scoreboard is
`docs/Speedometer_3-23_Benchmarks.md`. Predecessor: `CPU_Perf_Resume_2026-08-18.md`.

## Where things stand

**Performance work SUCCEEDED and is released.** Phase B (collapsed bus FSM) +
Phase C (demand-start SDRAM) took the core from 75% → **83% of a real Mac LC**:
Benchmark Mix 2.771 → **3.067** (+10.7%), Colour 0.937 → **1.030** (+9.9%),
every test improved. Shipped as `releases/MacLC_20260817.rbf`.

**★★★ OPEN AND BLOCKING: floppy reads are broken.** Mounting a floppy gives
"illegal instruction" / "coprocessor not installed" bombs — the executed-garbage
signature. Confirmed across MULTIPLE images (6.0.7 System Tools among them), so
it is systematic, not a bad image. Two fixes were applied and **NEITHER
resolved it** (see "what was already tried" below).

**I-cache is ported, fixed, and awaiting a hardware trial** (details at the end).

**On the bench right now:** md5 `8e267104e2974692759edb3b10e22534`, STA clean
(+0.576 setup / +0.244 hold), I-cache present but OSD-**Disabled**.
Disk backup: `/media/fat/games/MACLC/MacLC_7-5-5.PRE-ICACHE-BACKUP.hda`.

---

## ★ PRIORITY 1 — the floppy bug. STOP REASONING, START MEASURING.

Two fixes were derived from code analysis and shipped without a reproduction;
both failed to fix it. Do not add a third guess. The sequence below buys facts.

### Step 1 (DO THIS FIRST — it may invalidate everything): is it a regression?

**Nobody has ever verified that floppies work on a PRE-mission build.** Deploy
`releases/MacLC_20260815.rbf` (the tip before this mission started) and mount
the same 6.0.7 image.

- **Fails there too ⇒ NOT a Phase C regression.** The floppy path may have been
  broken earlier (by the PDS-ethernet work, or a host-side/image issue), and the
  whole Phase C investigation below is misdirected. Bisect further back instead.
- **Works there ⇒ genuine regression.** Then bisect: `2791e6a` (Phase B only)
  → `f13d936` (Phase C) to find which change broke it.

This single test is worth more than any further code reading, and it is ~10
minutes with `launch_unstable_core.py --push`.

### Step 2: use the HARDWARE instrument that already exists

`USE_DBG_HUD` (commented out in `MacLC.qsf`) + `scripts/parse_hud.py` was built
for exactly this class of problem. **HUD row 7/8 = the floppy/media witness**
(`floppy.v` `dbg_media`, `dbg_flp_byte_cnt`, `dbg_flp_miss_cnt`,
`dbg_ism_flpe`). Turn it on and read out, during a failing mount:
- is `byte_cnt` advancing at all? (frozen ⇒ **no read was attempted** — a
  different bug class from "reads return bad data", per CLAUDE.md)
- is `miss_cnt` climbing? (⇒ the encoder is starving on fetches)
- `insertDisk` / `CSTIN` state (⇒ the media-change protocol, not the datapath)
★ Remember to switch `USE_DBG_HUD` back OFF before any release fit.

### Step 3: make the SIM able to mount a floppy

This is the durable fix for the whole test gap (task #7) and also unblocks the
I-cache corruption hunt. `verilator/sim.v` already has the ioctl/blkdevice
ports; `sim_main.cpp` handles ROM download. Extend it to feed a `.dsk` through
the same `ioctl_index`-tagged path the FPGA top uses, then the existing
`bus_hist`/trace tooling can watch a real disk read offline.

### What was ALREADY tried (do not repeat)

| fix | commit | rationale | outcome |
|---|---|---|---|
| Invalidate the floppy window's served-address cache on `dio_download` | `3f4a8a7` | The gate skips a fetch whose address repeats, but mounting rewrites SDRAM at those addresses | **did not fix** (real hole regardless; keep) |
| Floppy accesses bypass the clk_sys request pipeline (`flp_addr`) | `cf9a98b` | `floppy.v` latches at busPhase 3; the pipeline pushed data capture to busPhase 0 of the NEXT slot | **did not fix** — so this timing model is WRONG or incomplete. Re-derive against a scope/HUD, or revert it. |

★ Because fix 2 was justified by a timing argument that the hardware then
contradicted, treat the whole "when does floppy data actually arrive" model as
UNVERIFIED. Measure it; do not re-reason it.

### Other Phase C floppy-adjacent changes worth auditing

- `addrController_top.v`: floppy windows are **pending-gated** (`flp_pend_*`) —
  a window only fires when the encoder's address changed. If the encoder ever
  needs the SAME address served twice, it starves. **Try simply disabling the
  gate** (fire every rotation, as the pre-Phase-C design did) as a one-line
  experiment; under demand-start the CPU no longer needs that slot anyway.
- `flp_guard` blocks CPU starts around windows — check it cannot deadlock.
- `_memoryUDS/_memoryLDS` now force both bytes only during `flp_win_any`
  (previously during any non-CPU slot).
- Refresh is explicit now and has a keep-out inside the guard zone.

---

## ★ PRIORITY 2 — the I-cache: ready for a hardware trial

Ported onto this tree and **the 6-week-old blocker is root-caused and fixed**.

- ★ Port needed `tg68k.addr_early` (the kernel's combinational address): Phase B
  registers `addr` and asserts AS on the SAME edge, so fed the registered
  address the module's correspondence guard rejects every fetch — **100% miss,
  silently**. Do not "simplify" that back.
- Measured in sim: **99.96% hit**, fetch cycle **8 → 6 ticks flat**.
- The July hang was an **M10K read-during-write hazard**: the continuous lookup
  reads tag/data every clock while snoop and fill write them, so silicon can
  return a NEW tag beside STALE data = a hit carrying the wrong instruction
  word. The module's old audit ("fill garbage never consumed, next AS-fall ≥2
  clk") relied on the pre-Phase-B 8-tick cycle; Phase B+C's 6-tick cycle
  consumed that margin.
- **Fix**: `rdw_collide` forces a miss when the entry read this cycle was also
  written this cycle. **Proven by fault injection** in `verilator/tb_fetch_cache.v`:
  `+define+FETCH_CACHE_HOSTILE_RDW` (write-first tag beside read-first data)
  FAILS with `+define+FETCH_CACHE_NO_RDW_FIX` and PASSES with the guard in;
  hit counts unchanged.
- STA on the cache's own paths: +3.3 ns in, +20 ns out, +0.424 ns hold.

**Untested on hardware since the fix.** To try: OSD → `CPU I-Cache → Enabled`
(no reboot — it fills and snoops while disabled, so it is warm and coherent the
instant it is flipped; flipping back is instant too). Back up the disk image
first. Watch **Sieve (53.7%), Queens (72.3%), Bubble Sort (74.4%)** — the
tight-loop tests a 1 KB I-cache should move most.

---

## Standing laws + hard-won lore

- `sys/` is OFF-LIMITS. Both tops stay in sync (`MacLC.sv` ⇄ `verilator/sim.v`).
- Per-seed HW gate is law; STA-met is not enough. **But** if a marginal path
  recurs across seeds, fix it STRUCTURALLY — that is how `served_addr` was
  finally deleted (`93d5ea5`) after two reseeds chased it.
- **NEVER re-add a multicycle on the SDRAM request paths.** One hid a −6.710 ns
  violation and corrupted RAM (`docs/CPU_Perf_Log.md` entry 4).
- ★ **Offline-clean does NOT imply hardware-clean.** Three times this session a
  change passed sim + STA + TBs and failed on silicon (Phase C address timing,
  Phase D Sad Mac, the I-cache hang). Verilator models settling time, RAM port
  semantics and read-during-write ideally. The tools that actually caught things
  were **STA probes on the post-fit netlist** (`scratch/sta_*.tcl`) and
  **deliberate fault injection**.
- ★ **The unit TBs do not cross module boundaries.** All four floppy TBs
  instantiate the encoder/SWIM directly and never touch `addrController` or
  `sdram.v` — every Phase C bug lived in that seam and every TB passed anyway.
- Quartus 17 threw a mid-fit Access Violation once and left a phantom
  `quartus_fit.exe` in `tasklist` that makes `build_only.sh` wait forever — use
  `--no-wait` for the rest of a session after any crash.
- Verify artifact freshness by CONTENT, not `ls` — a stale `bus_hist.log` cost a
  wrong conclusion mid-session.
- Never `pkill -f` with a substring matching your own command chain.
- Guest liveness oracle: move the cursor and diff two screenshots. The menubar
  clock is FROZEN on every build (1 Hz `onesec` → VIA CA2 path; the 60 Hz
  TickCount path Speedometer uses is proven healthy, so benchmarks are valid).

## Parked / not to revisit

- **Phase D** (VRAM reads from BRAM port A), branch `cpu-phase-d`: Sad Macs on
  hardware; RAM conversion proven innocent by bisect, fault is in serving the
  reads; never exercised at 8bpp in sim. Worth only ~3% — leave parked.
- More framebuffer BRAM, the DDR3 video channel, porting the MacIIvi 68030
  cache: all ruled out with reasons in `CPU_Improvements_Prompt.md`.
