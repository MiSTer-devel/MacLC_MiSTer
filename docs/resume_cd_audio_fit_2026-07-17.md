# RESUME: CD Audio RTL — TIMING CLOSED; display check blocked by grab infra (2026-07-17 ~02:15)

Branch: `add-cd-audio` @ `a7fe0b1` (pushed). Supersedes
`resume_cd_audio_fit_2026-07-16.md` (that doc's decision tree is DONE).

## Headline

**STA is MET: worst slack +0.157 ns design-wide** at `a7fe0b1` (SEED 8).
Artifact staged: `scratch/MacLC_CDAUDIO_20260717_a7fe0b1s8.rbf`
(md5 `94c6063bbd97b0a2e85fce1dc21acbcc`), also pushed to
`.143:/media/fat/_Unstable/MacLC.rbf` (md5-verified).
**NOT cleared**: the mandatory display check could not be completed —
the MiSTer's frame-grab path is broken for MacLC cores tonight
(evidence below), so no screenshot of ANY MacLC RBF is obtainable.
Do not release; do not clear. Physical-display check is the next gate.

## How timing closed (the night's arc, all committed)

| Build | Change | pll_hdmi worst | Notes |
|---|---|---|---|
| seeds 5/6/7 | 20-bit + ALWAYS-aggressive (proven recipe) | −1.52/−1.27/−1.49 | TNS −66..−77; lottery stuck |
| `5e175c6` | probe trim (~2.5K ALMs debug fabric off) | — | LAB overflow exposed RAM-flip class |
| `bae8fd8` | + M10K pins on every ≥8Kbit inferred RAM | −0.969 | TNS −47.6; clk_sys +1.50/+2.20 |
| `577d3cc` | AUTOMATICALLY routability experiment | −1.081 | WORSE than ALWAYS; reverted `ef330b0` |
| `ef330b0` | back to ALWAYS + SEED 8 | −1.187 | fit DB used for path analysis |
| `0c68725` | PALETTE("false") kills pal cone | **+0.065 MET** | **but frame-dead on HW — reverted** |
| `a7fe0b1` | upstream ascal + SDC false-path on pal cone | **+0.157 MET** | current staged build |

Key findings, each its own commit message with details:

1. **Probe trim** (`5e175c6`): dbg_probes 1,919 ALMs + sld_hub 621 + ADB
   ISSP were riding in every build. Kept the 18-node deck the missions
   still use (PSDT/PSDS/PSD2/PSD3, SCSI live family, PADR/PSTA/PACT/
   PIFA/PIFD/PDRD, PVID).
2. **Migrating RAM-flip class** (`bae8fd8`, memory updated): ANY netlist
   change re-rolls Quartus 17's silent RAM inference for EVERY unpinned
   RAM, framework files included. Three successive maps dropped three
   different ≥8Kbit victims (scsi ram_c → both osd_buffers → ascal poly
   tables ×3). Plain `no_rw_check` (upstream default) does NOT protect;
   `"M10K,no_rw_check"` does. Audit = map.rpt GLOBAL totals vs last-good
   (kept in `scratch/seed6_reports/`).
3. **Path analysis** (`scratch/sta_pll_hdmi_paths.tcl`, reusable): ALL 40
   worst pll_hdmi paths = ONE cone: `o_acpt4/o_shift → shift_opack →
   pal_idx → pal1_mem → o_fb_pal_dr_x2` @148.5 MHz — ascal's 8bpp
   FRAMEBUFFER palette. MacLC has no MISTER_FB ⇒ unreachable feature.
4. **PALETTE("false") is display-fatal** (`0c68725`→`a7fe0b1`): removing
   the cone via the generic met timing but ascal produced NO frames
   (Main could not grab one; not black — none). Upstream never ships
   PALETTE=false; do NOT retry it. The SDC false-path achieves the same
   STA result with ascal bit-exact upstream.

## OPEN #1 — no core vsync reaches Main on ANY MacLC rbf (display check blocked)

Localized layer-by-layer tonight (~01:07–02:25); each step's evidence:

- MACLC grabs WORKED 15:43–15:47 Jul 16 (fork Main, prior rbf, post
  s1/s2 config repair at 15:24-25 — configs UNCHANGED since).
- Tonight NO MacLC rbf produces a screenshot file: `0c68725s8`,
  `a7fe0b1s8`, AND the control (yesterday's screenshot-proven
  `MacLC_PRAMFIX_20260716_5cef15ds4.rbf`) — **rbf-independent**.
- Fails identically on the FORK and the STOCK Main (swap test done —
  stock backup verified working as a swap; fork restored after) —
  **Main-version-independent**. Menu-core grabs work throughout.
- MiSTer.ini untouched (Jun 16), no bypass settings; screenshots dir
  writable, disk 43%; dir NOT over the max-file-count trap (6 files).
- Ran Main with stdout captured (`killall MiSTer; /media/fat/MiSTer >
  /tmp/mister_stdout.log &`): on `screenshot`, **do_screenshot never
  runs** — zero scaler-init printfs. Main's screenshot executes from a
  FRAME CALLBACK (`add_frame_callback(screenshot_cb)`, runs per core
  vsync in user_io_poll) ⇒ **the core's vsync events never reach Main**;
  the request pends forever (hence no file AND no error, distinct from
  both the black-frame class and imlib write errors).
- ascal's DDR3 header at 0x20000000 reads all-zeros under MacLC (Main's
  `mister_scaler_init` needs 01 01 magic) — consistent: no input frames,
  ascal writes nothing. (Menu-core devmem shows pixel data — menu is a
  framebuffer core, not a valid control for the header check.)
- Meanwhile the Mac CPU is RUNNING on these same boots: PACT bus-cycle
  counter advancing, PADR walking RAM/VIA-poll addresses, MiSTer_fb
  re-inits on load. CPU-side clocks healthy; video side silent.

**Prime suspect: board-state video-clock/PLL failure** (the documented
per-boot PLL-lock/power variance class — see board-not-heat memory),
striking every MacLC rbf equally while CPU clk_sys runs. clkrate.tcl
could not verify (see OPEN #2 — it errors NO PVID PROBE on this build).

**Morning sequence (10 min):**
1. **POWER-CYCLE .143** (the historical fix for this class; per
   shared-mister law no verdicts before it anyway).
2. Look at the PHYSICAL screen with `a7fe0b1s8` loaded
   (`/media/fat/_Unstable/MacLC.rbf`, load via OSD or
   `echo load_core ... > /dev/MiSTer_cmd`). Desktop visible = display
   check PASS (screenshot should also work again — verify with
   `bash scripts/grab.sh scratch/a7fe0b1s8_desktop.png`).
3. If video is still dead after a power-cycle on the CONTROL rbf too →
   board/bench issue, not the build; if dead ONLY on tonight's builds →
   reopen the fit-class investigation (seed roll first).

## OPEN #2 — JTAG probe reads mostly all-FF (secondary mystery)

`read_probes.sh` on tonight's builds: PACT (free-running counter) and
PADR (cpuAddr) read live, plausible values — **the Mac CPU is alive and
executing** (RAM then VIA-polling addresses; bus cycling normally).
Everything else reads 0xFFFFFFFF including states that are impossible by
construction (PSTA all selects high simultaneously). Survives the clean
reboot ⇒ not the HPS-sickness class. Unexplained; do NOT trust PVID/PSTA
etc. until understood. (Note: PSTA updates unconditionally every clk, so
this is not ALLOW_POWER_UP_DONT_CARE junk on a never-enabled register —
it looks like a hub/readback issue for a subset of instances.)
`clkrate.tcl` fails outright on this build ("NO PVID PROBE") though
cpu_state.tcl resolves the instance table fine — the two readers walk
the hub differently; another symptom of the same hub oddity.
cpu_state.tcl still lists removed probes (PRST) — harmless, tidy later.
If the all-FF pattern persists after the power-cycle, note that a
possible common cause with OPEN #1 exists: several probe families
sample signals coming from or near the video/clk_vid domain — but
PSTA's inputs are clk_sys-side, so treat that theory with suspicion.

## State on the bench right now (02:30)

- .143: **fork Main restored** at /media/fat/MiSTer (stock backup intact
  at MiSTer.stock_20260716), rebooted to the menu. The stock-swap test
  is DONE (both Mains fail identically — see OPEN #1); the fork is NOT
  the culprit and stays deployed for the CD/audio HW work.
- `a7fe0b1s8` (the STA-met CD-audio build) sits at
  `/media/fat/_Unstable/MacLC.rbf` ready to load after the power-cycle.
- HPS side (TOC blob + audio windows, fork f38b189) deployed and intact.
- Reboots performed tonight: API (01:07), clean `reboot` (01:15, cleared
  an HPS-sick state where even menu grabs failed), swap reboots (01:53,
  02:28). No power-cycle yet — that is the morning's first move.

## Next session, in order

1. Resolve OPEN #1 (stock-Main swap test is 5 minutes) → get ONE
   screenshot of `a7fe0b1s8` showing the Mac desktop = display check.
   (If stock Main is swapped in, CD features are gone — swap the fork
   back for the audio test itself.)
2. Display check PASS → the HW audio protocol from
   `resume_cd_audio_fit_2026-07-16.md` §"HW audio test protocol"
   (data regression, mixed-mode disc TOC/PLAY/pitch, SEARCH, position,
   stress-while-copying, boot-chime regression). Needs a human by the
   machine for the listening steps.
3. Then: release staging per house convention + update
   `cdrom-scsi3-mission` memory to CLOSED for the RTL leg.

## House-law addendum earned tonight

- Display-check taxonomy: **no-frame-grabbed is a distinct (worse)
  failure class than black-frame** — and can be INFRASTRUCTURE, so run a
  known-good control RBF before condemning a build.
- The RAM-pin sweep (`bae8fd8`) means future netlist changes should hold
  the flip class at bay for everything ≥8Kbit; keep auditing global map
  totals anyway (small RAMs can still flip; they're just survivable).
