/* tb_ism_reinit.v — replay the Sony driver's Welcome-time SWIM RE-INIT.
 *
 * The 2026-08-03 hardware bug: booting FROM a 1.44MB MFM floppy reaches
 * "Welcome to Macintosh" (first ISM session reads fine), then loops forever.
 * MAME 0.264 ground truth (same image, healthy boot, SWIM tap frames 615-660):
 * at Welcome the driver TEARS DOWN the first ISM session, drops to IWM mode
 * for a sense/tach pass, re-unlocks ISM, strobes motor-on + MFMModeOn, and
 * re-arms the read engine. Our first session is TB-proven (tb_ism_read); this
 * TB proves (or breaks) the SECOND session after a driver-style teardown.
 *
 * Session 1 here = tb_ism_read's exact validated sequence, shortened.
 * PASS = session 2 pops >= POPS2 bytes. FAIL prints mode/error readbacks.
 *
 * Build + run (Verilator 5.x):
 *   verilator --binary -j 0 -Wno-fatal --timescale 1ns/1ps +define+SIMULATION \
 *     -Irtl --top-module tb_ism_reinit verilator/tb_ism_reinit.v \
 *     rtl/swim.v rtl/floppy.v rtl/mfm_track_encoder.v rtl/floppy_track_encoder.v
 *   ./obj_dir/Vtb_ism_reinit
 *
 * Fixture: verilator/track0.hex = first 16384 bytes of any bootable 1.44MB
 * raw image, one hex byte per line (not committed - Apple boot-block bytes):
 *   python -c "d=open('disk.dsk','rb').read()[:16384]; open('verilator/track0.hex','w').write('
'.join(f'{b:02x}' for b in d))"
 * The content check is self-referential (compares pops against the same img),
 * so any bootable image works.
 */

`timescale 1ns/1ps

module tb_ism_reinit;

	localparam POPS1 = 200;   // session-1 target (proves baseline still good)
	localparam POPS2 = 200;   // session-2 target (the actual test)

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
	reg        SEL = 0;          // VIA PA5 / HDSEL
	reg        driveSel = 1;
	wire [15:0] dataOut;

	// ---- disk image model: track 0 side 0 = image bytes 0..9215
	localparam IMG_WORDS = 16384;
	reg [7:0] img [0:IMG_WORDS-1];

	wire [21:0] dskReadAddrInt, dskReadAddrExt;
	reg         dskReadAckInt = 0;
	wire        dskReadAckExt = 1'b0;
	wire [7:0]  dskReadData = (dskReadAddrInt < IMG_WORDS) ? img[dskReadAddrInt] : 8'hE5;

	integer ack_div = 0;
	integer nfetch = 0;
	always @(posedge clk) begin
		if (cen) begin
			ack_div <= ack_div + 1;
			if (ack_div >= 8) begin
				ack_div <= 0;
				dskReadAckInt <= 1'b1;
				if (nfetch < 60 || (dskReadAddrInt > 22'd600 && nfetch < 3000)) begin
					$display("TB-FETCH: addr=%0d data=%02x enc: trk=%0d side=%b sec=%0d st=%0d off=%0d hd=%b",
					         dskReadAddrInt, dskReadData,
					         tb_ism_reinit.dut.floppyInt.driveTrack,
					         tb_ism_reinit.dut.floppyInt.driveSide,
					         tb_ism_reinit.dut.floppyInt.menc.sector,
					         tb_ism_reinit.dut.floppyInt.menc.state,
					         tb_ism_reinit.dut.floppyInt.menc.src_offset,
					         tb_ism_reinit.dut.floppyInt.menc.hd);
					nfetch = nfetch + 1;
				end
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
		.insertDisk(2'b01),
		.diskSides(2'b01),
		.diskMFM(2'b01),
		.diskHD(2'b01),
		.diskEject(),
		.diskMotor(),
		.dskReadData(dskReadData),
		.dskReadAddrInt(dskReadAddrInt),
		.dskReadAckInt(dskReadAckInt),
		.dskReadAddrExt(dskReadAddrExt),
		.dskReadAckExt(dskReadAckExt)
	);

	// ---- CPU access tasks (identical to tb_ism_read) ----
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

	// ---- shared read-session task: arm + poll + pop until `target` bytes ----
	integer npop;
	reg [7:0] v, hs;
	integer guard, arms;
	reg [7:0] popbuf [0:4095];   // holds the most recent session's pops

	task read_session(input integer target, input [127:0] tag, output integer got);
	integer pops;
	begin
		pops = 0; arms = 0;
		while (pops < target && arms < 100) begin
			arms = arms + 1;
			swim_wr(4'h4, 8'hF4);        // park phases on RdData0
			swim_rd(4'h2, v);            // clear error
			swim_wr(4'h6, 8'h18);        // ModeClr 18 (ACTION,WRITE off)
			swim_wr(4'h7, 8'h01);        // ModeSet 01 \ pulse FIFO clear
			swim_wr(4'h6, 8'h01);        // ModeClr 01 /
			swim_rd(4'h2, v);
			swim_wr(4'h7, 8'h08);        // ModeSet 08 -> ACTION rising = READ

			guard = 0;
			while (guard < 200000 && pops < target) begin
				guard = guard + 1;
				swim_rd(4'h7, hs);
				if (hs[7]) begin
					swim_rd(4'h1, v);
					popbuf[pops] = v;
					pops = pops + 1;
					guard = 0;
				end
			end
			swim_wr(4'h6, 8'h18);        // end of field
			if (guard >= 200000) begin
				$display("TB[%0s]: hunt TIMED OUT on arm %0d with %0d pops", tag, arms, pops);
				arms = 100;
			end
		end
		$display("TB[%0s]: pops=%0d arms=%0d", tag, pops, arms);
		got = pops;
	end
	endtask

	integer got1, got2;

	initial begin
		$readmemh("track0.hex", img);

		_reset = 0;
		repeat (40) @(posedge clk);
		_reset = 1;
		repeat (40) @(posedge clk);

		// ================= SESSION 1 (tb_ism_read's validated flow) ========
		swim_wr(4'hF, 8'h57);
		swim_wr(4'hF, 8'h17);
		swim_wr(4'hF, 8'h57);
		swim_wr(4'hF, 8'h57);
		swim_rd(4'h6, v);
		if (v !== 8'h40) begin
			$display("TB: FAIL — did not enter ISM (mode=%02x)", v);
			$finish;
		end

		swim_wr(4'h5, 8'h20);            // Setup: IBM, MFM read
		swim_wr(4'h6, 8'h04);
		swim_wr(4'h7, 8'h82);            // mode C2: motor + devsel INT

		SEL = 1'b1;                       // MFMModeOn strobe needs SEL=1
		repeat (20) @(posedge clk);
		swim_wr(4'h4, 8'hF1);
		swim_wr(4'h4, 8'hF9);
		swim_wr(4'h4, 8'hF1);
		SEL = 1'b0;
		repeat (20) @(posedge clk);

		repeat (20000) @(posedge clk);   // spin-up

		read_session(POPS1, "S1", got1);
		if (got1 < POPS1) begin
			$display("TB: FAIL — baseline session 1 broken (%0d pops)", got1);
			$finish;
		end

		// ================= DRIVER-STYLE TEARDOWN ==========================
		// MAME frames ~600-616: read side wound down, mode cleared wholesale
		// (motor off, ACTION off, exit ISM back to IWM).
		swim_wr(4'h6, 8'hF8);            // ModeClr F8: motor|ISM|HDSEL|WR|ACTION
		swim_rd(4'h6, v);
		$display("TB: after teardown, reg6 readback = %02x (IWM-mode value)", v);

		// ================= IWM-MODE INTERLUDE (sense/tach-style) ==========
		// The driver reads q6/q7-class offsets with SEL both ways (tach RPM
		// measurement + sense pass). These are non-0xF accesses: they also
		// reset the IWM->ISM unlock counter, like the real access stream.
		SEL = 1'b0;
		swim_rd(4'hC, v);
		swim_rd(4'hE, v);
		SEL = 1'b1;
		swim_rd(4'hC, v);
		swim_rd(4'hE, v);
		SEL = 1'b0;
		repeat (2000) @(posedge clk);    // brief spin-down gap

		// ================= RE-UNLOCK + RE-INIT (MAME F623) ================
		swim_wr(4'hF, 8'h57);
		swim_wr(4'hF, 8'h17);
		swim_wr(4'hF, 8'h57);
		swim_wr(4'hF, 8'h57);
		swim_rd(4'h6, v);
		$display("TB: after RE-unlock, ISM mode reg = %02x (expect 40)", v);
		if (v !== 8'h40) begin
			$display("TB: FAIL — ISM RE-ENTRY broken (mode=%02x)", v);
			$finish;
		end

		swim_wr(4'h5, 8'h20);            // Setup again
		swim_rd(4'h5, v);
		$display("TB: setup readback after re-init = %02x (expect 20)", v);
		swim_wr(4'h6, 8'h04);
		swim_wr(4'h7, 8'h82);            // motor + devsel INT again
		swim_rd(4'h6, v);
		$display("TB: mode after re-init = %02x (expect C2)", v);

		// motor-on drive strobe with SEL=0 (MAME F623: F2->FA->F2), then
		// MFMModeOn with SEL=1 (F1->F9->F1) — the full observed strobe pair.
		SEL = 1'b0;
		repeat (20) @(posedge clk);
		swim_wr(4'h4, 8'hF2);
		swim_wr(4'h4, 8'hFA);
		swim_wr(4'h4, 8'hF2);
		SEL = 1'b1;
		repeat (20) @(posedge clk);
		swim_wr(4'h4, 8'hF1);
		swim_wr(4'h4, 8'hF9);
		swim_wr(4'h4, 8'hF1);
		SEL = 1'b0;
		repeat (20) @(posedge clk);

		repeat (20000) @(posedge clk);   // spin-up again

		// ================= SESSION 2 — THE TEST ===========================
		read_session(POPS2, "S2", got2);

		if (got2 >= POPS2) begin : verify_content
			// Count-only is too weak (a broken path still strobes the FIFO).
			// Self-referential content check: find the popped IDAM, take its
			// sector number R, find the following DAM, then compare the data
			// field against the image at sector (R-1). The engine resumes
			// mid-track, so which sector arrives first is not fixed.
			integer k, r, dam, ok, errs;
			r = -1; dam = -1;
			for (k = 3; k < got2 && r < 0; k = k + 1)
				if (popbuf[k-3]==8'hA1 && popbuf[k-2]==8'hA1 && popbuf[k-1]==8'hA1 && popbuf[k]==8'hFE)
					r = popbuf[k+3];               // CHRN: C,H,R,N follow FE
			for (k = 3; k < got2 && dam < 0; k = k + 1)
				if (popbuf[k-3]==8'hA1 && popbuf[k-2]==8'hA1 && popbuf[k-1]==8'hA1 && popbuf[k]==8'hFB)
					dam = k + 1;                   // data starts after FB
			ok = 0; errs = 0;
			if (r > 0 && dam > 0) begin
				for (k = 0; k < 32 && (dam + k) < got2; k = k + 1) begin
					if (popbuf[dam+k] !== img[(r-1)*512 + k]) errs = errs + 1;
				end
				ok = (errs == 0);
				$display("TB: session 2 sector R=%0d, %0d/32 data bytes mismatch vs image", r, errs);
			end else
				$display("TB: session 2 could not locate IDAM/DAM in pops (r=%0d dam=%0d)", r, dam);
			if (ok)
				$display("TB: PASS — session 2 serves correct image data after re-init");
			else
				$display("TB: FAIL — session 2 data wrong (r=%0d dam=%0d errs=%0d)", r, dam, errs);
		end
		else begin
			swim_rd(4'h6, v);  $display("TB: FAIL diag — mode  = %02x", v);
			swim_rd(4'h2, v);  $display("TB: FAIL diag — error = %02x", v);
			swim_rd(4'h7, hs); $display("TB: FAIL diag — hs    = %02x", hs);
			swim_rd(4'h5, v);  $display("TB: FAIL diag — setup = %02x", v);
			$display("TB: FAIL — session 2 dead after re-init (%0d pops)", got2);
		end
		$finish;
	end

	// global watchdog
	initial begin
		#4000000000;
		$display("TB: WATCHDOG timeout");
		$finish;
	end

endmodule
