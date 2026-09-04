# RESUME — floppy FIXED and validated; I-cache still broken (open)

Paste this as the opening prompt of a session in this repo
(`C:\Temp\mistercore\MacLC_MiSTer`). Branch: **`cpu-icache`**.
Read **`docs/CPU_Perf_Log.md`** for mechanisms (the top entry is the whole
floppy story); the scoreboard is `docs/Speedometer_3-23_Benchmarks.md`.
Predecessor: `docs/CPU_Perf_Resume_2026-08-19.md`.

---

## Where things stand

**Performance work shipped**: Phase B (collapsed bus FSM) + Phase C
(demand-start SDRAM) took the core 75% → 83% of a real Mac LC — Benchmark Mix
2.771 → 3.067, released as `releases/MacLC_20260817.rbf`.

**★★★ The floppy regression is FIXED and HARDWARE-VALIDATED (2026-08-19).**
Final build **md5 `a920b071aa6c6430474bfe7335bbf271`, STA met +0.243 ns**,
currently on the bench. Mount *and* read both work:
- `Fetch GCR800K.dsk` mounts and the Finder opens its window listing
  `Fetch 2.1.2 / 482K / application` — identical to what pre-mission
  `releases/MacLC_20260815.rbf` shows. That listing is an HFS catalog B-tree
  **read off the disk**, so reads genuinely work, not just the mount.
- `OS608-1440k.dsk` (1.44 MB MFM) no longer raises the "unreadable" dialog it
  reliably produced before.
- Boots clean to the Finder; the guest stays healthy through mounts.

**★★ The I-cache is STILL BROKEN on hardware (user-confirmed 2026-08-19).**
See Priority 1.

---

## What the floppy bug actually was (do not re-derive this)

It was **never the floppy datapath**. The image *download* shared the CPU's
SDRAM request nets, and its posted-write ack landed in `cpu_done` — which *is*
`_cpuDTACK`. The guest completed reads it never issued and executed the
previous access's data. Both 2026-08-18 fixes missed because both aimed at the
read path.

**The unifying law — this is the durable finding:** Phase C's demand-start
silently removed the slot alignment that made every CPU-vs-non-CPU mux safe
*by construction*. Every such shared mux became a bug. There were three, each
with a different symptom, and each only became visible after the previous one
was fixed:

| # | Shared resource | Symptom | Fix |
|---|---|---|---|
| 1 | request nets (`oe/we/addr/din/ds`) + `cpu_done` | mount **bombs** the guest | dedicated `dl_*` download port in `sdram.v` |
| 2 | `memoryAddr` + both data strobes | mount **freezes** guest, sprayed framebuffer | gate `dskReadAck*`/`flp_guard` on `!dio_download` **inside** addrController |
| 3 | `sdram_do` → `dataController.memoryDataIn` → `cpuDataOut` | **boot hangs** once windows fire every rotation | floppy byte gets its own `dskReadDataIn` wire |

Plus one **functional** defect: Phase C's `flp_pend_*` window gate delivered
**one** ack per address change, but `floppy.v`'s MFM loop sets `mfm_ack_skip`
on every delivered byte and therefore needs **two acks per byte** (one absorbed
by the skip, one to set `mfm_fresh`). With one ack it stalls at its own
`// else: payload byte not fetched yet` branch. GCR leans on repeated acks the
same way. Gate reverted.

**Perf debt from that revert: found, paid, measured.** Ungated windows cost the
CPU ~25% of its demand-start opportunities (`flp_guard` covers busCycle 01+10),
and the GCR encoder **free-runs with no disk**, so every SCSI-only boot and
every benchmark run was paying it. `addrController` gained an `flp_present`
input (`dsk_int_ins | dsk_ext_ins`) folded into `flp_ok`. Measured in the sim
harness, 100 frames with a mid-run mount: **4,370,487 → 5,130,293 instructions
(+17.4%)**, both `check_boot` PASS. Keyed on *disk present* rather than *motor
spinning* on purpose — behaviour with a floppy mounted stays byte-for-byte
identical to the validated configuration.

---

## ★ PRIORITY 1 — the I-cache

**Status: ported, sim-clean, STA-clean, and STILL HANGS ON HARDWARE.**

The July blocker was diagnosed as an M10K read-during-write hazard and fixed
with `rdw_collide` (`fb11cd1`), **proven by fault injection** in
`verilator/tb_fetch_cache.v` (`+define+FETCH_CACHE_HOSTILE_RDW` fails without
the guard, passes with it). That fix is real but was **not sufficient** — do
not re-litigate RDW as "the" cause. It was *a* cause.

Known-good facts to build on:
- The port needs `tg68k.addr_early` (the kernel's combinational address).
  Phase B registers `addr` and asserts AS on the same edge, so feeding the
  registered address makes the correspondence guard reject every fetch —
  **100% miss, silently**. Do not "simplify" that back.
- Measured in sim: **99.96% hit**, fetch cycle **8 → 6 ticks flat**.
- STA on the cache's own paths: +3.3 ns in, +20 ns out, +0.424 ns hold.

### ★ How to test it — do NOT drive the OSD blind

This cost a hardware cycle and produced an unusable result:
- The **in-core OSD is not captured in screenshots**.
- **`/media/fat/config/MacLC.cfg` is NOT written on option changes** — it is a
  stale 16-byte file from 08-08. There is no readback oracle.
- Row **11 is `Memory 2MB/10MB`** and row **12 is `CPU I-Cache`**. A one-row
  miscount drops a running guest from 10 MB to 2 MB and freezes it **in a way
  indistinguishable from an I-cache hang.**
- `Aspect ratio` and `Scale` are useless as calibration targets — they affect
  the output scaler, not the 640×480 framebuffer the screenshot captures.

**Instead: build a test fit with `.enable(1'b1)` hardwired** at `MacLC.sv:1206`
(replacing `.enable(status[11])`). Then booting *is* the test, with no menu
navigation to get wrong. **Revert to `status[11]` before any release fit.**

Current OSD row map, derived from `CONF_STR` (separators are skipped — proven
by `osd`+`confirm` with zero downs landing on Mount Pri Floppy):
`0` Pri Floppy, `1` Sec Floppy, `2` SCSI-0, `3` SCSI-1, `4` PRAM, `5` CD-ROM,
`6` CD-ROM Drive, `7` Ethernet, `8` Aspect, `9` Scale, `10` Monitor,
`11` Memory, `12` CPU I-Cache, `13` MT32-pi page.

### Where to look next

The three defects above were all *shared muxes between the CPU and a non-CPU
agent*. The fetch cache is a fourth agent on the same bus, added after Phase C
removed the slot alignment — so **apply the same law to it**: enumerate every
net the cache reads or drives that the CPU also uses, and ask whether the old
slot alignment was what made it safe. In particular check what the cache
snoops (fill/invalidate writes) against `cpu_done`, `sdram_do`/`cpu_dout`, and
the now-separate `dskReadDataIn` path.

Watch **Sieve (53.7%), Queens (72.3%), Bubble Sort (74.4%)** — the tight-loop
tests a 1 KB I-cache should move most.

---

## ★ PRIORITY 2 — validation debt on the shipped floppy fix

The floppy fix is validated *functionally* but not yet cleared for release:
1. **Re-run Speedometer on hardware.** My changes touch CPU bandwidth in both
   directions (the pending-gate revert costs it, `flp_present` gives it back).
   The 3.067 Benchmark Mix number is no longer known to hold.
2. **Finder colour-icon gate** (`scripts/icon_gate.py` on `grab_fresh.sh`
   frames) — note the gate is flagged STALE in memory; check by eye at 3× zoom.
3. **≥2-boot Finder soak** (per-fit marginality is permanent lore).
4. **Release stamp**: copy to `releases/MacLC_YYYYMMDD.rbf` + the hash-named
   build, per `CLAUDE.md`.

---

## Bench state (as left)

- On the box: `a920b071aa6c6430474bfe7335bbf271` (the validated floppy build).
  **The guest is currently FROZEN** from the ambiguous I-cache/Memory toggle —
  just reload the core.
- **Live guest disks are `MacLC_6-0-8.hda` + `MacPPP-2.0.1.hda`** — *not* the
  7.5.5 image the old `PRE-ICACHE` backup was taken from.
- Fresh md5-verified backups made 2026-08-19:
  `MacLC_6-0-8.PRE-ICACHE-20260819.hda`, `MacPPP-2.0.1.PRE-ICACHE-20260819.hda`.
- 267 GB free on `/media/fat` — backups are cheap, take them.

---

## Tooling added this session (use it)

- **`verilator/sim.v` can mount a floppy mid-run**: `--floppy0 <img>
  --mount-floppy0-at <frame>`. Every download used to be queued at startup with
  the CPU in reset, which made the sim *structurally blind* to this entire bug
  class. `check_boot.sh` PASSes on that path now.
- **`verilator/tb_dl_cpu_seam.v`** — fault-injected regression gate for the
  download-vs-CPU seam. Passes against the fix; fails 3/10 reads with stale
  data against the pre-fix wiring. Run it after any `sdram.v` request-path edit.

---

## Standing laws + hard-won lore

- `sys/` is OFF-LIMITS. Both tops stay in sync (`MacLC.sv` ⇄ `verilator/sim.v`).
- Per-seed HW gate is law; STA-met is not enough.
- **NEVER re-add a multicycle on the SDRAM request paths** (one hid a −6.710 ns
  violation and corrupted RAM — `CPU_Perf_Log.md` entry 4).
- ★ **The unit TBs do not cross module boundaries.** All four floppy TBs
  instantiate the encoder/SWIM directly and never touch `addrController` or
  `sdram.v` — every bug this session lived in exactly that seam and every TB
  passed anyway.
- ★ **Offline-clean does not imply hardware-clean**, but the converse trap is
  just as real: *this session's two reasoning-only changes both introduced
  regressions*, while cheap measurements each eliminated a whole class of cause
  in minutes — the 10-minute A/B against the pre-mission release (which nobody
  had ever run), the fault-injected TB, and a free "does MFM fail too?" mount.
  **Measure before you theorise.**

### Bench discipline

- ★ **NEVER use `grab_fresh.sh` bursts as a sleep.** Use `sleep N`. Screenshot
  polling churns the HPS, and this repo's own lore says that churn fakes
  failures on known-good builds — it may have poisoned the very liveness check
  it was padding. (User called this out directly on 08-19.)
- Guest liveness oracle: move the cursor and diff two screenshots.
- The menubar clock is FROZEN on every build (1 Hz `onesec` → VIA CA2); the
  60 Hz TickCount path Speedometer uses is healthy, so benchmarks are valid.

### Toolchain gotchas

- **Verify RBF freshness by CONTENT, not `ls`/`md5sum` polling** — drvfs
  caching returned the *previous* build's hash for ~20 minutes after the
  artifact was written.
- A phantom `quartus_fit.exe` from 2026-08-17 is still in `tasklist` and makes
  `build_only.sh` wait forever — always pass `--no-wait`.
- A comment line beginning `// verilator/...` is parsed by Verilator as a
  metacomment and **fails the build** ("Unknown verilator comment").
- **`sim_ram.v` holds `reset` HIGH for the whole ROM download** (its
  write-commit path says so) — never clear a download ack in its reset branch.
  `rtl/sdram.v` is immune; its `reset` is the SDRAM init ladder.
- **`sim/sim_bus.cpp` holds `ioctl_wr` HIGH as a LEVEL** while `ioctl_wait` is
  set — not the one-cycle pulse `hps_io` gives. So (a) an `else if (ack)` clear
  is unreachable → deadlock, and (b) clearing on the ack *level* leaves
  `ioctl_wait` at 0 for two clocks, and SimBus presents a new word on every
  clock it sees 0 → every other word skipped, ROM lands half empty, CPU fetches
  `$FFFF` garbage from frame 9. **Clear on the ack's RISING EDGE.**
- Making the sim's download slot-gated (to match `MacLC.sv`) makes its ROM
  download ~16× slower — ~8 sim-frames instead of ~0.5. Not a hang; budget it.

---

## Parked / not to revisit

- **Phase D** (VRAM reads from BRAM port A), branch `cpu-phase-d`: Sad Macs on
  hardware; RAM conversion proven innocent by bisect. Worth ~3% — leave parked.
- More framebuffer BRAM, the DDR3 video channel, porting the MacIIvi 68030
  cache: all ruled out with reasons in `CPU_Improvements_Prompt.md`.
