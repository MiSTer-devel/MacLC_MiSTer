# CD volume-law readout — decodes the CDA2/3/4 taps as REPURPOSED on the
# cd-volume-probe branch (see rtl/scsi.v, 2026-07-30). Prints one line per
# call; drive it once per volume step.
#   Run: bash -c 'export PATH=/c/intelFPGA_lite/17.0/quartus/bin64:$PATH; \
#                 quartus_stp_tcl -t scripts/vol_probe.tcl'
# One bounded session per invocation (HPS-exhaustion law).

# Pick the chain by CONTENT — the bench has two USB-Blasters and enumeration
# order is not stable (the 2026-07-17 "all-FF probes" trap).
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
if {$hw eq ""} { puts "NO CHAIN WITH CDA0 (probe rbf not loaded?)"; qexit -error }
array set idx {}
foreach inst $info { set idx([lindex $inst 3]) [lindex $inst 0] }
proc rd {name} {
    global idx
    if {![info exists idx($name)]} { return -1 }
    set v [read_probe_data -instance_index $idx($name) -value_in_hex]
    scan $v %x n
    return $n
}
proc f {v lsb w} { return [expr {($v >> $lsb) & ((1 << $w) - 1)}] }

start_insystem_source_probe -device_name $dev -hardware_name $hw
set a2 [rd CDA2]
set a3 [rd CDA3]
set a4 [rd CDA4]
end_insystem_source_probe

# CDA2 = {ch0, vol0, ch1, vol1}
set ch0 [f $a2 24 8]; set vol0 [f $a2 16 8]
set ch1 [f $a2 8 8];  set vol1 [f $a2 0 8]
# CDA3 = {page byte6, byte7, ch2, vol2}   b6/b7 must be 4B 4B (the 75/75 pair)
set b6 [f $a3 24 8]; set b7 [f $a3 16 8]
set ch2 [f $a3 8 8]; set vol2 [f $a3 0 8]
# CDA4 = {write count, last page code, bdlen, vol3}
set cnt [f $a4 24 8]; set page [f $a4 16 8]
set bdl [f $a4 8 8];  set vol3 [f $a4 0 8]

set align [expr {($b6 == 0x4B && $b7 == 0x4B) ? "ALIGNED(4B 4B)" : "SUSPECT"}]
puts [format "vol0=%3d (0x%02X) vol1=%3d  ch0=%02X ch1=%02X | writes=%3d page=%02X bdlen=%d | b6b7=%02X%02X %s | vol2=%d vol3=%d | raw %08X %08X %08X" \
      $vol0 $vol0 $vol1 $ch0 $ch1 $cnt $page $bdl $b6 $b7 $align $vol2 $vol3 $a2 $a3 $a4]
