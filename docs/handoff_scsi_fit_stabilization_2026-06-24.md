# Handoff / Prompt — Lock in the SCSI read path for a RELEASE-stable MacLC core (2026-06-24)

You are picking up the MacLC_MiSTer core after a long debugging marathon. **Read this whole doc
first — it is self-contained.** Your mission is narrow and high-value; do not get pulled into the
BlueSCSI toolbox feature work (that is parked).

---

## ▶ MISSION

The Mac LC core has **never had a reliable happy-path boot.** The root symptom is that the
**SCSI status-read path is fit-sensitive** — whether the guest Mac can read its boot hard disk
depends on where Quartus happens to place logic that build. Every recompile is a dice roll.

**Goal (in priority order):**
1. **RULE IN / RULE OUT SCSI** as *the* instability cause — prove it with the JTAG probes, not by
   guessing. (If the instability is actually elsewhere — SDRAM/RAM, video PLL — pivot and say so.)
2. If SCSI is confirmed: **make the SCSI read fit-INDEPENDENT** so it closes timing with large
   margin in *every* build and never regresses again — the release-grade fix (4 layers, below).
3. Deliver a build that boots to the Finder desktop reliably across **many cold AND warm boots**,
   and a build process that **fails fast** if the SCSI margin ever erodes.

**Success criteria:** ≥ ~20 consecutive clean boots (mixed cold/warm) from the SCSI HD; SCSI-read
timing margin large and fit-independent (shows up the same across ≥2 different SEEDs); a build-time
timing gate that would reject a marginal SCSI fit before it ships.

---

## ROOT CAUSE (what we proved this session)

The CPU reads `scsi_bsy` (CSR bit 6) through a **long unregistered combinational chain**:

```
scsi_bsy → CSR mux (rtl/ncr5380.sv) → ncr5380 dout → peripheral read-mux (rtl/dataController_top.sv)
        → cpu_data_in → TG68 samples it (gated by DTACK/VPA)
```

Two compounding problems:
1. **Long combinational path** → its delay depends entirely on placement → different every fit.
2. **STA mis-models it** ("passes timing analysis, fails on hardware"): the read is a VPA/6800-style
   E-paced cycle, but the path into the CPU is NOT constrained to reflect that, so the reported
   slack is fiction. This is why "just close global timing" never fixed it.

**Already ruled out (do not redo):** registering the CSR/BSR *storage* does NOT help — the long part
is the **mux chain AFTER the CSR**, not the CSR register. (See memory `cold-boot-reboot-welcome-handoff`,
`scsi-port-state-and-byte-slip`.)

**Observed failure faces of the same instability (one RBF, build `e92fe874`):**
- Cold boot → **"? disk"** (ROM healthy, HD mounted, but can't *read* it).
- Warm reboot → **Sad Mac `0000000F` / `00007FFF`** (class `0F` = an unexpected 68K **exception**
  during startup, not a RAM/ROM POST failure).
- Historically also: cold-boot reboot loops, DMA stalls, byte-slip corruption.

---

## THE RELEASE-GRADE FIX — 4 layers, root first

**Layer 1 — Register the read-data bus (the structural fix that kills fit-sensitivity).**
Insert a pipeline register on **`cpu_data_in`** (the peripheral read-mux output that feeds the CPU)
and **delay `DTACK` by one `clk_sys`** so the CPU samples the *registered* value. The CPU runs at
`clk_sys/2` (see `MacLC.sdc` TG68 multicycle), so the budget exists: this splits one 2-cycle
combinational path STA can't model into **two 1-cycle reg→reg hops it models exactly** and that
close with margin in any fit. Optionally rebalance/shorten the read-mux so each hop is shallow.
Register the **read-data / mux output**, NOT the CSR (that was tried).

**Layer 2 — Constrain it truthfully (`MacLC.sdc`).**
Add an explicit `set_multicycle_path` for the VPA peripheral-read endpoints reflecting the real
E-paced budget, so reported slack becomes meaningful (today the SDC has ONLY the TG68
kernel-internal 2-cycle multicycle — nothing on the peripheral read).

**Layer 3 — Lock the placement (Quartus design partition / incremental compile).**
Put the NCR5380/SCSI subsystem in a preserved partition so, once it closes, its placement-and-routing
is frozen across rebuilds — future feature work (e.g. the toolbox, which knocked it last time) then
physically cannot re-place the SCSI logic.

**Layer 4 — Gate it in the build.**
Post-compile `report_timing` on the SCSI-read endpoints; **fail the build if margin < threshold**
(e.g. +0.5 ns). With Layer 1 the path has huge margin so this always passes — and the day something
erodes it, the build stops instead of shipping a dice-roll.

---

## EXECUTION PLAN (do these in order)

**Step 0 — Baseline a BOOTING core (so you have a reference).**
- `git rev-parse --abbrev-ref HEAD` MUST be **`new-disk-features`** (68020 TG68K + toolbox). If not,
  `git checkout new-disk-features`. NEVER build MacLC from `kernel-sync-030mmu2` (that is the 68030
  MacLC II lineage — it grey-screens as a MacLC; see BRANCH TRAP gotcha).
- The current `e92fe874` fit is unstable. Do a **SEED re-fit** (set `SEED 2` in `MacLC.qsf`, build)
  to get *a* booting fit as your working reference. Earlier fits booted 7.1, so a good fit exists.
- Confirm it boots past grey (it will — 68020) and ideally reaches the desktop on some boots.

**Step 1 — MEASURE the SCSI read margin (quantify the target).**
- `report_timing` from the CSR/`scsi_bsy` source to the TG68 data sample, setup, a few paths.
  Record the real slack and the path depth. This is your "before" number.

**Step 2 — RULE IN / OUT SCSI (the explicit ask). Restore the probes first.**
- The probe deck (`rtl/dbg_probes.sv`, instantiated in `MacLC.sv:~980`) got **optimized out** of
  `e92fe874` (its feed signals were tied off). Fix the `dbg_*` feeds so the deck survives synthesis;
  confirm with `bash scripts/read_probes.sh` (must report instances, not "no device").
- Reproduce a failure and read the probes. SCSI is the culprit IF: CPU looping on a SCSI-register
  read (`PSCS` reg 4 = CSR), `PDRD` showing the SCSI status reg, the loop polling `scsi_bsy`, or
  `PSC3`/`PSC6` showing the bus reset/abort signature. If instead the CPU is stuck elsewhere
  (SDRAM, video, SCC `$A49FF8`-style early-ROM), **SCSI is NOT the issue — pivot and report.**
- (Grey-screen `$A49FF8` SCC loop was the *wrong-branch* 030 build, already solved — don't chase it
  on `new-disk-features`.)

**Step 3 — Implement the fix (only if Step 2 confirms SCSI).** Layers 1→4 above. Layer 1 touches
the CPU bus — design carefully; the DTACK/VPA handshake must account for the +1 cycle or ALL
peripheral reads break.

**Step 4 — VERIFY.**
- A&E clean: `quartus_map.exe --analysis_and_elaboration MacLC` (~1 min, 0 errors / ~65 warn base).
- Full compile; `report_timing` shows large, fit-independent SCSI-read margin; rebuild with a
  DIFFERENT seed and confirm the margin holds (proves fit-independence).
- HW soak: deploy, launch, **many cold and warm boots** — the bar is dozens of clean boots.

---

## ENVIRONMENT & COMMANDS

- **Repo:** `C:\Temp\mistercore\MacLC_MiSTer`, branch **`new-disk-features`**, HEAD `cee170c`.
- **Build RBF:** `quartus_sh --flow compile MacLC` → `output_files/MacLC.rbf` (~25–30 min). Quartus
  CLI at `/c/intelFPGA_lite/17.0/quartus/bin64`. `SEED` is in `MacLC.qsf` (currently 1).
- **RTL gate (no Verilator on this box — user directive):** `quartus_map.exe
  --analysis_and_elaboration MacLC`. This is syntax/elaboration only — it does NOT prove function,
  so the Layer-1 CPU-bus change carries real risk: lean on full `report_timing` + careful HW soak.
  (The Verilator sim + MAME compare exist — `verilator/`, `docs/mame_compare.md` — but Verilator is
  banned on this Windows box; only use them if you have another machine/WSL that can run them.)
- **MiSTer:** `root@192.168.99.143`, key `~/.ssh/mister_only`, MiSTer Remote HTTP `8182`. Values in
  `scripts/local.env` (gitignored; `source` it).
- **Deploy RBF:** snapshot first (a running build/GUI can rewrite `output_files/MacLC.rbf` mid-copy):
  `cp output_files/MacLC.rbf /tmp/x.rbf; scp -i KEY /tmp/x.rbf root@HOST:/media/fat/_Unstable/MacLC.rbf`,
  then md5-verify both ends.
- **Launch core (no re-push):** `source scripts/local.env; python tools/misterdeploy/launch_unstable_core.py --core MacLC.rbf`
  (reboots to a clean menu, OSD-navigates, verifies `coreRunning`).
- **Probes:** `bash scripts/read_probes.sh` (decoded dump; `scripts/cpu_state.tcl` is the decoder).
  Loop disasm: `scripts/sample_loop.tcl` + `scripts/loop_disasm.py`. Docs: `docs/jtag_probes.md`.
- **Screenshot:** `bash scripts/grab.sh out.png` (POSTs `/api/screenshots`, downloads newest).
- **HPS binary swap (rarely needed for SCSI work):** can't overwrite the running `/media/fat/MiSTer`
  in place ("Text file busy") — `mv` it aside, then `cp`/`scp` the new one, then reboot.

---

## CRITICAL GOTCHAS (these cost hours this session)

1. **★ BRANCH TRAP.** `kernel-sync-030mmu2` = 68030 **MacLC II** → grey-screens as a MacLC (CPU
   loops early in ROM ~`$A49FF8` on the SCC, SCSI never selected). The MacLC (68020) branch is
   **`new-disk-features`**. ALWAYS verify the branch before building. MacLC II now lives in a
   separate repo `..\MacLCII_MiSTer` (memory `maclcii-separate-repo`).
2. **HPS/RBF must match.** The toolbox HPS binary auto-mounts SCSI slot 3; running it against a
   non-toolbox RBF makes a **phantom-slot wedge that looks exactly like a boot hang.** For pure SCSI
   work use the **stock HPS** (`/media/fat/MiSTer` = `MiSTer.original`, md5 `5a6fd2f0…`). The toolbox
   HPS is preserved at `/media/fat/MiSTer.toolbox_84a9b75b`.
3. **Long background builds may not notify** if the session has a multi-hour gap (a compile died
   silently at ~8h once). Actively re-check: `tasklist | grep quartus_fit` + tail the build log;
   don't trust the completion ping alone.
4. **Probe deck can vanish** from a fit if its feed signals are tied off (happened in `e92fe874`).
   After any build meant for debugging, confirm `read_probes.sh` actually finds instances.
5. **STA lies on this path.** Positive global slack ≠ working SCSI. The `−0.183 ns` violation in
   `e92fe874` was the **HDMI PLL** (`pll_hdmi|…|divclk`), benign — NOT the SCSI path. Don't chase
   global slack; measure the SCSI-read path specifically.
6. **Don't push to git / merge** without explicit user say-so (memory `dont-auto-merge-prs`).

---

## CURRENT STATE (as of 2026-06-24)

- **Grey screen: SOLVED** — it was the wrong (030) branch. `new-disk-features` (68020) boots the ROM.
- **Repo:** `new-disk-features` @ `cee170c` ("checking in last code bits" — toolbox SEND + tb_ready
  gated detection; A&E-clean, previously timing-met on an earlier fit). Working tree clean except
  untracked `docs/`, `output_files_LC1/`.
- **Latest build `output_files/MacLC.rbf` = `e92fe874`** (SEED 1): full compile 0 err; worst setup
  slack **−0.183 ns = HDMI PLL (benign)**; **probes optimized out**; **SCSI unstable** (cold "?disk",
  warm Sad Mac). This is the dice-roll build — your baseline to improve on.
- **Device `192.168.99.143`:** `_Unstable/MacLC.rbf` = `e92fe874`; `/media/fat/MiSTer` = stock
  `5a6fd2f0`; toolbox HPS at `MiSTer.toolbox_84a9b75b`; `MiSTer.original` = stock backup; ini
  `shared_folder=/media/fat/games/MacLC/shared` (inert under stock HPS).
- **Toolbox feature = PARKED.** Don't work on it. It rides on the same `new-disk-features` and its
  fit-perturbation is part of why SCSI margin matters — the SCSI fix benefits it later.

## KEY FILES
- `rtl/ncr5380.sv` (CSR / `scsi_bsy` / dout) · `rtl/dataController_top.sv` (peripheral read mux,
  `cpu_data_in`) · `MacLC.sv` (top, DTACK/VPA glue, dbg_probes inst) · `rtl/scsi.v` (SCSI target).
- `MacLC.sdc` (constraints — add the VPA-read multicycle here) · `MacLC.qsf` (SEED, partitions).
- `scripts/read_probes.sh`, `scripts/cpu_state.tcl`, `scripts/grab.sh`,
  `tools/misterdeploy/launch_unstable_core.py`, `scripts/local.env`.
- Memories to read: `cold-boot-reboot-welcome-handoff`, `scsi-port-state-and-byte-slip`,
  `scsi-completion-irq-welcome-wedge`, `scsi-dma-stall-offline-analysis`, `tg68-multicycle-timing`,
  `maclcii-separate-repo`, `quartus-cli-rtl-validation`, `mister-remote-osd-deploy`.
