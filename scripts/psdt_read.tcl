set hw ""; set dev ""; set info {}
foreach h [get_hardware_names] {
    if {[catch {get_device_names -hardware_name $h} devs]} { continue }
    foreach d $devs {
        if {![string match "*5CSE*" $d]} { continue }
        if {[catch {get_insystem_source_probe_instance_info -device_name $d -hardware_name $h} ii]} { continue }
        foreach inst $ii { if {[lindex $inst 3] eq "CDA0"} { set hw $h; set dev $d; set info $ii; break } }
        if {$hw ne ""} { break }
    }
    if {$hw ne ""} { break }
}
if {$hw eq ""} { puts "NO CHAIN"; qexit -error }
array set idx {}
foreach inst $info { set idx([lindex $inst 3]) [lindex $inst 0] }
proc rd {name} { global idx dev hw
    if {![info exists idx($name)]} { return -1 }
    set v [read_probe_data -instance_index $idx($name) -value_in_hex]; scan $v %x n; return $n }
start_insystem_source_probe -device_name $dev -hardware_name $hw
set t [rd PSDT]; set s [rd PSDS]; set adr [rd PADR]; set act0 [rd PACT]
after 300
set act1 [rd PACT]
end_insystem_source_probe
puts [format "PSDT raw=%08X berr_fires=%d max_stall=%d" $t [expr {$t >> 24}] [expr {$t & 0x7FFFFF}]]
puts [format "PSDS raw=%08X snapped=%d" $s [expr {($s >> 16) & 1}]]
puts [format "PADR=%08X cpu_alive_delta=%d" $adr [expr {$act1 - $act0}]]
