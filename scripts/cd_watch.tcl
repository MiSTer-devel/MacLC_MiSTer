# Bounded play-class command watch: ONE JTAG session, ~3 min, prints only
# TRANSITIONS of {CDA3/4 play CDB, CDA1 cmd_cnt, CDA0 pstate}. Pairs with a
# narrated button sequence from the user to map every CD Player control to
# the CDB the driver composes (or to NO command = player-internal refusal).
# Run: quartus_stp_tcl -t scripts/cd_watch.tcl
set hw ""; set dev ""; set info {}
foreach h [get_hardware_names] {
    if {[catch {get_device_names -hardware_name $h} devs]} { continue }
    foreach d $devs {
        if {![string match "*5CSE*" $d]} { continue }
        if {[catch {get_insystem_source_probe_instance_info -device_name $d -hardware_name $h} ii]} { continue }
        foreach inst $ii {
            if {[lindex $inst 3] eq "CDA0"} { set hw $h; set dev $d; set info $ii; break }
        }
        if {$hw ne ""} { break }
    }
    if {$hw ne ""} { break }
}
if {$hw eq ""} { puts "NO CHAIN WITH CDA0"; qexit -error }
array set idx {}
foreach inst $info { set idx([lindex $inst 3]) [lindex $inst 0] }
proc rd {name} {
    global idx
    if {![info exists idx($name)]} { return -1 }
    set v [read_probe_data -instance_index $idx($name) -value_in_hex]
    scan $v %x n
    return $n
}
proc f {v lo w} { expr {($v >> $lo) & ((1 << $w) - 1)} }
start_insystem_source_probe -device_name $dev -hardware_name $hw
set t0 [clock milliseconds]
set p3 -1; set p4 -1; set pc -1; set ps -1
puts "WATCH START (transitions only; ~180s)"
for {set i 0} {$i < 130} {incr i} {
    set v3 [rd CDA3]; set v4 [rd CDA4]
    set v1 [rd CDA1]; set v0 [rd CDA0]
    set cc [f $v1 8 8]
    set st [f $v0 15 2]
    if {$v3 != $p3 || $v4 != $p4 || $cc != $pc || $st != $ps} {
        set dt [expr {([clock milliseconds] - $t0) / 100}]
        puts [format "t=%4d00ms cmds=%3d pstate=%d  play-cdb: op=%02X cdb1=%02X 3=%02X 4=%02X 5=%02X 6=%02X 7=%02X 8=%02X" \
            $dt $cc $st [f $v3 24 8] [f $v4 24 8] [f $v3 16 8] [f $v3 8 8] [f $v3 0 8] [f $v4 16 8] [f $v4 8 8] [f $v4 0 8]]
        set p3 $v3; set p4 $v4; set pc $cc; set ps $st
    }
    after 1300
}
end_insystem_source_probe
puts "WATCH END"
