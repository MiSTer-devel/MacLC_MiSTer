# Measure CD-audio delivery health over JTAG (In-System probes).
#   quartus_stp_tcl -t scripts/cd_meters.tcl
#
# Run WHILE a CD audio track is audibly playing (AppleCD Audio Player, Play).
# Needs an RBF built with USE_AUDIO_ISSP=1 (CDS/AUD) and USE_DBG_PROBES=1
# (CDUR) in MacLC.qsf.
#
# CDUR (32b): [31:16] = starvation entries (engine wanted a half-frame that
#                       the HPS had not delivered; wraps)
#             [15:0]  = starved clk/256 (7.877 us units at 32.5 MHz; wraps)
#   Healthy playback: both frozen (0/s). The 07-20 ship-day HDMI capture
#   showed ~5% starvation duty = 0.4-4 ms freezes = the "scratchy / not CD
#   quality" report; CDS 41.8k/s was the same 5% deficit seen end-to-end.
#
# CDS (32b): [31:16] = cd_snd_l value-change counter, [15:0] = cd_snd_r.
#   RETIRED as a cadence meter since the interpolated output stage (6ffe854 +
#   the 8-clk hold): during playback it wraps too fast to mean anything.
#   Nonzero deltas = engine alive; that is all it says now.
#
# Cable selection is by PROBE CONTENT (a CDS instance must exist), never by
# cable order — two DE10s live on this bench.

set hw ""; set dev ""
set idxCDS -1; set idxAUD -1; set idxCDUR -1
foreach h [get_hardware_names] {
    foreach d [get_device_names -hardware_name $h] {
        if {![string match "*5CSE*" $d]} { continue }
        set jCDS -1; set jAUD -1; set jCDUR -1; set i 0
        if {[catch {get_insystem_source_probe_instance_info -device_name $d -hardware_name $h} info]} { continue }
        foreach inst $info {
            set nm [lindex $inst 3]
            if {$nm eq "CDS"}  { set jCDS $i }
            if {$nm eq "AUD"}  { set jAUD $i }
            if {$nm eq "CDUR"} { set jCDUR $i }
            incr i
        }
        if {$jCDS >= 0} {
            set hw $h; set dev $d
            set idxCDS $jCDS; set idxAUD $jAUD; set idxCDUR $jCDUR
            break
        }
    }
    if {$hw ne ""} break
}
if {$hw eq ""} { puts "no cable with a CDS probe deck found (build without USE_AUDIO_ISSP, or wrong board powered)"; return }
puts "hw=$hw dev=$dev  (CDS=$idxCDS AUD=$idxAUD CDUR=$idxCDUR)"

catch { end_insystem_source_probe }
start_insystem_source_probe -device_name $dev -hardware_name $hw
after 300
proc rd {i} { for {set r 0} {$r < 6} {incr r} { if {![catch {read_probe_data -instance_index $i -value_in_hex} v]} { return [expr 0x$v] }; after 40 }; return 0 }
proc fld {v sh m} { return [expr ($v >> $sh) & $m] }

if {$idxCDUR >= 0} {
    puts "interval  starve-entries/s  starved-ms/s  duty%     CDS-L/s  CDS-R/s"
} else {
    puts "interval  CDS-L/s  CDS-R/s   (no CDUR in this build)"
}
for {set k 0} {$k < 6} {incr k} {
    set t0 [clock milliseconds]
    set s0 [rd $idxCDS]
    set u0 0
    if {$idxCDUR >= 0} { set u0 [rd $idxCDUR] }
    after 1000
    set s1 [rd $idxCDS]
    set u1 0
    if {$idxCDUR >= 0} { set u1 [rd $idxCDUR] }
    set t1 [clock milliseconds]
    set dt [expr {($t1 - $t0) / 1000.0}]
    set dl [expr {([fld $s1 16 0xFFFF] - [fld $s0 16 0xFFFF]) & 0xFFFF}]
    set dr [expr {([fld $s1 0 0xFFFF] - [fld $s0 0 0xFFFF]) & 0xFFFF}]
    if {$idxCDUR >= 0} {
        set de [expr {([fld $u1 16 0xFFFF] - [fld $u0 16 0xFFFF]) & 0xFFFF}]
        set du [expr {([fld $u1 0 0xFFFF] - [fld $u0 0 0xFFFF]) & 0xFFFF}]
        # starved time: units * 256 clk / 32.5 MHz
        set ms [expr {$du * 256.0 / 32500.0 / $dt}]
        set duty [expr {$ms / 10.0}]
        puts [format "  %d       %8d          %8.2f     %5.2f    %7d  %7d" \
            $k [expr {int($de/$dt)}] $ms $duty [expr {int($dl/$dt)}] [expr {int($dr/$dt)}]]
    } else {
        puts [format "  %d       %7d  %7d" $k [expr {int($dl/$dt)}] [expr {int($dr/$dt)}]]
    }
}
puts "verdict: starve 0/s = delivery healthy; entries>0 = HPS serving missed"
puts "         the 13.3 ms half-frame budget that many times per second."

if {$idxAUD >= 0} {
    set v [rd $idxAUD]
    puts "AUD: ASC writes=[fld $v 0 0xFFFF]  ASC reads=[fld $v 16 0xFFFF]  (context only)"
}

end_insystem_source_probe
