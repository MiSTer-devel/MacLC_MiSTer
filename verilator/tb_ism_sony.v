/* tb_ism_sony.v — DRIVER-FAITHFUL testbench for the SWIM ISM (MFM) read path.
 *
 * Models the LC ROM Sony driver's MFM read-sector primitives INSTRUCTION-FOR-
 * INSTRUCTION (disassembly: scratch/sonydis/sony_mfm_read.asm, ROM a6ee26 /
 * a6eee8 / a6ea88), where the earlier TBs waited forever and popped at leisure:
 *
 *   - Address-field primitive (a6ee26): 20000-poll hunt budget SHARED across
 *     mismatch re-arms (a6ee42/a6ee72); pops via the MARK register; compares
 *     byte VALUES against A1 A1 A1 FE; any mismatch -> disarm+FIFO-flush+re-arm
 *     without budget reload; exhaust -> -67 (noAdrMkErr). CHRN bytes each get a
 *     31-poll budget (a6ee84..) -> expiry = -66 (noNybErr).
 *   - Data-field primitive (a6eee8): fresh arm, 65536-poll budget for the first
 *     hunt byte, 31 polls for the rest; A1 A1 A1 FB value-compare, mismatch ->
 *     -71 (noDtaMkErr) with NO re-hunt; 512-byte pop loop (31-poll budget each).
 *   - THE VERDICT (a6ef78-a6ef9c): pops CRC-hi, then the poll value that first
 *     shows b7 for CRC-lo is KEPT (moveb %a3@,%d5) and `d5 & 0x22` (b5 error
 *     pending | b1 CRC-error-on-NEWEST-entry) alone accepts/rejects the field:
 *     ID field -> -69, data field -> -72.
 *   - Session teardown probes (a6ea88/a6eb60): reads of the DATA and MARK
 *     registers with the FIFO typically empty — each sets error bit2 exactly as
 *     on a real SWIM1/MAME. These are BENIGN and explain the hardware "unr"
 *     counter; the TB tallies how often they find the FIFO empty.
 *
 * Access timing: the SWIM sits in the LC's VPA/E-clock region (MacLC.sv:845),
 * so EVERY register access is E-paced (~1.23 us) and the hunt loop's SCC
 * PollProc read costs another E cycle — modeled as fixed clk delays.
 *
 * PASS = every sector of the sweep reads with a zero result code and a
 * byte-exact payload. Any -66/-67/-69/-71/-72 is printed with full context.
 *
 * Build + run (Verilator 5.x, from repo root):
 *   verilator --binary -j 0 -Wno-fatal --timescale 1ns/1ps \
 *     +define+SIMULATION -Irtl --top-module tb_ism_sony verilator/tb_ism_sony.v \
 *     rtl/swim.v rtl/floppy.v rtl/mfm_track_encoder.v rtl/floppy_track_encoder.v
 *   ./obj_dir/Vtb_ism_sony
 */

`timescale 1ns/1ps

module tb_ism_sony;

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

	// ---- disk image model: synthetic, address-keyed (no file dependency).
	// Covers tracks 0-1 both sides: max addr ((1*2+1)*18+17)*512+511 = 36863.
	localparam IMG_WORDS = 40960;
	reg [7:0] img [0:IMG_WORDS-1];
	integer ii;
	initial begin
		for (ii = 0; ii < IMG_WORDS; ii = ii + 1)
			img[ii] = ii[7:0] ^ ii[13:6] ^ 8'h5A;
	end

	wire [21:0] dskReadAddrInt, dskReadAddrExt;
	reg         dskReadAckInt = 0;
	wire        dskReadAckExt = 1'b0;
	wire [7:0]  dskReadData = (dskReadAddrInt < IMG_WORDS) ? img[dskReadAddrInt] : 8'hE5;

	// Periodic fetch ack, mimicking addrController's extra bus slot: one
	// cen-wide pulse every 16 cen (= every ~1.97 us), unconditional.
	//
	// ★ ACK_PHASE sweeps the slot's phase relative to the MFM byte clock.
	// On hardware that phase is arbitrary — the extra-slot rotation is free-
	// running and the MFM session starts whenever the driver arms — so a
	// delivery/fetch race that only bites at some alignments would look
	// exactly like the observed NON-DETERMINISTIC per-file copy failures
	// (2026-08-05: two identical runs failed on disjoint file sets).
	// Override per run: ./obj_dir/Vtb_ism_sony +ackphase=N   (N = 0..63 clk)
	integer ack_div = 0;
	integer ack_phase = 0;
	integer ack_hold = 0;
	integer stall_byte = 0;      // +stallbyte=N : inject a late poll at data byte N
	integer stall_len = 700;     // +stalllen=N  : its length in clk (700 ~ 22us)
	initial begin
		if (!$value$plusargs("stallbyte=%d", stall_byte)) stall_byte = 0;
		if (!$value$plusargs("stalllen=%d", stall_len))   stall_len  = 700;
	end
	initial if (!$value$plusargs("ackphase=%d", ack_phase)) ack_phase = 0;
	initial begin
		ack_hold = 1;
		repeat (ack_phase) @(posedge clk);
		ack_hold = 0;
	end
	always @(posedge clk) begin
		if (cen && !ack_hold) begin
			ack_div <= ack_div + 1;
			if (ack_div >= 15) begin
				ack_div <= 0;
				dskReadAckInt <= 1'b1;
			end else
				dskReadAckInt <= 1'b0;
		end
	end

	wire [31:0] dbg_flpe;   // {5'b0, ism_error, arm, ovr, unr}

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
		.dbg_ism_flpe(dbg_flpe),
		.dbg_flp_byte_cnt(), .dbg_flp_miss_cnt(), .dbg_flp_disk_data(),
		.dbg_flp_track(), .dbg_flp_side(), .dbg_flp_step_cnt(),
		.dbg_iwm_latch(), .dbg_flp_byte_stb(), .dbg_flp_raw(), .dbg_flp_gcr_addr()
	);

	// ---- E-paced CPU access primitives ------------------------------------
	// One VPA access ≈ 1.23 us ≈ 40 clk @32MHz: address setup, UDS low across
	// several cen samples, release, inter-access gap (E resync + next opcode).
	task swim_wr(input [3:0] a, input [7:0] d);
	begin
		@(posedge clk);
		cpuAddrRegHi <= a; dataIn <= {8'h00, d}; _cpuRW <= 1'b0;
		selectSWIM <= 1'b1; _cpuUDS <= 1'b0;
		repeat (12) @(posedge clk);
		selectSWIM <= 1'b0; _cpuUDS <= 1'b1; _cpuRW <= 1'b1;
		repeat (28) @(posedge clk);
	end
	endtask

	task swim_rd(input [3:0] a, output [7:0] d);
	begin
		@(posedge clk);
		cpuAddrRegHi <= a; _cpuRW <= 1'b1;
		selectSWIM <= 1'b1; _cpuUDS <= 1'b0;
		repeat (12) @(posedge clk);
		d = dataOut[15:8];
		selectSWIM <= 1'b0; _cpuUDS <= 1'b1;
		repeat (28) @(posedge clk);
	end
	endtask

	// The hunt loops interleave an SCC PollProc read (tstb %a5@) — one more
	// E-paced access elsewhere in the machine. Model as a pure delay.
	task scc_poll_delay;
	begin
		repeat (40) @(posedge clk);
	end
	endtask

	// ---- driver-model state ----
	reg [7:0]  hs;               // last handshake value (the driver's d5)
	reg [7:0]  popv;
	reg [7:0]  chrn_c, chrn_h, chrn_r, chrn_n;
	reg [7:0]  errreg_snap;
	reg [7:0]  buffer [0:511];
	integer    result;           // 0 = ok, else Mac error code (negative)
	integer    hunt_budget;
	integer    k, b, matched;

	localparam ERR_NONYB   = -66;   // per-byte poll budget expired
	localparam ERR_NOADRMK = -67;   // address-mark hunt budget exhausted
	localparam ERR_BADCKSM = -69;   // ID field verdict (d5 & 0x22)
	localparam ERR_NODTAMK = -71;   // data-mark compare mismatch
	localparam ERR_BADDCK  = -72;   // data field verdict (d5 & 0x22)

	// arm choreography exactly as a6ee46-a6ee60 / a6eef0-a6ef0a:
	// rd Error / ModeClr 18 / ModeSet 01 / ModeClr 01 / rd Error / ModeSet 08
	task arm_read;
		reg [7:0] tmp;
	begin
		swim_rd(4'h2, tmp);
		swim_wr(4'h6, 8'h18);
		swim_wr(4'h7, 8'h01);
		swim_wr(4'h6, 8'h01);
		swim_rd(4'h2, tmp);
		swim_wr(4'h7, 8'h08);
	end
	endtask

	// per-byte wait: up to 31 handshake polls (moveq #30 + dbmi), keeping the
	// LAST handshake value in `hs` (the driver's d5). ok=0 -> budget expired.
	task wait_byte(output integer ok);
		integer n;
	begin
		ok = 0;
		n  = 0;
		while (n < 31 && !ok) begin
			swim_rd(4'h7, hs);
			if (hs[7]) ok = 1;
			n = n + 1;
		end
	end
	endtask

	// same but with the SCC PollProc in the loop (data-loop slow path a6ef3c)
	task wait_byte_scc(output integer ok);
		integer n;
	begin
		ok = 0;
		n  = 0;
		while (n < 31 && !ok) begin
			scc_poll_delay;
			swim_rd(4'h7, hs);
			if (hs[7]) ok = 1;
			n = n + 1;
		end
	end
	endtask

	// ---- a6ee26: read the NEXT address field into chrn_* ------------------
	// Returns result = 0 with CHRN + ID verdict applied, or -66/-67/-69.
	task read_addr_field(output integer res);
		integer ok, done;
		reg [7:0] expect_mk [0:3];
	begin
		expect_mk[0] = 8'hA1; expect_mk[1] = 8'hA1;
		expect_mk[2] = 8'hA1; expect_mk[3] = 8'hFE;
		res  = 0;
		done = 0;
		hunt_budget = 20000;                    // a6ee42 — NOT reloaded on re-arm
		while (!done) begin
			arm_read;
			// hunt: match A1 A1 A1 FE by VALUE, pops via MARK reg (a6ee66-82)
			matched = 0;
			while (!done && matched < 4) begin
				ok = 0;
				while (!ok && hunt_budget > 0) begin
					scc_poll_delay;             // tstb %a5@ each iteration
					swim_rd(4'h7, hs);
					if (hs[7]) ok = 1;
					else hunt_budget = hunt_budget - 1;
				end
				if (!ok) begin
					res  = ERR_NOADRMK;         // a6ee76 -> a6ef9e, d0=-67
					done = 1;
				end else begin
					swim_rd(4'h1, popv);
					if (popv == expect_mk[matched])
						matched = matched + 1;
					else
						matched = 5;            // mismatch -> re-arm (a6ee82)
				end
			end
			if (matched == 4) done = 1;         // pattern found
			// matched==5: loop -> re-arm with the REMAINING budget
		end
		if (res == 0) begin
			// CHRN: 4 bytes, 31-poll budget each (a6ee84-a6eece)
			wait_byte(k); if (!k) res = ERR_NONYB;
			if (res == 0) begin swim_rd(4'h1, chrn_c);
				wait_byte(k); if (!k) res = ERR_NONYB; end
			if (res == 0) begin swim_rd(4'h1, chrn_h);
				wait_byte(k); if (!k) res = ERR_NONYB; end
			if (res == 0) begin swim_rd(4'h1, chrn_r);
				scc_poll_delay;                  // a6eeba
				wait_byte(k); if (!k) res = ERR_NONYB; end
			if (res == 0) begin swim_rd(4'h1, chrn_n);
				// close-out a6ef78: CRC-hi pop, CRC-lo pop with d5 verdict
				wait_byte(k); if (!k) res = ERR_NONYB;
			end
			if (res == 0) begin
				swim_rd(4'h1, popv);             // CRC hi
				wait_byte(k);                    // d5 := hs at CRC-lo
				if (!k) res = ERR_NONYB;
				else begin
					swim_rd(4'h1, popv);         // CRC lo
					swim_rd(4'h2, errreg_snap);  // a6ef90 (reads+clears error)
					if (hs & 8'h22) res = ERR_BADCKSM;   // a6ef96 verdict
				end
			end
		end
		swim_wr(4'h6, 8'h18);                    // a6ef9e disarm
	end
	endtask

	// ---- a6eee8: read the next DATA field into buffer[] -------------------
	task read_data_field(output integer res);
		integer ok, n;
		reg [7:0] expect_mk [0:3];
	begin
		expect_mk[0] = 8'hA1; expect_mk[1] = 8'hA1;
		expect_mk[2] = 8'hA1; expect_mk[3] = 8'hFB;
		res = 0;
		arm_read;
		// first hunt byte: 65536-poll budget (a6ef14 moveq #-1,%d2)
		matched = 0;
		hunt_budget = 65536;
		while (res == 0 && matched < 4) begin
			ok = 0;
			while (!ok && hunt_budget > 0) begin
				scc_poll_delay;
				swim_rd(4'h7, hs);
				if (hs[7]) ok = 1;
				else hunt_budget = hunt_budget - 1;
			end
			if (!ok)
				res = ERR_NONYB;                 // a6ef22 -> a6ef52 -> -66
			else begin
				hunt_budget = 31;                // a6ef24: budget 30 after 1st
				swim_rd(4'h1, popv);
				if (popv == expect_mk[matched]) matched = matched + 1;
				else res = ERR_NODTAMK;          // a6ef2e — NO re-hunt
			end
		end
		// 512-byte loop (a6ef36-a6ef4c): fast path = single poll, slow path =
		// 31-poll budget with SCC
		n = 0;
		while (res == 0 && n < 512) begin
			// ★ +stallbyte=N injects ONE late poll mid-field, the way a VPA
			// phase/refresh hiccup stretches a real poll past the 16us byte
			// cell. Harmless for DATA (the byte is still delivered) but it
			// lets a second byte land, so the FIFO sits at pos=2 and the
			// handshake's b1/b0 — which describe the NEWEST entry — start
			// reporting the byte AFTER the one being popped. At the CRC-low
			// byte that is the gap 0x4E (crc0=0) and the driver's `d5 & 0x22`
			// verdict rejects a sector whose data was read perfectly.
			if (stall_byte != 0 && n == stall_byte)
				repeat (stall_len) @(posedge clk);
			swim_rd(4'h7, hs);
			if (!hs[7]) begin
				wait_byte_scc(ok);
				if (!ok) res = ERR_NONYB;
			end
			if (res == 0) begin
				swim_rd(4'h1, popv);
				buffer[n] = popv;
				n = n + 1;
			end
		end
		if (res == 0) begin
			// close-out (a6ef72->a6ef78): CRC-hi, CRC-lo with d5 verdict
			wait_byte(ok);
			if (!ok) res = ERR_NONYB;
			else begin
				swim_rd(4'h1, popv);             // CRC hi
				wait_byte(ok);                   // d5 := hs at CRC-lo
				if (!ok) res = ERR_NONYB;
				else begin
					swim_rd(4'h1, popv);         // CRC lo
					swim_rd(4'h2, errreg_snap);
					if (hs & 8'h22) res = ERR_BADDCK;    // -72
				end
			end
		end
		swim_wr(4'h6, 8'h18);                    // disarm
	end
	endtask

	// ---- a6ea88-style session teardown probes -----------------------------
	// rd error / rd status / rd DATA (pop!) / rd setup — tally empty-pops.
	integer teardown_probes = 0, teardown_empty = 0;
	task teardown_probe;
		reg [7:0] tmp, errv;
	begin
		swim_rd(4'h2, tmp);        // clear pending
		swim_rd(4'h6, tmp);        // status
		swim_rd(4'h0, tmp);        // DATA pop — empty most of the time
		swim_rd(4'h5, tmp);        // setup
		swim_rd(4'h2, errv);       // did the probe set error bit2?
		teardown_probes = teardown_probes + 1;
		if (errv & 8'h04) teardown_empty = teardown_empty + 1;
	end
	endtask

	// ---- caller: find sector R on the current track, then read its data ---
	// Models the a6d63e orchestration: address fields until R matches (each
	// call = fresh budget), inter-primitive latency, then the data primitive.
	integer id_reads, err_cnt;
	integer fail_66, fail_67, fail_69, fail_71, fail_72, fail_data, fail_notgt;
	localparam ERR_NOTARGET = -99;  // TB-only: wanted C/H/R never seen (wrong
	                                // track/side served, or sector absent)
	task read_sector(input integer want_c, input integer want_h,
	                 input integer want_r, output integer res);
		integer done, guard;
	begin
		res = 0; done = 0; guard = 0;
		while (!done) begin
			read_addr_field(res);
			id_reads = id_reads + 1;
			if (res != 0) done = 1;              // error escalates to caller
			else if (chrn_c == want_c[7:0] && chrn_h == want_h[7:0] &&
			         chrn_r == want_r[7:0])
				done = 1;                        // target ID found
			else begin
				guard = guard + 1;
				if (guard > 40) begin            // > 2 revolutions of IDs
					res = ERR_NOTARGET; done = 1;
					$display("TB:   last ID seen: C=%0d H=%0d R=%0d (wanted %0d/%0d/%0d)",
					         chrn_c, chrn_h, chrn_r, want_c, want_h, want_r);
				end
			end
		end
		if (res == 0) begin
			// caller overhead between ID verdict and data-primitive arm:
			// R compare + record keeping, a few E-paced accesses (~30-60 us,
			// must fit the 544 us gap2 window)
			repeat (1400) @(posedge clk);
			read_data_field(res);
		end
	end
	endtask

	// ---- ISM-mode head step (tb_ism_step choreography): DIRTN then STEP ---
	// dir_out = 1 steps toward track 0 (ca2=1), 0 steps toward 79 (ca2=0).
	// SEL (VIA PA5) must be LOW for the strobes — the drive-register write
	// address is {ca1,ca0,SEL}, so a strobe with SEL=1 decodes as a different
	// register entirely (the real driver drops PA5 before seeking; a first
	// TB draft strobed with SEL=1 after a side-1 round and the "STEP" landed
	// on WRTPRT — head never moved). Leaves phases re-parked on F4.
	task ism_seek_step(input dir_out);
	begin
		SEL = 1'b0;
		repeat (40) @(posedge clk);
		swim_wr(4'h4, {4'hF, 1'b0, dir_out, 2'b00});  // DIRTN reg, data=ca2
		swim_wr(4'h4, {4'hF, 1'b1, dir_out, 2'b00});  // lstrb rise
		swim_wr(4'h4, {4'hF, 1'b0, dir_out, 2'b00});  // commit DIRTN
		swim_wr(4'h4, 8'hF1);                          // STEP reg (ca0=1)
		swim_wr(4'h4, 8'hF9);                          // lstrb rise
		swim_wr(4'h4, 8'hF1);                          // commit STEP
		swim_wr(4'h4, 8'hF4);                          // re-park on RdData0
		repeat (400) @(posedge clk);                   // head settle
	end
	endtask

	// ---- expected payload: track t, side s, sector r (1-based), offset ----
	function [7:0] expect_byte(input integer t, input integer s,
	                           input integer r, input integer off);
		integer a;
	begin
		a = ((t * 2 + s) * 18 + (r - 1)) * 512 + off;
		expect_byte = a[7:0] ^ a[13:6] ^ 8'h5A;
	end
	endfunction

	// ---- one round: 18 sectors on (track, side), sequential or strided ----
	// Strided order (x7 mod 18) forces each search to hunt ~7 sectors away:
	// arms land mid-data-field and inside mark runs instead of phase-locking.
	integer cur_track;
	reg [7:0] v;
	integer round, sec, res, mism, j, jit;
	integer total_reads, total_fail;

	task run_round(input integer rnd, input integer side,
	               input integer strided);
		integer si, s;
	begin
		SEL = side[0];                      // VIA PA5 selects the head
		repeat (100) @(posedge clk);
		for (si = 0; si < 18; si = si + 1) begin
			s = strided ? ((si * 7) % 18) + 1 : si + 1;
			// pseudo-random arm-phase jitter, up to ~16 ms (> one sector time)
			jit = (((si + 1) * 199933 + (rnd + 1) * 77351) % 131072);
			repeat (jit) @(posedge clk);
			read_sector(cur_track, side, s, res);
			total_reads = total_reads + 1;
			if (res != 0) begin
				total_fail = total_fail + 1;
				case (res)
					ERR_NONYB:    fail_66 = fail_66 + 1;
					ERR_NOADRMK:  fail_67 = fail_67 + 1;
					ERR_BADCKSM:  fail_69 = fail_69 + 1;
					ERR_NODTAMK:  fail_71 = fail_71 + 1;
					ERR_BADDCK:   fail_72 = fail_72 + 1;
					ERR_NOTARGET: fail_notgt = fail_notgt + 1;
				endcase
				$display("TB: round %0d trk %0d side %0d sector %0d -> ERROR %0d (hs=%02x err_snap=%02x flpe=%08x)",
				         rnd, cur_track, side, s, res, hs, errreg_snap, dbg_flpe);
			end else begin
				mism = 0;
				for (j = 0; j < 512; j = j + 1)
					if (buffer[j] !== expect_byte(cur_track, side, s, j))
						mism = mism + 1;
				if (mism != 0) begin
					fail_data = fail_data + 1;
					total_fail = total_fail + 1;
					$display("TB: round %0d trk %0d side %0d sector %0d -> DATA MISMATCH %0d bytes (first: got %02x want %02x)",
					         rnd, cur_track, side, s, mism,
					         buffer[0], expect_byte(cur_track, side, s, 0));
				end
			end
		end
	end
	endtask

	// ---- SCAN EFFICIENCY: a whole track read in order, NO artificial jitter --
	// run_round() injects up to ~4 ms of jitter between sectors, which destroys
	// the rotational phase relationship on purpose (robustness). That hides the
	// question a real sequential file copy actually asks: with only the
	// driver's own inter-read overhead, does the scan catch the NEXT sector, or
	// does it miss it and go the long way round?
	//
	// This matters because -81 sectNFErr (ROM a6d3a6 via a6d388) is reached by
	// burning one retry per UNWANTED sector encountered, from the fixed budget
	// at SonyVars+46. Our encoder lays sectors 1..18 with NO interleave, so if
	// post-read processing overruns gap3+sync (108+12 bytes = 1.92 ms) the scan
	// misses every following sector and each read costs ~18 IDs instead of ~1.
	// Ideal here is id_reads/18 ~= 1. A ratio near 2 means we skip every other
	// sector; near 18 means a full revolution per sector.
	// +postgap=N models the driver's PER-SECTOR post-processing (copying the
	// 512 bytes out, updating the wanted bitmap, loop bookkeeping) in clk
	// ticks. The margin it eats is the gap3+sync window between the end of one
	// data field and the next ID mark: 108+12 bytes x 16 us = 1.92 ms =
	// ~61,440 clk @32 MHz. Sweeping it finds the cliff where the scan starts
	// missing the next sector, which is what turns into -81 on hardware.
	integer scan_id0, scan_ids, postgap;
	task run_track_scan(input integer side);
		integer si, res_l, mism_l, j_l;
	begin
		SEL = side[0];
		repeat (100) @(posedge clk);
		scan_id0 = id_reads;
		for (si = 1; si <= 18; si = si + 1) begin
			if (postgap > 0) repeat (postgap) @(posedge clk);
			read_sector(cur_track, side, si, res_l);
			total_reads = total_reads + 1;
			if (res_l != 0) begin
				total_fail = total_fail + 1;
				if (res_l == ERR_NOTARGET) fail_notgt = fail_notgt + 1;
				$display("TB: SCAN trk %0d side %0d sector %0d -> ERROR %0d",
				         cur_track, side, si, res_l);
			end else begin
				mism_l = 0;
				for (j_l = 0; j_l < 512; j_l = j_l + 1)
					if (buffer[j_l] !== expect_byte(cur_track, side, si, j_l))
						mism_l = mism_l + 1;
				if (mism_l != 0) begin
					fail_data = fail_data + 1; total_fail = total_fail + 1;
					$display("TB: SCAN trk %0d side %0d sector %0d -> DATA MISMATCH %0d",
					         cur_track, side, si, mism_l);
				end
			end
		end
		scan_ids = id_reads - scan_id0;
		$display("TB: SCAN EFFICIENCY trk %0d side %0d postgap=%0d clk (%0d.%02d ms): %0d ID reads for 18 sectors = %0d.%02d per sector",
		         cur_track, side, postgap, postgap / 32000,
		         ((postgap % 32000) * 100) / 32000,
		         scan_ids, scan_ids / 18, ((scan_ids % 18) * 100) / 18);
		if (scan_ids > 18 * 3)
			$display("TB:   ** POOR: the scan is missing the next sector — a real copy would burn the driver's +46 retry budget and fail -81");
	end
	endtask

	initial begin
		id_reads = 0; err_cnt = 0;
		scan_id0 = 0; scan_ids = 0;
		postgap = 0;
		void'($value$plusargs("postgap=%d", postgap));
		fail_66 = 0; fail_67 = 0; fail_69 = 0; fail_71 = 0; fail_72 = 0;
		fail_data = 0; fail_notgt = 0; total_reads = 0; total_fail = 0;
		cur_track = 0;

		_reset = 0;
		repeat (40) @(posedge clk);
		_reset = 1;
		repeat (40) @(posedge clk);

		// --- IWM -> ISM switch (offset 0xF, data bit6 = 1,0,1,1) ---
		swim_wr(4'hF, 8'h57);
		swim_wr(4'hF, 8'h17);
		swim_wr(4'hF, 8'h57);
		swim_wr(4'hF, 8'h57);
		swim_rd(4'h6, v);
		if (v !== 8'h40) begin
			$display("TB: FAIL — did not enter ISM mode (mode=%02x)", v);
			$finish;
		end

		// --- session init (MAME capture section 6) ---
		swim_wr(4'h5, 8'h20);            // Setup: IBM, MFM read datapath
		swim_wr(4'h6, 8'h04);            // ModeClr 04
		swim_wr(4'h7, 8'h82);            // ModeSet 82 -> mode C2 (motor+devsel)
		swim_rd(4'h6, v);
		$display("TB: mode = %02x (expect C2)", v);

		// MFMModeOn strobe ($9): SEL=1, phases F1 -> F9 -> F1
		SEL = 1'b1;
		repeat (20) @(posedge clk);
		swim_wr(4'h4, 8'hF1);
		swim_wr(4'h4, 8'hF9);
		swim_wr(4'h4, 8'hF1);
		SEL = 1'b0;
		repeat (20) @(posedge clk);

		// park phases on RdData0 (session-level, as the ROM caller does)
		swim_wr(4'h4, 8'hF4);

		// spin-up
		repeat (20000) @(posedge clk);

		$display("TB: ACK_PHASE = %0d clk", ack_phase);
		// --- the sweep -------------------------------------------------------
		// R0: track 0 side 0, sequential (phase-locked baseline, as a real
		//     sequential copy runs)
		// R1: track 0 side 0, strided (random-ish arm phases, mid-field arms)
		// R2: track 0 side 1, sequential — exercises the SEL/HDSEL head latch
		// R3: track 0 side 1, strided
		// R4: seek to track 1 (ISM STEP), side 0 strided — seek+read interplay
		// R5: track 1 side 1, strided; then seek home and spot-check track 0
		// R-scan: the realistic sequential-copy case, measured before anything
		// else perturbs the rotational phase.
		run_track_scan(0);
		teardown_probe;  repeat (7717) @(posedge clk);
		run_track_scan(1);
		teardown_probe;  repeat (7717) @(posedge clk);

		run_round(0, 0, 0);
		teardown_probe;  repeat (7717) @(posedge clk);
		run_round(1, 0, 1);
		teardown_probe;  repeat (5309) @(posedge clk);
		run_round(2, 1, 0);
		teardown_probe;  repeat (7717) @(posedge clk);
		run_round(3, 1, 1);
		teardown_probe;  repeat (5309) @(posedge clk);

		ism_seek_step(1'b0);                // toward 79: track 0 -> 1
		cur_track = 1;
		run_round(4, 0, 1);
		teardown_probe;  repeat (7717) @(posedge clk);
		run_round(5, 1, 1);
		teardown_probe;  repeat (5309) @(posedge clk);

		ism_seek_step(1'b1);                // toward 0: back to track 0
		cur_track = 0;
		SEL = 1'b0;
		read_sector(0, 0, 9, res);          // post-seek-home spot check
		total_reads = total_reads + 1;
		if (res != 0) begin
			total_fail = total_fail + 1;
			$display("TB: post-seek-home sector 9 -> ERROR %0d", res);
		end else begin
			mism = 0;
			for (j = 0; j < 512; j = j + 1)
				if (buffer[j] !== expect_byte(0, 0, 9, j)) mism = mism + 1;
			if (mism != 0) begin
				fail_data = fail_data + 1; total_fail = total_fail + 1;
				$display("TB: post-seek-home sector 9 -> DATA MISMATCH %0d bytes", mism);
			end
		end

		$display("TB: ================= SUMMARY =================");
		$display("TB: sector reads %0d  id-field reads %0d  failures %0d",
		         total_reads, id_reads, total_fail);
		$display("TB:   -66(noNyb)=%0d -67(noAdrMk)=%0d -69(IDcksm)=%0d -71(noDtaMk)=%0d -72(Dcksm)=%0d notgt=%0d data=%0d",
		         fail_66, fail_67, fail_69, fail_71, fail_72, fail_notgt, fail_data);
		$display("TB: teardown probes %0d, empty-pop (unr) %0d — the HW unr-counter noise floor",
		         teardown_probes, teardown_empty);
		$display("TB: final flpe (err/arm/ovr/unr) = %08x", dbg_flpe);
		if (total_fail == 0)
			$display("TB: PASS — driver-faithful sweep clean");
		else
			$display("TB: FAIL — %0d of %0d sector reads failed", total_fail, total_reads);
		$finish;
	end

	// global watchdog
	initial begin
		repeat (40) #1000000000;
		$display("TB: WATCHDOG timeout (reads done: %0d)", total_reads);
		$finish;
	end

endmodule
