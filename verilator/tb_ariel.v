/* tb_ariel.v — Ariel RAMDAC CLUT write/readback semantics.
 *
 * Guards the palette_latch reload path: the latch used to be loaded from the
 * palette array in the same cycle as the access (palette[data_in] /
 * palette[palette_addr+1]); those extra read addresses forced Quartus to
 * build a 6,144-FF copy of the CLUT plus wide read muxes (~2.3k ALMs). The
 * reload now comes from a shadow M10K read port one cycle later (latch_pend).
 * This TB proves the CPU-visible semantics are unchanged:
 *   T1 full entry write + readback (latch load on REG_ADDR write)
 *   T2 sequential entries via auto-increment (wrap reload on write AND read)
 *   T3 partial component write = read-modify-write through the latch
 *   T4 address wrap 255->0 and address-register readback
 *   T5 video lookup port
 *   T6 REG_ADDR read resets the component counter but not the latch
 * Each access holds mem_latch two cycles (double pulse), so the ariel_armed
 * one-shot is exercised on every access.
 *
 * Run (from verilator/):
 *   verilator --binary --timing -Mdir obj_tb_ariel -o Vtb_ariel \
 *       tb_ariel.v ../rtl/ariel_ramdac.sv --top-module tb_ariel
 *   ./obj_tb_ariel/Vtb_ariel
 * Differential: the same TB passes on the pre-shadow RTL (same-cycle loads).
 */

`timescale 1ns/1ps

module tb_ariel;

	reg clk = 0;
	always #15.625 clk = ~clk;

	reg        reset = 1;
	reg [10:0] reg_addr = 0;
	reg        uds_n = 1, lds_n = 1;
	reg [7:0]  data_in = 0;
	wire [7:0] data_out;
	reg        we = 0, req = 0, mem_latch = 0;
	reg        cpu_as_n = 1;
	reg [7:0]  pixel_index = 0;
	wire [23:0] rgb_out;
	wire       ariel_written;

	ariel_ramdac dut(
		.clk_sys(clk), .clk_pix(clk), .reset(reset),
		.reg_addr(reg_addr), .uds_n(uds_n), .lds_n(lds_n),
		.data_in(data_in), .data_out(data_out),
		.we(we), .req(req), .mem_latch(mem_latch), .cpu_as_n(cpu_as_n),
		.pixel_index(pixel_index), .rgb_out(rgb_out),
		.ariel_written(ariel_written));

	localparam REG_A = 2'd0;  // address register  (A1=0, UDS)
	localparam REG_P = 2'd1;  // palette data      (A1=0, LDS)

	integer errors = 0;
	integer i;
	reg [7:0] r0;

	// One CPU bus access. byte_reg = {A1, ~lds_n}; exactly one strobe active.
	task access(input isw, input [1:0] sel, input [7:0] wdata, output [7:0] rdata);
		begin
			@(negedge clk);
			reg_addr  = {10'b0, sel[1]};
			lds_n     = ~sel[0];
			uds_n     = sel[0];
			we        = isw;
			data_in   = wdata;
			req       = 1;
			cpu_as_n  = 0;
			@(negedge clk);       // AS low before the latch slot
			mem_latch = 1;
			@(negedge clk);
			@(negedge clk);       // held 2 cycles: one-shot must ignore the 2nd
			mem_latch = 0;
			@(negedge clk);
			rdata = data_out;
			req = 0; cpu_as_n = 1; uds_n = 1; lds_n = 1; we = 0;
			repeat (4) @(negedge clk);  // re-arm + latch reload settle
		end
	endtask

	reg [7:0] wr_dummy;
	task wr(input [1:0] sel, input [7:0] v);
		access(1, sel, v, wr_dummy);
	endtask
	task rd(input [1:0] sel, output [7:0] v);
		access(0, sel, 8'h00, v);
	endtask

	task expect8(input [7:0] got, input [7:0] want, input [127:0] name);
		if (got !== want) begin
			$display("FAIL %0s: got %02x want %02x", name, got, want);
			errors = errors + 1;
		end
	endtask

	initial begin
		repeat (8) @(negedge clk);
		reset = 0;
		repeat (300) @(negedge clk);   // reset init sweep (256 entries) + margin

		// T1: single entry write + readback
		wr(REG_A, 8'd5);
		wr(REG_P, 8'h11); wr(REG_P, 8'h22); wr(REG_P, 8'h33);
		wr(REG_A, 8'd5);
		rd(REG_P, r0); expect8(r0, 8'h11, "T1.R");
		rd(REG_P, r0); expect8(r0, 8'h22, "T1.G");
		rd(REG_P, r0); expect8(r0, 8'h33, "T1.B");

		// T2: three sequential entries through the auto-increment (the write
		// loop exercises the write-wrap reload, the read loop the read-wrap)
		wr(REG_A, 8'd10);
		for (i = 0; i < 9; i = i + 1) wr(REG_P, 8'h40 + i[7:0]);
		wr(REG_A, 8'd10);
		for (i = 0; i < 9; i = i + 1) begin
			rd(REG_P, r0); expect8(r0, 8'h40 + i[7:0], "T2.seq");
		end

		// T3: writing only R of entry 11 must keep its G/B (latch RMW)
		wr(REG_A, 8'd11);
		wr(REG_P, 8'hAA);
		wr(REG_A, 8'd11);
		rd(REG_P, r0); expect8(r0, 8'hAA, "T3.R");
		rd(REG_P, r0); expect8(r0, 8'h44, "T3.G");
		rd(REG_P, r0); expect8(r0, 8'h45, "T3.B");

		// T4: address wraps 255 -> 0; address register reads back 1 after
		wr(REG_A, 8'd255);
		wr(REG_P, 8'h01); wr(REG_P, 8'h02); wr(REG_P, 8'h03);
		wr(REG_P, 8'h04); wr(REG_P, 8'h05); wr(REG_P, 8'h06);
		rd(REG_A, r0); expect8(r0, 8'd1, "T4.addr");
		wr(REG_A, 8'd0);
		rd(REG_P, r0); expect8(r0, 8'h04, "T4.R0");
		rd(REG_P, r0); expect8(r0, 8'h05, "T4.G0");
		rd(REG_P, r0); expect8(r0, 8'h06, "T4.B0");

		// T5: video lookup port sees entry 5
		pixel_index = 8'd5;
		repeat (3) @(negedge clk);
		if (rgb_out !== 24'h112233) begin
			$display("FAIL T5.video: got %06x want 112233", rgb_out);
			errors = errors + 1;
		end

		// T6: REG_ADDR read resets the component counter, not the latch
		wr(REG_A, 8'd10);
		rd(REG_P, r0);                       // R of entry 10, comp -> 1
		rd(REG_A, r0); expect8(r0, 8'd10, "T6.addr");
		rd(REG_P, r0); expect8(r0, 8'h40, "T6.Ragain");

		if (errors == 0) $display("tb_ariel: ALL PASS");
		else begin
			$display("tb_ariel: %0d FAILURES", errors);
			$fatal;
		end
		$finish;
	end

	initial begin
		#10_000_000;
		$display("tb_ariel: TIMEOUT");
		$fatal;
	end

endmodule
