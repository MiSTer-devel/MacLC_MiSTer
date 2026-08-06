/* tb_disk_swap.v — unit test for the disk-CHANGE presentation fix.
 *
 * WHY THIS EXISTS (2026-08-05): mounting image B while image A was in the drive
 * never moved the drive's CSTIN sense line, so the guest kept image A's VCB and
 * cached catalog while SDRAM already held image B. The volume looked mounted but
 * every File Manager call failed "…cannot be found" with ZERO disk I/O. On
 * hardware that cost a month of misdiagnosis, and the whole defect is one
 * missing EDGE — which is exactly the kind of thing a 3-second testbench should
 * be guarding from now on.
 *
 * EXTENDED 2026-08-06 for the full MAME-validated media-change protocol
 * (docs/resume_floppy_swap_2026-08-06.md §5/§7; runtime capture tap_swapB):
 *   - the SWITCHED sense register (read reg 6 = MAME DiskChg = !m_dskchg):
 *     0 out of reset and across a FIRST mount, set by any media REMOVAL
 *     (host swap, wrong-size mount, guest eject), surviving the next insert,
 *     cleared ONLY by the DskchgClear strobe (cmd {SEL,ca2,ca1,ca0} = 0xC).
 *     Landing the CSTIN transition WITHOUT this register was the ebbdac6-
 *     reverted regression.
 *   - EJECT in ISM mode: the ROM's Phases walks (F5 F6 F7 FF FE … F0) pass
 *     through the EJECT pattern and must NOT eject while the drive is not
 *     ISM-devsel'd (ism_sel=0); a genuine eject strobe with ism_sel=1 MUST
 *     eject (the 6.0.8 installer's disk-2 swap depends on it).
 *
 * WHAT IT CHECKS, on the same `insertDisk`-generation logic MacLC.sv uses:
 *   1. first mount after reset  -> CSTIN 1 (empty) then 0; SWITCHED stays 0
 *   2. a SWAP with no eject     -> CSTIN returns to 1 for the full hold, then
 *                                  0 again; SWITCHED reads 1 after the swap
 *   2b. DskchgClear strobe      -> SWITCHED back to 0
 *   3. the empty window must be long enough for the driver's ~0.8 s poll
 *   4. a wrong-sized file leaves the drive EMPTY and sets SWITCHED
 *   5. ISM phases walk with ism_sel=0 must NOT eject
 *   6. ISM eject strobe with ism_sel=1 MUST eject (and set SWITCHED)
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

	// ---- the drive: sense lines exactly as the guest reads them -------------
	reg ca0 = 1'b0, ca1 = 1'b0, ca2 = 1'b0, sel = 1'b1;  // parked on reg 1 (CSTIN)
	reg lstrb = 1'b0;
	reg ism_active = 1'b0, ism_sel = 1'b0;

	wire [7:0] readData;
	wire [7:0] dbg_status;
	wire [31:0] dbg_media;
	floppy drv (
		.clk(clk), .cep(cep), .cen(cen),
		._reset(_reset),
		.ca0(ca0), .ca1(ca1), .ca2(ca2), .SEL(sel),
		.lstrb(lstrb), ._enable(1'b0),
		.writeData(8'h00), .readData(readData),
		.advanceDriveHead(1'b1),
		.newByteReady(),
		.insertDisk(dsk_int_ins),
		.diskSides(dsk_int_ds),
		.diskEject(diskEject[0]),
		.motor(), .act(),
		.dskReadAddr(), .dskReadAck(1'b0), .dskReadData(8'h00),
		.ism_active(ism_active), .ism_action(1'b0), .ism_sel(ism_sel),
		.mfm_disk(1'b0), .mfm_hd(1'b0),
		.mfm_byte(), .mfm_mark(), .mfm_crc0(), .mfm_stb(),
		.dbg_byte_cnt(), .dbg_miss_cnt(), .dbg_disk_image_data(),
		.dbg_drive_track(), .dbg_drive_side(), .dbg_step_cnt(),
		.dbg_byte_stb(), .dbg_raw_byte(), .dbg_gcr_addr(),
		.dbg_strb_cnt(), .dbg_strb_en_cnt(), .dbg_strb_last(),
		.dbg_rej_step(), .dbg_status(dbg_status),
		.dbg_media(dbg_media),
		.dbg_mfm_stall_us(), .dbg_mfm_stall_cnt()
	);
	assign diskEject[1] = 1'b0;

	// sense bit as the guest reads it (bit 7 of whatever register is parked)
	wire sense = readData[7];
	wire cstin = sense;   // valid while parked on reg 1 (the default)

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

	// Park the sense address {ca2,ca1,ca0,SEL} and let it settle.
	task park(input p_ca2, input p_ca1, input p_ca0, input p_sel);
	begin
		ca2 <= p_ca2; ca1 <= p_ca1; ca0 <= p_ca0; sel <= p_sel;
		repeat (16) @(posedge clk);
	end
	endtask

	// Drive-command strobe, MAME cmd = {ss,ca2,ca1,ca0}: set the lines, raise
	// LSTRB for a few cep periods, drop it (our RTL decodes on the falling
	// edge with the lines stable across the pulse — F5 note in the findings).
	task strobe(input [3:0] cmd);
	begin
		sel <= cmd[3]; ca2 <= cmd[2]; ca1 <= cmd[1]; ca0 <= cmd[0];
		repeat (16) @(posedge clk);
		lstrb <= 1'b1;
		repeat (16) @(posedge clk);
		lstrb <= 1'b0;
		repeat (16) @(posedge clk);
	end
	endtask

	// One ISM Phases-register write: {lstrb,ca2,ca1,ca0} = the low nibble.
	task phases(input [3:0] nib);
	begin
		lstrb <= nib[3]; ca2 <= nib[2]; ca1 <= nib[1]; ca0 <= nib[0];
		repeat (8) @(posedge clk);
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

	// Read the SWITCHED sense register (read reg 6 = {ca2,ca1,ca0,SEL}=0110),
	// then re-park on CSTIN (reg 1).
	reg switched;
	task read_switched;
	begin
		park(1'b0, 1'b1, 1'b1, 1'b0);
		switched = sense;
		park(1'b0, 1'b0, 1'b0, 1'b1);
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
		read_switched;
		chk(switched === 1'b0, "SWITCHED reads 0 out of reset (MAME device_start)");

		mount(24'd409600, 2000);                 // an 800K image
		measure_empty(empty_clks);
		chk(cstin === 1'b0, "disk reads IN after the first mount completes");
		chk(empty_clks >= DSK_EMPTY_CY,
		       "first mount held the drive empty for the full hold window");
		read_switched;
		chk(switched === 1'b0, "FIRST mount does not set SWITCHED (load never does)");

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
		read_switched;
		chk(switched === 1'b1,
		       "SWITCHED reads 1 after the swap (survives the re-insert)");

		$display("== 2b. DskchgClear strobe clears SWITCHED");
		strobe(4'hC);                            // {ss,ca2,ca1,ca0} = DskchgClear
		read_switched;
		chk(switched === 1'b0, "DskchgClear strobe cleared SWITCHED");
		chk(cstin === 1'b0, "clear strobe did not disturb the mounted disk");

		$display("== 3. hold is long enough for the driver's media poll");
		// MacLC.sv ships 26'h3FFFFFF at 32.5 MHz = 2.06 s. The MAME runtime
		// capture (tap_swapB) shows the NoDiskInPl+DiskChg pair polled every
		// ~0.8 s — assert the SHIPPED width clears one full poll period.
		chk((26'h3FFFFFF / 32500000) >= 1,
		       "shipped DSK_EMPTY_CY spans at least one second");

		repeat (2000) @(posedge clk);

		$display("== 4. a wrong-sized file must leave the drive EMPTY");
		mount(24'd123456, 2000);                 // not a floppy image size
		repeat (2*DSK_EMPTY_CY) @(posedge clk);
		chk(cstin === 1'b1,
		       "bad-size image leaves the drive empty (no stale re-insert)");
		read_switched;
		chk(switched === 1'b1, "the removal (bad-size mount) set SWITCHED");
		strobe(4'hC);
		read_switched;
		chk(switched === 1'b0, "cleared again for the next phase");

		$display("== 5. ISM phases walk must NOT eject (ism_sel=0)");
		mount(24'd409600, 2000);
		repeat (2*DSK_EMPTY_CY) @(posedge clk);
		chk(cstin === 1'b0, "disk mounted for the walk test");
		ism_active <= 1'b1; ism_sel <= 1'b0;
		// SEL (PA5) low: the walk's F8->F7 falling edge then addresses write
		// reg {ca1,ca0,SEL}=110 = EJECT with ca2=1 — the exact 2026-08-03
		// pattern. With SEL=1 the walk never lands on the eject register and
		// this test would pass vacuously.
		sel <= 1'b0;
		repeat (4) @(posedge clk);
		// the ROM/driver walk: F5 F6 F7 FF FE FD FC FB FA F9 F8 F7 … F0
		phases(4'h5); phases(4'h6); phases(4'h7);
		phases(4'hF); phases(4'hE); phases(4'hD); phases(4'hC);
		phases(4'hB); phases(4'hA); phases(4'h9); phases(4'h8);
		phases(4'h7); phases(4'h6); phases(4'h5); phases(4'h4);
		phases(4'h3); phases(4'h2); phases(4'h1); phases(4'h0);
		repeat (32) @(posedge clk);
		park(1'b0, 1'b0, 1'b0, 1'b1);
		chk(cstin === 1'b0, "phases walk did NOT eject the disk (2026-08-03 bug)");
		chk(diskEject[0] === 1'b0, "no eject pulse during the walk");

		$display("== 6. ISM eject with the drive devsel'd MUST eject");
		ism_active <= 1'b1; ism_sel <= 1'b1;
		repeat (4) @(posedge clk);
		strobe(4'h7);                            // {ss,ca2,ca1,ca0} = EjectOn
		park(1'b0, 1'b0, 1'b0, 1'b1);
		chk(cstin === 1'b1, "ISM eject accepted: drive reads EMPTY");
		chk(dsk_int_ins === 1'b0, "eject cleared the host mount flags");
		read_switched;
		chk(switched === 1'b1, "the eject set SWITCHED (MAME unload)");
		ism_active <= 1'b0; ism_sel <= 1'b0;

		$display("");
		if (errors == 0) $display("tb_disk_swap: PASS");
		else             $display("tb_disk_swap: FAIL (%0d)", errors);
		$finish;
	end

endmodule
