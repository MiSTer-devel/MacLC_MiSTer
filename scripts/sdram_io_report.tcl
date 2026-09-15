# SDRAM interface timing report — run AFTER a fit, against the constraints in
# MacLC.sdc (2026-09-12). Reports the read data eye at the I/O-cell capture
# register and the write/command margin at the chip, i.e. the numbers that used
# to be invisible because the SDRAM pins were unconstrained.
#
#   quartus_sta -t scripts/sdram_io_report.tcl [outdir]
#
# Expect roughly +2.2 ns setup / +6.5 ns hold on the read side and +4 / +6 on
# the write side, and — the whole point — essentially the SAME numbers on every
# fitter seed, because sd_data_q is packed into the I/O cell and has no fabric
# route for a seed to reshuffle. The "stage" lines are the internal hand-offs
# behind it (sd_data_q -> sd_data_r full period; sd_data_r -> cpu_dout/eth_dout
# and dout -> the floppy latch half period); they must all be positive too.
# See docs/plan_sdram_read_capture_2026-09-12.md.

set outdir "."
if {[info exists quartus(args)] && [llength $quartus(args)] >= 1} {
	set outdir [lindex $quartus(args) 0]
}
file mkdir $outdir

project_open MacLC
create_timing_netlist
read_sdc
update_timing_netlist

# Never let a missing register or an empty path collection abort the report —
# a chain build must still produce every other number.
proc slack {desc args} {
	set n 0
	if {[catch {
		set p [eval get_timing_paths $args -npaths 1]
		foreach_in_collection q $p {
			puts [format "SDRAM_IO %-34s %8.3f" $desc [get_path_info $q -slack]]
			incr n
		}
	} err]} {
		puts [format "SDRAM_IO %-34s   ERROR: %s" $desc $err]
		return
	}
	if {$n == 0} { puts [format "SDRAM_IO %-34s   (no paths found)" $desc] }
}

proc safe_report {args} { if {[catch {eval report_timing $args} e]} { puts "SDRAM_IO report_timing skipped: $e" } }

set CAP [get_registers {*sdram|sd_data_q*}]
if {[get_collection_size $CAP] == 0} {
	puts "SDRAM_IO WARNING: no *sdram|sd_data_q* registers in this netlist."
	puts "SDRAM_IO          (pre-2026-09-12 RTL captured the pins directly at STATE_READ)"
}

slack "read  DQ -> sd_data_q  setup" -from_clock [get_clocks sdram_clk] -to $CAP -setup
slack "read  DQ -> sd_data_q  hold"  -from_clock [get_clocks sdram_clk] -to $CAP -hold
slack "write FPGA -> chip     setup" -to_clock   [get_clocks sdram_clk] -setup
slack "write FPGA -> chip     hold"  -to_clock   [get_clocks sdram_clk] -hold
# internal hand-offs behind the I/O-cell capture (rtl/sdram.v read-capture block)
set RET [get_registers {*sdram|sd_data_r*}]
set CON [get_registers {*sdram|cpu_dout* *sdram|eth_dout*}]
set FLP [get_registers {*sdram|dout[*}]
slack "stage sd_data_q -> sd_data_r setup" -from $CAP -to $RET -setup
slack "stage sd_data_q -> sd_data_r hold"  -from $CAP -to $RET -hold
slack "stage sd_data_q -> dout setup"      -from $CAP -to $FLP -setup
slack "stage sd_data_q -> dout hold"       -from $CAP -to $FLP -hold
slack "stage sd_data_r -> cpu/eth setup"   -from $RET -to $CON -setup
slack "stage sd_data_r -> cpu/eth hold"    -from $RET -to $CON -hold
slack "stage dout -> floppy latch setup"   -from $FLP -to [get_registers {*dskReadDataLatch*}] -setup
slack "stage dout -> floppy latch hold"    -from $FLP -to [get_registers {*dskReadDataLatch*}] -hold
slack "stage cpu_dout -> tg68_din_r setup" -from [get_registers {*sdram|cpu_dout*}] -to [get_registers {*tg68_din_r*}] -setup

safe_report -setup -from_clock [get_clocks sdram_clk] -to $CAP -npaths 4 -detail full_path -file "$outdir/sdram_read_setup.txt"
safe_report -hold  -from_clock [get_clocks sdram_clk] -to $CAP -npaths 4 -detail full_path -file "$outdir/sdram_read_hold.txt"
safe_report -setup -to_clock   [get_clocks sdram_clk] -npaths 4 -detail full_path -file "$outdir/sdram_write_setup.txt"
safe_report -hold  -to_clock   [get_clocks sdram_clk] -npaths 4 -detail full_path -file "$outdir/sdram_write_hold.txt"
report_ucp -file "$outdir/sdram_ucp.txt"

project_close
