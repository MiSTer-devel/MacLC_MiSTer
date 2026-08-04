/* tb_ism_step.v — can the head STEP while the SWIM is in ISM mode?
 *
 * Motivation (2026-08-04): the on-screen HUD on hardware showed
 * dbg_step_cnt == 0 and driveTrack == 0 for an ENTIRE 1.44MB copy session —
 * the MFM encoder was serving cylinder 0 forever while the driver tried to
 * read files that live further out. dbg_step_cnt alone cannot say whether
 * the driver never strobed or whether our decode rejected the strobe, so
 * this TB removes the guest from the picture: it issues the step sequence
 * ITSELF, both the IWM way and the ISM way, and checks driveTrack.
 *
 * Step protocol (floppy.v): a drive-register write is {ca1,ca0,SEL} latched
 * on the FALLING edge of lstrb with _enable low. STEP = 2 = {ca1=0,ca0=1,
 * SEL=0} and additionally requires ca2 == 0. Direction lives in
 * DRIVE_REG_DIRTN = 0 = {0,0,0} (ca2 = 0 -> toward track 79).
 *
 * In IWM mode the phase lines are set one at a time through the soft
 * switches (cpuAddrRegHi 0..3). In ISM mode they are set ALL AT ONCE by
 * writing the Phases register (ISM reg 4): data[0]=ca0, [1]=ca1, [2]=ca2,
 * [3]=lstrb, [7:4]=output enables.
 */

`timescale 1ns/1ps

module tb_ism_step;

	reg clk = 0;
	always #15.625 clk = ~clk;

	reg [1:0] phase = 0;
	always @(posedge clk) phase <= phase + 1'b1;
	wire cep = (phase == 2'd0);
	wire cen = (phase == 2'd2);

	reg _reset = 0;
	reg selectSWIM = 0, _cpuRW = 1, _cpuUDS = 1;
	reg [15:0] dataIn = 0;
	reg [3:0]  cpuAddrRegHi = 0;
	reg        SEL = 0;
	reg        driveSel = 1;
	wire [15:0] dataOut;

	localparam IMG_WORDS = 16384;
	reg [7:0] img [0:IMG_WORDS-1];
	wire [21:0] dskReadAddrInt;
	reg         dskReadAckInt = 0;
	wire [7:0]  dskReadData = (dskReadAddrInt < IMG_WORDS) ? img[dskReadAddrInt] : 8'hE5;

	wire [6:0]  dbg_track;
	wire [15:0] dbg_step_cnt;
	wire [15:0] dbg_strb_cnt, dbg_strb_en_cnt;
	wire [23:0] dbg_strb_last;

	integer ack_div = 0;
	always @(posedge clk) if (cen) begin
		ack_div <= ack_div + 1;
		if (ack_div >= 8) begin ack_div <= 0; dskReadAckInt <= 1'b1; end
		else dskReadAckInt <= 1'b0;
	end

	swim dut (
		.clk(clk), .cep(cep), .cen(cen), ._reset(_reset),
		.selectSWIM(selectSWIM), ._cpuRW(_cpuRW), ._cpuUDS(_cpuUDS),
		.dataIn(dataIn), .cpuAddrRegHi(cpuAddrRegHi),
		.SEL(SEL), .driveSel(driveSel), .dataOut(dataOut),
		.insertDisk(2'b01), .diskEject(), .diskSides(2'b01),
		.diskMFM(2'b01), .diskHD(2'b01),
		.diskMotor(), .diskAct(),
		.dskReadAddrInt(dskReadAddrInt), .dskReadAckInt(dskReadAckInt),
		.dskReadAddrExt(), .dskReadAckExt(1'b0), .dskReadData(dskReadData),
		.dbg_ism_flpe(),
		.dbg_flp_byte_cnt(), .dbg_flp_miss_cnt(), .dbg_flp_disk_data(),
		.dbg_flp_track(dbg_track), .dbg_flp_side(), .dbg_flp_step_cnt(dbg_step_cnt),
		.dbg_iwm_latch(), .dbg_flp_byte_stb(), .dbg_flp_raw(),
		.dbg_flp_strb_cnt(dbg_strb_cnt), .dbg_flp_strb_en_cnt(dbg_strb_en_cnt),
		.dbg_flp_strb_last(dbg_strb_last), .dbg_flp_gcr_addr()
	);

	task swim_wr(input [3:0] a, input [7:0] d);
	begin
		@(posedge clk);
		cpuAddrRegHi <= a; dataIn <= {8'h00, d}; _cpuRW <= 1'b0;
		selectSWIM <= 1'b1; _cpuUDS <= 1'b0;
		repeat (12) @(posedge clk);
		selectSWIM <= 1'b0; _cpuUDS <= 1'b1; _cpuRW <= 1'b1;
		repeat (12) @(posedge clk);
	end
	endtask

	task swim_rd(input [3:0] a, output [7:0] d);
	begin
		@(posedge clk);
		cpuAddrRegHi <= a; _cpuRW <= 1'b1; selectSWIM <= 1'b1; _cpuUDS <= 1'b0;
		repeat (12) @(posedge clk);
		d = dataOut[15:8];
		selectSWIM <= 1'b0; _cpuUDS <= 1'b1;
		repeat (12) @(posedge clk);
	end
	endtask

	reg [7:0] dummy;

	// IWM-mode step: set the phase lines through the soft switches, then
	// raise and drop lstrb (soft switch 3).
	task iwm_step;
	begin
		swim_wr(4'h0, 8'h00);            // ca0 = 0  -\ DIRTN register (0)
		swim_wr(4'h2, 8'h00);            // ca1 = 0  -/
		swim_wr(4'h4, 8'h00);            // ca2 = 0   = direction "toward 79"
		swim_wr(4'h7, 8'h00);            // lstrb = 1  (addr hi bit0 = 1 -> set)
		swim_wr(4'h6, 8'h00);            // lstrb = 0  -> commit DIRTN
		swim_wr(4'h1, 8'h00);            // ca0 = 1  -\ STEP register (2)
		swim_wr(4'h2, 8'h00);            // ca1 = 0  -/
		swim_wr(4'h4, 8'h00);            // ca2 = 0
		swim_wr(4'h7, 8'h00);            // lstrb = 1
		swim_wr(4'h6, 8'h00);            // lstrb = 0  -> commit STEP
	end
	endtask

	// ISM-mode step: write the Phases register (ISM reg 4) directly.
	// data = {oe[3:0], lstrb, ca2, ca1, ca0}
	task ism_step(input [3:0] oe);
	begin
		swim_wr(4'h4, {oe, 4'b0000});    // DIRTN reg, lstrb low
		swim_wr(4'h4, {oe, 4'b1000});    // lstrb high
		swim_wr(4'h4, {oe, 4'b0000});    // lstrb low  -> commit DIRTN
		swim_wr(4'h4, {oe, 4'b0001});    // STEP reg (ca0=1), lstrb low
		swim_wr(4'h4, {oe, 4'b1001});    // lstrb high
		swim_wr(4'h4, {oe, 4'b0001});    // lstrb low  -> commit STEP
	end
	endtask

	integer i;
	integer t_before, s_before;
	integer fails = 0;

	initial begin
		for (i = 0; i < IMG_WORDS; i = i + 1) img[i] = 8'hE5;
		_reset = 0; repeat (40) @(posedge clk);
		_reset = 1; repeat (40) @(posedge clk);

		// ---------------- Phase 1: IWM mode ----------------
		swim_wr(4'hA, 8'h00);            // select internal drive
		swim_wr(4'h9, 8'h00);            // drive ENABLE
		repeat (200) @(posedge clk);

		t_before = dbg_track; s_before = dbg_step_cnt;
		for (i = 0; i < 4; i = i + 1) iwm_step;
		$display("IWM  mode: track %0d -> %0d   step_cnt %0d -> %0d   strb=%0d (en=%0d)",
		         t_before, dbg_track, s_before, dbg_step_cnt,
		         dbg_strb_cnt, dbg_strb_en_cnt);
		if (dbg_track == t_before) begin
			$display("  ** IWM STEP FAILED — head did not move");
			fails = fails + 1;
		end

		// ---------------- Phase 2: enter ISM ----------------
		// MAME switch sequence: four offset-0xF accesses with data bit6
		// following 1,0,1,1.
		swim_wr(4'hF, 8'h40);
		swim_wr(4'hF, 8'h00);
		swim_wr(4'hF, 8'h40);
		swim_wr(4'hF, 8'h40);
		repeat (100) @(posedge clk);
		swim_rd(4'h6, dummy);
		$display("ISM mode entered? Mode reg = %02x (bit6 set = ISM)", dummy);

		// Drive select + motor on, the ISM way (Mode set, reg 7).
		swim_wr(4'h7, 8'h80);            // motor on
		swim_wr(4'h7, 8'h02);            // drive 1 select
		repeat (200) @(posedge clk);

		// ---------------- Phase 3: ISM step, OE all on ----------------
		t_before = dbg_track; s_before = dbg_step_cnt;
		for (i = 0; i < 4; i = i + 1) ism_step(4'hF);
		$display("ISM  mode (oe=F): track %0d -> %0d   step_cnt %0d -> %0d   strb=%0d (en=%0d)",
		         t_before, dbg_track, s_before, dbg_step_cnt,
		         dbg_strb_cnt, dbg_strb_en_cnt);
		if (dbg_track == t_before) begin
			$display("  ** ISM STEP FAILED — head did not move (strobes seen: %0d, with _enable low: %0d)",
			         dbg_strb_cnt, dbg_strb_en_cnt);
			fails = fails + 1;
		end

		// ---------------- Phase 4: ISM step, OE zero ----------------
		t_before = dbg_track;
		for (i = 0; i < 4; i = i + 1) ism_step(4'h0);
		$display("ISM  mode (oe=0): track %0d -> %0d   strb=%0d (en=%0d)",
		         t_before, dbg_track, dbg_strb_cnt, dbg_strb_en_cnt);

		// ------- Phase 5: ISM step with the MOTOR OFF (the hardware case) -------
		// The 2026-08-04 HUD capture on hardware recorded 67 lstrb falling
		// edges of which only 4 had _enable low, and among the rejected ones a
		// PERFECTLY FORMED step ({ca1,ca0,SEL} = 2 with ca2 = 0). The drive was
		// simply not enabled at the time. _enable comes from ism_devsel_int,
		// which ANDs in ism_mode_reg[7] = MOTOR ON — so a seek issued while the
		// motor bit is clear is silently dropped, the head stays on cylinder 0,
		// and every read past cyl 0 fails. Real hardware gates the drive
		// register path on drive SELECT; motor-on only spins the media.
		swim_wr(4'h6, 8'h80);            // Mode CLEAR bit7 -> motor off
		repeat (200) @(posedge clk);
		t_before = dbg_track; s_before = dbg_step_cnt;
		for (i = 0; i < 4; i = i + 1) ism_step(4'hF);
		$display("ISM  mode MOTOR OFF: track %0d -> %0d   step_cnt %0d -> %0d   strb=%0d (en=%0d)",
		         t_before, dbg_track, s_before, dbg_step_cnt,
		         dbg_strb_cnt, dbg_strb_en_cnt);
		if (dbg_track == t_before) begin
			$display("  ** MOTOR-OFF STEP DROPPED — reproduces the hardware defect");
			fails = fails + 1;
		end else
			$display("  OK: seeks land with the motor off (drive-select gating)");

		$display("last 4 strobe patterns (newest first), {_enable,ca2,ca1,ca0,SEL,ism}:");
		for (i = 0; i < 4; i = i + 1)
			$display("   %06b", (dbg_strb_last >> (6*i)) & 6'h3F);

		$display("STEP TB: %0d failures", fails);
		$finish;
	end

	initial begin
		#40_000_000;
		$display("TIMEOUT");
		$finish;
	end

endmodule
