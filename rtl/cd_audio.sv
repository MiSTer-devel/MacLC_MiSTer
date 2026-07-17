// cd_audio.sv - AppleCD audio playback engine for the SCSI CD-ROM target.
//
// Instantiated INSIDE scsi.v (CDROM instance only) so it shares the target's
// HPS io channel; the only signals leaving the SCSI hierarchy are the two
// sound outputs. Byte behavior follows MAME's nscsi_cdrom_apple_device
// (../mame src/devices/bus/nscsi/cd.cpp) — the same oracle the target's
// INQUIRY / 0xC1 TOC / sense already match. The HPS side of the contract
// (TOC blob + raw-audio block windows) is documented in
// Main_MiSTer/support/maclc/maclc_cd.h and docs/plan_cd_audio_rtl.md.
//
// Structure (strict single-driver: each always block owns its registers):
//   MAIN FSM  - TOC blob fetch + parse (MCDA magic, else synthesized
//               single-track fallback: stock Main / Verilator / flat image),
//               0xC1 response precompute (99 descriptors, last repeated, per
//               MAME), command execution (SEARCH/PLAY/PAUSE/STOP/SCAN),
//               periodic track/MSF refresh for AUDIO STATUS / READ Q SUBCODE,
//               and the playhead bookkeeping.
//   FETCH FSM - streams 2352-byte frames (5 blocks) from the audio window
//               into a 2-frame ping-pong buffer while playing.
//   SAMPLE    - 44.1 kHz fractional cadence, 16-bit LE stereo, one frame
//               consumed per 588 stereo samples.
//
// Channel sharing: scsi.v raises ch_grant only while the target is bus-idle
// with no data io pending; the MAIN FSM has priority over FETCH via fr_ok.
// A data READ stops playback outright (oracle behavior), so contention is
// self-limiting.

module cd_audio #(
	parameter CLK_HZ = 32'd32_500_000   // clk rate, for the 44.1 kHz cadence
)(
	input             clk,
	input             rst,

	input             mounted,
	input             img_mounted,      // mount pulse: (re)acquire the TOC
	input      [31:0] img_blocks,       // 512-byte blocks of the data region

	// audio-family CDB, latched by scsi.v (status GOOD already returned)
	input             cmd_stb,
	input       [7:0] cmd_op,
	input       [7:0] cdb1, cdb2, cdb3, cdb4, cdb5, cdb6, cdb7, cdb9,
	input             read_stb,         // data READ latched: stop playback
	input             eject_stb,

	// shared HPS io channel
	input             ch_grant,
	output            ca_io_active,     // owns the channel (request/ack window)
	output            ca_io_rd,
	output     [31:0] ca_io_lba,
	input             io_ack,
	input       [7:0] sd_buff_addr,
	input      [15:0] sd_buff_dout,
	input             sd_buff_wr,

	// live registers for AUDIO STATUS (0xCC) / READ Q SUBCODE (0xC2)
	output reg  [7:0] ast_code,         // 0 play, 1 paused, 3 end, 5 idle
	output reg  [7:0] cur_ctrl,
	output reg  [7:0] cur_trk_bcd,
	output reg  [7:0] abs_m, abs_s, abs_f,   // BCD, no +150 (oracle)
	output reg  [7:0] rel_m, rel_s, rel_f,

	// 0xC1 READ TOC response RAM: bytes at toc_base .. toc_base+3.
	// Layout: [0..3]   mode-00 header {01, last BCD, 00, 00}
	//         [4..7]   mode-40 lead-out {M, S, F BCD, 00}
	//         [8+4k..] track k+1 descriptor {ctrl, M, S, F BCD}, k = 0..98
	input       [8:0] toc_base,
	output      [7:0] toc_q0, toc_q1, toc_q2, toc_q3,
	output reg        toc_ready,

	output reg signed [15:0] snd_l,
	output reg signed [15:0] snd_r,

	// JTAG probe feed (CDA0): TOC/engine state, composed here so the whole
	// hierarchy passes one opaque word.
	//   [0]=mounted [1]=toc_ready [2]=toc_valid [9:3]=n_tracks
	//   [14:10]=mst [16:15]=pstate [18:17]=fst
	//   [26:19]=toc_fetch_cnt (M_ACQ_REQ fires, wraps)
	//   [31:27]=frame_fetch_cnt[4:0] (F_REQ fires, wraps)
	output     [31:0] dbg_cda0
);

// HPS window contract (Main_MiSTer support/maclc/maclc_cd.h)
localparam [31:0] TOC_BLK   = 32'h7FFF_0000;
localparam [31:0] AUDIO_BLK = 32'h4000_0000;

// ============================================================================
// RAMs (proven scsi_dpram primitive from scsi.v)
// ============================================================================
// raw MCDA blob: 1 KB as 512 x 16 (port a = HPS stream, port b = FSM reads)
reg          blob_cap;
reg          blob_blk;
reg  [8:0]   blob_ra;
wire [15:0]  blob_q_ram;
cd_sdp #(.DW(16), .AW(9)) blob_ram (
	.clock(clk),
	.waddr({blob_blk, sd_buff_addr}), .wdata(sd_buff_dout),
	.wr(blob_cap && sd_buff_wr),
	.raddr(blob_ra), .q(blob_q_ram)
);
// Every blob-consuming FSM below is written against a 2-cycle read pipeline
// ("step k: blob_q holds word k-2"); cd_sdp is a 1-cycle RAM. Without this
// output stage every consumer reads one word EARLY: the M_HDR_RD magic check
// compares "MC" against word 1 ("DA"), toc_valid can never set, and every
// disc degrades to the synthesized single data track with PLAY rejected —
// the exact HW symptom found 2026-07-17 (first hardware exercise of this
// path; the sim has no CD/TOC harness). One register here aligns the
// hardware with the contract for ALL blob readers at once.
reg [15:0] blob_q;
always @(posedge clk) blob_q <= blob_q_ram;
wire [7:0] blob_b0 = blob_q[7:0];      // even byte (LE lane order on FPGA)
wire [7:0] blob_b1 = blob_q[15:8];

// 0xC1 response: two byte planes x 256, two read ports each = 4 serve lanes.
// Four mirrored 1w1r cd_sdp instances (same write, distinct read address)
// rather than scsi_dpram: with a constant-zero wren on one port, Quartus 17
// drops the TDP template and silently falls back to ~2000 LUTs of register
// fabric per plane (the 2026-07-07 BRAM-inference lesson; verified in
// map.rpt on the first fit attempt of this file).
reg        resp_we;
reg  [8:0] resp_wa;
reg  [7:0] resp_wd;
wire [7:0] re_q0, re_q1, ro_q0, ro_q1;
// even byte at/after addr x lives at plane index (x + x[0]) >> 1;
// odd  byte at/after addr x lives at plane index  x >> 1
wire [8:0] tb0 = toc_base;
wire [8:0] tb2 = toc_base + 9'd2;
wire       resp_we_e = resp_we && !resp_wa[0];
wire       resp_we_o = resp_we &&  resp_wa[0];
wire [8:0] tb0_e = (tb0 + {8'd0, tb0[0]}) >> 1;
wire [8:0] tb2_e = (tb2 + {8'd0, tb2[0]}) >> 1;
cd_sdp #(.DW(8), .AW(8)) resp_e0 (
	.clock(clk), .waddr(resp_wa[8:1]), .wdata(resp_wd), .wr(resp_we_e),
	.raddr(tb0_e[7:0]), .q(re_q0)
);
cd_sdp #(.DW(8), .AW(8)) resp_e1 (
	.clock(clk), .waddr(resp_wa[8:1]), .wdata(resp_wd), .wr(resp_we_e),
	.raddr(tb2_e[7:0]), .q(re_q1)
);
cd_sdp #(.DW(8), .AW(8)) resp_o0 (
	.clock(clk), .waddr(resp_wa[8:1]), .wdata(resp_wd), .wr(resp_we_o),
	.raddr(tb0[8:1]), .q(ro_q0)
);
cd_sdp #(.DW(8), .AW(8)) resp_o1 (
	.clock(clk), .waddr(resp_wa[8:1]), .wdata(resp_wd), .wr(resp_we_o),
	.raddr(tb2[8:1]), .q(ro_q1)
);
assign toc_q0 = tb0[0] ? ro_q0 : re_q0;
assign toc_q1 = tb0[0] ? re_q0 : ro_q0;   // byte at tb0+1: opposite plane, same pair
assign toc_q2 = tb2[0] ? ro_q1 : re_q1;
assign toc_q3 = tb2[0] ? re_q1 : ro_q1;

// frame ping-pong: 2 x 1280 x 16 (2352 B payload + 208 B pad per half)
reg         fr_cap;
reg         fr_half_w;
reg  [2:0]  fr_blk;
reg [11:0]  frame_ra;
wire [15:0] frame_q;
cd_sdp #(.DW(16), .AW(12)) frame_ram (
	.clock(clk),
	.waddr({fr_half_w, fr_blk, sd_buff_addr}), .wdata(sd_buff_dout),
	.wr(fr_cap && sd_buff_wr),
	.raddr(frame_ra), .q(frame_q)
);

// ============================================================================
// helpers
// ============================================================================
function [7:0] bcd2bin;
	input [7:0] b;
	bcd2bin = {4'd0, b[7:4]} * 8'd10 + {4'd0, b[3:0]};
endfunction
function [7:0] bin2bcd;                // 0..99
	input [7:0] v;
	bin2bcd = v >= 8'd90 ? {4'd9, (v - 8'd90)-8'd0} :
	          v >= 8'd80 ? {4'd8, v - 8'd80} :
	          v >= 8'd70 ? {4'd7, v - 8'd70} :
	          v >= 8'd60 ? {4'd6, v - 8'd60} :
	          v >= 8'd50 ? {4'd5, v - 8'd50} :
	          v >= 8'd40 ? {4'd4, v - 8'd40} :
	          v >= 8'd30 ? {4'd3, v - 8'd30} :
	          v >= 8'd20 ? {4'd2, v - 8'd20} :
	          v >= 8'd10 ? {4'd1, v - 8'd10} : v;
endfunction
function [31:0] msf2lba;               // BCD M/S/F -> LBA
	input [7:0] m, s, f;
	msf2lba = {24'd0, bcd2bin(m)} * 32'd4500
	        + {24'd0, bcd2bin(s)} * 32'd75
	        + {24'd0, bcd2bin(f)};
endfunction

// ============================================================================
// io-channel request mux (each FSM owns its own request registers)
// ============================================================================
reg         toc_rd, toc_act;
reg  [31:0] toc_lba;
reg         fr_rd, fr_act;
reg  [31:0] fr_lba;
assign ca_io_rd     = toc_rd | fr_rd;
assign ca_io_lba    = toc_act ? toc_lba : fr_lba;
assign ca_io_active = toc_act | fr_act;

reg old_ack;
always @(posedge clk) old_ack <= io_ack;
wire ack_fall = old_ack & ~io_ack;

// ============================================================================
// playback state (owned by MAIN FSM) + sample-engine handshake wires
// ============================================================================
localparam ST_IDLE = 2'd0, ST_PLAY = 2'd1, ST_PAUSE = 2'd2, ST_END = 2'd3;
reg  [1:0]  pstate;
reg [31:0]  cur_lba, stop_lba;
reg         flush;                     // 1-clk: position changed, requeue audio
wire        frame_done;                // sample engine finished a frame

always @(*) begin
	case (pstate)
	ST_PLAY:  ast_code = 8'h00;
	ST_PAUSE: ast_code = 8'h01;
	ST_END:   ast_code = 8'h03;
	default:  ast_code = 8'h05;
	endcase
end

// ============================================================================
// MAIN FSM
// ============================================================================
localparam [4:0]
	M_IDLE     = 5'd0,
	M_ACQ_REQ  = 5'd1,  M_ACQ_WAIT = 5'd2,
	M_HDR_RD   = 5'd3,                      // stream words 0..5 into hdr regs
	M_EMIT_H   = 5'd4,                      // header slot bytes 0..3
	M_LO_DIV   = 5'd5,  M_EMIT_LO  = 5'd6,  // lead-out MSF -> slots 4..7
	M_TRK_RD   = 5'd7,                      // stream entry words (4) of track t_idx
	M_TRK_DIV  = 5'd8,  M_EMIT_TRK = 5'd9,
	M_BUILT    = 5'd10,
	M_CMD      = 5'd11,                     // decode a pending command
	M_CTRK_RD  = 5'd12,                     // track-mode: read start(k), start(k+1)
	M_APPLY    = 5'd13,
	M_REF_SCAN = 5'd14,                     // find track containing cur_lba
	M_REF_DIVA = 5'd15, M_REF_DIVR = 5'd16;
reg [4:0] mst;

reg  [2:0] step;                        // word-stream step within a state
reg  [6:0] t_idx;
reg [31:0] t_start;
reg  [7:0] t_ctrl;
reg [31:0] div_v;                       // shared iterative M/S/F divider
reg  [6:0] div_m, div_s;
reg  [1:0] emit_k;

reg        toc_valid;
reg  [6:0] n_tracks;

// probe counters (CDA0): how many blob-block fetches / audio-frame fetches
// actually fired — distinguishes "fetch never ran" from "ran, parse failed".
reg  [7:0] dbg_toc_fetch_cnt = 8'd0;
reg  [4:0] dbg_fr_fetch_cnt  = 5'd0;
reg [31:0] leadout_lba;

reg  [7:0] c_op, c_1, c_2, c_3, c_4, c_5, c_6, c_7, c_9;
reg        cmd_pend;
reg [31:0] c_addr;                      // resolved target address
reg [31:0] c_next;                      // start of following track (track mode)
reg  [6:0] c_trk;                       // 0-based requested track

reg [31:0] ref_abs, ref_rel;
reg [31:0] scan_start;
reg  [6:0] scan_idx, scan_best_trk;
reg  [7:0] scan_ctrl_c, scan_best_ctrl;
reg [31:0] scan_best_start;
reg  [6:0] refm_hold, refs_hold;
reg [15:0] ref_cnt;

// track entry k lives at blob words 8+4k .. 11+4k
// (bytes 16+8k: +0 ctrl, +1 resv, +2..5 start LE, +6..7 pregap)
wire [8:0] entry_w = 9'd8 + {t_idx, 2'b00};

always @(posedge clk) begin
	if (rst) begin
		mst <= M_IDLE; step <= 0; emit_k <= 0;
		blob_cap <= 0; blob_blk <= 0; blob_ra <= 0;
		toc_rd <= 0; toc_act <= 0; toc_lba <= 0;
		resp_we <= 0; resp_wa <= 0; resp_wd <= 0;
		toc_valid <= 0; toc_ready <= 0; n_tracks <= 7'd1; leadout_lba <= 0;
		cmd_pend <= 0; pstate <= ST_IDLE; cur_lba <= 0; stop_lba <= 0; flush <= 0;
		cur_ctrl <= 8'h14; cur_trk_bcd <= 8'h01;
		abs_m <= 0; abs_s <= 0; abs_f <= 0; rel_m <= 0; rel_s <= 0; rel_f <= 0;
		ref_cnt <= 0; t_idx <= 0;
	end else begin
		resp_we <= 1'b0;
		flush   <= 1'b0;

		// command capture: never lost, executed from M_IDLE
		if (cmd_stb) begin
			c_op <= cmd_op; c_1 <= cdb1; c_2 <= cdb2; c_3 <= cdb3; c_4 <= cdb4;
			c_5 <= cdb5; c_6 <= cdb6; c_7 <= cdb7; c_9 <= cdb9;
			cmd_pend <= 1'b1;
		end
		// oracle: a data READ (or eject / unmount) stops playback
		if ((read_stb || eject_stb || !mounted) && pstate != ST_IDLE)
			pstate <= ST_IDLE;

		// playhead advance, one frame at a time
		if (frame_done) begin
			if (cur_lba + 32'd1 >= stop_lba) begin
				cur_lba <= stop_lba;
				pstate  <= ST_END;
			end
			else cur_lba <= cur_lba + 32'd1;
		end

		case (mst)
		// -------------------------------------------------- idle / dispatch
		M_IDLE: begin
			blob_cap <= 1'b0;
			if (img_mounted && mounted) begin
				toc_ready <= 1'b0; toc_valid <= 1'b0; blob_blk <= 1'b0;
				pstate <= ST_IDLE;
				mst <= M_ACQ_REQ;
			end
			else if (mounted && !toc_ready) begin
				// Need-driven (re)acquisition — HW root cause 2026-07-17, probe
				// CDA0 showed mounted=1/toc_ready=0/toc_fetches=1/mst=IDLE: the
				// PRAM late-load AUTO-RESTART resets this FSM mid-acquisition;
				// the scsi.v mounted latch survives the restart but the
				// img_mounted PULSE never repeats, so the pulse-driven trigger
				// above never re-fires and every 0xC1 serves a zeroed TOC ("one
				// track", PLAY rejected). Also covers the first-mount ordering
				// fragility (pulse vs latch update). Terminates: acquisition
				// always ends in toc_ready=1 (real blob or synthesized).
				toc_valid <= 1'b0; blob_blk <= 1'b0;
				mst <= M_ACQ_REQ;
			end
			else if (cmd_pend) begin
				cmd_pend <= 1'b0;
				mst <= M_CMD;
			end
			else begin
				ref_cnt <= ref_cnt + 16'd1;
				if ((&ref_cnt) && toc_ready && mounted) begin
					ref_abs <= cur_lba;
					scan_idx <= 0; scan_best_trk <= 0;
					scan_best_start <= 0; scan_best_ctrl <= 8'h14;
					step <= 0;
					mst <= toc_valid ? M_REF_SCAN : M_REF_DIVA;
				end
			end
		end

		// -------------------------------------------------- TOC blob fetch
		M_ACQ_REQ: if (ch_grant && !fr_act) begin
			toc_lba  <= TOC_BLK + {31'd0, blob_blk};
			toc_rd   <= 1'b1;
			toc_act  <= 1'b1;
			blob_cap <= 1'b1;
			dbg_toc_fetch_cnt <= dbg_toc_fetch_cnt + 8'd1;
			mst <= M_ACQ_WAIT;
		end
		M_ACQ_WAIT: begin
			if (io_ack) toc_rd <= 1'b0;
			if (ack_fall && toc_act) begin
				toc_act  <= 1'b0;
				blob_cap <= 1'b0;
				if (!blob_blk) begin blob_blk <= 1'b1; mst <= M_ACQ_REQ; end
				else begin blob_ra <= 9'd0; step <= 0; mst <= M_HDR_RD; end
			end
		end

		// ------------------------------------------ header words 0..5 stream
		// step k: blob_q holds word k-2 (addr set at k-1); capture accordingly
		M_HDR_RD: begin
			blob_ra <= blob_ra + 9'd1;
			step <= step + 3'd1;
			case (step)
			3'd2: toc_valid <= (blob_b0 == "M") && (blob_b1 == "C");       // word0
			3'd3: if (!((blob_b0 == "D") && (blob_b1 == "A"))) toc_valid <= 1'b0; // word1
			3'd4: ;                                                        // word2: version/first
			3'd5: begin                                                    // word3: {data_trk, last}
				if (toc_valid)
					n_tracks <= (blob_b0 == 8'd0) ? 7'd1 :
					            (blob_b0 > 8'd99) ? 7'd99 : blob_b0[6:0];
			end
			3'd6: if (toc_valid) leadout_lba[15:0]  <= blob_q;             // word4
			3'd7: begin                                                    // word5
				if (toc_valid) leadout_lba[31:16] <= blob_q;
				else begin
					n_tracks    <= 7'd1;
					leadout_lba <= {2'd0, img_blocks[31:2]};               // 2048-blocks
				end
				step <= 0; emit_k <= 0;
				mst <= M_EMIT_H;
			end
			default: ;
			endcase
		end

		// ------------------------------------------ response header [0..3]
		M_EMIT_H: begin
			resp_we <= 1'b1;
			emit_k  <= emit_k + 2'd1;
			case (emit_k)
			2'd0: begin resp_wa <= 9'd0; resp_wd <= 8'h01; end
			2'd1: begin resp_wa <= 9'd1; resp_wd <= bin2bcd({1'b0, n_tracks}); end
			2'd2: begin resp_wa <= 9'd2; resp_wd <= 8'h00; end
			default: begin
				resp_wa <= 9'd3; resp_wd <= 8'h00;
				div_v <= leadout_lba; div_m <= 0; div_s <= 0;
				mst <= M_LO_DIV;
			end
			endcase
		end
		M_LO_DIV: begin
			if ((div_v >= 32'd4500) && (div_m != 7'd99)) begin
				div_v <= div_v - 32'd4500; div_m <= div_m + 7'd1;
			end
			else if (div_v >= 32'd75) begin
				div_v <= div_v - 32'd75; div_s <= div_s + 7'd1;
			end
			else begin emit_k <= 0; mst <= M_EMIT_LO; end
		end
		M_EMIT_LO: begin
			resp_we <= 1'b1;
			emit_k  <= emit_k + 2'd1;
			case (emit_k)
			2'd0: begin resp_wa <= 9'd4; resp_wd <= bin2bcd({1'b0, div_m}); end
			2'd1: begin resp_wa <= 9'd5; resp_wd <= bin2bcd({1'b0, div_s}); end
			2'd2: begin resp_wa <= 9'd6; resp_wd <= bin2bcd(div_v[7:0]); end
			default: begin
				resp_wa <= 9'd7; resp_wd <= 8'h00;
				t_idx <= 0; step <= 0;
				mst <= M_TRK_RD;
			end
			endcase
		end

		// ---------------------------------- per-track descriptors, k = 0..98
		// stream entry words +0..+2 (ctrl, start lo, start hi); clamp index
		M_TRK_RD: begin
			if (!toc_valid) begin
				// synthesized single data track at LBA 0
				t_ctrl <= 8'h14; t_start <= 32'd0;
				div_v <= 32'd0; div_m <= 0; div_s <= 0;
				mst <= M_TRK_DIV;
			end else begin
				step <= step + 3'd1;
				case (step)
				3'd0: blob_ra <= 9'd8  + {(t_idx < n_tracks ? t_idx : n_tracks - 7'd1), 2'b00};
				3'd1: blob_ra <= blob_ra + 9'd1;
				3'd2: begin t_ctrl        <= blob_b0; blob_ra <= blob_ra + 9'd1; end
				3'd3: t_start[15:0]  <= blob_q;
				default: begin
					t_start[31:16] <= blob_q;
					div_v <= {blob_q, t_start[15:0]};
					div_m <= 0; div_s <= 0; step <= 0;
					mst <= M_TRK_DIV;
				end
				endcase
			end
		end
		M_TRK_DIV: begin
			if ((div_v >= 32'd4500) && (div_m != 7'd99)) begin
				div_v <= div_v - 32'd4500; div_m <= div_m + 7'd1;
			end
			else if (div_v >= 32'd75) begin
				div_v <= div_v - 32'd75; div_s <= div_s + 7'd1;
			end
			else begin emit_k <= 0; mst <= M_EMIT_TRK; end
		end
		M_EMIT_TRK: begin
			resp_we <= 1'b1;
			emit_k  <= emit_k + 2'd1;
			case (emit_k)
			2'd0: begin resp_wa <= 9'd8  + {t_idx, 2'b00}; resp_wd <= t_ctrl; end
			2'd1: begin resp_wa <= 9'd9  + {t_idx, 2'b00}; resp_wd <= bin2bcd({1'b0, div_m}); end
			2'd2: begin resp_wa <= 9'd10 + {t_idx, 2'b00}; resp_wd <= bin2bcd({1'b0, div_s}); end
			default: begin
				resp_wa <= 9'd11 + {t_idx, 2'b00}; resp_wd <= bin2bcd(div_v[7:0]);
				if (t_idx == 7'd98) mst <= M_BUILT;
				else begin t_idx <= t_idx + 7'd1; step <= 0; mst <= M_TRK_RD; end
			end
			endcase
		end
		M_BUILT: begin
			toc_ready <= 1'b1;
			mst <= M_IDLE;
		end

		// -------------------------------------------------- command execute
		M_CMD: begin
			mst <= M_IDLE;   // default; overridden below
			case (c_op)
			8'hca: begin                                   // AUDIO PAUSE
				if (c_1 == 8'h10) begin
					if (pstate == ST_PLAY) pstate <= ST_PAUSE;
				end else if (pstate == ST_PAUSE) pstate <= ST_PLAY;
			end
			8'hc8, 8'hc9, 8'hcb, 8'hcd: begin              // SEARCH/PLAY/STOP/SCAN
				case (c_9[7:6])
				2'b01: begin                               // MSF (C9: bytes 3..5, else 5..7)
					c_addr <= (c_op == 8'hc9) ? msf2lba(c_3, c_4, c_5)
					                          : msf2lba(c_5, c_6, c_7);
					mst <= M_APPLY;
				end
				2'b10: begin                               // track number (BCD byte 5)
					if (bcd2bin(c_5) == 8'd0) begin
						// track 0: stop (oracle: PLAY/SEARCH track 0 stops)
						if (c_op != 8'hcb) pstate <= ST_IDLE;
					end else begin
						c_trk <= (bcd2bin(c_5) - 8'd1 < 8'd99) ? bcd2bin(c_5) - 8'd1 : 7'd98;
						step  <= 0;
						mst   <= toc_valid ? M_CTRK_RD : M_APPLY;
						if (!toc_valid) begin c_addr <= 32'd0; c_next <= leadout_lba; end
					end
				end
				default: begin                             // LBA (big-endian 2..5)
					c_addr <= {c_2, c_3, c_4, c_5};
					mst <= M_APPLY;
				end
				endcase
			end
			default: ;                                     // 0xCE handled in scsi.v
			endcase
		end
		// track mode: read start(k) then start(k+1) (or leadout when last).
		// Address stream one word per cycle; data arrives two states later
		// (same convention as M_HDR_RD/M_TRK_RD).
		M_CTRK_RD: begin
			step <= step + 3'd1;
			case (step)
			3'd0: blob_ra <= 9'd9 + {(c_trk < n_tracks ? c_trk : n_tracks - 7'd1), 2'b00};
			3'd1: blob_ra <= blob_ra + 9'd1;
			3'd2: begin
				c_addr[15:0] <= blob_q;                    // start(k) lo
				blob_ra <= 9'd9 + {((c_trk + 7'd1) < n_tracks ? (c_trk + 7'd1) : n_tracks - 7'd1), 2'b00};
			end
			3'd3: begin
				c_addr[31:16] <= blob_q;                   // start(k) hi
				blob_ra <= blob_ra + 9'd1;
			end
			3'd4: c_next[15:0] <= blob_q;                  // start(k+1) lo
			default: begin
				c_next[31:16] <= blob_q;                   // start(k+1) hi
				if ((c_trk + 7'd1) >= n_tracks) c_next <= leadout_lba;
				step <= 0;
				mst <= M_APPLY;
			end
			endcase
		end
		M_APPLY: begin
			mst <= M_IDLE;
			case (c_op)
			8'hcb: begin                                   // STOP: set stop position
				stop_lba <= (c_9[7:6] == 2'b10) ? c_next : c_addr;
				if ((pstate == ST_PLAY || pstate == ST_PAUSE) &&
				    (cur_lba >= ((c_9[7:6] == 2'b10) ? c_next : c_addr)))
					pstate <= ST_IDLE;
			end
			8'hc9: begin                                   // PLAY
				if (c_1[4]) begin
					// address is the END; start stays at current position
					stop_lba <= c_addr;
					if (cur_lba < c_addr) pstate <= ST_PLAY;
				end else begin
					cur_lba <= c_addr;
					flush   <= 1'b1;
					pstate  <= ST_PLAY;
					if (c_9[7:6] == 2'b10) stop_lba <= leadout_lba;
					else if (stop_lba <= c_addr) stop_lba <= leadout_lba;
				end
			end
			default: begin                                 // SEARCH (0xC8) / SCAN (0xCD, v1 = seek)
				cur_lba <= c_addr;
				flush   <= 1'b1;
				if (c_9[7:6] == 2'b10) stop_lba <= c_next;
				else if (stop_lba <= c_addr) stop_lba <= leadout_lba;
				pstate  <= c_1[4] ? ST_PLAY : ST_PAUSE;
			end
			endcase
		end

		// -------------------------------- status refresh (track + abs/rel MSF)
		M_REF_SCAN: begin
			step <= step + 3'd1;
			case (step)
			3'd0: blob_ra <= 9'd8 + {scan_idx, 2'b00};
			3'd1: blob_ra <= blob_ra + 9'd1;
			3'd2: begin scan_ctrl_c <= blob_b0; blob_ra <= blob_ra + 9'd1; end
			3'd3: scan_start[15:0] <= blob_q;
			default: begin
				if ({blob_q, scan_start[15:0]} <= ref_abs) begin
					scan_best_start <= {blob_q, scan_start[15:0]};
					scan_best_trk   <= scan_idx;
					scan_best_ctrl  <= scan_ctrl_c;
				end
				step <= 0;
				if ((scan_idx + 7'd1) < n_tracks) scan_idx <= scan_idx + 7'd1;
				else begin
					div_v <= ref_abs; div_m <= 0; div_s <= 0;
					mst <= M_REF_DIVA;
				end
			end
			endcase
		end
		M_REF_DIVA: begin
			if (!toc_valid && step == 3'd0) begin
				// fallback path enters here directly: single data track at 0
				scan_best_start <= 32'd0; scan_best_trk <= 7'd0; scan_best_ctrl <= 8'h14;
				div_v <= ref_abs; div_m <= 0; div_s <= 0;
				step <= 3'd1;
			end
			else if ((div_v >= 32'd4500) && (div_m != 7'd99)) begin
				div_v <= div_v - 32'd4500; div_m <= div_m + 7'd1;
			end
			else if (div_v >= 32'd75) begin
				div_v <= div_v - 32'd75; div_s <= div_s + 7'd1;
			end
			else begin
				refm_hold <= div_m; refs_hold <= div_s;
				abs_f <= bin2bcd(div_v[7:0]);
				ref_rel <= ref_abs - scan_best_start;
				div_v <= ref_abs - scan_best_start; div_m <= 0; div_s <= 0;
				step <= 0;
				mst <= M_REF_DIVR;
			end
		end
		M_REF_DIVR: begin
			if ((div_v >= 32'd4500) && (div_m != 7'd99)) begin
				div_v <= div_v - 32'd4500; div_m <= div_m + 7'd1;
			end
			else if (div_v >= 32'd75) begin
				div_v <= div_v - 32'd75; div_s <= div_s + 7'd1;
			end
			else begin
				abs_m <= bin2bcd({1'b0, refm_hold});
				abs_s <= bin2bcd({1'b0, refs_hold});
				rel_m <= bin2bcd({1'b0, div_m});
				rel_s <= bin2bcd({1'b0, div_s});
				rel_f <= bin2bcd(div_v[7:0]);
				cur_ctrl    <= scan_best_ctrl;
				cur_trk_bcd <= bin2bcd({1'b0, scan_best_trk} + 8'd1);
				mst <= M_IDLE;
			end
		end
		default: mst <= M_IDLE;
		endcase
	end
end

// ============================================================================
// FETCH FSM: fill the free frame half while playing
// ============================================================================
reg  [1:0] fr_valid;
reg        fr_half_r;                  // half being played (owned by sample engine? no: here)
reg  [1:0] fst;

// CDA0 probe word (all fields declared above by here; layout in the port list)
assign dbg_cda0 = { dbg_fr_fetch_cnt, dbg_toc_fetch_cnt,
                    fst, pstate, mst, n_tracks, toc_valid, toc_ready, mounted };
reg [31:0] fetch_lba;
reg        fetch_sync;                 // reload fetch_lba from cur_lba
localparam F_IDLE = 2'd0, F_REQ = 2'd1, F_WAIT = 2'd2;

// sample engine tells us when it consumed a frame / which half it reads
wire       sample_consume;             // = frame_done
wire       sample_half = fr_half_r;

always @(posedge clk) begin
	if (rst) begin
		fst <= F_IDLE; fr_cap <= 0; fr_valid <= 2'b00; fr_half_w <= 0; fr_blk <= 0;
		fr_rd <= 0; fr_act <= 0; fr_lba <= 0; fetch_lba <= 0; fetch_sync <= 1'b1;
	end else begin
		if (flush) begin fr_valid <= 2'b00; fetch_sync <= 1'b1; end
		else if (frame_done) fr_valid[sample_half] <= 1'b0;

		case (fst)
		F_IDLE: begin
			fr_cap <= 1'b0;
			if (fetch_sync) begin fetch_lba <= cur_lba; fetch_sync <= 1'b0; end
			else if ((pstate == ST_PLAY) && mounted && toc_ready &&
			         !(&fr_valid) && (fetch_lba < stop_lba)) begin
				fr_half_w <= fr_valid[0] ? 1'b1 : 1'b0;
				fr_blk    <= 3'd0;
				fst <= F_REQ;
			end
		end
		F_REQ: begin
			if (flush) fst <= F_IDLE;
			else if (ch_grant && !toc_act && !toc_rd && !fr_rd && (mst == M_IDLE)) begin
				fr_lba <= AUDIO_BLK + (fetch_lba * 32'd5) + {29'd0, fr_blk};
				fr_rd  <= 1'b1;
				fr_act <= 1'b1;
				fr_cap <= 1'b1;
				dbg_fr_fetch_cnt <= dbg_fr_fetch_cnt + 5'd1;
				fst <= F_WAIT;
			end
		end
		F_WAIT: begin
			if (io_ack) fr_rd <= 1'b0;
			if (ack_fall && fr_act) begin
				fr_act <= 1'b0;
				fr_cap <= 1'b0;
				if (fr_blk == 3'd4) begin
					fr_valid[fr_half_w] <= 1'b1;
					fetch_lba <= fetch_lba + 32'd1;
					fst <= F_IDLE;
				end else begin
					fr_blk <= fr_blk + 3'd1;
					fst <= F_REQ;
				end
			end
		end
		default: fst <= F_IDLE;
		endcase
	end
end

// ============================================================================
// SAMPLE engine: 44.1 kHz cadence; a frame = 588 stereo samples = 1176 words
// ============================================================================
reg [31:0] acc;
reg [10:0] widx;
reg  [1:0] sph;
reg        frame_done_r;
assign frame_done = frame_done_r;

always @(posedge clk) begin
	if (rst) begin
		acc <= 0; widx <= 0; sph <= 0; frame_done_r <= 0;
		snd_l <= 0; snd_r <= 0; fr_half_r <= 0; frame_ra <= 0;
	end else begin
		frame_done_r <= 1'b0;
		if (flush) begin
			widx <= 0; acc <= 0; sph <= 0; fr_half_r <= 1'b0;
		end
		else if (pstate == ST_PLAY && fr_valid[fr_half_r]) begin
			if (sph == 2'd0) begin
				acc <= acc + 32'd44_100;
				if (acc >= (CLK_HZ - 32'd44_100)) begin
					acc <= acc + 32'd44_100 - CLK_HZ;
					frame_ra <= {fr_half_r, widx};      // 1 + 11 = 12 bits
					sph <= 2'd1;
				end
			end else begin
				sph <= sph + 2'd1;
				case (sph)
				2'd1: frame_ra <= {fr_half_r, widx + 11'd1};
				2'd2: snd_l <= frame_q;
				default: begin
					snd_r <= frame_q; sph <= 2'd0;
					if (widx == 11'd1174) begin
						widx <= 0;
						fr_half_r <= ~fr_half_r;
						frame_done_r <= 1'b1;
					end else widx <= widx + 11'd2;
				end
				endcase
			end
		end
		else begin
			if (pstate != ST_PLAY) begin snd_l <= 0; snd_r <= 0; end
			// underrun (half not ready): hold position, emit silence
			if (pstate != ST_PLAY) acc <= 0;
		end
	end
end

endmodule

// Minimal simple-dual-port RAM (one write, one registered read) for the
// single-reader buffers above — scsi_dpram would burn two unused mirror
// arrays per instance (the map.rpt M10K check applies here; see the
// 2026-07-07 BRAM-inference lesson: exactly one write statement per array).
module cd_sdp #(parameter DW = 16, AW = 12)
(
	input           clock,
	input  [AW-1:0] waddr,
	input  [DW-1:0] wdata,
	input           wr,
	input  [AW-1:0] raddr,
	output reg [DW-1:0] q
);
// vram_bram's hardware-proven inference recipe (see rtl/vram_bram.sv):
// forced "M10K" (overrides the small-RAM heuristic that silently turned the
// 2 Kbit response planes into ~2000 registers each — fit attempts #1-#3 of
// this file) + no_rw_check, with write and read in SEPARATE always blocks.
(* ramstyle = "M10K,no_rw_check" *) reg [DW-1:0] ram [0:(1<<AW)-1];
always @(posedge clock) if (wr) ram[waddr] <= wdata;
always @(posedge clock) q <= ram[raddr];
endmodule
