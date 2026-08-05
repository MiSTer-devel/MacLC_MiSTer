/* tb_mfm_idcensus.v — full-disk ID-field census of mfm_track_encoder (2026-08-05).
 *
 * Motivation: the Finder copy fails (near-)deterministically at specific
 * tracks ({1,10,67,34,38,43} on 1261d4e0) with byte-perfect payloads and NO
 * primitive error storm — i.e. the wanted sector's ID never matches. This TB
 * asks the encoder directly: for EVERY (track 0..79, side 0..1), over two
 * revolutions, is the set of ID fields exactly {1..18}, each with C==track,
 * H==side, N==2, a good ID CRC (ocrc0 at CRC-lo), and a following DAM?
 *
 * The encoder is `ready`-paced and rate-agnostic, so we pull one byte per
 * clock: ~12.4k bytes/track, 160 positions, ~4M cycles total — seconds.
 * Payload content is irrelevant to the census; idata is fed junk.
 *
 * Build + run:
 *   verilator --binary -j 0 -Wno-fatal --timescale 1ns/1ps +define+SIMULATION \
 *     -I../rtl --top-module tb_mfm_idcensus tb_mfm_idcensus.v ../rtl/mfm_track_encoder.v
 *   ./obj_dir/Vtb_mfm_idcensus
 */

`timescale 1ns/1ps

module tb_mfm_idcensus;

	reg clk = 0;
	always #15.625 clk = ~clk;

	reg rst = 1;
	reg ready = 0;
	reg side = 0;
	reg [6:0] track = 0;
	wire [21:0] addr;
	wire [7:0] odata;
	wire omark, ocrc0, oneeds, oindex;

	// junk payload — census only cares about ID structure
	wire [7:0] idata = addr[7:0] ^ addr[15:8];

	mfm_track_encoder enc(
		.clk(clk), .ready(ready), .rst(rst),
		.side(side), .track(track), .hd(1'b1),
		.addr(addr), .idata(idata),
		.odata(odata), .omark(omark), .ocrc0(ocrc0),
		.oneeds(oneeds), .oindex(oindex)
	);

	localparam SPT = 18;
	localparam TRKBYTES = 12422;

	// stream parser state
	integer mark_run;          // consecutive omark A1s seen
	reg [7:0] id_c, id_h, id_r, id_n;
	integer id_phase;          // >0: capturing C,H,R,N,CRChi,CRClo after A1A1A1 FE
	integer dam_pending;       // sector header seen, awaiting its DAM
	integer seen [1:18];       // per-sector ID count this position
	integer dam_seen [1:18];
	integer crc_ok [1:18];
	integer cur_r;             // sector whose CRC/DAM we are tracking
	integer errors, positions_bad, total_ids;
	integer t, s, i, k, bad_here;

	task pull_byte;
		begin
			ready = 1; @(posedge clk); ready = 0; @(posedge clk);
		end
	endtask

	// parse one delivered byte
	task automatic step_parse;
		begin
			if (omark && odata == 8'hA1) mark_run = mark_run + 1;
			else begin
				if (mark_run >= 3) begin
					// address-mark byte follows the A1 A1 A1 run
					if (odata == 8'hFE) begin
						id_phase = 1;      // capture CHRN + CRC
						dam_pending = 0;
					end
					else if (odata == 8'hFB) begin
						if (cur_r >= 1 && cur_r <= 18 && dam_pending) begin
							dam_seen[cur_r] = dam_seen[cur_r] + 1;
							dam_pending = 0;
						end
					end
				end
				else if (id_phase != 0) begin
					case (id_phase)
						1: id_c = odata;
						2: id_h = odata;
						3: id_r = odata;
						4: id_n = odata;
						5: ; // CRC hi
						6: begin
							// CRC lo byte: encoder flags a completed good CRC here
							if (id_r >= 1 && id_r <= 18) begin
								total_ids = total_ids + 1;
								seen[id_r] = seen[id_r] + 1;
								cur_r = id_r;
								dam_pending = 1;
								if (ocrc0) crc_ok[id_r] = crc_ok[id_r] + 1;
								if (id_c != {1'b0, track} || id_h != {7'b0, side} || id_n != 8'd2) begin
									errors = errors + 1;
									bad_here = 1;
									$display("BAD ID  trk=%0d side=%0d: C=%0d H=%0d R=%0d N=%0d",
									         track, side, id_c, id_h, id_r, id_n);
								end
							end else begin
								errors = errors + 1;
								bad_here = 1;
								$display("BAD R   trk=%0d side=%0d: R=%0d out of range", track, side, id_r);
							end
						end
					endcase
					id_phase = (id_phase == 6) ? 0 : id_phase + 1;
				end
				mark_run = 0;
			end
		end
	endtask

	initial begin
		errors = 0; positions_bad = 0; total_ids = 0;
		repeat (8) @(posedge clk);
		rst = 0;
		repeat (4) @(posedge clk);

		for (t = 0; t < 80; t = t + 1) begin
			for (s = 0; s < 2; s = s + 1) begin
				track = t[6:0]; side = s[0];
				// re-align the generator to the new position: reset restarts
				// the track at gap4a (same as a re-seek settling in hardware)
				rst = 1; @(posedge clk); @(posedge clk); rst = 0; @(posedge clk);
				mark_run = 0; id_phase = 0; dam_pending = 0; cur_r = 0; bad_here = 0;
				for (i = 1; i <= 18; i = i + 1) begin
					seen[i] = 0; dam_seen[i] = 0; crc_ok[i] = 0;
				end
				// two revolutions
				for (k = 0; k < 2*TRKBYTES; k = k + 1) begin
					pull_byte;
					step_parse;
				end
				// census
				for (i = 1; i <= 18; i = i + 1) begin
					if (seen[i] != 2) begin
						errors = errors + 1; bad_here = 1;
						$display("CENSUS  trk=%0d side=%0d: sector %0d seen %0d times (want 2)",
						         t, s, i, seen[i]);
					end
					if (crc_ok[i] != seen[i]) begin
						errors = errors + 1; bad_here = 1;
						$display("IDCRC   trk=%0d side=%0d: sector %0d crc0 %0d/%0d",
						         t, s, i, crc_ok[i], seen[i]);
					end
					if (dam_seen[i] != seen[i]) begin
						errors = errors + 1; bad_here = 1;
						$display("NODAM   trk=%0d side=%0d: sector %0d dam %0d/%0d",
						         t, s, i, dam_seen[i], seen[i]);
					end
				end
				if (bad_here) positions_bad = positions_bad + 1;
			end
		end

		$display("TB: ================= SUMMARY =================");
		$display("TB: positions 160, IDs parsed %0d, bad positions %0d, errors %0d",
		         total_ids, positions_bad, errors);
		if (errors == 0) $display("TB: PASS — every track/side serves exactly sectors 1..18, correct C/H/N, good ID CRCs, DAMs present");
		else $display("TB: FAIL");
		$finish;
	end
endmodule
