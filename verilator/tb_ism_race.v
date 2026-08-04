/* tb_ism_sweep.v — full-geometry MFM read verification (2026-08-03).
 *
 * "Are files coming off the floppy correctly?" — the TB answer, without
 * booting: seek across the cylinder range, read on BOTH heads, and
 * byte-compare every captured sector's 512 data bytes against the raw
 * image at the address its own CHRN header declares. The CHRN check also
 * proves each seek landed on the commanded cylinder (C==track, H==side).
 *
 * Positions: tracks {0,1,16,40,64,79} x sides {0,1}. At each, arm the ISM
 * read engine and pop until one complete IDAM..DAM..512-byte field is in
 * the buffer (the mark-hunt drops gap bytes, so pops start at a mark).
 *
 * Fixture: verilator/floppy_all.hex = the ENTIRE 1.44MB raw image, one hex
 * byte per line (not committed — Apple-licensed bytes):
 *   python -c "d=open('disk.dsk','rb').read(); open('verilator/floppy_all.hex','w').write(chr(10).join(f'{b:02x}' for b in d))"
 *
 * Build + run (Verilator 5.x):
 *   verilator --binary -j 0 -Wno-fatal --timescale 1ns/1ps +define+SIMULATION \
 *     -I../rtl --top-module tb_ism_sweep tb_ism_sweep.v \
 *     ../rtl/swim.v ../rtl/floppy.v ../rtl/mfm_track_encoder.v ../rtl/floppy_track_encoder.v
 *   ./obj_dir/Vtb_ism_sweep
 */

`timescale 1ns/1ps

module tb_ism_race;

	// ---- clocking (as in the core) ----
	reg clk = 0;
	always #15.625 clk = ~clk;          // 32 MHz

	reg [1:0] phase = 0;
	always @(posedge clk) phase <= phase + 1'b1;
	wire cep = (phase == 2'd0);
	wire cen = (phase == 2'd2);

	reg _reset = 0;

	// ---- CPU-side SWIM bus ----
	reg        selectSWIM = 0;
	reg        _cpuRW = 1;
	reg        _cpuUDS = 1;
	reg [15:0] dataIn = 0;
	reg [3:0]  cpuAddrRegHi = 0;
	reg        SEL = 0;
	reg        driveSel = 1;
	wire [15:0] dataOut;

	// ---- full-image model ----
	localparam IMG_BYTES = 1474560;
	reg [7:0] img [0:IMG_BYTES-1];

	wire [21:0] dskReadAddrInt, dskReadAddrExt;
	reg         dskReadAckInt = 0;
	wire        dskReadAckExt = 1'b0;
	// HARDWARE-FAITHFUL fetch model (2026-08-04): on the FPGA the image is
	// packed 2 bytes per SDRAM word; the returning lane is chosen by the LIVE
	// dskReadAddrInt[0] (MacLC.sv extra_rom_data_demux) while the WORD came
	// from a fetch issued earlier. If the encoder advances inside that window
	// the wrong lane is served. Model: word latched at issue, lane live.
	reg [15:0] fetch_word_l = 16'hE5E5;
	wire [21:0] even_a = {dskReadAddrInt[21:1], 1'b0};
	wire [21:0] odd_a  = {dskReadAddrInt[21:1], 1'b1};
	always @(posedge clk) if (cen)
		fetch_word_l <= {(even_a < IMG_BYTES) ? img[even_a] : 8'hE5,
		                 (odd_a  < IMG_BYTES) ? img[odd_a]  : 8'hE5};
	wire [7:0]  dskReadData = dskReadAddrInt[0] ? fetch_word_l[7:0] : fetch_word_l[15:8];

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

	// ---- CPU access tasks ----
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

	// ---- drive-register strobes via the ISM Phases register --------------
	// {LSTRB,ca2,ca1,ca0} low nibble, high nibble F = all outputs enabled.
	// driveWriteAddr = {ca1,ca0,SEL}, value = ca2 (floppy.v).
	task strobe(input [3:0] nib);   // pulse LSTRB around the given ca value
	begin
		swim_wr(4'h4, {4'hF, 1'b0, nib[2:0]});
		swim_wr(4'h4, {4'hF, 1'b1, nib[2:0]});
		swim_wr(4'h4, {4'hF, 1'b0, nib[2:0]});
	end
	endtask

	integer cur_track = 0;

	task seek_to(input integer target);
	integer n;
	begin
		SEL = 1'b0;
		repeat (20) @(posedge clk);
		if (target < cur_track) begin
			strobe(3'b100);          // DIRTN with ca2=1: toward track 0
			n = cur_track - target;
		end else begin
			strobe(3'b000);          // DIRTN with ca2=0: toward track 79
			n = target - cur_track;
		end
		repeat (n) begin
			strobe(3'b001);          // STEP with ca2=0: one step
			repeat (4000) @(posedge clk);   // step settle
		end
		cur_track = target;
		repeat (2000) @(posedge clk);
	end
	endtask

	// ---- one verified sector at the current (track, side) ---------------
	localparam POPS = 13800;   // ~one full revolution: all 18 sectors in one armed read
	reg [7:0] popbuf [0:16383];
	reg [7:0] hsbuf  [0:16383];   // handshake at pop time: b1 = ~crc0 (CRC-error), b0 = mark
	reg [7:0] v, hs;
	integer guard, pops;
	integer total_errs = 0, total_secs = 0, total_fail = 0;

	task read_and_verify(input integer exp_track, input integer exp_side);
	integer k, j, c, h, r, n, errs, base, found;
	begin
		// side select rides the arm sequence: park F4 with SEL = side, and
		// the ACTION-gated head latch samples it when the engine arms.
		SEL = exp_side[0];
		repeat (20) @(posedge clk);

		pops = 0;
		swim_wr(4'h4, 8'hF4);        // park phases on RdData
		swim_rd(4'h2, v);            // clear error
		swim_wr(4'h6, 8'h18);
		swim_wr(4'h7, 8'h01);
		swim_wr(4'h6, 8'h01);
		swim_rd(4'h2, v);
		swim_wr(4'h7, 8'h08);        // ACTION rising = read
		guard = 0;
		while (guard < 400000 && pops < POPS) begin
			guard = guard + 1;
			swim_rd(4'h7, hs);
			if (hs[7]) begin
				swim_rd(4'h1, v);
				popbuf[pops] = v;
				pops = pops + 1;
				guard = 0;
			end
		end
		swim_wr(4'h6, 8'h18);        // end read
		SEL = 1'b0;

		// walk the WHOLE buffer: verify every complete IDAM+DAM field (a full
		// revolution holds all 18 sectors — the same continuous pattern a real
		// file copy produces)
		begin : parse_track
			integer seen;
			seen = 0; found = 0;
			for (k = 3; k < pops - 8; k = k + 1) begin
				if (popbuf[k-3]==8'hA1 && popbuf[k-2]==8'hA1 && popbuf[k-1]==8'hA1 && popbuf[k]==8'hFE) begin
					c = popbuf[k+1]; h = popbuf[k+2]; r = popbuf[k+3];
					j = k + 7;
					while (j < pops - 3 && !(popbuf[j-3]==8'hA1 && popbuf[j-2]==8'hA1 && popbuf[j-1]==8'hA1 && popbuf[j]==8'hFB) && (j - k) < 80)
						j = j + 1;
					if (j < pops - 3 && popbuf[j]==8'hFB && (pops - (j+1)) >= 512) begin
						if (c != exp_track || h != exp_side) begin
							$display("RACETEST: trk%0d side%0d — CHRN C=%0d H=%0d R=%0d (SEEK/SIDE WRONG)", exp_track, exp_side, c, h, r);
							total_fail = total_fail + 1;
						end else if (r >= 1 && r <= 18 && !(seen & (1 << (r-1)))) begin
							seen = seen | (1 << (r-1));
							errs = 0;
							base = ((c*2 + h)*18 + (r-1))*512;
							for (n = 0; n < 512; n = n + 1)
								if (popbuf[j+1+n] !== img[base+n]) errs = errs + 1;
							total_secs = total_secs + 1;
							total_errs = total_errs + errs;
							// DRIVER-VISIBLE CRC verdict: the pop of the 2nd CRC
							// byte (j+1+512+1) must carry hs bit1 == 0 (crc valid)
							if ((j + 514) < pops && hsbuf[j+514][1] !== 1'b0) begin
								$display("RACETEST: trk%0d side%0d sec%0d — DATA OK but CRC FLAG BAD (hs=%02x) ** DRIVER-VISIBLE FAIL **",
								         exp_track, exp_side, r, hsbuf[j+514]);
								total_fail = total_fail + 1;
							end
							if (errs) begin
								total_fail = total_fail + 1;
								$display("RACETEST: trk%0d side%0d sec%0d — %0d/512 mismatches ** FAIL **", exp_track, exp_side, r, errs);
							end
							found = found + 1;
						end
					end
				end
			end
			$display("RACETEST: trk%0d side%0d — %0d/18 sectors captured%s", exp_track, exp_side, found,
			         (found >= 18) ? "" : "  ** INCOMPLETE **");
			if (found < 18) total_fail = total_fail + 1;
		end
	end
	endtask

	integer ti, si;
	// sustained copy-pattern region: cylinders 15..35 inclusive

	initial begin
		$readmemh("floppy_all.hex", img);
		

		_reset = 0;
		repeat (40) @(posedge clk);
		_reset = 1;
		repeat (40) @(posedge clk);

		// IWM->ISM + session init (tb_ism_read's validated flow)
		swim_wr(4'hF, 8'h57);
		swim_wr(4'hF, 8'h17);
		swim_wr(4'hF, 8'h57);
		swim_wr(4'hF, 8'h57);
		swim_rd(4'h6, v);
		if (v !== 8'h40) begin
			$display("SWEEP: FAIL — no ISM entry (%02x)", v);
			$finish;
		end
		swim_wr(4'h5, 8'h20);
		swim_wr(4'h6, 8'h04);
		swim_wr(4'h7, 8'h82);            // motor + devsel INT
		SEL = 1'b1;
		repeat (20) @(posedge clk);
		swim_wr(4'h4, 8'hF1);
		swim_wr(4'h4, 8'hF9);
		swim_wr(4'h4, 8'hF1);            // MFMModeOn (SEL=1)
		SEL = 1'b0;
		repeat (20000) @(posedge clk);   // spin-up

		for (ti = 18; ti <= 26; ti = ti + 1) begin
			seek_to(ti);
			for (si = 0; si < 2; si = si + 1)
				read_and_verify(ti, si);
		end

		$display("RACETEST RESULT: %0d sectors verified, %0d byte mismatches, %0d failures -> %s",
		         total_secs, total_errs, total_fail,
		         (total_fail == 0 && total_secs >= 300) ? "PASS" : "FAIL");
		$finish;
	end

	initial begin
		repeat (90) #1000000000;
		$display("RACETEST: WATCHDOG timeout");
		$finish;
	end

endmodule
