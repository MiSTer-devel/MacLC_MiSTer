/* tb_ism_read.v — targeted unit testbench for the SWIM ISM (MFM) read path.
 *
 * Drives the `swim` module with the EXACT register sequence the Mac LC's Sony
 * driver performs for a 1.44MB MFM read, captured from MAME 0.264 and recorded
 * in docs/findings_mame_floppy_groundtruth_2026-07-02.md section 6:
 *
 *     WR $F17E00: 57,17,57,57        ; IWM -> ISM (offset 0xF, bit6 = 1,0,1,1)
 *     ISM Setup = 20                 ; bit5=1 IBM, bit2=0 MFM read
 *     ModeClr 04 ; ModeSet 82        ; mode=C2: motor(b7) + devsel 01 = INT
 *     strobe MFMModeOn ($9) via Phases
 *     per field:  WR Phases F4 ; RD Error ; ModeClr 18 ;
 *                 ModeSet 01 ; ModeClr 01 ; ModeSet 08   <- ACTION rising = read
 *                 poll Handshake; when b7, pop reg1 (Mark)
 *
 * Runs in seconds; a full-System Verilator boot takes ~40 minutes. Prints the
 * popped byte stream so it can be diffed against scratch/flpsim/expect_track.py.
 *
 * Build + run (Verilator 5.x):
 *   verilator --binary -j 0 -Wno-fatal --timescale 1ns/1ps \
 *     -Irtl --top-module tb_ism_read verilator/tb_ism_read.v \
 *     rtl/swim.v rtl/floppy.v rtl/mfm_track_encoder.v rtl/floppy_track_encoder.v
 *   ./obj_dir/Vtb_ism_read
 */

`timescale 1ns/1ps

module tb_ism_read;

	// ---- clocking: 32 MHz clk with 8.125 MHz cep/cen enables (as in the core)
	reg clk = 0;
	always #15.625 clk = ~clk;          // 32 MHz

	reg [1:0] phase = 0;
	always @(posedge clk) phase <= phase + 1'b1;
	wire cep = (phase == 2'd0);
	wire cen = (phase == 2'd2);

	reg _reset = 0;

	// ---- CPU-side SWIM bus
	reg        selectSWIM = 0;
	reg        _cpuRW = 1;
	reg        _cpuUDS = 1;
	reg [15:0] dataIn = 0;
	reg [3:0]  cpuAddrRegHi = 0;
	reg        SEL = 0;          // VIA PA5 / HDSEL — side 0 for this test
	reg        driveSel = 1;
	wire [15:0] dataOut;

	// ---- disk image model: track 0 side 0 needs bytes 0..9215
	localparam IMG_WORDS = 16384;
	reg [7:0] img [0:IMG_WORDS-1];

	wire [21:0] dskReadAddrInt, dskReadAddrExt;
	reg         dskReadAckInt = 0;
	wire        dskReadAckExt = 1'b0;
	wire [7:0]  dskReadData = (dskReadAddrInt < IMG_WORDS) ? img[dskReadAddrInt] : 8'hE5;

	// Periodic fetch ack, mimicking addrController's extra bus slot (~2 us).
	// One cen-wide pulse; floppy.v latches on the following cep.
	integer ack_div = 0;
	always @(posedge clk) begin
		if (cen) begin
			ack_div <= ack_div + 1;
			if (ack_div >= 8) begin
				ack_div <= 0;
				dskReadAckInt <= 1'b1;
			end else
				dskReadAckInt <= 1'b0;
		end
	end

	swim dut (
		.clk(clk), .cep(cep), .cen(cen),
		._reset(_reset),
		.selectSWIM(selectSWIM),
		._cpuRW(_cpuRW),
		._cpuUDS(_cpuUDS),
		.dataIn(dataIn),
		.cpuAddrRegHi(cpuAddrRegHi),
		.SEL(SEL),
		.driveSel(driveSel),
		.dataOut(dataOut),
		.insertDisk(2'b01),      // internal drive: disk in
		.diskEject(),
		.diskSides(2'b01),
		.diskMFM(2'b01),         // internal disk is MFM
		.diskHD(2'b01),          // ... and 1.44MB HD
		.diskMotor(), .diskAct(),
		.dskReadAddrInt(dskReadAddrInt),
		.dskReadAckInt(dskReadAckInt),
		.dskReadAddrExt(dskReadAddrExt),
		.dskReadAckExt(dskReadAckExt),
		.dskReadData(dskReadData),
		.dbg_flp_byte_cnt(), .dbg_flp_miss_cnt(), .dbg_flp_disk_data(),
		.dbg_flp_track(), .dbg_flp_side(), .dbg_flp_step_cnt(),
		.dbg_iwm_latch(), .dbg_flp_byte_stb(), .dbg_flp_raw(), .dbg_flp_gcr_addr()
	);

	// ---- CPU access tasks (hold across >=1 cen, release across >=1 cen) ----
	task swim_wr(input [3:0] a, input [7:0] d);
	begin
		@(posedge clk);
		cpuAddrRegHi <= a; dataIn <= {8'h00, d}; _cpuRW <= 1'b0;
		selectSWIM <= 1'b1; _cpuUDS <= 1'b0;
		repeat (10) @(posedge clk);
		selectSWIM <= 1'b0; _cpuUDS <= 1'b1; _cpuRW <= 1'b1;
		repeat (10) @(posedge clk);
	end
	endtask

	task swim_rd(input [3:0] a, output [7:0] d);
	begin
		@(posedge clk);
		cpuAddrRegHi <= a; _cpuRW <= 1'b1;
		selectSWIM <= 1'b1; _cpuUDS <= 1'b0;
		repeat (10) @(posedge clk);
		d = dataOut[15:8];
		selectSWIM <= 1'b0; _cpuUDS <= 1'b1;
		repeat (10) @(posedge clk);
	end
	endtask

	// ---- captured pop stream ----
	integer  npop = 0;
	reg [7:0] popped  [0:4095];
	reg       popmark [0:4095];

	reg [7:0] v, hs;
	integer   i, guard, arms;
	integer   fh;

	initial begin
		$readmemh("track0.hex", img);

		// reset
		_reset = 0;
		repeat (40) @(posedge clk);
		_reset = 1;
		repeat (40) @(posedge clk);

		// --- IWM -> ISM: four accesses to offset 0xF, data bit6 = 1,0,1,1 ---
		swim_wr(4'hF, 8'h57);
		swim_wr(4'hF, 8'h17);
		swim_wr(4'hF, 8'h57);
		swim_wr(4'hF, 8'h57);
		swim_rd(4'h6, v);
		$display("TB: after switch, ISM mode reg = %02x (expect 40)", v);
		if (v !== 8'h40) begin
			$display("TB: FAIL — did not enter ISM mode");
			$finish;
		end

		// --- session init (MAME section 6) ---
		swim_wr(4'h5, 8'h20);            // Setup: IBM, MFM read datapath
		swim_rd(4'h5, v);
		$display("TB: setup readback = %02x (expect 20)", v);

		swim_wr(4'h6, 8'h04);            // ModeClr 04
		swim_wr(4'h7, 8'h82);            // ModeSet 82 -> mode C2 (motor + devsel INT)
		swim_rd(4'h6, v);
		$display("TB: mode = %02x (expect C2)", v);

		// Strobe MFMModeOn ($9): phases F1 -> F9 (LSTRB rise) -> F1.
		// The drive latches cmd = {SEL,ca2,ca1,ca0}, and SEL is VIA PA5 — the
		// driver raises PA5 for this strobe (MAME capture seq 641087/641095).
		// With SEL=0 the SAME phase pattern decodes as $1 StepOn and the head
		// walks off track instead of entering MFM mode.
		SEL = 1'b1;
		repeat (20) @(posedge clk);
		swim_wr(4'h4, 8'hF1);
		swim_wr(4'h4, 8'hF9);
		swim_wr(4'h4, 8'hF1);
		SEL = 1'b0;                      // back to side 0 for the read
		repeat (20) @(posedge clk);

		// let the drive spin up a little
		repeat (20000) @(posedge clk);

		// --- per-field read loop ---
		arms = 0;
		while (npop < 1400 && arms < 400) begin
			arms = arms + 1;
			swim_wr(4'h4, 8'hF4);        // park phases on RdData0
			swim_rd(4'h2, v);            // clear error
			swim_wr(4'h6, 8'h18);        // ModeClr 18 (ACTION,WRITE off)
			swim_wr(4'h7, 8'h01);        // ModeSet 01 \ pulse FIFO clear
			swim_wr(4'h6, 8'h01);        // ModeClr 01 /
			swim_rd(4'h2, v);
			swim_wr(4'h7, 8'h08);        // ModeSet 08 -> ACTION rising = READ START

			// poll handshake, pop through the Mark register (reg 1) as the
			// real driver does — including for data bytes.
			guard = 0;
			while (guard < 200000 && npop < 1400) begin
				guard = guard + 1;
				swim_rd(4'h7, hs);
				if (hs[7]) begin
					swim_rd(4'h1, v);
					popped[npop]  = v;
					popmark[npop] = hs[0];
					npop = npop + 1;
					guard = 0;
				end
			end
			swim_wr(4'h6, 8'h18);        // ModeClr 18 — end of this field
			if (guard >= 200000) begin
				$display("TB: hunt timed out on arm %0d with %0d pops", arms, npop);
				arms = 400;               // give up
			end
		end

		$display("TB: total pops = %0d over %0d arms", npop, arms);
		fh = $fopen("tb_pops.txt", "w");
		for (i = 0; i < npop; i = i + 1)
			$fwrite(fh, "SWIM-ISM: pop %02x m=%0d c0=0 pos=1\n", popped[i], popmark[i]);
		$fclose(fh);

		$write("TB: first 32 pops:");
		for (i = 0; i < 32 && i < npop; i = i + 1)
			$write(" %02x%s", popped[i], popmark[i] ? "m" : "");
		$write("\n");
		$finish;
	end

	// global watchdog
	initial begin
		#4000000000;
		$display("TB: WATCHDOG timeout, pops=%0d", npop);
		$finish;
	end

endmodule
