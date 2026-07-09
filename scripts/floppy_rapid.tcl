# Rapid in-process sampler for the floppy read-path probes (PFL0/PFL1).
# Holds ONE JTAG source-probe session open and reads in a tight loop, so a
# 1-2 s in-flight GCR read (before the OS rejects an 800K disk) is caught
# across many samples instead of missed between 7 s quartus_stp restarts.
# Modeled on scripts/sample_loop.tcl (the proven rapid-loop pattern).
#
#   quartus_stp_tcl -t scripts/floppy_rapid.tcl [n_samples] [delay_ms]
#
# PFL0 = {byte_cnt[31:16], miss_cnt[15:0]}
# PFL1 = {track[31:25], side[24], iwm_latch[23:16], step_cnt[15:8], disk_data[7:0]}
#
# Output (parse-friendly, one line per printed sample):
#   FS <seq> <t_ms> byte=<u> miss=<u> trk=<u> side=<u> lat=<hex> stp=<u> dat=<hex> addr=<hex>
# A line prints only when byte/miss/trk/side/stp CHANGES (the meaningful read/seek
# events; disk_data cycles even at idle so it is excluded from the change key),
# plus a heartbeat every 50 samples. byte_cnt CLIMBING = read in flight.

set n 4000
set dly 15
if {$argc >= 1} { set n   [lindex $argv 0] }
if {$argc >= 2} { set dly [lindex $argv 1] }

# ---- portable cable/device pick (same block as cpu_state.tcl) ----
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
puts "hw=$hw dev=$dev n=$n dly=$dly"
if {$dev eq ""} { puts "NO DEVICE — is the MiSTer on and the USB-Blaster cable up?"; exit 1 }

# get_insystem_source_probe_instance_info occasionally returns an incomplete
# instance list on the USB-Blaster (transient). enumerate = retry until
# PFL0+PFL1 appear; reused to re-open the session mid-capture if reads fail.
proc enumerate {} {
    global dev hw idx have_padr
    for {set try 0} {$try < 10} {incr try} {
        array unset idx ; array set idx {}
        set info [get_insystem_source_probe_instance_info -device_name $dev -hardware_name $hw]
        set i 0
        foreach inst $info { set idx([lindex $inst 3]) $i; incr i }
        if {[info exists idx(PFL0)] && [info exists idx(PFL1)]} {
            set have_padr [info exists idx(PADR)]
            return 1
        }
        after 300
    }
    return 0
}

# read one probe; return -1 (never throw) on a transient JTAG read glitch, so a
# single bad read drops one sample instead of aborting a multi-minute capture.
proc rdi {name} {
    global idx
    if {![info exists idx($name)]} { return -1 }
    if {[catch {read_probe_data -instance_index $idx($name) -value_in_hex} v]} { return -1 }
    # %llx not %x: %x wraps bit31-set values negative (PFL1 trk>=64, PADR>=0x80000000)
    if {[scan $v %llx nn] != 1} { return -1 }
    return $nn
}

array set idx {}
if {![enumerate]} { puts "NO PFL0/PFL1 probe after retries"; exit 1 }
catch {start_insystem_source_probe -device_name $dev -hardware_name $hw}

set t0 [clock milliseconds]
set prev ""
set fails 0
for {set s 0} {$s < $n} {incr s} {
    set f0 [rdi PFL0]
    set f1 [rdi PFL1]
    if {$f0 < 0 || $f1 < 0} {
        incr fails
        if {$fails >= 25} {
            # session likely dropped — re-open the probe session and keep going
            catch {end_insystem_source_probe}
            if {[enumerate]} { catch {start_insystem_source_probe -device_name $dev -hardware_name $hw} }
            set fails 0
        }
        if {$dly > 0} { after $dly }
        continue
    }
    set fails 0
    set addr 0
    if {$have_padr} { set addr [rdi PADR] ; if {$addr < 0} { set addr 0 } }
    set byte [expr {($f0>>16)&0xFFFF}]
    set miss [expr {$f0&0xFFFF}]
    set trk  [expr {($f1>>25)&0x7F}]
    set side [expr {($f1>>24)&1}]
    set lat  [expr {($f1>>16)&0xFF}]
    set stp  [expr {($f1>>8)&0xFF}]
    set dat  [expr {$f1&0xFF}]
    set key "$byte $miss $trk $side $stp"
    if {$key ne $prev || ($s % 50) == 0} {
        puts [format "FS %d %d byte=%u miss=%u trk=%u side=%u lat=%02X stp=%u dat=%02X addr=%06X" \
            $s [expr {[clock milliseconds]-$t0}] $byte $miss $trk $side $lat $stp $dat [expr {$addr & 0xFFFFFF}]]
        flush stdout
        set prev $key
    }
    if {$dly > 0} { after $dly }
}
# NB: Quartus 17.0 end_insystem_source_probe takes NO -device_name/-hardware_name
# (it ends the active session); passing them errors.
catch {end_insystem_source_probe}
puts "DONE samples=$n"
