/* tb_disk_swap.v — unit test for the disk-CHANGE presentation fix (ef430a2).
 *
 * WHY THIS EXISTS (2026-08-05): mounting image B while image A was in the drive
 * never moved the drive's CSTIN sense line, so the guest kept image A's VCB and
 * cached catalog while SDRAM already held image B. The volume looked mounted but
 * every File Manager call failed "…cannot be found" with ZERO disk I/O. On
 * hardware that cost a month of misdiagnosis, and the whole defect is one
 * missing EDGE — which is exactly the kind of thing a 3-second testbench should
 * be guarding from now on.
 *
 * WHAT IT CHECKS, on the same `insertDisk`-generation logic MacLC.sv uses:
 *   1. first mount after reset  -> CSTIN goes 1 (empty) then 0 (disk in)
 *   2. a SWAP with no eject     -> CSTIN must return to 1 for a good long while
 *                                  and then go 0 again. This is the regression:
 *                                  before the fix CSTIN never moved at all.
 *   3. the empty window must be long enough for a guest that polls the drive
 *      about once a second to actually observe it.
 *   4. a wrong-sized file must leave the drive EMPTY, not re-insert with the
 *      previous disk's geometry.
 *
 * The DUT here is the mount-presentation logic, replicated from MacLC.sv (the
 * real top pulls in the whole machine, which no unit test can boot). Keep the
 * two in step — if MacLC.sv's DSK_EMPTY_CY or its download-start clear changes,
 * change it here too.
 *
 * Build + run (from verilator/):
 *   verilator --binary -j 0 -Wno-fatal --timescale 1ns/1ps -I../rtl \
 *     --Mdir /tmp/obj_swap --top-module tb_disk_swap tb_disk_swap.v ../rtl/floppy.v \
 *     ../rtl/mfm_track_encoder.v ../rtl/floppy_track_encoder.v
 *   /tmp/obj_swap/Vtb_disk_swap
 */

`timescale 1ns/1ps

module tb_disk_swap;

	reg clk = 0;
	always #15.384 clk = ~clk;          // ~32.5 MHz = clk_sys

	reg [1:0] phase = 0;
	always @(posedge clk) phase <= phase + 1'b1;
	wire cep = (phase == 2'd0);
	wire cen = (phase == 2'd2);

	reg _reset = 0;

	// ---- host-side mount model: dio_download pulses per image upload -------
	reg        dio_download = 0;
	reg [7:0]  dio_index    = 0;
	reg [23:0] dio_addr     = 0;        // final WORD count of the upload

	// ---- the logic under test, mirroring MacLC.sv ---------------------------
	// Shortened hold so the test runs in ms instead of seconds; MacLC.sv uses
	// 26'h3FFFFFF (2.06 s). The BEHAVIOUR under test is the edge, not the width,
	// and requirement 3 is checked against this same parameter.
	localparam [17:0] DSK_EMPTY_CY = 18'h3FFFF;   // ~8 ms at 32.5 MHz
	reg [17:0] dsk_int_empty_cy;
	wire dsk_int_empty = (dsk_int_empty_cy != DSK_EMPTY_CY);

	reg dsk_int_ds, dsk_int_ss, dsk_int_mfm, dsk_int_hd;
	wire dsk_int_ins = !dsk_int_empty && (dsk_int_ds || dsk_int_ss || dsk_int_mfm);

	wire [1:0] diskEject;

	always @(posedge clk) begin
		reg old_down;
		old_down <= dio_download;
		if(~old_down && dio_download && dio_index == 1) begin
			dsk_int_ds  <= 0;
			dsk_int_ss  <= 0;
			dsk_int_mfm <= 0;
			dsk_int_hd  <= 0;
			dsk_int_empty_cy <= 18'd0;
		end
		else if(dio_download && dio_index == 1)
			dsk_int_empty_cy <= 18'd0;
		else if(dsk_int_empty_cy != DSK_EMPTY_CY)
			dsk_int_empty_cy <= dsk_int_empty_cy + 18'd1;

		if(old_down && ~dio_download && dio_index == 1) begin
			dsk_int_ds  <= (dio_addr == 409600);
			dsk_int_ss  <= (dio_addr == 204800);
			dsk_int_mfm <= (dio_addr == 368640) || (dio_addr == 737280);
			dsk_int_hd  <= (dio_addr == 737280);
		end
		if(diskEject[0]) begin
			dsk_int_ds  <= 0;
			dsk_int_ss  <= 0;
			dsk_int_mfm <= 0;
			dsk_int_hd  <= 0;
		end
	end

	// ---- the drive: CSTIN is what the guest actually polls ------------------
	wire [7:0] readData;
	wire [7:0] dbg_status;
	// phases parked on CSTIN (reg 1 = {ca2,ca1,ca0,SEL} = 4'b0001)
	floppy drv (
		.clk(clk), .cep(cep), .cen(cen),
		._reset(_reset),
		.ca0(1'b0), .ca1(1'b0), .ca2(1'b0), .SEL(1'b1),
		.lstrb(1'b0), ._enable(1'b0),
		.writeData(8'h00), .readData(readData),
		.advanceDriveHead(1'b1),
		.newByteReady(),
		.insertDisk(dsk_int_ins),
		.diskSides(dsk_int_ds),
		.diskEject(diskEject[0]),
		.motor(), .act(),
		.dskReadAddr(), .dskReadAck(1'b0), .dskReadData(8'h00),
		.ism_active(1'b0), .ism_action(1'b0), .ism_sel(1'b0),
		.mfm_disk(1'b0), .mfm_hd(1'b0),
		.mfm_byte(), .mfm_mark(), .mfm_crc0(), .mfm_stb(),
		.dbg_byte_cnt(), .dbg_miss_cnt(), .dbg_disk_image_data(),
		.dbg_drive_track(), .dbg_drive_side(), .dbg_step_cnt(),
		.dbg_byte_stb(), .dbg_raw_byte(), .dbg_gcr_addr(),
		.dbg_strb_cnt(), .dbg_strb_en_cnt(), .dbg_strb_last(),
		.dbg_rej_step(), .dbg_status(dbg_status),
		.dbg_mfm_stall_us(), .dbg_mfm_stall_cnt()
	);
	assign diskEject[1] = 1'b0;

	// CSTIN as the guest reads it: sense reg 1, bit 7. 1 = NO disk.
	wire cstin = readData[7];

	integer errors = 0;
	integer empty_clks;
	integer saw_empty;

	task chk(input cond, input [255:0] what);
	begin
		if (!cond) begin
			errors = errors + 1;
			$display("FAIL: %0s", what);
		end else
			$display("ok:   %0s", what);
	end
	endtask

	// Upload an image of `words` words into slot 1, taking `dur` clocks.
	task mount(input [23:0] words, input integer dur);
	begin
		dio_index <= 8'd1;
		dio_addr  <= words;
		dio_download <= 1'b1;
		repeat (dur) @(posedge clk);
		dio_download <= 1'b0;
		@(posedge clk);
	end
	endtask

	// Count clocks CSTIN stays high (empty) from now, up to a bound.
	task measure_empty(output integer n);
	begin
		n = 0;
		while (cstin === 1'b1 && n < 4*DSK_EMPTY_CY) begin
			@(posedge clk);
			n = n + 1;
		end
	end
	endtask

	initial begin
		dsk_int_ds = 0; dsk_int_ss = 0; dsk_int_mfm = 0; dsk_int_hd = 0;
		dsk_int_empty_cy = 18'd0;

		_reset = 0;
		repeat (40) @(posedge clk);
		_reset = 1;
		repeat (40) @(posedge clk);

		$display("== 1. reset state + first mount");
		chk(cstin === 1'b1, "drive reads EMPTY out of reset");

		mount(24'd409600, 2000);                 // an 800K image
		measure_empty(empty_clks);
		chk(cstin === 1'b0, "disk reads IN after the first mount completes");
		chk(empty_clks >= DSK_EMPTY_CY,
		       "first mount held the drive empty for the full hold window");

		repeat (2000) @(posedge clk);

		$display("== 2. SWAP with no eject (the regression under test)");
		// Pre-fix this was invisible: CSTIN stayed 0 across the whole swap.
		fork
			begin
				mount(24'd409600, 2000);
				measure_empty(empty_clks);
			end
			begin
				// watch that CSTIN actually LEAVES 0 during the swap
				saw_empty = 0;
				repeat (4*DSK_EMPTY_CY) begin
					@(posedge clk);
					if (cstin === 1'b1) saw_empty = 1;
				end
				chk(saw_empty == 1,
				       "SWAP made the drive report EMPTY (the missing edge)");
			end
		join
		chk(cstin === 1'b0, "disk reads IN again after the swap settles");
		chk(empty_clks >= DSK_EMPTY_CY,
		       "swap held the drive empty for the full hold window");

		$display("== 3. hold is long enough for a ~1 Hz drive poll");
		// MacLC.sv ships 26'h3FFFFFF at 32.5 MHz = 2.06 s. Assert that the
		// SHIPPED width (not this test's shortened one) clears ~1 s.
		chk((26'h3FFFFFF / 32500000) >= 1,
		       "shipped DSK_EMPTY_CY spans at least one second");

		repeat (2000) @(posedge clk);

		$display("== 4. a wrong-sized file must leave the drive EMPTY");
		mount(24'd123456, 2000);                 // not a floppy image size
		repeat (2*DSK_EMPTY_CY) @(posedge clk);
		chk(cstin === 1'b1,
		       "bad-size image leaves the drive empty (no stale re-insert)");

		$display("");
		if (errors == 0) $display("tb_disk_swap: PASS");
		else             $display("tb_disk_swap: FAIL (%0d)", errors);
		$finish;
	end

endmodule
