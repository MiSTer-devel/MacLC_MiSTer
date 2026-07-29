# Resume — the probes-off marginality hunt (2026-07-29)

Paste the block below as the opening message of the next session.
Everything after it is the supporting dossier.

---

## THE PROMPT (paste this)

> Resume the MacLC **probes-off marginality hunt** on branch
> `scsi-corruption-file` (repo `C:\Temp\mistercore\MacLC_MiSTer`).
>
> Read `docs/resume_probes_off_hunt_2026-07-29.md` first — it is the
> authoritative state and it supersedes the Mission-2 section of
> `docs/resume_prompt_2026-07-29.md`.
>
> Goal: make a **probes-OFF** fit of the current netlist survive the
> Finder gate, so releases can stop shipping the JTAG deck. The write
> corruption is FIXED and validated — do not re-open it.
>
> Start with the **BISECT** (§4.1): `USE_DBG_PROBES` currently gates TWO
> different things at once — the 11 `altsource_probe` instances AND the
> whole `dbg_probes` observer module that taps the CPU bus + peripheral
> selects + SCSI status. Split them into two macros and build each half.
> That tells you which one is doing the anchoring before you spend fits
> on attributes.
>
> Hard rules: gate in the **FINDER on colour icons**, never MacAtrium
> (§3); `sys/` is off-limits; `MacLC.qsf` macro flips are
> working-tree-only and must never be committed; ALWAYS check `grab.sh`'s
> returned filename timestamp; never hard-reload a RUNNING guest (clean
> Shut Down first). STA slack does NOT predict this failure — do not use
> it to pick candidates.

---

## 1. Where things stand

Branch `scsi-corruption-file`, working tree CLEAN, **nothing pushed or
merged** (user does their own PRs/merges).

```
5b12f00 docs: RETRACT the probes-off 'resolved' verdict — it still fails
e0d95cd docs: probes-off marginality RESOLVED   <-- WRONG, superseded by 5b12f00
eb88dc9 docs: correct the write-corruption verification recipe
ceaec45 scsi: make beat-role tracking immune to mid-pair mode re-latch
f38c06f scsi: fix write word-pairing lane slip (beat-role keyed storage)
0235fbb wrfb: route probe via latched last-data-phase target
7a6a902 (previous session) docs: resume prompt
```

**Mission 1 (write corruption) is DONE.** Root cause was `data_cnt[0]`
parity keying of `odd_byte_r` capture + the buffer data-source muxes in
`rtl/scsi.v`; the Mac driver's odd-length BYTE prefix lands word pairs as
(odd,even) and the lane slipped. Fixed by keying on the beat's ROLE in
the pair. Validated: in-guest File > Duplicate of a 14.5 MB fork =
**28,348 of 28,349 data blocks byte-identical** (the one differing block
is block 0, whose diff contains `20636f7079` = `" copy"`, the Finder
writing the filename into the resource-fork reserved area). Do not
re-open.

### The bench right now
- MiSTer `.143` parked at the **menu core** (guest stopped so the crashed
  Finder writes nothing further).
- `_Unstable/MacLC.rbf` = `cc57535d` (the FAILING probes-off build).
- Also in `_Unstable`: `MacLC_REL_` (35601be6), `MacLC_REL2_` (764d1703),
  `MacLC_REL3_` (3129a134) — the three older failing probes-off fits, and
  `MacLC_CDFIX_20260728.rbf`. Safe to clean once the hunt lands.
- ⚠ **`Mac68KColorGames_v1.hda` may be DIRTY** — the Finder crashed
  (error type 11) on it under `cc57535d`. Run Disk First Aid, or restore
  from `c:\temp\macatrium-build\Mac68KColorGames_v1.hda`, before trusting
  it as a fixture. Local pulls exist (§6) if forensics are needed.
- OSD master volume still ~2 notches down globally (`Volume.dat`=0x02).

---

## 2. THE FAILURE — what we are hunting

A probes-OFF fit boots, but **the Finder gets corrupt data and dies**.

Signature, in order of appearance:
1. Custom **COLOUR** icons render as multicolour noise — volume icons,
   System Folder icons, Trash, document icons. The noise blocks keep the
   icon's rough SHAPE, so it is the icon **pixel data** that is wrong,
   not the palette it is drawn with.
2. Plain 1-bit folder icons, window chrome, menu bar, menus and all text
   render **perfectly**. Item counts and sizes in the window header are
   correct.
3. On a subsequent boot: `Sorry, a system error occurred. "Finder" error
   type 11`.

That reads as **bad DATA reaching the Finder** — a read-path fault — not
a video/scanout fault. Nearest historical relative is the `#3`
STA-met-but-HW-marginal class (the CPU's VPA read of the SCSI status
register mis-observing `scsi_bsy`), see
`docs/handoff_cold_boot_reboot_2026-06-15.md`.

### Proof it is the BUILD, not the data and not the video path
Controlled A/B, **same disk image, same Finder window, minutes apart**:

| build | probes | RTL | result |
|---|---|---|---|
| `24592e25` | ON | `ceaec45` | all icons clean, Finder healthy — **twice** (08:35, 09:48) |
| `cc57535d` | OFF | `ceaec45` | icons = multicolour noise; next boot **Finder error type 11** |

- Data at rest is FINE — proved by booting the good build on the *same*
  image after the bad one showed corruption.
- The write path is FINE — offline block diff of two pulls
  (`imgdiff.py c2_copy.hda d2d.hda`) shows the 14.5 MB duplicate changed
  exactly **one contiguous 13.84 MB run + 8 tiny runs** (MDB/bitmap,
  catalog nodes, blocks 98/110/10352-10365/10392/10580/11424-11425/
  257705). No scattered collateral damage.
- Not a scanout/palette fault: **MacAtrium's colour UI renders fine on
  the very build whose Finder dies.**

### Historical failures (netlist `f896389`, i.e. PRE-write-fix)
| rbf | seed | STA | symptom |
|---|---|---|---|
| `35601be6` | 5 | +0.230 | Finder wedge, live cursor (VBL alive, main loop blocked) |
| `764d1703` | 3 | +0.245 | boots, then lands on "safe to switch off" |
| `3129a134` | 1 | +0.241 | Finder wedge again |

All three plus `cc57535d` are the **same class**: Finder-related death on
a probes-off fit. Every probe-bearing fit of every netlist has passed.

---

## 3. GATE PROTOCOL (follow exactly — the old gate gave a false pass)

**I called this mission "resolved" on 3 boots and was wrong.** Two of
those boots went into MacAtrium, which never exercises the failing path,
and the third showed the icon corruption that I misfiled as a
pre-existing display issue. Do not repeat that.

Per candidate fit:
1. **STA** — record it, but do NOT use it to accept/reject (§5).
2. **Boot** — must reach a desktop.
3. **FINDER COLOUR-ICON CHECK (the real gate).** Get into the Finder
   (MacAtrium QL menu → Exit to Finder), open a volume window containing
   custom colour icons — `MacAtrium_Sys` scrolled down shows System
   Folder 7.1 / 7.5.5 / 7.6.1, QuickTime Folder, TIM Voices — and compare
   against the known-good reference shot
   `scratch/cmp_A_probesON_0835.png`. Any multicolour speckle = FAIL.
   Also check the desktop volume icons and the Trash.
4. **Soak** — at least 2 further boot cycles landing in the FINDER (not
   MacAtrium), since the error-type-11 crash appeared on the second
   Finder boot, not the first.
5. **MacAtrium is NOT a display check.** It renders clean on a build
   whose Finder dies.

Reference shots in `scratch/`: `cmp_A_probesON_0835.png` (GOOD),
`cmp_B_probesOFF_0917.png` (BAD), `ab_finder_24592e25.png` (GOOD, full
screen), `m2_bootgate3.png` / `ab2_boot.png` (BAD, the latter with the
bomb).

---

## 4. THE HUNT

### 4.1 DO THIS FIRST — bisect what `USE_DBG_PROBES` actually removes

This is the single most valuable next step and it was NOT done. The macro
gates **two very different things** in `MacLC.sv` (`\`ifdef
USE_DBG_PROBES` at ~line 1171 → `\`endif` at ~line 1290):

**(a) 11 `altsource_probe` instances** — `CDA0 CDA1 CDA2 CDA3 CDA4 CDUR
PSDT PSDS PSD2 PSD3 WRFB`, plus the `sld_hub:auto_hub` JTAG hub they
imply (98 physical-synthesis entries, present only in probe builds).

**(b) the whole `dbg_probes probes(...)` observer module** — and this is
the sleeper. Its port list is essentially *the CPU bus plus every
peripheral select plus the SCSI status buses*:

```
cpuAddr[23:0], cpuFC, cpuAS_n, cpuRW, cpuDTACK_n, cpuVPA_n,
cpuUDS_n, cpuLDS_n, cpuIPL_n, cpu_din(dataControllerDataOut),
selectSCSI, selectSCSIDMA, selectRAM, selectROM, selectVRAM,
selectVIA, selectPseudoVIA, selectASC, selectAriel, selectIWM,
selectSCC, scsiDREQ, scsiIRQ,
scsi_dbg, scsi_dbg2, scsi_dbg4, scsi_dbg5, scsi_dbg_ncr,
scsi_dbg_ncr2, scsi_dbg_wr,
img_mounted[1:0], sd_rd[1:0], sd_wr[1:0], sd_ack[1:0],
pvia_video_config, v8_vblank
```

**Also dead-stripped with probes off:** `sdma_stall_max`,
`sdma_berr_cnt`, `sdma_snap_scsi2`, `sdma_snap_ncr`, `sdma_snap_wr`
(declared ~`MacLC.sv:790-830`, OUTSIDE the ifdef, but consumed ONLY by
the probes inside it). With probes off they have no readers, so they and
their whole capture cone vanish — taking the last loads off
`dbg_scsi2_w` / `dbg_ncr_w` / `dbg_wr_w`, which are combinational taps
out of `ncr5380.sv` / `scsi.v`.

So "probes off" is not "remove 20 debug nodes" — it removes a large
observer whose fanout pins the CPU bus and the SCSI status cone. That is
a far more plausible anchor than the ISSP instances alone.

**Bisect plan** (working-tree-only qsf edits, never commit):
1. Introduce a second macro, e.g. `USE_DBG_OBSERVER`, so `MacLC.sv` has
   `\`ifdef USE_DBG_PROBES` around (a) only and
   `\`ifdef USE_DBG_OBSERVER` around (b) only. This IS an RTL edit but it
   is pure conditional-compilation scaffolding — no behavioural change to
   either configuration. Commit it; it is genuinely useful.
2. Build **observer ON / ISSP OFF**. Gate per §3.
   - PASSES → the `dbg_probes` fanout is the anchor. Ship a slimmed
     always-on observer (§4.2) and you are done, with no JTAG hub.
   - FAILS → the ISSP instances / `sld_hub` placement carry it; go to
     §4.3 attributes.
3. Build **observer OFF / ISSP ON** as the complementary datum if step 2
   is ambiguous.

### 4.2 If the observer is the anchor — ship a slim always-on observer
Keep a small, permanently-compiled consumer of the same nets that costs a
handful of registers and no JTAG hub: register the SCSI status/CPU-bus
taps into a few `(* preserve *)` regs that feed nothing (or feed an
existing unused debug output). This converts the accidental anchoring
into a deliberate, documented one. Cheaper and more honest than shipping
the whole deck.

### 4.3 If it is not the observer — targeted attributes (original plan)
Attributes only, **no behavioural RTL** mixed in.
1. Diff the archived report pair for the SCSI cones — see §6,
   `scratch/m2/probes_{on,off}.{map,fit,sta}.rpt`. Register
   duplication/retiming entries name nets.
2. Anchor OUR side only (`sys/` is off-limits): `(* preserve *)` /
   `(* syn_keep *)` in RTL, or
   `set_instance_assignment -name PRESERVE_REGISTER ON -to <net>`.
   Shopping list, in priority order (these are what the decks observe):
   - `rtl/scsi.v` phase / `data_cnt` / `csr` state
   - `rtl/ncr5380.sv` `target_*` muxes, `dreq_r` / `din_pair_r` /
     `din_pair_next_r` / `host_bus_r` (the PDMA host-face pipeline),
     `dma_ack_busy` / `dma_settle`
   - the pseudo-DMA engine state that PSCS/PSNC/PSCW/PSDS observe
3. Rebuild probes-off, full §3 gate per fit, iterate the anchor set.

### 4.4 Orthogonal lever — the aggressive physical-synthesis settings
NOT tried yet, and cheap. `MacLC.qsf` runs a very aggressive optimisation
stack; with the probe fanout gone, these are free to re-optimise the
cone:
```
PHYSICAL_SYNTHESIS_REGISTER_RETIMING ON
PHYSICAL_SYNTHESIS_REGISTER_DUPLICATION ON
PHYSICAL_SYNTHESIS_COMBO_LOGIC ON
PHYSICAL_SYNTHESIS_COMBO_LOGIC_FOR_AREA ON
PHYSICAL_SYNTHESIS_ASYNCHRONOUS_SIGNAL_PIPELINING ON
ADV_NETLIST_OPT_SYNTH_WYSIWYG_REMAP ON
SYNTH_GATED_CLOCK_CONVERSION ON
PRE_MAPPING_RESYNTHESIS ON
MUX_RESTRUCTURE ON
ROUTER_LCELL_INSERTION_AND_LOGIC_DUPLICATION ON
ECO_OPTIMIZE_TIMING ON
OPTIMIZATION_MODE "HIGH PERFORMANCE EFFORT"
ALM_REGISTER_PACKING_EFFORT LOW
SEED 5
```
Try a probes-off fit with `PHYSICAL_SYNTHESIS_REGISTER_RETIMING OFF`
(then duplication, then gated-clock conversion) and gate per §3. If one
of these makes probes-off pass, that both fixes the release AND names the
transform responsible — a much better outcome than blind anchoring.
These are qsf assignments, not RTL, so they are in scope.

---

## 5. Measurements already taken (do not redo)

### STA — like-for-like, SAME RTL `ceaec45`
| domain | `24592e25` probes ON (**PASSES**) | `cc57535d` probes OFF (**FAILS**) |
|---|---|---|
| worst setup (`pll_hdmi`) | +0.399 | +0.317 |
| `emu\|pll` general[0] | **+1.475** | **+2.310** |
| `emu\|pll` general[1] | +2.233 | +2.406 |
| worst hold | +0.250 | +0.248 |

**The FAILING build has MORE margin in the core domains than the PASSING
one.** STA slack does not predict this failure — do not use it to accept
a candidate, and do not chase seeds for slack.
(For reference, build `4f656e01` = probes ON, RTL `f38c06f`: setup
+0.464, `emu|pll` +1.942/+2.003, hold +0.242. The table in
`docs/resume_prompt_2026-07-29.md` quotes THAT build's numbers, which is
not like-for-like — the numbers above are.)

### Netlist deltas (probes ON vs OFF, RTL `ceaec45`)
- Total registers **35,346 → 32,928** (Δ 2,418 = deck + `sld_hub`).
- Total block memory bits **3,975,530 → 3,975,530** — identical, so **no
  RAM migration** (the M10K MIGRATING-VICTIM class is NOT in play here).
- Physical-synthesis touched instances by module:
  `emu` 5,559 → 5,367; `ascal` 2,027 → 1,976; `osd:hdmi_osd` 216 → 159;
  `sld_hub:auto_hub` 98 → absent.
- Lines mentioning `scsi|ncr5380` in fit.rpt: 1,587 (on) vs 1,616 (off).
- A&S resource line, probes off: 66,933 logic cells, 2,030 RAM segments,
  3 PLLs, 51 DSP.

### What has ALREADY been ruled out
- **Not the data on disk** — good build renders clean on the same image.
- **Not the write path** — §2 block diff; plus the 14.5 MB duplicate came
  back byte-identical on `24592e25`.
- **Not RAM migration** — block memory bits identical.
- **Not fixed by the Mission-1 RTL change** — `ceaec45` changed the SCSI
  cone structurally (added `wm_beat2` / `store_low`, moved the buffer
  data-source mux off the `data_cnt[0]` parity path) and probes-off
  STILL fails. Do not expect further behavioural RTL to fix it by luck.
- **Not a scanout/palette fault** — MacAtrium colour UI is clean on the
  failing build; corrupted icons keep their shape.
- **Not a seed fluke** — 4 probes-off fits across seeds 1/3/5 and two
  different netlists have now failed; every probe build passes.
- **Anchors/attributes: NOT YET TRIED AT ALL.**
- **qsf physical-synthesis toggles: NOT YET TRIED AT ALL.**

---

## 6. Files, artefacts, tooling

### Saved RBFs (local, `scratch/`)
| file | md5 | probes | RTL | verdict |
|---|---|---|---|---|
| `MacLC_WRFIX_4f656e01s5.rbf` | `4f656e01` | ON | `f38c06f` | boots; write fix partial |
| `MacLC_WRFIX2_24592e25s5.rbf` | `24592e25` | ON | `ceaec45` | **KNOWN GOOD** — reference |
| `MacLC_RELOFF_cc57535ds5.rbf` | `cc57535d` | OFF | `ceaec45` | **FAILS** the Finder gate |

### Fitter/map report pair for the cone diff
`scratch/m2/probes_on.{map,fit,sta}.rpt` (= `24592e25`)
`scratch/m2/probes_off.{map,fit,sta}.rpt` (= `cc57535d`)

### Disk images pulled today (`scratch/tim3/`, 809 MB each)
`post_wrfix.hda` (after the installer on build #1), `c2_copy.hda` (after
the CD copy), `d2d.hda` (after the duplicate). Pristine original lives at
`c:\temp\macatrium-build\Mac68KColorGames_v1.hda` (md5 `d57c4521`).

### Forensics tools written 2026-07-29 (`scratch/tim3/`, gitignored)
- `difflist.py A B` — equal-length offset diff, run grouping, 512 B-block
  histogram + parity. The workhorse.
- `imgdiff.py A.hda B.hda [bs]` — block-level diff of two pulls of the
  same image; shows exactly which regions an operation changed.
- `align.py A B` — reference-free insertion/deletion/substitution counter
  for unequal-length files.
- `cmp3.py ref got...` — shift-hypothesis classifier at a divergence.
- `reiso.py` — re-extracts the CD data track from the raw 2352 B-sector
  BIN and diffs it against `TIM3-data.iso` (verified: 0 of 68,677 sectors
  differ, so ISO-derived references are trustworthy).
- `forkmap.py IMG NAME data|rsrc OFF...` — maps a fork offset to a raw
  image offset with NO extent stitching, for checking a suspect byte.
- `extract2.py` — whole-image HFS leaf scan; newest-cnid wins on
  duplicate names.

---

## 7. Ops crib — additions and corrections from this session

- **★ NEW: menu selection with `mouse.sh` must move VERTICALLY ONLY.**
  `walk dx dy` moves X fully, THEN Y. Starting from a menu title at y=8,
  any dx first slides along the MENU BAR and opens a different menu, so
  the release lands on the wrong menu's item. Two selections failed
  silently this way before I spotted it. Correct form:
  `slam -1 -1`, `walk <menu_x> 8`, `down`, `walk 0 <dy>`, `up`.
  Finder File menu item y-offsets from y=8: New Folder +21, Open +35,
  Close Window +63, Get Info +99, Duplicate **+131**, Make Alias +147.
  Special menu → Shut Down is `walk 0 131`.
- **Fast build swap without a full reboot:** `scp` the rbf to
  `_Unstable/MacLC.rbf.new`, `mv` it over `MacLC.rbf` (ETXTBSY blocks a
  direct overwrite), then
  `echo 'load_core /media/fat/_Unstable/MacLC.rbf' > /dev/MiSTer_cmd`.
  Much faster than `deploy_screenshot.sh` (which reboots + drives the
  OSD) and ideal for A/B work. `load_core` is NOT a shell command on the
  MiSTer — it only works through `/dev/MiSTer_cmd`.
- Releasing hda file handles for a pull: `load_core /media/fat/menu.rbf`
  via the same FIFO, then `scp`. Verify with `lsof | grep hda`.
- Guest reload law unchanged: clean **Shut Down** first (screenshot the
  "safe to switch off" screen), then `load_core`. Warm Restart is a
  known-broken grey hang.
- `grab.sh` returns the stored filename — **always check its timestamp**;
  the service dies under HPS churn and silently returns the previous
  file.
- Finder navigation: the volume window opens scrolled to the top; the
  colour-icon rows need ~4 clicks on the scrollbar down-arrow at
  `(450,258)`. Switching to list view via the View menu hits the
  vertical-walk trap above.
- Zoom for pixel-exact reads:
  `python -c "from PIL import Image; Image.open(s).crop(box).resize(...,Image.NEAREST).save(o)"`
  — PIL is available in the Windows python.

---

## 8. Other OPEN items (not this mission)

- **Deterministic CD-READ 2-byte defect.** CD-sourced copies contain
  `0x8080` where the CD holds `0x3840`, at fork offset `0x18200` = CD
  data-track sector **49,385 + 512 bytes** (a 512 B sub-boundary inside a
  2048 B sector). Identical across two runs and two builds, and
  faithfully preserved by a disk-to-disk copy ⇒ it enters on the READ
  side, not the write path. `0x8080` is unsigned-8-bit-audio silence
  replacing a smooth waveform ramp — reads as unfilled buffer content.
  The sector is clean Mode-1 (`00 ff*10 00`, header `11 00 35 01`) with
  no false sync in its user data. 1 occurrence in 7,088 CD sectors, so
  not a periodic serving-boundary bug. Full detail in
  `docs/resume_prompt_2026-07-29.md`.
- **Verification-methodology correction** (commit `eb88dc9`): the old
  "+78 bytes vs `machine_data_ref.dat`" pass criterion was unsound —
  that file is the CD SOURCE, the installer legitimately writes a
  transformed longer file, and the two reference files disagree at byte
  41,473. Use length-preserving tests (in-guest File > Duplicate) against
  ISO-derived references.
- Colour-icon corruption is the probes-off **failure signature**, NOT a
  pre-existing display bug — my initial "pre-existing" reading was wrong
  and the user corrected it.
