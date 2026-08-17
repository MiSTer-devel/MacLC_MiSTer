/*
 68000 compatible bus-wrapper for TG68K
 */

module tg68k (
	input clk,
	input reset,
	input phi1,
	input phi2,
	input [1:0] cpu,

	input  dtack_n,
	output rw_n,
	output as_n,
	output uds_n,
	output lds_n,
	output [2:0] fc,
	output reset_n,

	output reg E,
	input E_div,
	output E_PosClkEn,
	output E_NegClkEn,
	output vma_n,
	input vpa_n,

	input br_n,
	output bg_n,
	input bgack_n,

	input [2:0] ipl,
	input berr,
	input [15:0] din,
	output [15:0] dout,
	output longword,        // 1 = current access is a 32-bit (longword) access
	output reg [31:0] addr,

	// Debug outputs
	output [1:0] busstate
);

wire  [1:0] tg68_busstate;
wire        tg68_clkena = phi1 && (s_state == 7 || tg68_busstate == 2'b01);
wire [31:0] tg68_addr;
wire [15:0] tg68_din;
reg  [15:0] tg68_din_r;
wire        tg68_uds_n;
wire        tg68_lds_n;
wire        tg68_rw;

// The tg68k core doesn't reliably support mixed usage of autovector and non-autovector
// interrupts, so the TG68K kernel switched to non-autovector interrupts, and the 
// auto-vectors are provided here.
wire auto_iack = fc == 3'b111 && !vpa_n;
wire [7:0] auto_vector = {4'h1, 1'b1, addr[3:1]};
assign tg68_din = auto_iack ? {auto_vector, auto_vector} : din;

reg         uds_n_r;
reg         lds_n_r;
reg         rw_r;
reg         as_n_r;

assign      as_n = as_n_r;
assign      uds_n = uds_n_r;
assign      lds_n = lds_n_r;
assign      rw_n = rw_r;

reg   [2:0] s_state;

always @(posedge clk) begin
	if (reset) begin
		s_state <= 0;
		as_n_r <= 1;
		rw_r <= 1;
		uds_n_r <= 1;
		lds_n_r <= 1;
	end else begin
		addr <= tg68_addr;

		if (phi1) begin

			if (s_state != 4) s_state <= s_state + 1'd1;
			if (busreq_ack || bus_granted) s_state <= s_state;
			if (tg68_busstate == 2'b01) s_state <= 0;

			case (s_state)
				1: if (tg68_busstate != 2'b01) begin
					rw_r <= tg68_rw;
					if (tg68_rw) begin
						uds_n_r <= tg68_uds_n;
						lds_n_r <= tg68_lds_n;
					end
					as_n_r <= 0;
				end
				3: if (tg68_busstate != 2'b01) begin
					if (!tg68_rw) begin
						uds_n_r <= tg68_uds_n;
						lds_n_r <= tg68_lds_n;
					end
				end
				7: rw_r <= 1;
				default :;
			endcase

		end else if (phi2) begin

			if (s_state != 4 || tg68_busstate == 2'b01 || !dtack_n || xVma || berr)
				s_state <= s_state + 1'd1;
			if ((busreq_ack || bus_granted) && !busrel_ack) s_state <= s_state;
			if (tg68_busstate == 2'b01) s_state <= 0;

			case (s_state)

				6: begin
					tg68_din_r <= tg68_din;
					uds_n_r <= 1;
					lds_n_r <= 1;
					as_n_r <= 1;
				end
				default :;
			endcase

		end
	end
end

// from FX68K
// E clock and counter, VMA
reg [3:0] eCntr;
reg rVma;
reg Vpai;
assign vma_n = rVma;

// Internal stop just one cycle before E falling edge
wire xVma = ~rVma & (eCntr == 8) & en_E;

assign E_PosClkEn = (phi2 & (eCntr == 5) & en_E);
assign E_NegClkEn = (phi2 & (eCntr == 9) & en_E);

reg en_E;

always @( posedge clk) begin
	if (reset) begin
		E <= 1'b0;
		eCntr <=0;
		rVma <= 1'b1;
		en_E <= 1'b1;
	end else begin
		if (phi1) begin
			Vpai <= vpa_n;
			if (E_div) en_E <= !en_E; else en_E <= 1'b1;
		end

		if (phi2 & en_E) begin
			if (eCntr == 9)
				E <= 1'b0;
			else if (eCntr == 5)
				E <= 1'b1;

			if (eCntr == 9)
				eCntr <= 0;
			else
				eCntr <= eCntr + 1'b1;
		end

		if (phi2 & s_state != 0 & ~Vpai & (eCntr == 3) & en_E)
			rVma <= 1'b0;
		else if (phi1 & eCntr == 0 & en_E)
			rVma <= 1'b1;
	end
end

// Bus arbitration
reg bg_n_r;
assign bg_n = bg_n_r;

// process the bus request at the start of any bus cycle
// (start at only instruction fetch doesn't work well with ACSI DMA)
wire busreq_ack = !br_n /*&& tg68_busstate == 0*/ && s_state == 0;
wire busrel_ack = bus_acked && !bgack;

reg bgack, bus_granted, bus_acked, bus_acked_d;

always @(posedge clk) begin
	if (reset) begin
		bg_n_r <= 1;
		bus_granted <= 0;
		bus_acked <= 0;
	end else begin
		if (phi1) begin
			bgack <= ~bgack_n;
			bus_acked_d <= bus_acked;
		end
		if (phi2) begin
			if (busreq_ack) begin
				bg_n_r <= 0;
				bus_granted <= 1;
				bus_acked <= bgack;
			end
			if (bus_granted && bgack) bus_acked <= 1;
			if (bus_granted && bus_acked_d) bg_n_r <= 1;
			if (busrel_ack) begin
				bus_acked <= 0;
				bus_granted <= 0;
			end
		end
	end
end

	// Hold BERR across the bus cycle. The external berr (e.g. FC=7 CPU-space probe)
	// is gated on AS being asserted, but AS deasserts at s_state 6 while the kernel
	// only samples berr at s_state 7 (when tg68_clkena pulses). Without holding it,
	// the kernel sees berr=0 at the sample point and never latches make_berr, so the
	// bus-error exception is missed. Latch berr for the duration of the cycle and
	// clear it at the next cycle boundary (s_state 0).
	reg berr_hold;
	always @(posedge clk) begin
		if (reset)
			berr_hold <= 1'b0;
		else if (phi1 && s_state == 0)
			berr_hold <= 1'b0;
		else if (berr)
			berr_hold <= 1'b1;
	end
	wire berr_held = berr | berr_hold;

`ifdef SIMULATION
	// ── Step-0 bus-cycle histogram (branch cpu-enhancements) ─────────────────
	// Measures clk (clk_sys) ticks per completed bus cycle — the clkena-to-
	// clkena period — binned by busstate and a coarse target class, plus the
	// count of internal (busstate==01) kernel steps. Dumped to bus_hist.log
	// once per simulated second (32.5M ticks); counters reset each window.
	// Parse with scripts/bus_hist_report.py. Sim-only: invisible to Quartus.
	integer bh_file;
	integer bh_len;
	integer bh_hist [0:2][0:5][0:63];
	integer bh_ticksum [0:2][0:5];
	reg        bh_active;
	reg [1:0]  bh_bs;
	reg [2:0]  bh_cls;
	reg        bh_sawvma;
	integer bh_ticks, bh_busy, bh_int_clkena, bh_win;
	integer bh_i, bh_j, bh_k;
	initial begin
		bh_file = $fopen("bus_hist.log", "w");
		bh_active = 0; bh_len = 0; bh_ticks = 0; bh_busy = 0;
		bh_int_clkena = 0; bh_win = 0;
		for (bh_i = 0; bh_i < 3; bh_i = bh_i + 1) begin
			for (bh_j = 0; bh_j < 6; bh_j = bh_j + 1) begin
				bh_ticksum[bh_i][bh_j] = 0;
				for (bh_k = 0; bh_k < 64; bh_k = bh_k + 1)
					bh_hist[bh_i][bh_j][bh_k] = 0;
			end
		end
	end
	// Coarse target class from the kernel address (stable across the cycle):
	// 0=RAM ($0-$9FFFFF; includes overlay-ROM reads during early boot)
	// 1=ROM ($Axxxxx)  2=VRAM ($F40000-$FBFFFF)  3=VPA peripheral
	// 4=DTACK I/O in $Fxxxxx (SCSI pseudo-DMA / unmapped)  5=other/32-bit
	// NB: high address bits DON'T route to class 5 wholesale — the ROM drives
	// I/O through 32-bit aliases ($50Fxxxxx) that the V8 serves via 24-bit
	// truncation. Only NuBus/PDS slot space ($F1-$FE) is genuinely separate.
	wire [2:0] bh_class_w =
		((tg68_addr[31:24] >= 8'hF1) &&
		 (tg68_addr[31:24] <= 8'hFE)) ? 3'd5 :
		(tg68_addr[23:20] == 4'hA)  ? 3'd1 :
		(tg68_addr[23:20] <  4'hA)  ? 3'd0 :
		(tg68_addr[23:20] == 4'hF)  ? (((tg68_addr[19:18] == 2'b01) ||
		                                (tg68_addr[19:18] == 2'b10)) ? 3'd2 : 3'd3) :
		                              3'd5;
	always @(posedge clk) begin
		if (!reset) begin
			bh_ticks = bh_ticks + 1;
			if (bh_active) begin
				bh_len  = bh_len + 1;
				bh_busy = bh_busy + 1;
				if (!rVma) bh_sawvma = 1;
			end
			if (phi1 && tg68_busstate == 2'b01) bh_int_clkena = bh_int_clkena + 1;
			// cycle END: the kernel-clocking edge (s_state 7 at phi1)
			if (bh_active && phi1 && s_state == 3'd7) begin
				bh_i = (bh_bs == 2'b00) ? 0 : ((bh_bs == 2'b10) ? 1 : 2);
				bh_j = ((bh_cls == 3'd3) && !bh_sawvma) ? 4 : {29'd0, bh_cls};
				bh_k = (bh_len > 63) ? 63 : bh_len;
				bh_hist[bh_i][bh_j][bh_k] = bh_hist[bh_i][bh_j][bh_k] + 1;
				bh_ticksum[bh_i][bh_j] = bh_ticksum[bh_i][bh_j] + bh_len;
				bh_active = 0;
			end
			// cycle START: the edge that moves s_state 0 -> 1 (phi2, non-internal)
			if (!bh_active && phi2 && s_state == 3'd0 && tg68_busstate != 2'b01
			    && !(busreq_ack || bus_granted)) begin
				bh_active = 1;
				bh_len    = 1;
				bh_sawvma = 0;
				bh_bs     = tg68_busstate;
				bh_cls    = bh_class_w;
			end
			// window dump: once per simulated second
			if (bh_ticks >= 32500000) begin
				$fwrite(bh_file, "WINDOW %0d ticks=%0d busy=%0d int_clkena=%0d\n",
				        bh_win, bh_ticks, bh_busy, bh_int_clkena);
				for (bh_i = 0; bh_i < 3; bh_i = bh_i + 1) begin
					for (bh_j = 0; bh_j < 6; bh_j = bh_j + 1) begin
						if (bh_ticksum[bh_i][bh_j] != 0) begin
							$fwrite(bh_file, "T %0d %0d %0d\n",
							        bh_i, bh_j, bh_ticksum[bh_i][bh_j]);
							bh_ticksum[bh_i][bh_j] = 0;
						end
						for (bh_k = 0; bh_k < 64; bh_k = bh_k + 1) begin
							if (bh_hist[bh_i][bh_j][bh_k] != 0) begin
								$fwrite(bh_file, "H %0d %0d %0d %0d\n",
								        bh_i, bh_j, bh_k, bh_hist[bh_i][bh_j][bh_k]);
								bh_hist[bh_i][bh_j][bh_k] = 0;
							end
						end
					end
				end
				$fflush(bh_file);
				bh_ticks = 0; bh_busy = 0; bh_int_clkena = 0;
				bh_win = bh_win + 1;
			end
		end
	end
`endif

	TG68KdotC_Kernel tg68k (
		.clk            ( clk           ),
		.nReset         ( ~reset        ),
		.clkena_in      ( tg68_clkena   ),
		.data_in        ( tg68_din_r    ),
		.IPL            ( ipl           ),
		.IPL_autovector ( 1'b0          ),
		.berr           ( berr_held     ),
		.clr_berr       ( /*tg68_clr_berr*/ ),
		.CPU            ( cpu           ), // 00->68000  01->68010  11->68020(only some parts - yet)
		.addr_out       ( tg68_addr     ),
		.data_write     ( dout          ),
		.nUDS           ( tg68_uds_n    ),
		.nLDS           ( tg68_lds_n    ),
		.nWr            ( tg68_rw       ),
		.busstate       ( tg68_busstate ), // 00-> fetch code 10->read data 11->write data 01->no memaccess
		.longword       ( longword      ),
		.nResetOut      ( reset_n       ),
		.FC             ( fc            )
	);

	`ifdef VERBOSE_TRACE
	always @(posedge clk) begin
		if (tg68_clkena && tg68_busstate == 2'b00)
			$display("TG68: FETCH PC=%h opcode=%h @%0t", tg68_addr, tg68_din_r, $time);
	end
	`endif
// Expose busstate for debugging
assign busstate = tg68_busstate;

endmodule
