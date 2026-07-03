# Layer 4 build-time timing gate for the SCSI / peripheral VPA read path.
#
#   Run after a compile:   quartus_sta -t scripts/check_scsi_timing.tcl
#   Exit codes:  0 = PASS (margin >= THRESHOLD)
#                2 = FAIL (SCSI read margin eroded below THRESHOLD)
#                3 = periph_din_reg not found (register optimized out / renamed)
#
# Rationale: the Mac LC boot reliability hinges on the CPU correctly reading the
# SCSI CSR (esp. bit6 / scsi_bsy). That value reaches the CPU through periph_din_reg
# (MacLC.sv), which captures the peripheral read mux one clk_sys before the E-paced
# VPA sample. MacLC.sdc relaxes the deep input cone (-to periph_din_reg) to a
# conservative 2x because the real VPA window is >= 5 clk_sys. This gate proves the
# margin is real and fit-INDEPENDENT: it checks BOTH halves of the registered path
# and rejects any build whose worst slack on either half drops below THRESHOLD, so a
# marginal fit is caught here instead of shipping a dice-roll boot.
#
#   (a) -to   periph_din_reg : deep, historically fit-sensitive cone (scsi_bsy ...)
#   (b) -from periph_din_reg : the new reg -> CPU (tg68_din_r) hop, single-cycle

set THRESHOLD 0.5 ;# ns — minimum acceptable worst-case setup slack on the read path

project_open MacLC
create_timing_netlist -model slow
read_sdc
update_timing_netlist

# Worst-case setup slack over a generous set of paths matching a filter.
proc worst_to_from {dir} {
    set w 1.0e9
    if {$dir eq "to"} {
        set paths [get_timing_paths -setup -to [get_keepers {*periph_din_reg*}] -npaths 200 -nworst 200]
    } else {
        set paths [get_timing_paths -setup -from [get_keepers {*periph_din_reg*}] -npaths 200 -nworst 200]
    }
    foreach_in_collection p $paths {
        set s [get_path_info $p -slack]
        if {$s < $w} { set w $s }
    }
    return $w
}

set w_to   [worst_to_from to]
set w_from [worst_to_from from]

# Overall design worst slack, for context (NOT part of the gate — the HDMI PLL
# routinely sits slightly negative and is benign; see the fit-stabilization handoff).
set design_worst 1.0e9
foreach_in_collection p [get_timing_paths -setup -npaths 50 -nworst 50] {
    set s [get_path_info $p -slack]
    if {$s < $design_worst} { set design_worst $s }
}

puts ""
puts "================= SCSI / peripheral read-path timing gate ================="
puts [format "  worst setup slack   -to periph_din_reg  : %8.3f ns  (deep scsi_bsy cone, 2x mcp)" $w_to]
puts [format "  worst setup slack -from periph_din_reg  : %8.3f ns  (reg -> CPU din, 1 cycle)" $w_from]
puts [format "  threshold                               : %8.3f ns" $THRESHOLD]
puts [format "  (context) overall design worst setup    : %8.3f ns" $design_worst]
puts "==========================================================================="
puts ""
puts "----- detail: worst paths -to periph_din_reg -----"
report_timing -setup -to [get_keepers {*periph_din_reg*}] -npaths 4 -detail summary -stdout
puts "----- detail: worst paths -from periph_din_reg -----"
report_timing -setup -from [get_keepers {*periph_din_reg*}] -npaths 4 -detail summary -stdout

project_close

if {$w_to > 9.0e8 || $w_from > 9.0e8} {
    puts "GATE: ERROR — no periph_din_reg timing paths found (register optimized out or renamed?)"
    exit 3
}
set worst $w_to
if {$w_from < $worst} { set worst $w_from }
if {$worst < $THRESHOLD} {
    puts [format "GATE: FAIL — SCSI read margin %.3f ns < %.3f ns threshold; reject this fit." $worst $THRESHOLD]
    exit 2
}
puts [format "GATE: PASS — SCSI read margin %.3f ns >= %.3f ns; fit is safe to ship." $worst $THRESHOLD]
exit 0
