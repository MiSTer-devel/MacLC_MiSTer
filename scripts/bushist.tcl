# DTACK-cycle latency HISTOGRAM readout — PBH0 (+PBL0-6) in rtl/dbg_probes.sv.
# Buckets by AS-low length in clk_sys ticks, split fetch vs data:
#   prog: <=4, 5, 6, 7, 8, >=9    data: same
# The mode = TG68K's effective minimum through the DTACK path; mass above the
# mode = reclaimable wait states (slot alignment etc.).
#
#   quartus_stp_tcl -t scripts/bushist.tcl [window_seconds]   (default 10)
#
# PBH0 is ONE probe instance with a 4-bit writable SOURCE selecting which of
# the 12 bucket counters the 32-bit probe shows. PBH0 sits at PBL0+7 when the
# hub name table reads corrupted (instantiated directly after PBL6).
# Cross-check: sum of prog buckets ~= dPBL1, data buckets ~= dPBL3.

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
if {$dev eq ""} { puts "NO DEVICE"; exit 1 }

set info [get_insystem_source_probe_instance_info -device_name $dev -hardware_name $hw]
set ninst [llength $info]
array set idx {}
set i 0
foreach inst $info { set idx([lindex $inst 3]) $i; incr i }

start_insystem_source_probe -device_name $dev -hardware_name $hw

proc rdi {i} {
    if {[catch {read_probe_data -instance_index $i -value_in_hex} v]} { return -1 }
    if {[string length $v] > 8} { return -1 }
    scan $v %x n
    return $n
}
proc d32 {a b} { expr {($b - $a) & 0xFFFFFFFF} }

# locate PBL0 (name, else clk-rate signature — same approach as buslat.tcl)
set base -1
if {[info exists idx(PBL0)]} {
    set base $idx(PBL0)
    puts "PBL0 by name at idx $base"
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
        set num [expr {abs(double($d1) - double($d2))}]
        set den [expr {(double($d1) + double($d2)) / 2.0}]
        if {$num / $den > 0.10} continue
        if {$den > $bestrate} { set bestrate $den; set best $i }
    }
    if {$best < 0} { puts "PBL0 NOT FOUND — is the histogram build loaded?"; exit 1 }
    set base $best
    puts "PBL0 located at idx $base"
}
set pbh [expr {$base + 7}]
if {[info exists idx(PBH0)]} { set pbh $idx(PBH0); puts "PBH0 by name at idx $pbh" } \
else { puts "PBH0 assumed at idx $pbh (PBL0+7)" }

proc rdh {pbh sel} {
    write_source_data -instance_index $pbh -value [format "%X" $sel] -value_in_hex
    after 20
    return [rdi $pbh]
}

proc snap {base pbh} {
    set s {}
    for {set k 1} {$k <= 4} {incr k} { lappend s [rdi [expr {$base + $k}]] }
    for {set b 0} {$b < 12} {incr b} { lappend s [rdh $pbh $b] }
    lappend s [rdi $base]
    return $s
}

puts "sampling ${window}s window..."
set sa [snap $base $pbh]
after [expr {int($window * 1000)}]
set sb [snap $base $pbh]

end_insystem_source_probe

set labels {<=4 5 6 7 8 >=9}
set lens   {4 5 6 7 8 10}

set dclk [d32 [lindex $sa 16] [lindex $sb 16]]
set secs [expr {double($dclk) / 32500000.0}]
puts "==================== DTACK latency histogram ===================="
puts [format "window          : %.3f s" $secs]

foreach {tag off cntoff sumoff} {prog 0 0 1 data 6 2 3} {
    set dcnt [d32 [lindex $sa $cntoff] [lindex $sb $cntoff]]
    set dsum [d32 [lindex $sa $sumoff] [lindex $sb $sumoff]]
    set tot 0
    set bd {}
    for {set b 0} {$b < 6} {incr b} {
        set d [d32 [lindex $sa [expr {4 + $off + $b}]] [lindex $sb [expr {4 + $off + $b}]]]
        lappend bd $d
        incr tot $d
    }
    if {$tot == 0} { puts "$tag: no cycles"; continue }
    set avg [expr {$dcnt > 0 ? double($dsum)/double($dcnt) : 0.0}]
    puts [format "---- %s: %u cycles (PBL cnt %u — histogram/PBL match %.1f%%), avg %.2f clk" \
        $tag $tot $dcnt [expr {100.0*double($tot)/double($dcnt>0?$dcnt:1)}] $avg]
    # mode = biggest bucket
    set mode 0; set modecnt 0
    for {set b 0} {$b < 6} {incr b} {
        if {[lindex $bd $b] > $modecnt} { set modecnt [lindex $bd $b]; set mode $b }
    }
    set excess 0.0
    for {set b 0} {$b < 6} {incr b} {
        set d [lindex $bd $b]
        puts [format "    %-4s clk : %10u  (%5.1f%%)%s" [lindex $labels $b] $d \
            [expr {100.0*double($d)/double($tot)}] [expr {$b == $mode ? "  <-- mode" : ""}]]
        if {$b > $mode} {
            set excess [expr {$excess + double($d) * ([lindex $lens $b] - [lindex $lens $mode])}]
        }
    }
    puts [format "    reclaimable above mode ~= %.0f clk = %.1f%% of window (%.1f%% of %s bus time)" \
        $excess [expr {100.0*$excess/double($dclk)}] \
        [expr {$dsum > 0 ? 100.0*$excess/double($dsum) : 0.0}] $tag]
}
puts "=================================================================="
