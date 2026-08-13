# Resume prompt — MT32-pi on-screen info overlay (MacLC)

Paste this into a fresh session to add the MT32-pi "Show Info" on-screen readout.

---

## Objective
Add the MT32-pi on-screen info overlay to the MacLC core, reusing ao486's display
conventions. When the user changes MT32-pi Synth/ROM/SoundFont in the OSD, briefly
show the mode name (e.g. "MT-32 v1", "CM-32L", "SoundFont 3") as an overlay, then
fade after ~2 s (like ao486's LCD-Auto).

## Current state (already done — do NOT redo)
- MT32-pi **OSD control menu** is complete and HW-validated (commit `b0b9396`):
  CONF_STR `P1` page — Use MT32-pi (`status[24]`), Synth (`status[26]`),
  Munt ROM (`status[28:27]`), SoundFont (`status[31:29]`) → `mt32_mode_req` /
  `mt32_rom_req` / `mt32_sf_req`. Changing them live changes the Pi's output.
- The **on-screen overlay is deliberately OMITTED**: in `MacLC.sv` the `mt32pi`
  instance ties `.CLK_VIDEO(1'b0) .CE_PIXEL(1'b0) .VGA_VS(1'b0) .VGA_DE(1'b0)`
  and leaves `mt32_lcd_en/pix/update` unconnected (search "LCD overlay unused").
- Release: `releases/MacLC_20260813.rbf` = fit `ffb30650`, SEED 7.

## Reuse ao486 conventions (this is the reference — it drives the same sys/mt32pi.sv)
ao486's overlay compositing (its `gamma_fast` `RGB_in`), verbatim:
```
mt32_lcd ? {{2{mt32_lcd_pix}},R[7:2], {2{mt32_lcd_pix}},G[7:2], {2{mt32_lcd_pix}},B[7:2]} : {R,G,B}
```
i.e. inside the overlay box the video is dimmed to the low 6 bits and the LCD text
pixel is OR'd into the top 2 bits (white text on dimmed video). `mt32_lcd =
mt32_lcd_en & mt32_lcd_on`. Plus ao486's `mt32_info_req` / `mt32_info_disp`
(clk_sys) and `mt32_lcd_on` 2-second timeout (CLK_VIDEO). Pull the exact blocks
from `ao486.sv` (search `mt32_lcd`, `mt32_info`, `mt32_lcd_on`).

## Concrete steps (MacLC.sv)
1. **Wire the mt32pi video inputs to the LIVE signals** (replace the tied-0s at
   the instance ~L749): `.CLK_VIDEO(clk_vid) .CE_PIXEL(v8_ce_pix)
   .VGA_VS(v8_vsync) .VGA_DE(v8_de)`. Connect `.mt32_lcd_en(mt32_lcd_en)
   .mt32_lcd_pix(mt32_lcd_pix) .mt32_lcd_update(mt32_lcd_update)` and the
   `.mt32_mode() .mt32_rom() .mt32_sf() .mt32_newmode()` status outputs.
2. **"Show Info" CONF_STR + status bit.** ⚠ Our `status` bus is only `[31:0]`
   (see `wire [31:0] status;` ~L172) — ao486's `status[42:41]` will NOT fit.
   Use a FREE low bit: free bits are 1,2,3,9,11,14–17,19–23,25. Suggest
   `status[23:22]` → `"P1OMN,Show Info,No,Yes,LCD-On,LCD-Auto;"` (M=22,N=23),
   `wire [1:0] mt32_info = status[23:22];`. (Alternatively widen `status` to
   `[63:0]` and mirror ao486 exactly — but the free-low-bit path avoids touching
   the hps_io width.)
3. **Adapt ao486's timing logic.** `mt32_info_req`/`mt32_info_disp` on `clk_sys`;
   `mt32_lcd_on` on `clk_vid`. Scale ao486's `90000000*2` timeout to OUR clk_vid
   (~58.74 MHz static, C0=12): ~`117_000_000` for ~2 s.
4. **Composite into VGA_R/G/B** at the existing overlay point (~L507–513, which
   already has the `hud_on_q ? hud_px : v8_vga_r` pattern for USE_DBG_HUD — put
   the mt32 mux on the FINAL VGA_R/G/B so it works with HUD off, the release
   case ~L511–513):
   ```
   wire mt32_lcd = mt32_lcd_en & mt32_lcd_on;
   assign VGA_R = mt32_lcd ? {{2{mt32_lcd_pix}}, v8_vga_r[7:2]} : v8_vga_r;  // + G,B
   ```
   Channels are `[7:0]` (`v8_vga_r` etc.). Keep the HUD branch's precedence if
   USE_DBG_HUD is ever on.

## Gotchas specific to THIS core (read before building)
- ★★ **CLK_VIDEO runtime-retarget hazard.** This core reconfigures the pixel PLL
  at runtime (monitor-mode `OA`/`status[10]`, vsync_adjust, vscale). That caused
  the HDMI "out of range" bug — fixed by `pix_quiet` holding `vidrst` across the
  retarget (commit `7e6bd6d`, memory `hdmi-out-of-range-pll-retarget`). The
  mt32pi LCD logic will now live on `clk_vid`. Verify it's reset-safe across a
  retarget: change monitor mode (`OA`) WITH the overlay active and confirm no
  garbage/lockup. The `mt32pi` module resets its LCD state on `reset` (=~n_reset).
- ★★ **Seed-sensitive core + per-fit HW video gate is LAW.** Any netlist change
  re-rolls placement; fits have MET timing yet shown corrupt video (seed 5) or an
  empty desktop (seed 6). Gate EVERY fit on a HW boot: deploy → grab a fresh
  frame (`scripts/grab_fresh.sh`) → confirm clean video AND a fully-populated
  7.5.5 desktop (volume icon + Trash + window icons). Roll SEED in MacLC.qsf if
  it fails (avoid 2,3; ledger in memory `midi-over-scc-feature`: 4/7 good).
- **sys/ is OFF-LIMITS.** `sys/mt32pi.sv` is framework — wire from MacLC.sv only.
- Overlay position/size come from inside `sys/mt32pi.sv` (fixed small box). Sanity
  check it lands acceptably on both monitor modes (640×480 VGA and 512×384 12").

## Validation
1. Build (`bash scripts/build_only.sh`), STA must be MET.
2. HW video+boot gate (above). Roll seeds until clean.
3. Deploy; in the OSD change MT32-pi Synth/ROM → the overlay should pop up ~2 s
   showing the mode name; confirm no video corruption and that a monitor-mode
   switch with the overlay up doesn't break HDMI.
4. Re-confirm MIDI (to the Pi) and PPP still work (serial RTL unchanged, but the
   core is seed-sensitive, so re-check on the final fit).
5. Re-stamp `releases/MacLC_YYYYMMDD.rbf` + hash-provenance copy; commit.

## References
- `ao486.sv` — search `mt32_lcd`, `mt32_info`, `mt32_lcd_on`, `mt32_info_disp`.
- `sys/mt32pi.sv` — LCD outputs + the video inputs to feed.
- `MacLC.sv` — mt32pi instance (~L735), VGA out (~L500–516), CONF_STR (~L66),
  `status` width (~L172), `clk_vid`/`v8_ce_pix`/`v8_vsync`/`v8_de`.
- Memories: `hdmi-out-of-range-pll-retarget`, `midi-over-scc-feature` (seed
  ledger + 32-bit status note), `quartus-cli-rtl-validation` (video-gate law).
