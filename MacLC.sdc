# MacLC project timing constraints (read after sys/sys_top.sdc).
#
# ----------------------------------------------------------------------------
# TG68 kernel multicycle — REQUIRED for reliable timing closure.
# ----------------------------------------------------------------------------
# The TG68 kernel (TG68KdotC_Kernel) is a clock-enabled CPU: it advances ONLY on
# tg68_clkena (rtl/tg68k/tg68k.v). The Phase-B bus FSM (branch cpu-enhancements)
# pulses clkena once per bus cycle at S_ENDC — always >= 5 ticks after the
# previous pulse — and for internal (busstate==01) steps gates it with
# !clkena_d (clkena delayed one tick), so clkena can never pulse on two
# consecutive clk_sys cycles — consecutive kernel updates are always >= 2
# clk_sys periods apart. (The pre-Phase-B walker got the same guarantee from
# clocking only at phi1.) Every kernel register (including the inferred
# register-file RAM regfile_rtl_0/1 and its read-during-write bypass) takes its
# meaningful input from, and feeds, other clkena-gated kernel logic. So
# kernel-internal reg->reg paths genuinely have TWO clk_sys periods to settle,
# not one. If the FSM's clkena gating is ever changed, re-verify this invariant
# before trusting any fit.
#
# Without this, STA over-constrains the kernel to a single clk_sys period (~30.8ns
# @ 32.5MHz). The CPU's long decode/datapath/regfile-bypass paths are ~33ns, so
# they "fail" (the worst, regfile WE->bypass, measured -2.699ns) yet are
# placement-fragile enough to *sometimes* squeak by (+0.2ns) — the design was
# closing timing by luck. Relaxing the genuinely-2-cycle kernel paths to 2 periods
# takes the worst kernel slack hugely positive; the design's real limiter becomes
# the framework ascal scaler (~+0.56ns), independent of the CPU and of the DDR3
# video work. See docs/handoff_ddr3_video_2026-06-06.md.
#
# Scope is kernel-INTERNAL only (-from kernel -to kernel): it deliberately does NOT
# touch the tg68k WRAPPER state machine (s_state/eCntr update on phi1|phi2 = every
# clk_sys = genuine 1-cycle) nor any CPU<->SDRAM/peripheral path (those sample at
# full clk_sys rate and must stay single-cycle). HW-validated by a clean boot to
# the Finder desktop (the CPU executes millions of instructions through these paths
# to boot; a wrong multicycle would corrupt/crash it).
set_multicycle_path -setup -end 2 -from [get_keepers {*TG68KdotC_Kernel*}] -to [get_keepers {*TG68KdotC_Kernel*}]
set_multicycle_path -hold  -end 1 -from [get_keepers {*TG68KdotC_Kernel*}] -to [get_keepers {*TG68KdotC_Kernel*}]

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
