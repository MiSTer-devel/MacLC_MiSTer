# Read and decode the PFSW probe: floppy_sd_writer's witness word (Phase 4).
# Field layout is the writer's `dbg` port (rtl/floppy_sd_writer.v):
#   [31:24] queue-full REFUSALS = sectors lost (sat)   [23:16] out-of-range refusals (sat)
#   [15:8]  blocks landed (wraps)         [7:4]  eject flushes started (sat)
#   [3:0]   pstate
# Two samples 500 ms apart so a copy in progress shows as a moving landed
# count. The gate condition for a sustained large-file copy is overflow == 0.
#
#   bash -c 'export PATH=/c/intelFPGA_lite/17.0/quartus/bin64:$PATH; quartus_stp_tcl -t scripts/pfsw_probe.tcl'
#
# Cable/device detection is copied from scripts/cpu_state.tcl.
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

proc rd {name} {
    global idx dev hw
    if {![info exists idx($name)]} { return -1 }
    set v [read_probe_data -instance_index $idx($name) -value_in_hex]
    scan $v %x n
    return $n
}

start_insystem_source_probe -device_name $dev -hardware_name $hw

proc decode {v} {
    set ovf  [expr {($v >> 24) & 0xFF}]
    set ref  [expr {($v >> 16) & 0xFF}]
    set land [expr {($v >> 8)  & 0xFF}]
    set fl   [expr {($v >> 4)  & 0xF}]
    set st   [expr {$v & 0xF}]
    set names {IDLE RD_ACK RD_DONE WAIT_ACK WAIT_DONE SCAN_RD SCAN_END HDR_RD HDR_END HDR_WR HDR_WDONE ? ? ? ? ?}
    return [format "overflow=%d refused=%d landed=%d flushes=%d pstate=%d(%s)" \
        $ovf $ref $land $fl $st [lindex $names $st]]
}
if {![info exists idx(PFSW)]} { puts "PFSW not in this fit (probes-off build?)"; exit 1 }
set a [rd PFSW]
after 500
set b [rd PFSW]
puts [format "PFSW = %08X  %s" $a [decode $a]]
puts [format "PFSW = %08X  %s" $b [decode $b]]
if {(($a >> 24) & 0xFF) == 0} { puts "REFUSAL COUNT 0 - no sector was lost (the queue never filled)" } else { puts "*** REFUSAL COUNT NONZERO - the sector queue filled and commits were REFUSED; those sectors are NOT on the card ***" }

# ---------------------------------------------------------------------------
# PISM: the ISM registers the driver programmed, plus the MFM WRITE witness.
# The anchor is what places every MFM write - an MFM data field does not name
# its sector, so the write goes where the ID field the CPU last POPPED said it
# should (plan section 6.1). A wrong anchor writes a WELL-FORMED sector to the
# WRONG place, silently, which is why this is the first thing to read when a
# written sector turns up somewhere unexpected.
# ---------------------------------------------------------------------------
proc decode_ism {v} {
    set mode   [expr {($v >> 24) & 0xFF}]
    set setup  [expr {($v >> 16) & 0xFF}]
    set act    [expr {($v >> 15) & 1}]
    set arm    [expr {($v >> 14) & 1}]
    set aok    [expr {($v >> 13) & 1}]
    set asec   [expr {($v >>  8) & 0x1F}]
    set anchor [expr {$aok ? "sector $asec" : "INVALID"}]
    return [format "MODE=%02X SETUP=%02X  write:%s arm=%d  anchor=%s"         $mode $setup [expr {$act ? "ACTIVE" : "idle"}] $arm $anchor]
}
if {[info exists idx(PISM)]} {
    set s [rd PISM]
    puts [format "PISM = %08X  %s" $s [decode_ism $s]]
    set act [expr {($s >> 15) & 1}]
    set aok [expr {($s >> 13) & 1}]
    set asec [expr {($s >> 8) & 0x1F}]
    if {$act && !$aok} {
        puts "*** WRITE ENGINE ARMED WITH NO ANCHOR - a data field carrying no ID field of its own will be REFUSED, not placed ***"
    }
    if {$aok && ($asec < 1 || $asec > 18)} {
        puts "*** ANCHOR $asec IS OFF THE MEDIUM (1..18 HD / 1..9 DD) ***"
    }
} else {
    puts "PISM not in this fit (probes-off build?)"
}
