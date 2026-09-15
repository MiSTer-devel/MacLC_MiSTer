# Name the combinational loop(s) TimeQuest is estimating through.
#
# HISTORY. Written 2026-09-15 when MacLC.sdc's kernel-cap note attributed the
# TG68 loop to "setexecOPC feeding the setstate mux trees" and a read of the RTL
# did not support that. The first version called `report_loops`, which is NOT a
# TimeQuest command in Quartus 17.0 ("invalid command name"). It was never
# needed anyway: TimeQuest prints every loop it finds while building the timing
# netlist, as Warning 332125 ("Found combinational loop of N nodes File: ...
# Line: ...") followed by one Warning 332126 line per node — and those lines are
# already in output_files/MacLC.sta.rpt (and .fit.rpt) after every compile.
#
# The 2026-09-15 loop (132 nodes) was named from exactly that list: setexecOPC
# -> datatype (MULU/MULS override) -> EA-build (An) test -> setstate ->
# setexecOPC. It is gone as of branch tg68-break-comb-loop; see
# docs/tg68_comb_loop_plan.md.
#
# WHAT THIS SCRIPT DOES NOW. Rebuilds the timing netlist and lets TimeQuest
# print the loop warnings, then says what to grep for. Use it on a project
# whose last compile you do not have the reports of; otherwise just:
#   grep -n "332125\|332126" output_files/MacLC.sta.rpt
#
# Usage (project must NOT be mid-compile — quartus_sta takes the project DB):
#   "$QUARTUS_BIN/quartus_sta" -t scripts/report_loops.tcl
project_open MacLC
create_timing_netlist -model slow
read_sdc
update_timing_netlist
puts "===== COMBINATIONAL LOOPS ====="
puts "Any loop is listed ABOVE as Warning (332125) with one Warning (332126) line per node."
puts "No 332125 above means TimeQuest found no combinational loop in this netlist."
project_close
