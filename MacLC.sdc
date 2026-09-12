# MacLC project timing constraints (read after sys/sys_top.sdc).
#
# ----------------------------------------------------------------------------
# TG68 kernel — HARD CAP on kernel-internal paths, NOT a two-period credit.
# ----------------------------------------------------------------------------
# History. From 2026-06-07 (29e1f69) to 2026-09-12 this block was
#   set_multicycle_path -setup -end 2 -from kernel -to kernel  (+ -hold -end 1)
# on the argument that the kernel (TG68KdotC_Kernel) only advances on
# tg68_clkena pulses that are always >= 2 clk_sys apart, so kernel reg->reg
# paths genuinely have two periods (61.5 ns) to settle. That argument is TRUE
# (re-verified 2026-09-12: every kernel and ALU register is clkena_lw/clkena_in
# gated, the inferred register-file M10Ks have clock enables on both ports, and
# the seed-7 fit runs fine with a worst kernel single-cycle slack of -7.2 ns).
#
# It is nevertheless UNSAFE as the fitter's objective, and it was the cause of
# the "STA met, hardware corrupt, differs per SEED" class that has dogged this
# core since June (July SCSI colour-icon noise -> the always-on anchor hack,
# August F-line bombs, the seed-8 corrupted-fetch fit, the 08-27 QuarkXPress
# Line-1111 hang, and 2026-09-12: same RTL, seed 7 clean, seed 5 hangs at the
# desktop, seed 4 freezes at the desktop, all reproducible). Why: the TG68
# decoder contains a 150-node STRUCTURAL combinational loop (Quartus Critical
# Warning 332081 "Estimating the delays through the loop", TG68KdotC_Kernel.vhd
# ~line 1656: setexecOPC is a function of setstate/next_micro_state, and the
# setstate mux trees use setexecOPC as a select — not a functional oscillator,
# the setexecOPC-guarded branches only set ALU operand-routing flags — but STA
# can only ESTIMATE delay through those mux trees). Given a 61.5 ns budget the
# fitter treats the whole kernel as non-critical and leaves its paths anywhere
# from 32 to 38 ns as STA sees them, with the loop-hidden remainder unbounded and
# re-rolled by every placement; on some seeds the real delay of one decode path
# for one instruction pattern exceeds the two periods that actually exist, and
# that instruction then fails deterministically (Quark typing, Finder start-up).
#
# Experiment E1 (2026-09-12): the seed-4 fit that froze at the desktop, rebuilt
# with ONLY this credit removed, closed the kernel at a single period to
# -0.165 ns (the fitter CAN compact the kernel to ~31 ns when it must) and is
# stable on hardware through boots, QuarkXPress typing and restarts.
#
# So: cap kernel-internal paths at ~one period. The fitter must keep the kernel
# compact (exactly the E1 fit), STA reports honestly against that cap, and the
# genuine two-period budget leaves ~29 ns of real margin for whatever the loop
# estimate under-reports. 32.0 ns = one 30.76 ns period + ~1.2 ns so a normal
# fit reports "met" (E1 worst 30.93 ns); a fit that cannot make 32 ns is a fit
# to reject, not to explain away. set_max_delay overrides any multicycle for
# these paths; hold stays the default single-cycle check. Do NOT restore the
# two-period credit "because the kernel really is two-cycle" — that is exactly
# how the loop's hidden delay gets a free hand. The clean long-term fix is to
# break the structural loop in the kernel so STA is exact; until then this cap
# is the guard. Scope is kernel-INTERNAL only, as before: the tg68k wrapper FSM
# and every CPU<->SDRAM/peripheral path are ordinary single-cycle paths.
set_max_delay -from [get_keepers {*TG68KdotC_Kernel*}] -to [get_keepers {*TG68KdotC_Kernel*}] 32.0

# ----------------------------------------------------------------------------
# Peripheral (VPA) read-data register — SCSI read-path fit-stabilization.
# ----------------------------------------------------------------------------
# periph_din_reg (MacLC.sv) captures the peripheral read mux (dataControllerDataOut)
# one clk_sys stage before the CPU samples it on VPA/6800 cycles. Its deepest input
# cone is the SCSI CSR's scsi_bsy bit (scsi.v phase -> |target_bsy -> CSR -> far route
# -> 7-way mux) — historically THE fit-sensitive net that made the SCSI HD read fail
# on some builds (bit6/scsi_bsy read wrong, bit1/scsi_sel read right).
#
# Peripheral reads are E-paced: the kernel stalls at S_WAIT for the E-paced
# (phi2 && xVma) exit (near E-fall) and latches read data two ticks later at
# S_TAIL2, ALWAYS >= 5 clk_sys after the address/select settle (the VMA/E
# handshake takes at least one E quantum; rtl/tg68k/tg68k.v). So the cone into
# periph_din_reg genuinely has multiple clk_sys to resolve, not one. Credit a CONSERVATIVE 2x (61.6 ns @
# 32.5 MHz) — well inside the >=5-cycle window — so STA reports the real margin
# instead of over-constraining this E-paced read to a single 30.8 ns period (the
# "STA passes but HW fails" trap). periph_din_reg is only CONSUMED during VPA reads,
# when its input is held stable by the CPU; its fan-OUT (-> tg68_din_r, near the CPU)
# stays a normal single-cycle path and is deliberately NOT relaxed here.
set_multicycle_path -setup -end 2 -to [get_keepers {*periph_din_reg*}]
set_multicycle_path -hold  -end 1 -to [get_keepers {*periph_din_reg*}]

# ----------------------------------------------------------------------------
# Phase C: clk_sys -> SDRAM demand sequencer — NO multicycle. Deliberate.
# ----------------------------------------------------------------------------
# An earlier attempt (b48b60c, reverted here) credited these paths 2 destination
# periods on the theory that the t[0] start gate made the request data "a full
# clk_sys old" at capture. STA on the post-fit netlist DISPROVED it:
#   slack -6.710 ns, WINDOW 15.381 ns, tg68k|addr[16] -> sdram|sd_addr[12]
# i.e. the capture window is ONE clk_64 period, and the V8 address-translation
# cone needs ~22 ns. The constraint was hiding a 6.7 ns violation; the SDRAM was
# being handed a half-settled row/column address, which corrupted memory and
# bombed the guest (F-line, 2026-08-17). See docs/CPU_Perf_Log.md.
#
# The fix is structural instead: MacLC.sv registers the whole SDRAM request
# bundle (addr/din/ds/oe/we/flp_win/flp_guard) in clk_sys before it reaches the
# sequencer, so the deep cone terminates at a clk_sys flop with a full 30.76 ns
# period, and the sequencer captures from an adjacent register over a short
# route. Both legs are then honest single-cycle paths that STA checks for real.
# DO NOT re-add a multicycle here — if these paths fail, fix the pipelining.

# ----------------------------------------------------------------------------
# Pixel-clock domain (pll_video) CDC — false-path the 2FF synchronizer heads.
# ----------------------------------------------------------------------------
# The V8 scanout runs on clk_vid (pll_video, reconfigured 25.175/15.664/58.742
# MHz). sys_top.sdc decouples every clock domain with set_clock_groups, but
# its core-PLL pattern (*|pll|pll_inst|...) matches only the MAIN pll — the
# pll_video clock landed in NO group, so every framework path touching
# CLK_VIDEO (ascal video-in, OSD, HDMI transfer) was timed against unrelated
# domains: design-wide false violations (worst -27.9 ns, clk_sys TNS -89k).
# Declare it asynchronous to everything else, exactly like pll_hdmi/pll_audio.
#
# The deliberate clk_sys<->clk_vid crossings this blesses are all safe by
# construction: (a) dual-clock M10Ks (vram_bram framebuffer, ariel palette —
# no timed cross-port arc), (b) 2FF *_meta synchronizers (config into the
# video module, video-domain reset, VBL/HBL back into clk_sys), and (c) the
# quasi-static words_per_line bus into addrController's VRAM write packing —
# incoherent only across a monitor/depth change, when the guest redraws the
# whole screen anyway.
set_clock_groups -asynchronous -group [get_clocks {emu|pllv|*|divclk}]

# Belt-and-braces documentation of the synchronizer heads (redundant with the
# clock group above, harmless).
set_false_path -to [get_keepers {*vmode_meta* *monid_meta* *tbyp_meta* *tsel_meta*}]
set_false_path -to [get_keepers {*vidrst_meta* *vbl_meta* *hbl_meta*}]

# ----------------------------------------------------------------------------
# SDRAM interface I/O constraints (2026-09-12).
# ----------------------------------------------------------------------------
# Until now the SDRAM pins carried NO I/O constraints at all: report_ucp on the
# shipped builds listed all 16 SDRAM_DQ[*] inputs and the whole A/BA/DQ/DQM/cmd
# output set as unconstrained, so STA never checked the read data eye. The eye
# was therefore set by the fitter's routing alone — which is why a pure reseed
# (SEED 8 -> 4) shipped a core that hangs QuarkXPress with a Line-1111 F-line
# exception while the same RTL at another seed is clean. Full measurement and
# bisect: docs/plan_sdram_read_capture_2026-09-12.md.
#
# SDRAM_CLK is altddio_out(datain_h=0, datain_l=1) of clk_64, i.e. the INVERTED
# clk_64 — declare it as such so the chip's launch edges are modelled correctly.
#
# Delay values: Alliance AS4C32M16SB-7 (64/128 MB MiSTer modules; Winbond
# W9825G6KH-6 on the 32 MB module is equivalent):
#   tAC(CL2) 6.0 ns, tOH 2.5 ns, tIS(tDS) 1.5 ns, tIH(tDH) 0.8 ns,
#   plus ~0.5 ns of board trace allowance on the max numbers.
#
# The read capture is rtl/sdram.v's sd_data_q — a single I/O-cell register on
# the FALLING edge of clk_64. The chip launches on ITS rising edge (= a clk_64
# falling edge) and we capture on the NEXT clk_64 falling edge, which is the
# default single-cycle relationship: no multicycle is needed or wanted here.
# Measured eye at that register (three seeds, 0.04 ns spread): +2.2 ns setup,
# +6.5 ns hold — the edge sits early in an ~8.8 ns eye; the fat side is hold.
# From there the word is re-timed by sd_data_r (fabric, next falling edge:
# a full period for the I/O-cell -> core route) and consumed on the posedge
# after that; the floppy copy `dout` loads on that same falling edge. All of
# those are ordinary same-clock paths (negedge->negedge full period,
# negedge->posedge half period) that STA checks natively — nothing to add.
# ** If the pin capture is ever moved back to a posedge register, this must be
# re-derived — the pre-2026-09-12 STATE_READ capture needed
# `set_multicycle_path -setup -end 2` to be reported honestly at all. And a
# posedge stage directly behind sd_data_q does NOT close: that hand-off has
# half a period minus ~1.2 ns of I/O-cell clock skew against a ~6 ns route,
# and failed by -0.14..-0.64 ns on three seeds (2026-09-12). **
#
# sdram_clk is deliberately NOT added to the -exclusive clock groups in
# sys/sys_top.sdc: a clock that appears in no group stays related to every
# other clock, which is exactly what makes these paths get timed against
# clk_64 instead of being cut.
create_generated_clock -name sdram_clk -invert \
  -source [get_pins {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] \
  [get_ports {SDRAM_CLK}]

# chip -> FPGA (read data)
set_input_delay  -clock sdram_clk -max 6.5 [get_ports {SDRAM_DQ[*]}]
set_input_delay  -clock sdram_clk -min 2.5 [get_ports {SDRAM_DQ[*]}]

# FPGA -> chip (address, command, write data, byte masks)
set SDRAM_OUT [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQMH SDRAM_DQML SDRAM_nCAS SDRAM_nRAS SDRAM_nWE SDRAM_nCS}]
set_output_delay -clock sdram_clk -max  2.0 $SDRAM_OUT
set_output_delay -clock sdram_clk -min -0.8 $SDRAM_OUT
