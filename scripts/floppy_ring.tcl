# PFL1 floppy byte-capture RING controller — the SAFE replacement for the
# floppy_rapid.tcl streaming sampler (whose minutes-long source-probe loop and
# mid-run session reopen CRASHED the .143 MiSTer — see the SAFETY box in
# docs/resume_floppy_content_bug_2026-07-06.md). Every action here is ONE
# bounded JTAG session, a few seconds total, with NO mid-run reopen: on any
# read/write failure it restores live mode and ABORTS.
#
# The ring (MacLC.sv, behind the widened PFL1 probe), v2 raw-fetch format:
# 256 delivered-byte strobes, each recording {gcrReadAddr[15:0], raw SDRAM
# fetch latch[7:0], delivered GCR byte[7:0]} — separates zero-SDRAM-content
# (raw==0 at correct 0..6143 track-0 addrs) from fetch-address faults from
# encoder faults. sel-3 exposes floppy-download acceptance counters.
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
# PFL1 source = {arm[10], sel[9:8], addr[7:0]}
# sel: 0=live  1=ring[addr]  2=status  3=download counters (addr[1:0] picks)
# status = {8'hB5 magic, done[23], capturing[22], 2'b00, arm_cnt[19:16], 6'd0, wptr[9:0]}
# ring word = {gcrReadAddr[15:0], raw[7:0], enc[7:0]} of strobe #addr
# sel3: 0={8'hD1,4'd0,dl_words[19:0]} 1={8'hD2,4'd0,dl_nonzero[19:0]}
#       2={8'hD3, ds,ss,mfm,hd, dio_addr[19:0]} 3={8'hD4,8'd0,dl_xor[15:0]}
#       (D1..D4 = read-back magics)

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
    puts [format "RING: done=%d capturing=%d arm_cnt=%d strobes=%d" \
        $done $cap $armc $wptr]
    if {$pfl0 >= 0} {
        set f0 [rdi $pfl0]
        if {$f0 >= 0} {
            puts [format "PFL0: byte_cnt=%u miss_cnt=%u" \
                [expr {($f0 >> 16) & 0xFFFF}] [expr {$f0 & 0xFFFF}]]
        }
    }
    return $wptr
}

# sel-3 download counters. Warn-only (an older enc-only build muxes sel3 to
# the live word, so the D1/D2/D3 magics won't match — status must still work).
proc show_dl {} {
    global pfl1
    set magics {0xD1 0xD2 0xD3 0xD4}
    set vals {}
    for {set k 0} {$k < 4} {incr k} {
        if {![wsi $pfl1 [expr {0x300 | $k}]]} { bail "sel3 source write failed" }
        after 5
        set v [rdi $pfl1]
        if {$v < 0} { bail "sel3 read failed" }
        if {((($v >> 24) & 0xFF)) != [lindex $magics $k]} {
            puts [format "DL: sel3 magic mismatch at %d (got %08X) — pre-v2 build, skipping counters" $k $v]
            return
        }
        lappend vals $v
    }
    set words [expr {[lindex $vals 0] & 0xFFFFF}]
    set nz    [expr {[lindex $vals 1] & 0xFFFFF}]
    set v3    [lindex $vals 2]
    set dlxor [expr {[lindex $vals 3] & 0xFFFF}]
    puts [format "DL: dl_words=%u (expect 409600 for 800K) dl_nonzero=%u dl_xor=0x%04X" \
        $words $nz $dlxor]
    puts [format "DL: size-latch ds=%d ss=%d mfm=%d hd=%d  last dio_addr=0x%05X (%u)" \
        [expr {($v3 >> 23) & 1}] [expr {($v3 >> 22) & 1}] \
        [expr {($v3 >> 21) & 1}] [expr {($v3 >> 20) & 1}] \
        [expr {$v3 & 0xFFFFF}] [expr {$v3 & 0xFFFFF}]]
    puts "DL: (reference dl_nonzero/dl_xor for the mounted image: scripts/raw_compare.py)"
}

if {$cmd eq "status"} {
    show_status [read_status]
    show_dl
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
show_dl
if {$wptr == 0} {
    wsi $pfl1 0
    catch {end_insystem_source_probe}
    puts "ring is EMPTY — arm first, then mount the disk"
    exit 1
}
if {$wptr > 256} { set wptr 256 }
puts "sweeping $wptr strobes (~[expr {$wptr / 40}] s)..."
set encs {}
set raws {}
set addrs {}
for {set w 0} {$w < $wptr} {incr w} {
    if {![wsi $pfl1 [expr {0x100 | $w}]]} { bail "addr write failed at word $w" }
    after 5
    set v [rdi $pfl1]
    if {$v < 0} { bail "ring read failed at word $w" }
    lappend encs  [expr {$v & 0xFF}]
    lappend raws  [expr {($v >> 8) & 0xFF}]
    lappend addrs [expr {($v >> 16) & 0xFFFF}]
}
wsi $pfl1 0
catch {end_insystem_source_probe}
set bytes $encs   ;# the framing scan below operates on the delivered GCR stream

# ---- output + GCR framing scan (all offline from here — JTAG is done) ----
set fh [open $outfile w]
proc out {line} { global fh; puts $line; puts $fh $line }

set n [llength $bytes]
out "# floppy_ring dump v2 — [clock format [clock seconds]] — $n strobes (earliest first)"
out "# columns: strobe#  gcrReadAddr(hex)  sec/off(track-0 decode)  raw  enc"
for {set i 0} {$i < $n} {incr i} {
    set a [lindex $addrs $i]
    out [format "S%03d: %04X  %2d/%03d  %02X %02X" $i $a \
        [expr {$a >> 9}] [expr {$a & 0x1FF}] \
        [lindex $raws $i] [lindex $bytes $i]]
}
out ""
out "ENC hexdump (delivered GCR stream):"
for {set i 0} {$i < $n} {incr i 16} {
    set row {}
    for {set j $i} {$j < $n && $j < $i + 16} {incr j} {
        lappend row [format %02X [lindex $bytes $j]]
    }
    out [format "%04X: %s" $i [join $row " "]]
}
out ""
out "RAW hexdump (pre-encoder SDRAM fetch latch):"
for {set i 0} {$i < $n} {incr i 16} {
    set row {}
    for {set j $i} {$j < $n && $j < $i + 16} {incr j} {
        lappend row [format %02X [lindex $raws $j]]
    }
    out [format "%04X: %s" $i [join $row " "]]
}
out ""
out "FLAT-ENC (for offline grep/diff):"
set flat ""
foreach b $bytes { append flat [format %02X $b] }
for {set i 0} {$i < [string length $flat]} {incr i 128} {
    out [string range $flat $i [expr {$i + 127}]]
}
out ""
out "FLAT-RAW:"
set flat ""
foreach b $raws { append flat [format %02X $b] }
for {set i 0} {$i < [string length $flat]} {incr i 128} {
    out [string range $flat $i [expr {$i + 127}]]
}
out ""

# raw-stream + addr-walk verdict material
set raw_nz 0
foreach b $raws { if {$b != 0} { incr raw_nz } }
set amin 0xFFFF; set amax 0
foreach a $addrs {
    if {$a < $amin} { set amin $a }
    if {$a > $amax} { set amax $a }
}
out "==================== raw-fetch scan ===================="
out [format "raw nonzero: %d / %d strobes" $raw_nz $n]
out [format "gcrReadAddr range: %04X..%04X (track-0 data lives at 0000..17FF)" $amin $amax]
if {$raw_nz == 0 && $amax <= 0x17FF} {
    out "VERDICT HINT: raw==0 at CORRECT track-0 addresses -> the SDRAM disk-image"
    out "  region itself reads back zero: content bug is in the DOWNLOAD path"
    out "  (cross-check dl_words/dl_nonzero above) or the region was clobbered."
} elseif {$raw_nz > 0 && $amax > 0x17FF} {
    out "VERDICT HINT: fetch address left the track-0 window -> address-walk fault"
    out "  (encoder position/track/side inputs) — inspect the S-table addr column."
} elseif {$raw_nz > 0} {
    out "VERDICT HINT: raw data IS arriving -> if enc is still all-96 zeros the"
    out "  encoder/idata handoff is at fault (contradicts the lbmactwo diff!)."
}
out "==========================================================="
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
    out "VERDICT HINT: NO address/data marks in this 256-byte window (can be"
    out "  normal if it landed mid-field — check the raw-fetch scan above and"
    out "  re-arm for another window before blaming framing)."
} else {
    out "VERDICT HINT: marks PRESENT -> framing partially OK; diff the address"
    out "  field + checksums + sync-run lengths against MAME decoded_800k_v3.txt"
}
out "==========================================================="
close $fh
puts "written: $outfile"
