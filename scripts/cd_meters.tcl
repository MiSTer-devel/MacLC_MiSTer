# Measure the CD-audio digital cadence over JTAG (In-System probes).
#   quartus_stp_tcl -t scripts/cd_meters.tcl
#
# Run WHILE a CD audio track is audibly playing (AppleCD Audio Player, Play).
# Needs an RBF built with USE_AUDIO_ISSP=1 (MacLC.qsf).
#
# CDS (32b): [31:16] = cd_snd_l value-change counter (wraps at 65536)
#            [15:0]  = cd_snd_r value-change counter
# Verdict on the change-rate during music:
#   ~44100/s  -> full-rate content reaches the mixer; digital path exonerated
#                (suspect mix gain / 48 kHz ZOH resample / analog out instead)
#   ~22050/s  -> content is literally half-rate (duplicated samples): defect
#                in the serving/engine path
#   far lower, music stutters -> underruns (frame fetch starving)
#   ~0        -> engine not playing (check player state / disc type)
# Note: brief dips below 44100 are normal on quiet passages (equal successive
# samples don't count as changes) — judge by the MAX interval over the run.

set hw ""
foreach h [get_hardware_names] { foreach d [get_device_names -hardware_name $h] { if {[string match "*5CSE*" $d]} { set hw $h; set dev $d; break } }; if {$hw ne ""} break }
puts "hw=$hw dev=$dev"

set info [get_insystem_source_probe_instance_info -device_name $dev -hardware_name $hw]
set idxCDS -1; set idxAUD -1; set i 0
foreach inst $info {
    set nm [lindex $inst 3]
    if {$nm eq "CDS"} { set idxCDS $i }
    if {$nm eq "AUD"} { set idxAUD $i }
    incr i
}
if {$idxCDS < 0} { puts "CDS instance not found (build without USE_AUDIO_ISSP?)"; return }
catch { end_insystem_source_probe }
start_insystem_source_probe -device_name $dev -hardware_name $hw
after 300
proc rd {i} { for {set r 0} {$r < 6} {incr r} { if {![catch {read_probe_data -instance_index $i -value_in_hex} v]} { return [expr 0x$v] }; after 40 }; return 0 }
proc fld {v sh m} { return [expr ($v >> $sh) & $m] }

puts "interval   L-changes/s   R-changes/s"
set maxl 0; set maxr 0
for {set k 0} {$k < 5} {incr k} {
    set t0 [clock milliseconds]
    set v0 [rd $idxCDS]
    after 1000
    set v1 [rd $idxCDS]
    set t1 [clock milliseconds]
    set dt [expr {($t1 - $t0) / 1000.0}]
    set dl [expr {([fld $v1 16 0xFFFF] - [fld $v0 16 0xFFFF]) & 0xFFFF}]
    set dr [expr {([fld $v1 0 0xFFFF] - [fld $v0 0 0xFFFF]) & 0xFFFF}]
    set rl [expr {int($dl / $dt)}]
    set rr [expr {int($dr / $dt)}]
    if {$rl > $maxl} { set maxl $rl }
    if {$rr > $maxr} { set maxr $rr }
    puts [format "  %d        %6d        %6d" $k $rl $rr]
}
puts "max:       L=$maxl  R=$maxr   (44100=full-rate, 22050=halved, <<= underruns)"

if {$idxAUD >= 0} {
    set v [rd $idxAUD]
    puts "AUD: ASC writes=[fld $v 0 0xFFFF]  ASC reads=[fld $v 16 0xFFFF]  (context only)"
}

end_insystem_source_probe
