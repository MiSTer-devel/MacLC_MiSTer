# CPU bus-latency meter readout — PBL0-6 in rtl/dbg_probes.sv.
# Samples the free-running counters twice WINDOW seconds apart and prints
# per-class average latency, access rates, and bus occupancy. Start the
# workload of interest (POP gameplay, Finder idle, Speedometer) BEFORE
# running; the whole window should be one steady workload.
#
#   quartus_stp_tcl -t scripts/buslat.tcl [window_seconds]   (default 10)
#
# Classes (see dbg_probes.sv PBL comment):
#   prog = instruction fetches (FC 2/6), DTACK-terminated
#   data = operand accesses  (FC 1/5), DTACK-terminated
#   vpa  = E-clock cycles (VIA/IACK) — architectural latency, kept separate
# Latency unit = clk_sys ticks (32.5 MHz, 30.77 ns).
#
# NOTE (2026-07-03): with 38 ISSP nodes the Quartus 17.0 instance-NAME table
# reads back corrupted (garbage names/widths past ~idx 13) while per-index
# DATA reads stay correct. So this script name-matches when it can, and
# otherwise LOCATES PBL0 by signature — the only counter that increments
# every clk_sys (~32.5M/s, stable across sub-windows; all duration sums are
# strictly slower since occupancy < 100%) — then maps PBL1-6 as the next six
# indexes (they are instantiated consecutively) and verifies the map by the
# E-clock latency signature (avg vpa ≈ 40 clk). PVID sits at PBL0-1 and
# provides a VBL-rate readout (identifies VGA 38.7 Hz vs 12" 62.4 Hz mode).

set window 10
if {$argc >= 1} { set window [lindex $argv 0] }

set hw ""
foreach h [get_hardware_names] {
    if {[string match "DE-SoC*" $h]} { set hw $h; break }
}
if {$hw eq ""} {
    foreach h [get_hardware_names] {
        if {![catch {get_device_names -hardware_name $h} devs]} {
            foreach d $devs { if {[string match "*5CSE*" $d]} { set hw $h; break } }
        }
        if {$hw ne ""} break
    }
}
set dev ""
if {$hw ne ""} {
    foreach d [get_device_names -hardware_name $hw] { if {[string match "*5CSE*" $d]} { set dev $d; break } }
}
puts "hw=$hw dev=$dev"
if {$dev eq ""} { puts "NO DEVICE — is the MiSTer on and the USB-Blaster cable up?"; exit 1 }

set info [get_insystem_source_probe_instance_info -device_name $dev -hardware_name $hw]
set ninst [llength $info]
array set idx {}
set i 0
foreach inst $info {
    set idx([lindex $inst 3]) $i
    incr i
}

start_insystem_source_probe -device_name $dev -hardware_name $hw

proc rdi {i} {
    if {[catch {read_probe_data -instance_index $i -value_in_hex} v]} { return -1 }
    if {[string length $v] > 8} { return -1 }
    scan $v %x n
    return $n
}
proc d32 {a b} { expr {($b - $a) & 0xFFFFFFFF} }

# ---- locate PBL0 -----------------------------------------------------------
set base -1
if {[info exists idx(PBL0)]} {
    set base $idx(PBL0)
    puts "PBL0 found by name at idx $base"
} else {
    puts "name table corrupt — locating PBL0 by clk-rate signature..."
    set s0 {}; set s1 {}; set s2 {}
    for {set i 0} {$i < $ninst} {incr i} { lappend s0 [rdi $i] }
    after 400
    for {set i 0} {$i < $ninst} {incr i} { lappend s1 [rdi $i] }
    after 400
    for {set i 0} {$i < $ninst} {incr i} { lappend s2 [rdi $i] }
    set best -1; set bestrate 0
    for {set i 0} {$i < $ninst} {incr i} {
        set a [lindex $s0 $i]; set b [lindex $s1 $i]; set c [lindex $s2 $i]
        if {$a < 0 || $b < 0 || $c < 0} continue
        set d1 [d32 $a $b]; set d2 [d32 $b $c]
        if {$d1 < 1000000 || $d2 < 1000000} continue
        # stable rate: two sub-window deltas within 10% of each other
        set num [expr {abs(double($d1) - double($d2))}]
        set den [expr {(double($d1) + double($d2)) / 2.0}]
        if {$num / $den > 0.10} continue
        if {$den > $bestrate} { set bestrate $den; set best $i }
    }
    if {$best < 0} { puts "PBL0 NOT FOUND — is the bus-latency build loaded?"; exit 1 }
    set base $best
    puts [format "PBL0 located at idx %d (%.1fM ticks / sub-window)" $base [expr {$bestrate / 1e6}]]
    # verify: avg vpa latency from PBL5/PBL6 must look like E-clock sync
    set c5a [lindex $s0 [expr {$base + 5}]]; set c6a [lindex $s0 [expr {$base + 6}]]
    set c5b [lindex $s2 [expr {$base + 5}]]; set c6b [lindex $s2 [expr {$base + 6}]]
    set dvc [expr {(($c5b & 0xFFFF) - ($c5a & 0xFFFF)) & 0xFFFF}]
    set dvs [d32 $c6a $c6b]
    if {$dvc > 0} {
        set avgv [expr {double($dvs) / double($dvc)}]
        if {$avgv < 30.0 || $avgv > 55.0} {
            puts [format "VERIFY FAILED: avg vpa %.1f clk not E-like (expect ~40-44) — wrong base?" $avgv]
            exit 1
        }
        puts [format "map verified: avg vpa latency %.1f clk (E-clock signature)" $avgv]
    }
}

# ---- monitor-mode readout via PVID (base-1) --------------------------------
set pvid_i [expr {$base - 1}]
set v0 [rdi $pvid_i]
after 2000
set v1 [rdi $pvid_i]
if {$v0 >= 0 && $v1 >= 0} {
    set dv [expr {((($v1 >> 24) & 0xFF) - (($v0 >> 24) & 0xFF)) & 0xFF}]
    set vr [expr {double($dv) / 2.0}]
    set mode "?"
    if {$vr > 33.0 && $vr < 45.0} { set mode "640x480 VGA (38.7 Hz VBL)" }
    if {$vr > 55.0 && $vr < 70.0} { set mode "512x384 12in RGB (62.4 Hz VBL)" }
    puts [format "PVID vbl rate   : ~%.0f Hz -> %s" $vr $mode]
}

# ---- the measurement window ------------------------------------------------
proc snap {base} {
    set s {}
    for {set k 0} {$k <= 6} {incr k} { lappend s [rdi [expr {$base + $k}]] }
    return $s
}

puts "sampling ${window}s window..."
set sa [snap $base]
after [expr {int($window * 1000)}]
set sb [snap $base]

end_insystem_source_probe

foreach {clk0 pc0 ps0 dc0 ds0 pbl5_0 vs0} $sa {}
foreach {clk1 pc1 ps1 dc1 ds1 pbl5_1 vs1} $sb {}

set dclk [d32 $clk0 $clk1]
set dpc  [d32 $pc0 $pc1]
set dps  [d32 $ps0 $ps1]
set ddc  [d32 $dc0 $dc1]
set dds  [d32 $ds0 $ds1]
set dvs  [d32 $vs0 $vs1]
set dvc  [expr {(($pbl5_1 & 0xFFFF) - ($pbl5_0 & 0xFFFF)) & 0xFFFF}]
set max_prog [expr {($pbl5_1 >> 24) & 0xFF}]
set max_data [expr {($pbl5_1 >> 16) & 0xFF}]

if {$dclk == 0} { puts "clk counter did not advance — core not running?"; exit 1 }
set secs [expr {double($dclk) / 32500000.0}]

puts "==================== bus-latency meter ===================="
puts [format "window          : %.3f s (%u clk @32.5MHz)" $secs $dclk]

proc line {tag cnt sum secs} {
    if {$cnt == 0} { puts [format "%-15s : none" $tag]; return }
    set avg [expr {double($sum) / double($cnt)}]
    puts [format "%-15s : %10u cyc  avg %6.2f clk (%7.1f ns)  %8.0f /s  bus %5.1f%%" \
        $tag $cnt $avg [expr {$avg * 30.769}] [expr {double($cnt) / $secs}] \
        [expr {100.0 * double($sum) / (32500000.0 * $secs)}]]
}
line "prog (fetch)" $dpc $dps $secs
line "data"         $ddc $dds $secs
line "vpa (E-clock)" $dvc $dvs $secs

set occ [expr {100.0 * double($dps + $dds + $dvs) / double($dclk)}]
puts [format "bus occupancy   : %5.1f%%  (AS-low fraction, all classes)" $occ]
if {$dpc + $ddc > 0} {
    puts [format "fetch share     : %5.1f%% of DTACK accesses, %5.1f%% of DTACK bus time" \
        [expr {100.0 * double($dpc) / double($dpc + $ddc)}] \
        [expr {($dps + $dds) > 0 ? 100.0 * double($dps) / double($dps + $dds) : 0.0}]]
}
puts [format "max latency     : prog %u clk, data %u clk (since core load)" $max_prog $max_data]
puts "============================================================"
