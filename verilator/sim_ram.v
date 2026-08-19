//
// sim_ram.v
//
// Simple RAM module for Verilator simulation of MacLC
// Replaces the SDRAM controller with synchronous RAM
//

module sim_ram
(
	// cpu/chipset interface - same as sdram.v
	input               clk,        // system clock
	input               reset,      // reset signal

	input [15:0]        din,        // data input from chipset/cpu
	output reg [15:0]   dout,       // data output to chipset/cpu (floppy windows)
	input [24:0]        addr,       // 25 bit word address
	input [1:0]         ds,         // upper/lower data strobe
	input               oe,         // cpu/chipset requests read
	input               we,         // cpu/chipset requests write

	// Phase C demand-start handshake — mirrors rtl/sdram.v with matched
	// latency: reads assert cpu_done (+cpu_dout) two clk edges after the
	// request is seen, writes post at the first edge. Keep the latencies in
	// sync with the FPGA controller or the sim measures fiction.
	input               flp_win,
	input  [23:0]       flp_addr,   // unregistered floppy address (mirrors rtl/sdram.v:
	                                // the floppy path must bypass the request pipeline or
	                                // its data lands one tick after floppy.v latches it)
	input               flp_guard,

	// download (HPS image write) port — mirrors rtl/sdram.v. The download
	// used to ride the CPU's own oe/we/addr/din nets; under Phase C's level
	// request that let its posted-write ack land in cpu_done and be consumed
	// by the CPU as its OWN DTACK (root cause of the floppy-mount bomb).
	input               dl_req,     // pending level (= ioctl_wait)
	input               dl_slot,    // its bus slot (dioBusControl)
	input  [23:0]       dl_addr,
	input  [15:0]       dl_din,
	output reg          dl_ack,

	output reg          cpu_done,
	output reg [15:0]   cpu_dout,

	input [31:0]        frame_count // frame counter for debug logging
);

// 16MB of RAM (8M words of 16 bits)
// Address bits [22:0] used, giving 8MW = 16MB
// SDRAM layout: motherboard $000000, SIMM $100000, ROM $500000, VRAM $580000, floppies $600000+
reg [15:0] mem [0:8388607];  // 8M words = 16MB

// Debug counters
integer wr_count = 0;
integer rom_rd_count = 0;

reg        req_d;         // read request seen last edge (models ACTIVE->done)
wire cpu_req  = (oe || we) && !flp_win && !flp_guard;

always @(posedge clk) begin
	// Writes are allowed even during reset (needed for ROM loading).
	// !flp_win: with the Phase-C un-slotted _ramWE a pending CPU write's
	// `we` can be high during a floppy fetch window while `addr` is the
	// FLOPPY image address — committing then would corrupt the disk image.
	// (The FPGA controller is safe by construction: flp accesses force
	// we_latch=0 and CPU starts are blocked during windows.)
	if (we && |ds && !flp_win) begin
		if (ds[1]) mem[addr[22:0]][15:8] <= din[15:8];
		if (ds[0]) mem[addr[22:0]][7:0]  <= din[7:0];
		wr_count <= wr_count + 1;
		`ifdef VERBOSE_TRACE
		// Log first 10 writes and every 50000th after that
		if (wr_count < 10 || wr_count % 50000 == 0)
			$display("[F%0d] sim_ram WR[%0d]: addr=%h din=%h ds=%b",
				frame_count, wr_count, addr[22:0], din, ds);
		`endif
	end

	// download write — its own request, never touching cpu_done
	if (dl_req && dl_slot && !dl_ack) begin
		mem[dl_addr[22:0]] <= dl_din;
		dl_ack <= 1;
	end
	if (!dl_req) dl_ack <= 0;

	// floppy-window read serve (legacy dout path and timing). No oe
	// qualifier: oe is pure CPU intent now; the window itself IS the
	// floppy read request (mirrors rtl/sdram.v req_flp).
	if (flp_win) dout <= mem[flp_addr[22:0]];

	// demand handshake
	if (reset) begin
		cpu_done <= 0;
		req_d    <= 0;
		dl_ack   <= 0;
	end else if (!(oe || we)) begin
		cpu_done <= 0;         // AS released / request withdrawn
		req_d    <= 0;
	end else if (cpu_req && !cpu_done) begin
		if (we) begin
			cpu_done    <= 1;  // posted write (commit is the block above)
			req_d       <= 0;
		end else begin
			req_d <= 1;
			if (req_d) begin
				cpu_dout    <= mem[addr[22:0]];
				cpu_done    <= 1;
				end
		end
	end

	if (reset) begin
		rom_rd_count <= 0;
	end else begin
		if (oe && req_d && !cpu_done) begin
			// Log first 20 ROM reads only
			if (addr[22:0] >= 23'h500000 && addr[22:0] < 23'h540000 && rom_rd_count < 20) begin
				$display("[F%0d] sim_ram RD_ROM[%0d]: addr=%h dout=%h",
					frame_count, rom_rd_count, addr[22:0], mem[addr[22:0]]);
				rom_rd_count <= rom_rd_count + 1;
			end
		end
	end
end

// Allow ROM/RAM initialization from simulation
// verilator tracing_off
/* verilator lint_off UNUSED */
integer init_i;
initial begin
	// Deterministic power-up content. With Verilator's --x-initial fast the
	// uninitialized array pattern VARIES PER BUILD, and the boot ROM's
	// VRAM/video probe reads unwritten bytes — so adding a mere $display
	// could change which boot path the ROM takes (seen 2026-08-17 during
	// the magenta hunt: two builds of the same RTL took different
	// mode-probe branches). 16'hFFFF is chosen DELIBERATELY: it selects
	// the diskless ?-icon probe branch — the harder path, whose
	// probe-writes-into-ROM-space idiom caught two real Phase-C bugs
	// (docs/CPU_Perf_Log.md). Boot gate on this path: grey dither desktop
	// + arrow cursor + centered flashing-? disk icon at frame 450.
	for (init_i = 0; init_i < 8388608; init_i = init_i + 1)
		mem[init_i] = 16'hFFFF;
	cpu_dout = 16'h0000;
	dout     = 16'h0000;
end
/* verilator lint_on UNUSED */
// verilator tracing_on

endmodule
