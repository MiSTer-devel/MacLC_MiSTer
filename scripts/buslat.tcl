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
array set idx {}
set i 0
foreach inst $info {
    set idx([lindex $inst 3]) $i
    incr i
}
foreach p {PBL0 PBL1 PBL2 PBL3 PBL4 PBL5 PBL6} {
    if {![info exists idx($p)]} { puts "NO $p probe — is the bus-latency build loaded?"; exit 1 }
}

proc rd {name} {
    global idx dev hw
    set v [read_probe_data -instance_index $idx($name) -value_in_hex]
    scan $v %x n
    return $n
}

start_insystem_source_probe -device_name $dev -hardware_name $hw

proc snap {} {
    set s {}
    foreach p {PBL0 PBL1 PBL2 PBL3 PBL4 PBL6} { lappend s [rd $p] }
    lappend s [rd PBL5]
    return $s
}
proc d32 {a b} { expr {($b - $a) & 0xFFFFFFFF} }

puts "sampling ${window}s window..."
set s0 [snap]
after [expr {int($window * 1000)}]
set s1 [snap]

end_insystem_source_probe

foreach {clk0 pc0 ps0 dc0 ds0 vs0 pbl5_0} $s0 {}
foreach {clk1 pc1 ps1 dc1 ds1 vs1 pbl5_1} $s1 {}

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
