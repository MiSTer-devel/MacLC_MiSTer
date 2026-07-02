# Read the MacLC JTAG In-System probes and decode them.
# Deck: PADR PSTA PACT PIFA PIFD PDRD PSCS PSC2 PSC3 PSCW PSNC PSWL PSC6
#       PVID   (defined in rtl/dbg_probes.sv; PASC/PAUD audio probes removed)
#
#   quartus_stp_tcl -t scripts/cpu_state.tcl     (or: bash scripts/read_probes.sh)
#
# Ported from lbmactwo_MiSTer scripts/cpu_state.tcl (same cable detection,
# MacLC probe deck + layouts).

# Pick the cable + device portably: prefer a DE-SoC cable (the DE10-Nano
# on-board USB-Blaster II), else any cable whose chain has a Cyclone V (5CSE).
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

# ---- liveness: sample counters twice -------------------------------------
set act0  [rd PACT]
set ifa0  [rd PIFA]
after 200
set act1  [rd PACT]
set ifa1  [rd PIFA]

puts "================ MacLC probes ================"
puts [format "PACT bus cycles : %u -> %u  (%s)" $act0 $act1 \
    [expr {$act1 == $act0 ? "FROZEN — CPU wedged in one bus cycle" : "advancing"}]]
set ifc0 [expr {($ifa0 >> 24) & 0xFF}]
set ifc1 [expr {($ifa1 >> 24) & 0xFF}]
puts [format "PIFA last IF    : %06X (ifcnt %u -> %u, %s)" \
    [expr {$ifa1 & 0xFFFFFF}] $ifc0 $ifc1 \
    [expr {$ifc1 == $ifc0 ? "NO instruction fetches" : "fetching"}]]

set padr [rd PADR]
set a [expr {$padr & 0xFFFFFF}]
set region "?"
if {($a & 0xE00000) == 0xE00000} { set region "I/O (F0xxxx)" } \
elseif {$a < 0x800000}           { set region "RAM" } \
else                             { set region "high" }
puts [format "PADR cpuAddr    : %06X  (%s)" $a $region]

# ---- PSTA decode ----------------------------------------------------------
set sta [rd PSTA]
set fc [expr {$sta & 7}]
puts [format "PSTA            : %08X" $sta]
puts [format "  FC=%d RW=%d UDS_n=%d LDS_n=%d DTACK_n=%d VPA_n=%d AS_n=%d IPL_n=%d%d%d" \
    $fc [expr {($sta>>3)&1}] [expr {($sta>>4)&1}] [expr {($sta>>5)&1}] \
    [expr {($sta>>6)&1}] [expr {($sta>>7)&1}] [expr {($sta>>24)&1}] \
    [expr {($sta>>23)&1}] [expr {($sta>>22)&1}] [expr {($sta>>21)&1}]]
set sels {}
foreach {bit nm} {8 SCC 9 IWM 10 VIA 11 PseudoVIA 12 Ariel 13 ASC 14 RAM 15 ROM 16 VRAM 17 SCSI 18 SCSIDMA} {
    if {($sta >> $bit) & 1} { lappend sels $nm }
}
puts [format "  selects={%s}  scsiDREQ=%d scsiIRQ=%d" [join $sels ,] \
    [expr {($sta>>19)&1}] [expr {($sta>>20)&1}]]

# ---- PIFD / PDRD pairs ----------------------------------------------------
set ifd [rd PIFD]
puts [format "PIFD IF pair    : PC16=%04X opcode=%04X   (sample_loop.tcl for the full loop)" \
    [expr {($ifd>>16)&0xFFFF}] [expr {$ifd&0xFFFF}]]

# ---- PEXC / PEX2 / PEX3: exception-vector latches ---------------------------
if {[info exists idx(PEXC)]} {
    set ex [rd PEXC]
    set vn {- - BUSERR ADDRERR ILLEGAL DIV0 CHK TRAPV PRIV TRACE}
    set vec [expr {($ex>>4)&0xF}]
    set cnt [expr {$ex&0xF}]
    if {$cnt == 0} {
        puts "PEXC exception  : (no fatal-vector fetch since config)"
    } else {
        puts [format "PEXC last fatal : faulting IF=%06X vec=%d (%s) fires(wrap16)=%d" \
            [expr {($ex>>8)&0xFFFFFF}] $vec [lindex $vn $vec] $cnt]
    }
}
if {[info exists idx(PEX3)]} {
    set e3 [rd PEX3]
    set icnt [expr {$e3&0xFF}]
    if {$icnt == 0} {
        puts "PEX3 1st ILLEGAL: (none since config)"
    } else {
        set e2 [rd PEX2]
        puts [format "PEX3 1st ILLEGAL: faulting IF=%06X  total illegals=%d" \
            [expr {($e3>>8)&0xFFFFFF}] $icnt]
        puts [format "PEX2 at 1st ill : last IF addr16=%04X OPCODE=%04X" \
            [expr {($e2>>16)&0xFFFF}] [expr {$e2&0xFFFF}]]
    }
}
set drd [rd PDRD]
set daf [expr {($drd>>16)&0xFFFF}]
set dfull [expr {0xF00000 | ($daf << 4)}]
set ddev "?"
if {($dfull & 0xFFE000) == 0xF10000} { set ddev [format "SCSI reg %d" [expr {($dfull>>4)&7}]] } \
elseif {($dfull & 0xFFE000) == 0xF06000 || ($dfull & 0xFFE000) == 0xF12000} { set ddev "SCSI DACK" } \
elseif {($dfull & 0xFFE000) == 0xF00000} { set ddev "VIA1" } \
elseif {($dfull & 0xFFE000) == 0xF26000} { set ddev "PseudoVIA" } \
elseif {($dfull & 0xFFE000) == 0xF14000} { set ddev "ASC" } \
elseif {($dfull & 0xFFE000) == 0xF16000} { set ddev "IWM" }
puts [format "PDRD I/O read   : %06X (%s) = %04X" $dfull $ddev [expr {$drd&0xFFFF}]]

# ---- PFR: restart flight recorder (rev 2: BERR/RTE capture) ------------------
if {[info exists idx(PFR0)]} {
    set f0 [rd PFR0]; set f1 [rd PFR1]; set f2 [rd PFR2]; set f3 [rd PFR3]
    set frozen [expr {($f0>>27)&1}]
    set cause  [expr {($f0>>24)&7}]
    set cn {none CPURESET-FALL RESET-INSTR - BERR-NEAR-DEATH}
    puts [format "PFR recorder    : frozen=%d cause=%s  rst_falls=%d instr_falls=%d berr_trigs=%d" \
        $frozen [lindex $cn $cause] \
        [expr {($f1>>28)&0xF}] [expr {($f1>>24)&0xF}] [expr {($f3>>24)&0xFF}]]
    if {$frozen} {
        puts [format "  faulting IF=%06X (prev %06X)" \
            [expr {$f0&0xFFFFFF}] [expr {$f1&0xFFFFFF}]]
        if {[expr {($f2>>24)&1}]} {
            puts [format "  handler RTE landed at: %06X then %06X   <-- garbage = TG68 frame bug confirmed" \
                [expr {$f2&0xFFFFFF}] [expr {$f3&0xFFFFFF}]]
        } else {
            puts "  (RTE not yet seen after trigger)"
        }
    }
}

# ---- PSDT: pseudo-DMA stall timeout ------------------------------------------
if {[info exists idx(PSDT)]} {
    set sd [rd PSDT]
    set mx [expr {$sd & 0x7FFFFF}]
    puts [format "PSDT dma timeout: berr_fires=%d  max_stall=%d cyc (~%.2f ms)" \
        [expr {($sd>>24)&0xFF}] $mx [expr {$mx / 32500.0}]]
}

# ---- PRC0 / PRT1-3: #3 reboot isolation (SCSI-abort trail + init entry) -------
# busrst = # of SCSI bus resets (driver aborts). sr2700 = # of boot-inits seen by
# opcode (move #$2700,sr; cold boot = 1, +1 if the reboot re-runs SR setup).
# When trail_frozen: PRT1/PRT2 = the 2 PCs at the 2nd SCSI bus reset (the driver
# abort path — disassemble these). PRT3 = the latest boot-init entry PC (where
# init re-enters). Disassemble all three against boot0.rom (off = addr & 0x7FFFF).
if {[info exists idx(PRC0)]} {
    set c [rd PRC0]
    puts [format "PRC0 reboot-iso : scsi_bus_resets=%d  boot_inits(move#2700,sr)=%d  trail_frozen=%d" \
        [expr {($c>>24)&0xFF}] [expr {($c>>16)&0xFF}] [expr {$c&1}]]
    puts [format "  PRT3 latest init-entry pc        = %06X  (where ROM init (re-)enters)" [expr {[rd PRT3]&0xFFFFFF}]]
    if {[expr {$c&1}]} {
        puts [format "  PRT1 cpu pc @ 2nd SCSI bus reset = %06X  (driver abort path)" [expr {[rd PRT1]&0xFFFFFF}]]
        puts [format "  PRT2 prev fetch                  = %06X" [expr {[rd PRT2]&0xFFFFFF}]]
    } else {
        puts "  PRT1/2 trail not frozen (< 2 SCSI bus resets since config)"
    }
}

# ---- PRST: reset-source recorder (#3 spontaneous reboot after Happy Mac) ------
# The CPU reset (dataController_top.sv:189) is forced ONLY by _systemReset
# (n_reset) low OR the Egret asserting egret_reset_680x0. PRST latches WHICH
# source pulled the line on the first reboot after the CPU started running.
#   first_src bits: [7]EGRET [6]pll_unlock [5]rom_notloaded [4]OSD/status0
#                   [3]button [2]pram_force_reset [1]RESET_in [0]rom_download
# first_src==0x80 (EGRET only, n_reset still high) ⟹ the Egret HC05 rebooted it.
proc _prst_srcname {s} {
    set n {}
    if {$s & 0x80} {lappend n EGRET}
    if {$s & 0x40} {lappend n pll_unlock}
    if {$s & 0x20} {lappend n rom_notloaded}
    if {$s & 0x10} {lappend n OSD_status0}
    if {$s & 0x08} {lappend n button}
    if {$s & 0x04} {lappend n pram_force_reset}
    if {$s & 0x02} {lappend n RESET_in}
    if {$s & 0x01} {lappend n rom_download}
    if {[llength $n] == 0} { return "(none)" }
    return [join $n +]
}
if {[info exists idx(PRST)]} {
    set p [rd PRST]
    set fsrc [expr {($p>>16)&0xFF}]
    set seen [expr {($p>>6)&1}]
    puts [format "PRST reset-src  : reboots=%d armed=%d seen=%d first_nreset=%d n_reset=%d" \
        [expr {($p>>24)&0xFF}] [expr {($p>>7)&1}] $seen [expr {($p>>5)&1}] [expr {($p>>4)&1}]]
    if {$seen} {
        puts [format "  FIRST reboot cause = %s (first_src=0x%02X)%s" \
            [_prst_srcname $fsrc] $fsrc \
            [expr {(($fsrc & 0x80) && !($fsrc & 0x7F)) ? "  <== EGRET HC05 asserted 68k reset" : ""}]]
    } else {
        puts "  FIRST reboot = (none captured since the CPU started running)"
    }
    puts [format "  live reset_src = %s (0x%02X)" [_prst_srcname [expr {($p>>8)&0xFF}]] [expr {($p>>8)&0xFF}]]
}

# ---- SCSI -----------------------------------------------------------------
set scs [rd PSCS]
set regnames {CDR/ODR ICR MR TCR CSR BSR IDR RST}
set rn [expr {(($scs>>16) >> 4) & 7}]
puts [format "PSCS last rd    : reg %d (%s) = %04X  img_seen=%d%d sd_rd=%d%d sd_wr=%d%d" \
    $rn [lindex $regnames $rn] [expr {$scs&0xFFFF}] \
    [expr {($scs>>27)&1}] [expr {($scs>>26)&1}] \
    [expr {($scs>>29)&1}] [expr {($scs>>28)&1}] \
    [expr {($scs>>31)&1}] [expr {($scs>>30)&1}]]

set p2 [rd PSC2]
if {[info exists idx(PSC2)]} {
    puts [format "PSC2 selection  : at_sel_data=%02X at-sel{out_en=%d bsy=%d tbsy=%d%d MOUNTED=%d%d} live{out_en=%d sel=%d bsy=%d tbsy=%d%d mounted=%d%d adb=%d data=%02X}" \
        [expr {($p2>>24)&0xFF}] \
        [expr {($p2>>23)&1}] [expr {($p2>>21)&1}] [expr {($p2>>20)&1}] [expr {($p2>>19)&1}] \
        [expr {($p2>>18)&1}] [expr {($p2>>17)&1}] \
        [expr {($p2>>15)&1}] [expr {($p2>>14)&1}] [expr {($p2>>13)&1}] \
        [expr {($p2>>12)&1}] [expr {($p2>>11)&1}] [expr {($p2>>10)&1}] [expr {($p2>>9)&1}] \
        [expr {($p2>>8)&1}] [expr {$p2&0xFF}]]
}

set phn {IDLE CMD_IN DATA_OUT(rd) DATA_IN(wr) STATUS MSG ph6? ph7?}
set p3 [rd PSC3]
puts [format "PSC3 phases     : t1=%s t0=%s  max t1=%s t0=%s  rst_lo4=%d" \
    [lindex $phn [expr {($p3>>21)&7}]] [lindex $phn [expr {($p3>>18)&7}]] \
    [lindex $phn [expr {($p3>>10)&7}]] [lindex $phn [expr {($p3>>6)&7}]] \
    [expr {($p3>>28)&0xF}]]
puts [format "  sd_ack_seen=%d%d io_ack_seen=%d%d live io_rd=%d%d io_wr=%d%d io_ack=%d%d" \
    [expr {($p3>>17)&1}] [expr {($p3>>16)&1}] [expr {($p3>>15)&1}] [expr {($p3>>14)&1}] \
    [expr {($p3>>5)&1}] [expr {($p3>>4)&1}] [expr {($p3>>3)&1}] [expr {($p3>>2)&1}] \
    [expr {($p3>>1)&1}] [expr {($p3>>0)&1}]]

set w [rd PSCW]
puts [format "PSCW busreset   : valid=%d count=%d | at 1st reset: max_phase=%s read_done=%d sel_seen=%d last_op=%02X | live: max_phase=%s read_done=%d" \
    [expr {($w>>31)&1}] [expr {($w>>19)&0x7F}] \
    [lindex $phn [expr {($w>>28)&7}]] [expr {($w>>27)&1}] [expr {($w>>26)&1}] [expr {($w>>11)&0xFF}] \
    [lindex $phn [expr {($w>>8)&7}]] [expr {($w>>7)&1}]]

set n [rd PSNC]
puts [format "PSNC dma engine : dreq=%d req=%d ack=%d dma_en=%d dma_ack=%d ack_busy=%d holdoff=%d mr_dma=%d pmatch=%d word=%d long=%d tcr=%X dack_beats=%d" \
    [expr {$n&1}] [expr {($n>>1)&1}] [expr {($n>>2)&1}] [expr {($n>>3)&1}] \
    [expr {($n>>4)&1}] [expr {($n>>5)&1}] [expr {($n>>6)&7}] [expr {($n>>9)&1}] \
    [expr {($n>>10)&1}] [expr {($n>>11)&1}] [expr {($n>>12)&1}] [expr {($n>>14)&0xF}] \
    [expr {($n>>18)&0x3FFF}]]

# ---- PSDS/PSD2/PSD3: active pseudo-DMA stall snapshot -------------------------
# Sticky latch of the live SCSI state the first time a DACK access is DREQ-starved
# past ~16 ms. Discriminates a residual stall: H1 (phase=DATA_OUT io_rd=1 io_ack=0
# io_busy=1), H2 (pmatch=0 / phase!=DATA_OUT), H3 (dma_en=0). See
# docs/findings_scsi_dma_stall_offline_2026-06-14.md.
if {[info exists idx(PSDS)]} {
    set s [rd PSDS]
    if {[expr {($s>>16)&1}]} {
        puts [format "PSDS stall-snap : CAPTURED  phase1=%s phase0=%s io_rd=%d%d io_wr=%d%d io_ack=%d%d" \
            [lindex $phn [expr {($s>>11)&7}]] [lindex $phn [expr {($s>>8)&7}]] \
            [expr {($s>>5)&1}] [expr {($s>>4)&1}] [expr {($s>>3)&1}] [expr {($s>>2)&1}] \
            [expr {($s>>1)&1}] [expr {$s&1}]]
        set sn [rd PSD2]
        puts [format "  PSD2 ncr-snap : dreq=%d req=%d ack=%d dma_en=%d dma_ack=%d ack_busy=%d holdoff=%d mr_dma=%d pmatch=%d word=%d long=%d tcr=%X" \
            [expr {$sn&1}] [expr {($sn>>1)&1}] [expr {($sn>>2)&1}] [expr {($sn>>3)&1}] \
            [expr {($sn>>4)&1}] [expr {($sn>>5)&1}] [expr {($sn>>6)&7}] [expr {($sn>>9)&1}] \
            [expr {($sn>>10)&1}] [expr {($sn>>11)&1}] [expr {($sn>>12)&1}] [expr {($sn>>14)&0xF}]]
        set sw [rd PSD3]
        puts [format "  PSD3 wr-snap  : data_cnt=%d phase=%s done=%d io_wr=%d io_ack=%d io_busy=%d buf_sel=%d cmd_write=%d tlen=%d req=%d" \
            [expr {$sw&0xFFFF}] [lindex $phn [expr {($sw>>16)&7}]] \
            [expr {($sw>>19)&1}] [expr {($sw>>20)&1}] [expr {($sw>>21)&1}] [expr {($sw>>22)&1}] \
            [expr {($sw>>23)&1}] [expr {($sw>>24)&1}] [expr {($sw>>25)&0x3F}] [expr {($sw>>31)&1}]]
    } else {
        puts "PSDS stall-snap : (no deep stall captured since reset)"
    }
}

set l [rd PSWL]
puts [format "PSWL irq/defer  : req_deferred=%d req_bus=%d irq_latch=%d dma_armed=%d eodma=%d dreq=%d pmatch=%d dma_en=%d blind_wr=%d req_drops=%d" \
    [expr {($l>>15)&1}] [expr {($l>>14)&1}] [expr {($l>>13)&1}] [expr {($l>>12)&1}] \
    [expr {($l>>11)&1}] [expr {($l>>10)&1}] [expr {($l>>9)&1}] [expr {($l>>8)&1}] \
    [expr {$l&0xFF}] [expr {($l>>16)&0xFFFF}]]

set c6 [rd PSC6]
puts [format "PSC6 rst/opcode : bus_resets=%d hs2 t1=%X t0=%X  last opcode t1=%02X t0=%02X" \
    [expr {($c6>>24)&0xFF}] [expr {($c6>>20)&0xF}] [expr {($c6>>16)&0xF}] \
    [expr {($c6>>8)&0xFF}] [expr {$c6&0xFF}]]

# ---- sound / video ---------------------------------------------------------
# PASC/PAUD audio probes were removed from the build; print only if present.
set s [rd PASC]
if {$s >= 0 && [info exists idx(PASC)]} {
    puts [format "PASC sound      : asc_irq_cnt=%d cpu_wr_cnt=%d" \
        [expr {($s>>16)&0xFFFF}] [expr {$s&0xFFFF}]]
}
set au [rd PAUD]
if {$au >= 0 && [info exists idx(PAUD)]} {
    set amax [expr {($au>>16)&0xFFFF}]; if {$amax > 0x7FFF} { set amax [expr {$amax-0x10000}] }
    set amin [expr {$au&0xFFFF}];       if {$amin > 0x7FFF} { set amin [expr {$amin-0x10000}] }
    puts [format "PAUD audio range: min=%d max=%d  (%s)" $amin $amax \
        [expr {$amin == 32767 && $amax == -32768 ? "no samples yet" :
         ($amin <= -32700 && $amax >= 32700 ? "FULL-SCALE (clipping?)" : "bounded")}]]
}
set v [rd PVID]
puts [format "PVID video      : vbl_cnt=%d clut_wr=%d vram_wr=%d video_config=%02X" \
    [expr {($v>>24)&0xFF}] [expr {($v>>16)&0xFF}] [expr {($v>>8)&0xFF}] [expr {$v&0xFF}]]

catch { end_insystem_source_probe }
