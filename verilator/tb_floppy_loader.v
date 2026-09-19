/* tb_floppy_loader.v — unit bench for rtl/floppy_loader.v (Phase 1).
 *
 * WHY: the loader replaces ioctl_download as the way a floppy image reaches
 * SDRAM. It is the one new module in Phase 1, and its two failure modes are
 * both silent — a wrong SDRAM address puts the image where the read side is
 * not looking, and a wrong DC42 offset shifts every sector by 84 bytes. Both
 * would present on hardware as "the disk mounts but is unreadable", which is
 * exactly the class this project has burned weeks on before. Catch them here,
 * not at the hardware gate.
 *
 * WHAT IT MODELS: hps_io's block-device protocol as sys/hps_io.sv actually
 * implements it, not as one might assume —
 *   - sd_ack rises when the HPS picks the transfer up and falls when the
 *     sector has been delivered (hps_io.sv:331 sets it, :315 clears it);
 *   - sd_buff_addr resets to 0 at the start of each transfer (:345) and
 *     increments per word (:296);
 *   - sd_buff_wr is a ONE-CYCLE pulse per word (:295).
 * The SDRAM side models the sdram.v download port's two-phase LEVEL
 * handshake: ack rises while req is up, and falls after req drops.
 *
 * The reference image is byte-patterned so a misplaced word names itself.
 *
 * Build + run (Icarus, from the repo root):
 *   /c/iverilog/bin/iverilog -g2012 -s tb_floppy_loader \
 *     -o scratch/phase1/tb_load.vvp verilator/tb_floppy_loader.v \
 *     rtl/floppy_loader.v
 *   /c/iverilog/bin/vvp scratch/phase1/tb_load.vvp
 *
 * ★ 2026-09-19: this header named Verilator 5.x, which CANNOT build the bench
 * and has not been able to since run_mdb_mount was added. run_mdb_mount calls
 * run_mount (~line 148) before run_mount is declared (~line 231); Verilator
 * binds the forward reference as a zero-argument task and then rejects every
 * argument of every call, 4 args x 6 call sites = "Too many arguments in call
 * to task 'run_mount'" x 24. Icarus accepts the forward reference and the
 * bench passes as written: 34 checks, 0 errors. Do NOT run the old Verilator
 * line and conclude the bench is broken. Moving the run_mount declaration
 * above run_mdb_mount would make both tools build it, if that is ever wanted.
 */
`timescale 1ns/1ps

module tb_floppy_loader;

	reg clk = 0;
	always #15.384 clk = ~clk;          // ~32.5 MHz clk_sys

	reg         reset = 1;
	reg         img_mounted = 0;
	reg  [63:0] img_size = 0;
	reg         img_readonly = 0;

	wire [31:0] sd_lba;
	wire        sd_rd;
	reg         sd_ack = 0;
	reg  [12:0] sd_buff_addr = 0;
	reg  [15:0] sd_buff_dout = 0;
	reg         sd_buff_wr = 0;

	wire [23:0] wr_addr;
	wire [15:0] wr_data;
	wire        wr_req;
	reg         wr_ack = 0;

	wire        loading, done, raw_img, readonly, is_dc42, media_ds;
	wire  [7:0] dc42_fmt;
	wire [63:0] size;
	reg   [5:0] hdr_addr = 0;     // Phase 4b header store read port
	wire [15:0] hdr_data;

	localparam [23:0] BASE = 24'h600000;

	floppy_loader dut (
		.clk_sys(clk), .reset(reset),
		.img_mounted(img_mounted), .img_size(img_size), .img_readonly(img_readonly),
		.sd_lba(sd_lba), .sd_rd(sd_rd), .sd_ack(sd_ack),
		.sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
		.base_addr(BASE),
		.wr_addr(wr_addr), .wr_data(wr_data), .wr_req(wr_req), .wr_ack(wr_ack),
		.loading(loading), .done(done), .size(size),
		.readonly(readonly), .raw_img(raw_img),
		.is_dc42(is_dc42), .media_ds(media_ds),
		.hdr_addr(hdr_addr), .hdr_data(hdr_data), .dc42_fmt(dc42_fmt)
	);

	integer errors = 0;
	integer checks = 0;

	task ck(input cond, input [8*72-1:0] what);
		begin
			checks = checks + 1;
			if (!cond) begin
				errors = errors + 1;
				$display("FAIL: %0s", what);
			end else $display("ok:   %0s", what);
		end
	endtask

	// ── captured SDRAM writes ─────────────────────────────────────────────
	reg [15:0] sdram [0:65535];         // indexed by (wr_addr - BASE)
	reg        written [0:65535];
	integer    n_writes;
	integer    wbase;      // n_writes at the start of the current mount
	integer    i;
	integer    first_bad;

	// The word the file holds at a given file-word index. Self-identifying:
	// low byte = index low, high byte = index high, so a shifted or dropped
	// word is obvious and names its own position.
	function [15:0] file_word_at(input integer widx);
		file_word_at = {widx[15:8] ^ 8'h5A, widx[7:0]};
	endfunction

	// hps_io byte order: the loader byte-swaps to match the old download
	// path, so what lands in SDRAM is the swap of what the HPS delivered.
	function [15:0] swapped(input [15:0] w);
		swapped = {w[7:0], w[15:8]};
	endfunction

	reg dc42_mode;

	// ── a planted Master Directory Block in guest sector 2 (plan Phase 6B) ──
	// The values below are what the SNIFF must SEE, i.e. after the loader's
	// byte swap; deliver_sector delivers swapped() of them, which is the raw
	// HPS word. mdb_mode off leaves sector 2 as ordinary patterned data, whose
	// signature word cannot match either MDB magic.
	reg        mdb_mode;
	reg [15:0] mdb_sig_v;      // word 0:  drSigWord
	reg [15:0] mdb_nalbk_v;    // word 9:  drNmAlBlks
	reg [15:0] mdb_abhi_v;     // word 10: drAlBlkSiz, high half
	reg [15:0] mdb_ablo_v;     // word 11: drAlBlkSiz, low half

	// Word index WITHIN THE GUEST SECTOR for a file word index, i.e. the
	// 84-byte DC42 header taken back off. Mirrors the loader's mdb_idx.
	function integer sec_word(input integer fw);
		sec_word = (fw % 256) - (dc42_mode ? 42 : 0);
	endfunction

	function [15:0] mdb_word_at(input integer fw);
		begin
			case (sec_word(fw))
				0:       mdb_word_at = swapped(mdb_sig_v);
				9:       mdb_word_at = swapped(mdb_nalbk_v);
				10:      mdb_word_at = swapped(mdb_abhi_v);
				11:      mdb_word_at = swapped(mdb_ablo_v);
				default: mdb_word_at = file_word_at(fw);
			endcase
		end
	endfunction

	// plant an MDB and run a mount with it; nsec must reach sector 2
	task run_mdb_mount(input [63:0] fsize, input dc42, input integer nsec,
	                   input [15:0] sig, input [15:0] nalbk, input [15:0] absz);
		begin
			mdb_mode    = 1'b1;
			mdb_sig_v   = sig;
			mdb_nalbk_v = nalbk;
			mdb_abhi_v  = 16'd0;
			mdb_ablo_v  = absz;
			run_mount(fsize, 1'b0, dc42, nsec);
			mdb_mode    = 1'b0;
		end
	endtask

	// A real DiskCopy 4.2 header word as the HPS delivers it. ★ The detection
	// is on the RAW word: d[7:0] is the FIRST byte of the pair. Anchored to
	// the proven download path (MacLC.sv:2538-2541), NOT to what the loader
	// happens to do — an earlier version of this bench was built to match a
	// buggy loader and passed while both were wrong.
	//   word 0  : byte 0  = d[7:0] = Pascal name length 1..63
	//   word 40 : byte 80 = d[7:0] = disk-format byte (0=400K 1=800K 2=720K 3=1440K)
	//   word 41 : d = 16'h0001, the magic
	localparam [7:0] DC42_TEST_FMT = 8'd1;      // 800K GCR
	function [15:0] dc42_hdr_word(input integer widx);
		begin
			case (widx)
				0:       dc42_hdr_word = {8'h41, 8'd10};          // name length 10
				40:      dc42_hdr_word = {8'h00, DC42_TEST_FMT};  // byte 0x50
				41:      dc42_hdr_word = 16'h0001;                // the magic
				default: dc42_hdr_word = 16'hEEEE;                // must never reach SDRAM
			endcase
		end
	endfunction

	// ── model: deliver one 512-byte sector ────────────────────────────────
	task deliver_sector(input [31:0] lba);
		integer w;
		integer fw;
		begin
			@(posedge clk); #1 sd_ack = 1;      // HPS picks the transfer up
			sd_buff_addr = 0;
			for (w = 0; w < 256; w = w + 1) begin
				fw = lba * 256 + w;
				@(posedge clk);
				#1;
				sd_buff_addr = w[12:0];
				sd_buff_dout = (dc42_mode && fw < 42) ? dc42_hdr_word(fw)
				             : (mdb_mode && lba == 32'd2) ? mdb_word_at(fw)
				                                      : file_word_at(fw);
				sd_buff_wr   = 1;
				@(posedge clk);
				#1 sd_buff_wr = 0;              // one-cycle pulse, as hps_io does
			end
			@(posedge clk); #1 sd_ack = 0;      // transfer complete
		end
	endtask

	// ── model: the sdram.v download port ──────────────────────────────────
	// Two-phase LEVEL handshake: ack rises a couple of cycles after req, and
	// falls once req has dropped. Deliberately slower than the loader so the
	// drain is paced by SDRAM, as it is in the real design.
	integer ack_delay;
	always @(posedge clk) begin
		if (reset) begin
			wr_ack <= 0;
			n_writes <= 0;
			ack_delay <= 0;
		end else if (wr_req && !wr_ack) begin
			if (ack_delay == 3) begin
				wr_ack <= 1;
				ack_delay <= 0;
				if ((wr_addr - BASE) < 24'd65536) begin
					sdram[(wr_addr - BASE) & 24'hFFFF] <= wr_data;
					written[(wr_addr - BASE) & 24'hFFFF] <= 1'b1;
				end
				n_writes <= n_writes + 1;
			end else ack_delay <= ack_delay + 1;
		end else if (!wr_req && wr_ack) begin
			wr_ack <= 0;
		end
	end

	// ── the loader's own sector pump ──────────────────────────────────────
	// Follows sd_rd rather than driving a fixed sequence, so a loader that
	// asks for the wrong LBA, or asks twice, shows up as a mismatch.
	reg [31:0] served [0:4095];
	integer    n_served;
	always @(posedge clk) begin
		if (reset) n_served <= 0;
	end

	integer wait_n;
	task run_mount(input [63:0] fsize, input ro, input dc42, input integer nsec);
		integer s;
		begin
			dc42_mode = dc42;
			for (i = 0; i < 65536; i = i + 1) written[i] = 1'b0;
			n_served = 0;
			wbase    = n_writes;   // n_writes is free-running; compare deltas

			@(posedge clk);
			#1 img_size = fsize; img_readonly = ro; img_mounted = 1;
			@(posedge clk);
			#1 img_mounted = 0;

			for (s = 0; s < nsec; s = s + 1) begin
				// Wait for the loader to ask -- BOUNDED. An unbounded wait
				// turns "the loader asked for one sector too few" into the
				// deadlock guard's timeout, which is a red gate but says
				// nothing about which sector went missing; the 6D floor/ceil
				// regression is exactly that shape.
				wait_n = 0;
				while (!sd_rd && wait_n < 200000) begin
					@(posedge clk);
					wait_n = wait_n + 1;
				end
				if (!sd_rd) begin
					$display("FAIL: loader never requested sector %0d of %0d", s, nsec);
					errors = errors + 1;
					checks = checks + 1;
					disable run_mount;
				end
				served[n_served] = sd_lba;
				n_served = n_served + 1;
				deliver_sector(sd_lba);
				// let it drain before the next request
				while (loading && !sd_rd && !done) @(posedge clk);
			end
			while (!done) @(posedge clk);
		end
	endtask

	initial begin
		mdb_mode = 1'b0;
		for (i = 0; i < 65536; i = i + 1) begin
			sdram[i] = 16'hDEAD;
			written[i] = 1'b0;
		end

		repeat (4) @(posedge clk);
		#1 reset = 0;
		repeat (2) @(posedge clk);

		// ══ 1. raw image, 4 sectors ════════════════════════════════════════
		$display("== 1. raw image: every word at base + file index");
		run_mount(64'd2048, 1'b0, 1'b0, 4);

		ck(n_served == 4, "asked for exactly 4 sectors");
		ck(served[0] == 0 && served[1] == 1 && served[2] == 2 && served[3] == 3,
		   "asked for LBA 0,1,2,3 in order");
		ck(n_writes - wbase == 1024, "wrote 1024 words (4 x 256)");

		first_bad = -1;
		for (i = 0; i < 1024; i = i + 1)
			if (first_bad < 0 && (!written[i] || sdram[i] !== swapped(file_word_at(i))))
				first_bad = i;
		ck(first_bad < 0, "raw: every word byte-swapped at base + index");
		if (first_bad >= 0)
			$display("      first bad word %0d: got %04x want %04x written=%0d",
			         first_bad, sdram[first_bad], swapped(file_word_at(first_bad)),
			         written[first_bad]);

		ck(!written[1024], "raw: nothing written past the image");
		ck(raw_img === 1'b1, "raw: raw_img set (writable in stage 1)");
		ck(readonly === 1'b0, "raw: readonly latched low");
		ck(size == 64'd2048, "raw: size is the whole file");
		ck(loading === 1'b0, "raw: loading deasserted at done");

		// ══ 2. read-only latch ═════════════════════════════════════════════
		$display("== 2. img_readonly is latched at this slot's own mount pulse");
		run_mount(64'd1024, 1'b1, 1'b0, 2);
		ck(readonly === 1'b1, "readonly latched high from the mount pulse");

		// ══ 3. DC42: the 84-byte header must be stripped, not shifted ══════
		// This is the case with the nastiest failure mode: get the offset
		// wrong and every sector is displaced by 84 bytes, which mounts and
		// then fails every read. 42 words of header, so file word 42 must be
		// the FIRST thing in SDRAM and the filler must never appear at all.
		$display("== 3. DC42 header stripped at load");
		run_mount(64'd2048, 1'b0, 1'b1, 4);

		ck(raw_img === 1'b0, "dc42: raw_img CLEAR (must present write-protected)");
		ck(is_dc42 === 1'b1, "dc42: detected from the RAW header word");
		ck(dc42_fmt == DC42_TEST_FMT,
		   "dc42: format byte captured (size cannot decide geometry: tags trail)");
		ck(size == 64'd2048 - 64'd84, "dc42: size is the file minus the 84-byte header");
		ck(n_writes - wbase == (4 * 256) - 42, "dc42: wrote 982 words (1024 - 42 header)");

		first_bad = -1;
		for (i = 0; i < (4 * 256) - 42; i = i + 1)
			if (first_bad < 0 && (!written[i] || sdram[i] !== swapped(file_word_at(i + 42))))
				first_bad = i;
		ck(first_bad < 0, "dc42: file word 42 landed at base+0, payload contiguous");
		if (first_bad >= 0)
			$display("      first bad word %0d: got %04x want %04x written=%0d",
			         first_bad, sdram[first_bad], swapped(file_word_at(first_bad + 42)),
			         written[first_bad]);

		first_bad = -1;
		for (i = 0; i < (4 * 256) - 42; i = i + 1)
			if (first_bad < 0 && sdram[i] === 16'hEEEE) first_bad = i;
		ck(first_bad < 0, "dc42: no header filler word reached SDRAM");

		// The stripped header must be KEPT for the SD writer (Phase 4b), in
		// the internal swapped convention, readable two edges after hdr_addr.
		@(posedge clk); #1 hdr_addr = 6'd41;
		@(posedge clk); @(posedge clk); #1;
		ck(hdr_data === 16'h0100, "dc42: header word 41 (the magic) kept, swapped");
		@(posedge clk); #1 hdr_addr = 6'd0;
		@(posedge clk); @(posedge clk); #1;
		ck(hdr_data === 16'h0A41, "dc42: header word 0 (name length) kept, swapped");
		@(posedge clk); #1 hdr_addr = 6'd40;
		@(posedge clk); @(posedge clk); #1;
		ck(hdr_data === {DC42_TEST_FMT, 8'h00}, "dc42: header word 40 (format byte) kept, swapped");

		// ══ 4. unmount must not start a load ═══════════════════════════════
		$display("== 4. a zero-size mount pulse is an UNMOUNT");
		@(posedge clk);
		#1 img_size = 64'd0; img_mounted = 1;
		@(posedge clk);
		#1 img_mounted = 0;
		repeat (20) @(posedge clk);
		ck(sd_rd === 1'b0, "unmount issued no sd_rd");
		ck(loading === 1'b0, "unmount left loading low");

		// ══ 5. the DC42 PARTIAL TAIL BLOCK (plan Phase 6D) ═════════════════
		// ★ THE REGRESSION THIS CATCHES IS SILENT AND WAS LIVE FOR MONTHS.
		// sec_total used to FLOOR, so a DC42 file -- which is 84 + payload and
		// can never end on a block boundary -- lost its final partial block,
		// i.e. the last 84 bytes of its last sector, on every mount. HFS
		// leaves a volume's last block unused so nothing complained; DOS does
		// not. Main serves the block short (FileReadAdv returns a truthy 84)
		// with its own stale buffer behind the real bytes, which is why the
		// model below delivers a full 256 words for it too.
		$display("== 5. DC42: the file's final PARTIAL block is loaded, not dropped");
		run_mount(64'd2048 + 64'd84, 1'b0, 1'b1, 5);

		ck(n_served == 5, "ceil, not floor: 5 sectors asked for (4 whole + the tail)");
		ck(served[4] == 4, "the fifth request is LBA 4, the partial block");
		ck(n_writes - wbase == (5 * 256) - 42,
		   "wrote 1238 words: the whole file minus the 42 header words");
		ck(size == 64'd2048, "size is still the payload, header removed");

		// the payload the guest can see: 2048 bytes = 1024 words, file words
		// 42..1065. Words 982..1023 of it are the ones the floor used to drop.
		first_bad = -1;
		for (i = 0; i < 1024; i = i + 1)
			if (first_bad < 0 && (!written[i] || sdram[i] !== swapped(file_word_at(i + 42))))
				first_bad = i;
		ck(first_bad < 0, "every payload word reached SDRAM, including the last 42");
		if (first_bad >= 0)
			$display("      first bad word %0d: got %04x want %04x written=%0d",
			         first_bad, sdram[first_bad], swapped(file_word_at(first_bad + 42)),
			         written[first_bad]);
		ck(written[1023], "specifically: the LAST payload word is present");

		// ══ 6. the medium's sidedness sniff (plan Phase 6B) ════════════════
		// Sector 2's MDB, not the file's size: a One-Sided erase leaves a 400K
		// volume inside an 819,200-byte file, and sizing from the file
		// re-advertises it double-sided across a remount.
		$display("== 6. media_ds: the volume header in sector 2 decides");

		// (a) no MDB at all -- unformatted or foreign medium: do NOT cap it
		run_mount(64'd2048, 1'b0, 1'b0, 4);
		ck(media_ds === 1'b1, "no MDB signature: double-sided (never lower the ceiling)");

		// (b) a 400K MFS volume: 391 allocation blocks of 1024 B = 782 blocks
		run_mdb_mount(64'd2048, 1'b0, 4, 16'hD2D7, 16'd391, 16'd1024);
		ck(media_ds === 1'b0, "MFS 400K volume (782 blocks): SINGLE-sided");

		// (c) an 800K HFS volume: 1594 allocation blocks of 512 B
		run_mdb_mount(64'd2048, 1'b0, 4, 16'h4244, 16'd1594, 16'd512);
		ck(media_ds === 1'b1, "HFS 800K volume (1594 blocks): double-sided");

		// (d) a plausible signature with a nonsense drAlBlkSiz is NOT an MDB
		run_mdb_mount(64'd2048, 1'b0, 4, 16'h4244, 16'd391, 16'd1000);
		ck(media_ds === 1'b1, "drAlBlkSiz not a multiple of 512: rejected, stays double");

		// (e) ...and it survives a REMOUNT of the same medium, which is the
		// entire reason the sniff exists rather than a format-byte latch.
		run_mdb_mount(64'd2048, 1'b0, 4, 16'hD2D7, 16'd391, 16'd1024);
		ck(media_ds === 1'b0, "remounted 400K volume: still single-sided");

		// (f) inside a DC42 the MDB is 42 words further into file block 2.
		// Reading it at the raw offset would see patterned filler and answer
		// "double-sided" for every DC42 400K image.
		run_mdb_mount(64'd2048 + 64'd84, 1'b1, 5, 16'hD2D7, 16'd391, 16'd1024);
		ck(media_ds === 1'b0, "DC42 400K volume: the 84-byte header offset is applied");

		$display("");
		$display("tb_floppy_loader: %0d checks, %0d errors", checks, errors);
		if (errors == 0) $display("tb_floppy_loader: PASS");
		else             $display("tb_floppy_loader: FAIL");
		$finish;
	end

	// deadlock guard
	initial begin
		#50_000_000;
		$display("FAIL: timeout — loader never reached done");
		$finish;
	end

endmodule
