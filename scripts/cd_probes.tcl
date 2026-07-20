# CDA0/CDA1 decoded readout — CD-audio engine + CD target state.
# Run: bash -c 'export PATH=/c/intelFPGA_lite/17.0/quartus/bin64:$PATH; quartus_stp_tcl -t scripts/cd_probes.tcl'
# One bounded session (HPS-exhaustion law). Layouts: MacLC.sv CDA probe block.

# Select hardware+device by CONTENT: the bench has TWO USB-Blasters (two
# DE10s: MacLC + LBMacTwo) and enumeration order is not stable. Pick the
# chain whose probe instance table contains OUR deck (CDA0). This same
# wrong-board first-match was 2026-07-17's "all-FF probes" mystery.
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
if {$hw eq ""} { puts "NO CHAIN WITH CDA0 (wrong rbf on both boards?)"; qexit -error }
puts "using: $hw / $dev"
array set idx {}
foreach inst $info { set idx([lindex $inst 3]) [lindex $inst 0] }
proc rd {name} {
    global idx dev hw
    if {![info exists idx($name)]} { return -1 }
    set v [read_probe_data -instance_index $idx($name) -value_in_hex]
    scan $v %x n
    return $n
}
start_insystem_source_probe -device_name $dev -hardware_name $hw

set a2 [rd CDA2]
set a3 [rd CDA3]
set a4 [rd CDA4]
set a0 [rd CDA0]
set a1 [rd CDA1]
after 400
set b0 [rd CDA0]
set b1 [rd CDA1]
end_insystem_source_probe

if {$a0 == -1} { puts "CDA0 probe not found (old rbf?)"; qexit -error }

proc f {v lo w} { expr {($v >> $lo) & ((1 << $w) - 1)} }
foreach {tag v0 v1} [list A $a0 $a1 B $b0 $b1] {
    puts [format "CDA0.%s raw=%08X mounted=%d toc_ready=%d toc_valid=%d n_tracks=%d mst=%d pstate=%d fst=%d toc_fetches=%d frame_fetches=%d" \
        $tag $v0 [f $v0 0 1] [f $v0 1 1] [f $v0 2 1] [f $v0 3 7] [f $v0 10 5] [f $v0 15 2] [f $v0 17 2] [f $v0 19 8] [f $v0 27 5]]
    puts [format "CDA1.%s raw=%08X last_op=%02X cmd_cnt=%d sense_key=%X sense_asc=%02X last_ok=%d mounted=%d no_media=%d toc_ready=%d" \
        $tag $v1 [f $v1 0 8] [f $v1 8 8] [f $v1 16 4] [f $v1 20 8] [f $v1 28 1] [f $v1 29 1] [f $v1 30 1] [f $v1 31 1]]
}
if {$a2 != -1} {
    # latch = verbatim {cdb9, cdb6, cdb7, cdb8} of the last 0x43 READ TOC ask
    # (cdb9 top2: 00=format 0, 10=full TOC/0x80, 01=session info/0x40)
    puts [format "CDA2 last-0x43 ask: raw=%08X cdb9=%02X(fmt=%d%d) start6=%02X alloc=%d"         $a2 [f $a2 24 8] [f $a2 31 1] [f $a2 30 1] [f $a2 16 8] [f $a2 0 16]]
}
if {$a3 != -1} {
    # CDA3/CDA4 = full CDB of the last PLAY-CLASS command (47/48/4B/4E/C8..CD):
    # CDA3 {op, cdb3, cdb4, cdb5}, CDA4 {cdb1, cdb6, cdb7, cdb8}.
    puts [format "CDA3/4 last play-class: op=%02X cdb1=%02X cdb3=%02X cdb4=%02X cdb5=%02X cdb6=%02X cdb7=%02X cdb8=%02X" \
        [f $a3 24 8] [f $a4 24 8] [f $a3 16 8] [f $a3 8 8] [f $a3 0 8] [f $a4 16 8] [f $a4 8 8] [f $a4 0 8]]
}
puts "delta: toc_fetches +[expr {[f $b0 19 8] - [f $a0 19 8]}]  frame_fetches +[expr {(([f $b0 27 5] - [f $a0 27 5]) + 32) % 32}]  cmds +[expr {(([f $b1 8 8] - [f $a1 8 8]) + 256) % 256}]"
