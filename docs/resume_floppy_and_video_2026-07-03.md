# Resume — MacLC floppy read + in-game video performance (2026-07-03)

You are picking up the MacLC_MiSTer core with **SCSI boot already solid** (6.0.8/7.1/7.5.5
cold-boot to the Finder desktop; see `docs/findings_mame_floppy_groundtruth_2026-07-02.md`
sibling work and the README). Two investigations remain open. **Read this whole doc first.**

- **Branch:** `new-disk-features` @ `3a46a80` (the single work branch — `build-tooling` and the
  LC II ports are already merged/consolidated here). Nothing is pushed; the user pushes/merges.
- **Build:** `bash scripts/build_only.sh` (full compile ~21 min, prints an STA verdict + artifact;
  `--check` = ~3-4 min A&E only). RTL A&E gate before every build:
  `quartus_map.exe --analysis_and_elaboration MacLC` (~1 min, 0 err / ~64 base warn). SCSI margin
  gate (must stay green — this branch carries the SCSI fixes): `quartus_sta -t
  scripts/check_scsi_timing.tcl` (PASS ≥ +0.5 ns; currently ~+29 ns).
- **Deploy/launch:** `source scripts/local.env; python tools/misterdeploy/launch_unstable_core.py
  --host <ip> --core <rbf>`. **Always name the RBF with the git short-hash** (e.g.
  `MacLC_Unstable_20260702_3a46a80.rbf`) and keep **exactly ONE launchable MacLC RBF per box**
  (rename stale ones `*.disabled`) — see GOTCHA 1.

---

## HARDWARE — read before touching a box

- **`.143`** — has a **JTAG adapter** (USB-Blaster): the ONLY box where you can read the
  In-System probes (`bash scripts/read_probes.sh`, decoder `scripts/cpu_state.tcl`; the `PSCW`
  probe is currently a bus-reset snapshot from the SCSI work). Often running **MacLCii** for the
  user's separate LC II work — **ask before rebooting it out.**
- **`.188`** — **NO JTAG** (screenshot API + ssh only). Same ssh key (`~/.ssh/mister_only`),
  Remote HTTP `:8182`. It is the user's **color-video rig** (`MacAtrium-*-{256color,fullcolor}.hda`
  boot disks — these render as **unusable purple** because color >2bpp is unsupported; for a
  readable test surface point `config/MACLC.s0` at a 1-2bpp disk like `MacLC_7-0-1.hda` and
  **restore their s0 after**, backup convention `MACLC.s0.bak_*`). **`.188` reboot instability:**
  the menu-reboot frequently hangs (kernel pings, sshd/HTTP dead ~10 min+) — a `.188` infra quirk,
  needs a **physical power-cycle** (no remote power). Arm a poll-watcher, hand the power-cycle to
  the user; don't hammer it. See `[[second-mister-188]]`.
- **No Verilator on the Windows box** (standing user directive). WSL (Ubuntu-24.04) DOES run
  **MAME 0.264** (`/usr/games/mame`) — the floppy ground truth came from there. Whether WSL
  Verilator is permitted is unconfirmed — **ask the user** before using it (the GCR analysis wants
  it; see Investigation A).

---

## INVESTIGATION A — Floppy read (800K unreadable, 1.44MB undetected)

**Symptoms (user, current build 3a46a80):** an 800K GCR floppy → *"This disk is unreadable — do
you want to initialize it?"*; a 1.44MB MFM floppy → not detected as HD (GCR "One-/Two-Sided"
dialog). GCR = IWM mode, MFM = ISM mode; the SWIM does bit-separation in HW so the CPU sees
decoded bytes.

### Ground truth (authoritative — do not re-derive)
`docs/findings_mame_floppy_groundtruth_2026-07-02.md` — MAME 0.264 runtime capture of BOTH disks
booting real images (`6.0.7 System Tools.dsk` 800K, `OS-6.0.8 disk1` 1.44M). 12-item diff-list,
sense truth tables, the full ISM MFM protocol, and the 800K GCR read reference. Raw dumps in
`scratch/mame_floppy_0702/` (gitignored). Repro recipe in its §9 (WSL MAME + `floppy_tap.lua` +
`decode_v2.py`). **The old `verilator/mame/floppy/decode_*.py` have a false ISM-trigger — do not
reuse them.**

### Done — Build 1 (committed `3a46a80`): drive-ID / routing group
`rtl/floppy.v` + `rtl/swim.v`, A&E-clean, STA +0.241 ns, SCSI gate +29 ns:
- **F3** — sense reg 0xF (`is_2m`/DRVIN) was INVERTED (`mfm_hd`, 1=HD). MAME: **1=DD, 0=HD**. Now
  `~CSTIN & ~mfm_hd`. This is why BOTH disks were mis-routed (800K→MFM, 1.44M→GCR). THE routing fix.
- **F4/F5** — sense reg 0xD (MFMModeOn) now tracks the `$9`(set)/`$D`(clear) seek-phase strobes via
  a 4-bit `{SEL,ca2,ca1,ca0}` decode (`m_mfm` reg in floppy.v), was constant 1.
- **F11** — reverted the 06-13 `effSEL = ISM Mode[5]`; LC head-select is **V8 PA5 in every mode**
  (maclc.cpp never wires hdsel_cb). `effSEL = SEL`.
- **F9** — IWM status ACTIVE bit = OR of drive enables (was AND).

### HW result & the remaining 800K bug
**Build 1 did NOT fix 800K** — still "unreadable" on `.188`. "Unreadable" (vs. nothing) means the
drive IS accessed and sectors are read but **don't decode** → the **GCR encoder byte stream is
wrong**, a pre-existing data-path bug F3's routing fix exposed but doesn't address. (Could NOT
confirm on `.188` whether F3's routing actually took — that needs `.143` JTAG.)

**IN PROGRESS:** a background agent is diffing `rtl/floppy_track_encoder.v` against the MAME 800K
reference (§5 of the ground-truth doc: `FF×24 | D5 AA 96 | 96 9A 96 D9 D6 | DE AA`, FORMAT byte
`$22`, 6&2 checksum; raw `scratch/mame_floppy_0702/data_reads_800k.txt.gz`). Output will be
**`docs/findings_gcr_encoder_diff_2026-07-03.md`** — READ IT FIRST (it may already have the fix).
★ **Prime suspect:** the track→image-offset math ignores 800K **zoned recording** (12/11/10/9/8
sectors/track) — a fixed `track*12*512` offset reads track 0 fine but garbage past it → exactly
"unreadable" for a filesystem living past track 0.

### Remaining work
1. **Fix the GCR encoder** (per the findings doc) → retest 800K on `.188` (surface: 7.0.1 B&W;
   `System Tools.dsk` = 819,200 B is a valid raw 800K image, already on `.188`). This is the 800K
   fix.
2. **Build 2 — the ISM 1.44MB read engine** (bigger, not started): F1 (IWM→ISM switch counter on
   **offset-0xF only**, drop the drive-enable qualification — the ROM switches with drives
   disabled, and GCR write-data would false-fire the current detector), F2 (8-bit Phases reg4
   readback), F6 (ISM drive-select = `mode[7] && mode[2:1]`), F7 (**the deep one** — feed the MFM
   generator through the real 2-entry FIFO at the 16 µs byte rate; handshake b7=0 *between* fields;
   the `mfm_track_encoder` must model gap/sync framing, not free-run), F8 (ACTION rising-edge read
   reset + ModeClr → param_idx=0). **F7 realistically needs Verilator** — get the user's OK.
3. Lower priority: F10 (IWM write-handshake throttle) for eventual floppy *writes* (read-only today).

**Key files:** `rtl/floppy.v` (drive-ID sense, encoder mux, SDRAM fetch, `m_mfm`), `rtl/swim.v`
(IWM+ISM regs, switch detector ~L464, ISM read mux ~L305, handshake ~L333), `rtl/floppy_track_encoder.v`
(GCR), `rtl/mfm_track_encoder.v` (MFM), `MacLC.sv` (~L1359-1396 disk-type detect/routing;
diskMFM/diskHD). Memory: `[[mfm-1440-floppy-implemented]]`, `[[swim-ism-mfm-read-reference]]`.

---

## INVESTIGATION B — In-game video is slow (Prince of Persia benchmark)

**Symptom (user):** POP feels **slower than a real Mac LC**. CPU speed setting is NOT being changed
(and is confirmed correct — do not touch it). Possibly slow elsewhere too; POP is the benchmark.

### Survey findings (this session)
The CPU→VRAM write path is fine (posted to on-chip BRAM framebuffer, not stalled; video fetch is
BRAM-fed and steals zero SDRAM slots; the `90c7696` slot-reclaim giving the CPU 3/4 SDRAM slots is
already in this branch). **Leading hypothesis (H3): the VGA pixel clock is wrong.** `pix_en` =
`clk_sys/2` = 16.25 MHz fixed; 640×480 VGA needs 25.175 MHz, so the whole machine's **time base
runs ~0.6×** (VBL ≈ 38.7 Hz not 60; the Mac's Tick/VBL-paced timing — including game speed — is
derived from refresh). The **512×384 "12in RGB"** mode's timing is much closer to correct.
Secondary, harder: **no instruction cache in TG68K** (H2; every fetch hits the 16-bit bus — a real
68020 has a 256 B I-cache; ~30-50% of code-bound slowness, hard to retrofit); CPU clock is locked
to the video/pixel clock (can't overclock without a new PLL).

### ★ PENDING USER TEST (the decisive data point)
**Does POP run at normal speed on the "512×384 12in RGB" monitor setting** (vs VGA)? If yes → H3
(pixel clock) confirmed as the dominant cause. If it's still slow in 12" RGB too → the bottleneck is
CPU-bound (H2), a much larger effort.

### Fix plan (once H3 confirmed)
Implement a **correct per-monitor pixel clock**: a 25.175 MHz tap for 640×480 VGA (and the right
~15.7 MHz-ish for 12" RGB), muxed by the OSD monitor selection, so VBL/Tick run at true 60 Hz and
the time base is correct. Touches `rtl/pll.v` (add/adjust PLL output(s)), `rtl/maclc_v8_video.sv`
(pix_en/refresh timing, ~L86-89), `MacLC.sv` (~L357 clock wiring). **Watch:** the CPU clock is
currently derived from the same clk (`cpu_en_p = clk16_en_p = !busPhase[0]`) — decouple carefully or
the CPU speed changes with the monitor mode. Reference docs: `docs/handoff_performance_2026-06-08.md`
(H1-H4 ranked), `docs/handoff_video_bram_2026-06-07.md`, `docs/plan_ddr3_video_channel.md` (deferred
DDR3 video for color/16bpp — NOT needed for the speed fix). Note the LC II sibling has a
`video-performance` branch — check `..\MacLCII_MiSTer` for portable pixel-clock work before writing
from scratch (that's how the SCSI/video fixes came over).

---

## CRITICAL GOTCHAS

1. **★ Wrong-core / OSD off-by-one.** The launcher navigates the OSD by counting rows; a stale RBF
   sorting adjacent to the target → it launches the WRONG core, and every MacLC-family RBF reports
   `CORENAME=MACLC` so `verify()` rubber-stamps it. This wasted results twice. RULE: **one
   launchable MacLC RBF per box** (rename others `*.disabled`), **hash-suffixed names**, and the
   folder-open settle is **1.2 s** (`e0b24e3` — LC II's 0.6 s "fast" raced `.143`'s slower folder
   and ate the first key). Always confirm provenance before trusting a HW result.
2. **"The fix didn't help" ⇒ check the RBF provenance FIRST.** The big prior example: a "fix didn't
   work" RBF was built from `build-tooling` (a June-15 core with none of the fixes). Verify the
   running RBF's git hash/md5 before invalidating any change.
3. **`.188` reboot hang** → physical power-cycle (GOTCHA above / `[[second-mister-188]]`).
4. **No JTAG on `.188`; no Verilator on the Windows box** (WSL has MAME; ask re WSL Verilator).
5. **Don't push/merge** without explicit user say-so (`[[dont-auto-merge-prs]]`).
6. **`MacLC.qsf` shows as modified** (a linter/tool touches it) — leave it; not part of any fix.

## STATE AT HANDOFF
- `new-disk-features` @ `3a46a80`. Floppy Build 1 committed; GCR-encoder analysis running →
  `docs/findings_gcr_encoder_diff_2026-07-03.md`. `.188` running `MacLC_Unstable_20260702_3a46a80.rbf`
  (md5 `9f4a61ae`) on `MacLC_7-0-1.hda` (its `fullcolor` s0 is backed up as
  `MACLC.s0.bak_fullcolor_0702` — RESTORE it when done). Awaiting: the GCR fix, the POP/12"-RGB
  video test result, and Build 2. Memory: `[[scsi-fit-stabilization-mission]]`,
  `[[mfm-1440-floppy-implemented]]`, `[[second-mister-188]]`, `[[maclcii-separate-repo]]`.
