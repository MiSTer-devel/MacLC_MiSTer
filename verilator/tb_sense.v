/* tb_sense.v — sweep all 16 drive sense registers and compare against the
 * MAME 0.264 runtime capture (docs/findings_mame_floppy_groundtruth_2026-07-02.md
 * section 4, "1.44M HD disk" column, internal drive, disk inserted, track 0).
 *
 * The sense register is addressed by the phase lines: MAME indexes it as
 * {ss,ca2,ca1,ca0} where ss = VIA PA5 (SEL); our floppy.v indexes the same
 * physical wires as {ca2,ca1,ca0,SEL}. This TB drives the MAME index so the
 * comparison is apples-to-apples.
 *
 * Reads go through the IWM status register ({q7,q6} = 01), whose bit 7 is the
 * sense line — exactly how the real driver reads it (all sense reads in the
 * capture are plain IWM status reads).
 */

`timescale 1ns/1ps

module tb_sense;

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
		.dbg_flp_byte_cnt(), .dbg_flp_miss_cnt(), .dbg_flp_disk_data(),
		.dbg_flp_track(), .dbg_flp_side(), .dbg_flp_step_cnt(),
		.dbg_iwm_latch(), .dbg_flp_byte_stb(), .dbg_flp_raw(), .dbg_flp_gcr_addr()
	);

	task swim_acc(input [3:0] a, output [7:0] d);
	begin
		@(posedge clk);
		cpuAddrRegHi <= a; _cpuRW <= 1'b1; selectSWIM <= 1'b1; _cpuUDS <= 1'b0;
		repeat (10) @(posedge clk);
		d = dataOut[15:8];
		selectSWIM <= 1'b0; _cpuUDS <= 1'b1;
		repeat (10) @(posedge clk);
	end
	endtask

	// Read sense register `r`, indexed the MAME way: {ss,ca2,ca1,ca0}
	task read_sense(input [3:0] r, output sense);
		reg [7:0] d;
	begin
		SEL = r[3];
		swim_acc({3'h0, r[0]}, d);      // ca0
		swim_acc({3'h1, r[1]}, d);      // ca1
		swim_acc({3'h2, r[2]}, d);      // ca2
		swim_acc(4'b1110, d);           // q7 off
		swim_acc(4'b1101, d);           // q6 on -> this read returns IWM status
		sense = d[7];
	end
	endtask

	// MAME 0.264 capture, 1.44M HD disk in the internal drive.
	// 'x' = don't-care (free-running: index pulse / tachometer).
	reg [8*13:1] names [0:15];
	reg [1:0]    expect_v [0:15];   // 0, 1, or 2 = don't care
	integer i;
	reg s;
	integer fails = 0;

	initial begin
		names[0]="Dir";        expect_v[0]=2;
		names[1]="Step";       expect_v[1]=1;
		names[2]="Motor";      expect_v[2]=2;  // 1 until MotorOn is strobed
		names[3]="DiskChg";    expect_v[3]=0;
		names[4]="RdData0";    expect_v[4]=2;  // index pulse
		names[5]="Superdrive"; expect_v[5]=1;
		names[6]="DoubleSide"; expect_v[6]=1;
		names[7]="NoDrive";    expect_v[7]=0;
		names[8]="NoDiskInPl"; expect_v[8]=0;
		names[9]="NoWrProtect";expect_v[9]=1;
		names[10]="NotTrack0"; expect_v[10]=0;
		names[11]="NoTachPuls";expect_v[11]=2;
		names[12]="RdData1";   expect_v[12]=2;  // index pulse
		names[13]="MFMModeOn"; expect_v[13]=1;
		names[14]="NoReady";   expect_v[14]=0;
		names[15]="HD/is_2m";  expect_v[15]=0;  // 0 = HD disk
	end

	reg [7:0] dummy;

	initial begin
		$readmemh("track0.hex", img);
		_reset = 0; repeat (40) @(posedge clk);
		_reset = 1; repeat (40) @(posedge clk);

		// select the internal drive, then enable it (IWM soft switches)
		swim_acc(4'b1010, dummy);   // selectExternalDrive = 0 (internal)
		swim_acc(4'b1001, dummy);   // ENABLE = 1
		repeat (200) @(posedge clk);

		$display("reg  name          ours  MAME(1.44M HD)  verdict");
		for (i = 0; i < 16; i = i + 1) begin
			read_sense(i[3:0], s);
			if (expect_v[i] == 2)
				$display(" %x   %-12s   %b     (free/dontcare)   -", i[3:0], names[i], s);
			else if (s === expect_v[i][0])
				$display(" %x   %-12s   %b     %b               OK", i[3:0], names[i], s, expect_v[i][0]);
			else begin
				$display(" %x   %-12s   %b     %b               ** MISMATCH **",
				         i[3:0], names[i], s, expect_v[i][0]);
				fails = fails + 1;
			end
		end
		$display("SENSE SWEEP: %0d mismatches", fails);
		$finish;
	end

	initial begin
		#900000000;
		$display("TB: watchdog");
		$finish;
	end

endmodule
