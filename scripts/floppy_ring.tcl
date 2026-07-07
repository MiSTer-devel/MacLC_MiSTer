# PFL1 floppy byte-capture RING controller — the SAFE replacement for the
# floppy_rapid.tcl streaming sampler (whose minutes-long source-probe loop and
# mid-run session reopen CRASHED the .143 MiSTer — see the SAFETY box in
# docs/resume_floppy_content_bug_2026-07-06.md). Every action here is ONE
# bounded JTAG session, a few seconds total, with NO mid-run reopen: on any
# read/write failure it restores live mode and ABORTS.
#
# The ring (MacLC.sv, behind the widened PFL1 probe): the first 1024 bytes of
# the exact GCR stream HANDED to the IWM after an arm edge, recorded on-chip,
# so the track-0 sync/gap/address-mark framing can be diffed against MAME
# (scratch/mame_floppy_0702/data_reads_800k.txt.gz, decoded_800k_v3.txt).
#
# Usage (quartus bin64 on PATH, e.g. after `source scripts/local.env`):
#   quartus_stp_tcl -t scripts/floppy_ring.tcl arm             # reset + start capture
#   quartus_stp_tcl -t scripts/floppy_ring.tcl status          # capture state + PFL0
#   quartus_stp_tcl -t scripts/floppy_ring.tcl dump [outfile]  # sweep, decode, scan
#
# 800K content-bug protocol:
#   1. arm                    (BEFORE mounting; re-armable any number of times)
#   2. OSD-mount the raw 800K image as Pri Floppy; wait for the
#      "unreadable" dialog (~50 s — the ring fills in the burst's first ~20 ms)
#   3. dump                   (~5 s of JTAG; writes hexdump + mark scan)
#
# PFL1 source = {arm[10], sel[9:8], addr[7:0]}; sel: 0=live 1=ring[addr] 2=status
# status = {8'hB5 magic, done[23], capturing[22], 2'b00, arm_cnt[19:16], 6'd0, wptr[9:0]}
# ring word = 4 delivered bytes, [7:0] = earliest

set cmd "status"
set outfile "floppy_ring_dump.txt"
if {$argc >= 1} { set cmd [string tolower [lindex $argv 0]] }
if {$argc >= 2} { set outfile [lindex $argv 1] }
if {[lsearch {arm status dump} $cmd] < 0} {
    puts "unknown command '$cmd' — use: arm | status | dump \[outfile\]"
    exit 2
}

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
puts "hw=$hw dev=$dev"
if {$dev eq ""} { puts "NO DEVICE — is the MiSTer on and the USB-Blaster cable up?"; exit 1 }

# ---- locate PFL1 (+ PFL0 for context) — bounded STARTUP retries only ----
# Name-table-corruption fallback: PFL1 is the ONLY instance with source_width 11.
set pfl1 -1
set pfl0 -1
set info {}
for {set try 0} {$try < 5} {incr try} {
    set pfl1 -1; set pfl0 -1
    set info [get_insystem_source_probe_instance_info -device_name $dev -hardware_name $hw]
    set i 0
    set sw11 {}
    foreach inst $info {
        set nm [lindex $inst 3]
        if {$nm eq "PFL1"} { set pfl1 $i }
        if {$nm eq "PFL0"} { set pfl0 $i }
        if {[lindex $inst 1] == 11} { lappend sw11 $i }
        incr i
    }
    if {$pfl1 < 0 && [llength $sw11] == 1} {
        set pfl1 [lindex $sw11 0]
        puts "name table degraded — PFL1 by unique source_width=11 at idx $pfl1"
    }
    if {$pfl1 >= 0} break
    after 300
}
if {$pfl1 < 0} { puts "PFL1 NOT FOUND — is the capture-ring build loaded?"; exit 1 }
puts "PFL1 idx=$pfl1  PFL0 idx=$pfl0  instances=[llength $info]"

start_insystem_source_probe -device_name $dev -hardware_name $hw

# one probe read; -1 on failure (caller aborts — NO mid-run reopen by design)
# %llx NOT %x: plain %x wraps values with bit31 set (e.g. the 0xB5 status
# magic) to a NEGATIVE signed 32-bit int, which would look like a failure.
proc rdi {i} {
    if {[catch {read_probe_data -instance_index $i -value_in_hex} v]} { return -1 }
    if {[scan $v %llx n] != 1} { return -1 }
    return $n
}
# one source write; 0 on failure
proc wsi {i val} {
    if {[catch {write_source_data -instance_index $i -value [format %X $val] -value_in_hex}]} { return 0 }
    return 1
}
proc bail {msg} {
    global pfl1
    catch {wsi $pfl1 0}
    catch {end_insystem_source_probe}
    puts "ABORT: $msg (single bounded session — rerun rather than retry in-place)"
    exit 1
}

proc read_status {} {
    global pfl1
    if {![wsi $pfl1 0x200]} { bail "status source write failed" }
    after 5
    set s [rdi $pfl1]
    if {$s < 0} { bail "status read failed" }
    if {(($s >> 24) & 0xFF) != 0xB5} {
        bail [format "status magic mismatch (got %08X, want B5xxxxxx) — wrong build loaded?" $s]
    }
    return $s
}
proc show_status {s} {
    global pfl0
    set done [expr {($s >> 23) & 1}]
    set cap  [expr {($s >> 22) & 1}]
    set armc [expr {($s >> 16) & 0xF}]
    set wptr [expr {$s & 0x3FF}]
    puts [format "RING: done=%d capturing=%d arm_cnt=%d words=%d (%d bytes)" \
        $done $cap $armc $wptr [expr {$wptr * 4}]]
    if {$pfl0 >= 0} {
        set f0 [rdi $pfl0]
        if {$f0 >= 0} {
            puts [format "PFL0: byte_cnt=%u miss_cnt=%u" \
                [expr {($f0 >> 16) & 0xFFFF}] [expr {$f0 & 0xFFFF}]]
        }
    }
    return $wptr
}

if {$cmd eq "status"} {
    show_status [read_status]
    wsi $pfl1 0
    catch {end_insystem_source_probe}
    puts "DONE"
    exit 0
}

if {$cmd eq "arm"} {
    if {![wsi $pfl1 0x400]} { bail "arm write failed" }
    after 10
    if {![wsi $pfl1 0x000]} { bail "arm clear failed" }
    after 10
    set s [read_status]
    show_status $s
    if {!(($s >> 22) & 1)} { puts "WARNING: capturing=0 right after arm — wrong build?" }
    wsi $pfl1 0
    catch {end_insystem_source_probe}
    puts "ARMED — mount the floppy now; run 'dump' after the unreadable dialog"
    exit 0
}

# ---- dump ----
set s [read_status]
set wptr [show_status $s]
if {$wptr == 0} {
    wsi $pfl1 0
    catch {end_insystem_source_probe}
    puts "ring is EMPTY — arm first, then mount the disk"
    exit 1
}
if {$wptr > 256} { set wptr 256 }
puts "sweeping $wptr words (~[expr {$wptr / 40}] s)..."
set bytes {}
for {set w 0} {$w < $wptr} {incr w} {
    if {![wsi $pfl1 [expr {0x100 | $w}]]} { bail "addr write failed at word $w" }
    after 5
    set v [rdi $pfl1]
    if {$v < 0} { bail "ring read failed at word $w" }
    lappend bytes [expr {$v & 0xFF}] [expr {($v >> 8) & 0xFF}] \
                  [expr {($v >> 16) & 0xFF}] [expr {($v >> 24) & 0xFF}]
}
wsi $pfl1 0
catch {end_insystem_source_probe}

# ---- output + GCR framing scan (all offline from here — JTAG is done) ----
set fh [open $outfile w]
proc out {line} { global fh; puts $line; puts $fh $line }

set n [llength $bytes]
out "# floppy_ring dump — [clock format [clock seconds]] — $n bytes (earliest first)"
for {set i 0} {$i < $n} {incr i 16} {
    set row {}
    for {set j $i} {$j < $n && $j < $i + 16} {incr j} {
        lappend row [format %02X [lindex $bytes $j]]
    }
    out [format "%04X: %s" $i [join $row " "]]
}
out ""
out "FLAT (for offline grep/diff):"
set flat ""
foreach b $bytes { append flat [format %02X $b] }
for {set i 0} {$i < [string length $flat]} {incr i 128} {
    out [string range $flat $i [expr {$i + 127}]]
}
out ""

# FF self-sync runs
set ffruns {}
set run 0
for {set i 0} {$i < $n} {incr i} {
    if {[lindex $bytes $i] == 0xFF} { incr run } else {
        if {$run > 0} { lappend ffruns $run }
        set run 0
    }
}
if {$run > 0} { lappend ffruns $run }
set maxff 0; set runs4 0
foreach r $ffruns {
    if {$r > $maxff} { set maxff $r }
    if {$r >= 4} { incr runs4 }
}

# marks
set addrmarks {}; set datamarks {}; set d5aa_other {}; set epilogues 0; set nlow 0
for {set i 0} {$i < $n} {incr i} {
    set b0 [lindex $bytes $i]
    if {$b0 < 0x80} { incr nlow }
    if {$i >= $n - 2} continue
    set b1 [lindex $bytes [expr {$i + 1}]]
    set b2 [lindex $bytes [expr {$i + 2}]]
    if {$b0 == 0xD5 && $b1 == 0xAA} {
        if {$b2 == 0x96} { lappend addrmarks $i } \
        elseif {$b2 == 0xAD} { lappend datamarks $i } \
        else { lappend d5aa_other $i }
    }
    if {$b0 == 0xDE && $b1 == 0xAA} { incr epilogues }
}

out "==================== GCR framing scan ===================="
out [format "bytes=%d  bytes<0x80 (ILLEGAL in GCR)=%d" $n $nlow]
out [format "FF sync runs: %d total, %d of len>=4, longest=%d" \
    [llength $ffruns] $runs4 $maxff]
out [format "D5 AA 96 address marks : %d" [llength $addrmarks]]
out [format "D5 AA AD data marks    : %d" [llength $datamarks]]
out [format "D5 AA <other>          : %d" [llength $d5aa_other]]
out [format "DE AA epilogues        : %d" $epilogues]
foreach a $addrmarks {
    set row {}
    for {set j $a} {$j < $n && $j < $a + 12} {incr j} {
        lappend row [format %02X [lindex $bytes $j]]
    }
    out [format "  ADDR @%04X: %s   (want D5 AA 96 t s d f chk DE AA; MAME trk0: D5 AA 96 96 9A 96 D9 D6 DE AA)" $a [join $row " "]]
}
foreach a $datamarks {
    set row {}
    for {set j $a} {$j < $n && $j < $a + 6} {incr j} {
        lappend row [format %02X [lindex $bytes $j]]
    }
    out [format "  DATA @%04X: %s" $a [join $row " "]]
}
foreach a $d5aa_other {
    set row {}
    for {set j $a} {$j < $n && $j < $a + 6} {incr j} {
        lappend row [format %02X [lindex $bytes $j]]
    }
    out [format "  D5AA? @%04X: %s   (malformed mark?)" $a [join $row " "]]
}
if {[llength $addrmarks] == 0 && [llength $datamarks] == 0} {
    out "VERDICT HINT: NO address/data marks in 1 KB (~1.3 sectors' worth) ->"
    out "  the stream's sync/gap/mark framing is broken; the IWM can never"
    out "  byte-sync. Re-examine floppy_track_encoder.v output ORDER/phase."
} else {
    out "VERDICT HINT: marks PRESENT -> framing partially OK; diff the address"
    out "  field + checksums + sync-run lengths against MAME decoded_800k_v3.txt"
}
out "==========================================================="
close $fh
puts "written: $outfile"
