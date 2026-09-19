/* tb_floppy_format_relay.v — the GCR FORMAT RELAY gate (plan Phase 6A).
 *
 * WHY THIS EXISTS. The relay is the one piece of Phase 6 with a hardware
 * failure mode that no existing bench touches. The ROM requires that the FIRST
 * address field it reads back after formatting a track is the sector the
 * format wrote first; a free-running read side presents whatever sector the
 * head happens to be over and the format fails with fmt1Err. The relay makes
 * the read-side encoder restart its layout at the written sector.
 *
 * ★ THE DONOR HAS NO BENCH FOR THIS. MacPlus_MiSTer (rtl/floppy_track_encoder.v
 * at b340c9f, where the relay was written) ships no tb_* at all; the relay's
 * only validation there was hardware, through a chained external drive on a
 * Plus. This is the first bench it has ever had, not a port of one.
 *
 * WHAT IS REAL HERE. Everything on the path: the shipping rtl/floppy.v with
 * WRITE_SUPPORT=1, so the byte pacing, decReady, the GCR decoder's amark
 * report, the writeMode/writeBusyReg-derived wrEnd and the encoder's relay are
 * all the synthesised logic. Only three things are bench-side:
 *   - a SECOND floppy_track_encoder, used purely as a source of well-formed
 *     GCR bytes to play back as "what the guest's format wrote" (the same
 *     trick tb_floppy_write.v uses: feeding synthetic GCR would be testing the
 *     decoder against a second guess at the format);
 *   - a SECOND floppy_track_decoder watching the drive's READ stream, so the
 *     bench reads address-field sector numbers with the shipping decoder
 *     rather than a hand-rolled 6-and-2 table;
 *   - a zero-latency SDRAM model.
 *
 * ★ WHY TWO WRITES WITH DIFFERENT SECTORS. With one write the check is weak:
 * the free-running layout could have been about to emit that sector anyway, so
 * a relay that did nothing would pass. Two writes from the same track, whose
 * first address fields are DIFFERENT sectors, cannot both be coincidences —
 * the read side has to follow each one.
 *
 * ★ CASES 5-7 WRITE A WHOLE REVOLUTION OR MORE (added 2026-09-19). Cases 1-4
 * never write past two sectors, so the relay counter's wrap at rev_len -- the
 * path every real format takes -- was untested until then. They are slow
 * (~3 min each under Icarus); the whole bench is ~10 min. Do not trim them.
 *
 * EDGE DISCIPLINE: stimulus changes #1 after a clock edge, never at one.
 *
 * Build + run (Icarus 12.x, from the REPO ROOT):
 *   /c/iverilog/bin/iverilog -g2012 -s tb_floppy_format_relay \
 *     -o scratch/phase6/tb_relay.vvp verilator/tb_floppy_format_relay.v \
 *     rtl/floppy.v rtl/floppy_track_encoder.v rtl/mfm_track_encoder.v \
 *     rtl/floppy_track_decoder.v rtl/mfm_write_decoder.v \
 *     rtl/floppy_write_committer.v
 *   /c/iverilog/bin/vvp scratch/phase6/tb_relay.vvp
 *
 * Plusargs:
 *   +verbose   print every address field seen on the read stream
 */
`timescale 1ns/1ps

module tb_floppy_format_relay;

   reg clk = 0;
   always #15.384 clk = ~clk;          // ~32.5 MHz clk_sys

   reg [1:0] ph = 0;
   always @(posedge clk) ph <= ph + 2'd1;
   wire cep = (ph == 2'd3);            // 8.125 MHz peripheral enables
   wire cen = (ph == 2'd1);

   integer checks = 0;
   integer errors = 0;
   reg     verbose;
   task ck(input cond, input [8*80-1:0] what);
      begin
         checks = checks + 1;
         if (!cond) begin errors = errors + 1; $display("FAIL: %0s", what); end
         else                                  $display("ok:   %0s", what);
      end
   endtask

   // ── the track under test ───────────────────────────────────────────────
   // ★ TRACK 0, BECAUSE THE DRIVE RESETS THERE. floppy.v's driveTrack is 0 out
   // of reset, and the encoder, the decoder and the relay's rev_len all key
   // off it. An earlier version of this bench used track 79 for its shorter
   // 8-sector revolution and never stepped the head: the bench-side encoder
   // and monitor then ran a different geometry (8 spt) from the drive's (12),
   // and the monitor reported one address field per revolution instead of
   // twelve. Seeking here would only add the STEP register to the list of
   // things this bench can fail on.
   localparam [6:0] TRACK = 7'd0;
   localparam       SIDE  = 1'b0;
   localparam       SIDES = 1'b1;
   localparam integer REV_LEN = 12 * 782;   // the relay's rev_len for track[6:4]==0

   reg _reset = 0;

   // ── the drive ──────────────────────────────────────────────────────────
   reg ca0 = 1'b0, ca1 = 1'b0, ca2 = 1'b0, sel = 1'b0;
   reg lstrb = 1'b0;
   reg [7:0] writeData = 8'h00;
   reg       writeReq  = 1'b0;
   reg       writeMode = 1'b0;

   wire [7:0]  readData;
   wire        newByteReady;
   wire        writeBusy, writeUnderrun;
   wire [21:0] dskReadAddr;
   reg         dskReadAck = 0;
   // The image the encoder reads: a pure function of the address. Only
   // ADDRESS fields are inspected here and those do not depend on the
   // payload, so a synthetic image is exactly as good as a real one.
   wire  [7:0] dskReadData = dskReadAddr[7:0] ^ dskReadAddr[15:8];

   wire        wrSdReq;
   wire [21:0] wrSdAddr;
   wire [15:0] wrSdData;
   reg         wrSdAck = 0;
   always @(posedge clk) wrSdAck <= wrSdReq & ~wrSdAck;

   floppy dut (
      .clk(clk), .cep(cep), .cen(cen), ._reset(_reset),
      .ca0(ca0), .ca1(ca1), .ca2(ca2), .SEL(sel), .lstrb(lstrb),
      ._enable(1'b0),
      .writeData(writeData), .readData(readData),
      .writeReq(writeReq), .writeProtect(1'b0), .writeMode(writeMode),
      .writeBusy(writeBusy), .writeUnderrun(writeUnderrun),
      .wrSecValid(), .wrSecNum(), .wrSecAddr(),
      .wrSdAddr(wrSdAddr), .wrSdData(wrSdData), .wrSdReq(wrSdReq), .wrSdAck(wrSdAck),
      .wrCommitDone(), .wrCommitAddr(),
      .wrSdBufAddr(), .wrSdBufData(), .wrSdBufWr(),
      .advanceDriveHead(1'b1),
      .newByteReady(newByteReady),
      .insertDisk(1'b1), .diskSides(SIDES), .mediaSides(1'b1),
      .diskEject(), .motor(), .act(),
      .dskReadAddr(dskReadAddr), .dskReadAck(dskReadAck), .dskReadData(dskReadData),
      .ism_active(1'b0), .ism_action(1'b0), .ism_sel(1'b0),
      .mfm_disk(1'b0), .mfm_hd(1'b0),
      .mfm_byte(), .mfm_mark(), .mfm_crc0(), .mfm_stb(), .mfm_sector(),
      .mfm_wr_byte(8'd0), .mfm_wr_mark(1'b0), .mfm_wr_stb(1'b0),
      .mfm_wr_anchor(5'd0), .mfm_wr_anchor_ok(1'b0),
      .dbg_byte_cnt(), .dbg_miss_cnt(), .dbg_disk_image_data(),
      .dbg_drive_track(), .dbg_drive_side(), .dbg_step_cnt(),
      .dbg_byte_stb(), .dbg_raw_byte(), .dbg_gcr_addr(),
      .dbg_strb_cnt(), .dbg_strb_en_cnt(), .dbg_strb_last(),
      .dbg_rej_step(), .dbg_status(), .dbg_media(),
      .dbg_mfm_stall_us(), .dbg_mfm_stall_cnt()
   );

   // ★ dskReadAck IS A LEVEL AND floppy.v SAMPLES IT ON cen. The same trap
   // tb_mfm_write_path.v documents: a pulse timed off cep is already low by
   // the sampling edge, no fetch ever completes, and the drive stalls after
   // the track preamble.
   always @(posedge clk) dskReadAck <= 1'b1;

   // ── bench-side: the bytes a guest format would write ───────────────────
   // The shipping encoder run free, so the stream is a real track layout.
   reg         fmt_rst   = 1'b1;
   reg         fmt_ready = 1'b0;
   wire [21:0] fmt_addr;
   wire  [7:0] fmt_odata;
   wire  [7:0] fmt_idata = fmt_addr[7:0] ^ fmt_addr[15:8];

   floppy_track_encoder fmt (
      .clk(clk), .ready(fmt_ready), .rst(fmt_rst),
      .side(SIDE), .sides(SIDES), .track(TRACK),
      .addr(fmt_addr), .idata(fmt_idata), .odata(fmt_odata),
      // this instance is a byte source only; its own relay stays idle
      .wr_byte(1'b0), .wr_mark(1'b0), .wr_mark_sector(4'd0), .wr_end(1'b0)
   );

   // Captured stream, plus where each address field's D5 starts. READY_GAP
   // matters here for the same reason tb_floppy_track_encoder.v documents:
   // the encoder's addr register needs idle cycles to settle before each
   // ready-gated fetch, and holding ready high fetches some bytes twice.
   // >= a whole revolution (12 * 782 = 9384) plus the 1.3-revolution write of
   // case 6 (raised from 5600 on 2026-09-19 when the wrap cases were added)
   localparam integer FMT_BYTES = 12000;
   localparam integer READY_GAP = 8;
   reg  [7:0] fmt_stream [0:FMT_BYTES-1];
   integer    amark_at [0:63];     // index of the D5 of the k-th address field
   integer    n_amark;

   // ★ SAMPLE, THEN ADVANCE — odata is combinational on the encoder's current
   // state, so pulsing ready first and sampling after captures byte i+1 as
   // byte i and shifts the whole stream. tb_floppy_track_encoder.v's run_track
   // does it in this order for the same reason, including deasserting rst away
   // from the posedge (the DUT's reset is `posedge clk or posedge rst`).
   task capture_format_stream;
      integer i, n;
      begin
         fmt_rst = 1'b1;
         @(posedge clk);
         @(negedge clk); #1 fmt_rst = 1'b0;
         @(negedge clk); #1;              // let odata settle before sample 0
         n_amark = 0;
         for (i = 0; i < FMT_BYTES; i = i + 1) begin
            fmt_stream[i] = fmt_odata;    // sample...
            if (i >= 2 && fmt_stream[i] == 8'h96 &&
                fmt_stream[i-1] == 8'hAA && fmt_stream[i-2] == 8'hD5) begin
               if (n_amark < 64) amark_at[n_amark] = i - 2;
               n_amark = n_amark + 1;
            end
            for (n = 0; n < READY_GAP - 1; n = n + 1) @(posedge clk);
            #1 fmt_ready = 1'b1;          // ...then advance
            @(posedge clk);
            #1 fmt_ready = 1'b0;
         end
      end
   endtask

   // ── bench-side: the shipping decoder, watching the READ stream ─────────
   // floppy.v delivers a GCR byte by pulsing newByteReady with the byte in
   // readData (the phases are parked on RDDATA0 below, so readData is the
   // data register rather than a sense bit).
   wire       rd_amark;
   wire [3:0] rd_amark_sector;

   // ★ newByteReady IS A LEVEL, ONE cep PERIOD WIDE — feed the decoder its
   // EDGE. floppy.v hooks its own encoder up as `~old_newByteReady &
   // newByteReady` for exactly this reason. Driving the decoder from the level
   // presents each disk byte four times (once per clk of the cep period),
   // which corrupts every field: the first version of this bench did that and
   // the read side appeared to deliver no address fields at all.
   reg newByteReady_d = 1'b0;
   always @(posedge clk) newByteReady_d <= newByteReady;
   wire rd_stb = newByteReady && !newByteReady_d;

   floppy_track_decoder mon (
      .clk(clk), .ready(rd_stb), .rst(!_reset),
      .side(SIDE), .sides(SIDES), .track(TRACK),
      .idata(readData),
      .sector_valid(), .sector(), .addr(), .reject(),
      .amark(rd_amark), .amark_sector(rd_amark_sector),
      .fmt_mark(), .fmt_ds(),
      .buf_addr(9'd0), .buf_data()
   );

   // the last address field the read side presented, and a counter so a test
   // can wait for "the NEXT one" without racing
   // optional raw dump of the delivered read stream, for offline analysis
   integer dumpfd = 0;
   always @(posedge clk) if (dumpfd != 0 && rd_stb) $fwrite(dumpfd, "%c", readData);

   integer    n_rd_amark = 0;
   reg  [3:0] last_rd_sector = 4'hF;
   integer    rd_bytes = 0;
   integer    rd_bytes_at_amark = 0;
   always @(posedge clk) begin
      if (rd_stb) rd_bytes = rd_bytes + 1;
      if (rd_amark) begin
         n_rd_amark        = n_rd_amark + 1;
         last_rd_sector    = rd_amark_sector;
         rd_bytes_at_amark = rd_bytes;
         if (verbose)
            $display("      read-side address field #%0d: sector %0d at read byte %0d",
                     n_rd_amark, rd_amark_sector, rd_bytes);
      end
   end

   // ── drive plumbing ─────────────────────────────────────────────────────
   task park(input p_ca2, input p_ca1, input p_ca0, input p_sel);
      begin
         @(posedge clk);
         #1 ca2 = p_ca2; ca1 = p_ca1; ca0 = p_ca0; sel = p_sel;
         repeat (16) @(posedge clk);
      end
   endtask

   // a drive-register write: park the command lines, then strobe lstrb
   task cmd(input p_ca2, input p_ca1, input p_ca0, input p_sel);
      begin
         @(posedge clk);
         #1 ca2 = p_ca2; ca1 = p_ca1; ca0 = p_ca0; sel = p_sel;
         repeat (8) @(posedge clk);
         #1 lstrb = 1'b1;
         repeat (8) @(posedge clk);
         #1 lstrb = 1'b0;
         repeat (8) @(posedge clk);
      end
   endtask

   // Hand one byte to the drive the way swim.v does: writeReq is a LEVEL held
   // across the CPU access, and floppy.v's !writeBusyReg guard collapses it to
   // one byte. Driving a tidy one-cycle pulse would leave that guard untested.
   task write_byte(input [7:0] b);
      integer guard;
      begin
         @(posedge clk); #1 writeData = b; writeReq = 1'b1;
         repeat (6) @(posedge clk);
         #1 writeReq = 1'b0;
         guard = 0;
         while (writeBusy && guard < 20000) begin
            @(posedge clk);
            guard = guard + 1;
         end
         if (writeBusy) begin
            $display("FAIL: the drive never finished a write byte");
            errors = errors + 1;
            checks = checks + 1;
         end
      end
   endtask

   // Play `n` bytes of the captured format stream starting at index `from`,
   // with Q7 (write mode) asserted for the whole run, then leave write mode.
   // The relay's wrEnd comes from that release, not from writeBusy.
   //
   // `stall_at`/`stall_clks` inject a CPU STALL after that many bytes: the
   // guest stops feeding the drive for a while and then carries on, which is
   // what an interrupt does to the ROM's write loop. stall_at = 0 means none.
   task play_format_stall(input integer from, input integer n,
                          input integer stall_at, input integer stall_clks);
      integer i;
      begin
         @(posedge clk); #1 writeMode = 1'b1;
         repeat (8) @(posedge clk);
         for (i = 0; i < n; i = i + 1) begin
            write_byte(fmt_stream[from + i]);
            if (stall_at != 0 && i == stall_at) repeat (stall_clks) @(posedge clk);
         end
         @(posedge clk); #1 writeMode = 1'b0;
      end
   endtask

   task play_format(input integer from, input integer n);
      begin
         play_format_stall(from, n, 0, 0);
      end
   endtask

   // wait until the read side presents its next address field
   task wait_next_amark(input integer limit, output ok);
      integer n, was;
      begin
         was = n_rd_amark;
         n = 0; ok = 0;
         while (n < limit && !ok) begin
            @(posedge clk);
            if (n_rd_amark != was) ok = 1;
            n = n + 1;
         end
      end
   endtask

   integer i;
   integer got;
   integer bytes_at_write;

   // ★ THE ENCODER LAYS SECTORS OUT WITH A 2:1 INTERLEAVE, so the k-th address
   // field of a track is NOT sector k. floppy_track_encoder.v's STATE_WAIT
   // advances `sector` by two and folds back through
   // `{3'd0, !sector[0]}` at spt-2 / spt-1, which on a 12-sector track gives
   // 0 2 4 6 8 10 1 3 5 7 9 11. Written out here rather than read back from
   // the decoder: an expectation taken from the same logic under test would
   // move with a defect instead of catching it. (An earlier draft of this
   // bench assumed field k == sector k and reported three failures that were
   // entirely its own.)
   function [3:0] sector_of_field(input integer k);
      begin
         case (k % 12)
         0: sector_of_field = 4'd0;   1: sector_of_field = 4'd2;
         2: sector_of_field = 4'd4;   3: sector_of_field = 4'd6;
         4: sector_of_field = 4'd8;   5: sector_of_field = 4'd10;
         6: sector_of_field = 4'd1;   7: sector_of_field = 4'd3;
         8: sector_of_field = 4'd5;   9: sector_of_field = 4'd7;
         10: sector_of_field = 4'd9;  default: sector_of_field = 4'd11;
         endcase
      end
   endfunction

   // Bring the drive back to a known state: reset clears the relay, the write
   // decoder and the read encoder (which restarts at sector 0, STATE_SYN0), so
   // every case below is independent of the one before it. Without this a
   // write can land while the write decoder is still mid-payload from the
   // previous case, and it then arms on a different address field than the
   // bench intended.
   task fresh_drive;
      begin
         @(posedge clk); #1 _reset = 1'b0;
         repeat (8) @(posedge clk);
         #1 _reset = 1'b1;
         repeat (8) @(posedge clk);
         // MOTORON: the WRITE address is {ca1,ca0,SEL} = 4 = 3'b100, and the
         // value written is ca2, active low.
         cmd(1'b0, 1'b1, 1'b0, 1'b0);
         park(1'b1, 1'b0, 1'b0, 1'b0);          // RDDATA0: readData is the data reg
         // let the head settle into the stream before anything is written
         repeat (200) @(posedge clk);
         while (rd_bytes < 40) @(posedge clk);
      end
   endtask

   // ── one relay case ──────────────────────────────────────────────────────
   // Write `n` bytes of the captured layout starting three bytes before the
   // k-th address field, then assert BOTH halves of the relay's contract:
   //   (a) the read side goes QUIET — no address field for most of a
   //       revolution, because the layout restarted relay_ahead bytes short of
   //       the written mark. A relay that did nothing would present the next
   //       field of its own free-running layout within one sector (782 bytes);
   //   (b) when a field does arrive it is the sector the write laid down.
   // (a) is what actually distinguishes a working relay from an inert one;
   // (b) is what the ROM checks and what fmt1Err reports.
   task relay_case(input integer k, input integer n, input [3:0] expect_sector);
      begin
         relay_case_stall(k, n, expect_sector, 0, 0);
      end
   endtask

   task relay_case_stall(input integer k, input integer n, input [3:0] expect_sector,
                         input integer stall_at, input integer stall_clks);
      begin
         fresh_drive;
         play_format_stall(amark_at[k] - 3, n, stall_at, stall_clks);
         // ★ ZERO THE WITNESS *AFTER* THE WRITE, NOT BEFORE. The head keeps
         // turning while the CPU writes -- a byte costs the same 128 cep
         // either way -- so a write spanning two address fields takes over a
         // sector of read time, and the read side presents its own fields
         // throughout. Those are not what the relay produced; the quiet window
         // starts where the write ends. The relay itself fires two clocks
         // after write mode drops, so nothing of its own is lost here.
         n_rd_amark     = 0;
         bytes_at_write = rd_bytes;

         // (a) one sector's worth of read bytes with nothing presented
         while (rd_bytes - bytes_at_write < 782 && n_rd_amark == 0)
            @(posedge clk);
         ck(n_rd_amark == 0,
            "the layout restarted: no address field for a whole sector after the write");
         if (n_rd_amark != 0)
            $display("      (saw sector %0d only %0d read bytes after the write)",
                     last_rd_sector, rd_bytes_at_amark - bytes_at_write);

         // (b) and the one that eventually arrives is the written sector
         wait_next_amark(12000000, got);
         ck(got != 0, "an address field does arrive after the relay's gap");
         ck(last_rd_sector === expect_sector,
            "the first address field after the format is the sector the format wrote");
         if (verbose)
            $display("      relayed to sector %0d, %0d read bytes after the write",
                     last_rd_sector, rd_bytes_at_amark - bytes_at_write);
      end
   endtask

   initial begin
      verbose = $test$plusargs("verbose");
      if ($test$plusargs("dump")) dumpfd = $fopen("scratch/phase6/relay_read.bin", "wb");

      repeat (8) @(posedge clk);
      #1 _reset = 1;
      repeat (8) @(posedge clk);

      // ── 0. capture the stream a format would write ──────────────────────
      $display("0. capture a real track layout to play back as the format");
      capture_format_stream;
      ck(n_amark >= 6, "the captured stream holds at least six address fields");
      for (i = 0; i < 6; i = i + 1) begin
         if (verbose)
            $display("      captured address field #%0d at byte %0d (sector %0d)",
                     i, amark_at[i], sector_of_field(i));
         if (i > 0)
            ck(amark_at[i] - amark_at[i-1] == 782,
               "captured address fields are one sector (782 bytes) apart");
      end

      // ── 1. a format whose first address field is sector 4 ───────────────
      $display("1. format from field #2 (sector 4): the read side must restart there");
      relay_case(2, 40, sector_of_field(2));

      // ── 2. and again from a DIFFERENT sector ────────────────────────────
      // Two written sectors, two matching restarts. A read side that ignored
      // the relay could coincide with one; it cannot coincide with both.
      $display("2. format from field #5 (sector 10): the read side must follow that");
      relay_case(5, 40, sector_of_field(5));

      // ── 3. one write spanning TWO address fields relays ONCE ────────────
      // ★ 6A.3, AND THE REASON writeMode IS A PORT AT ALL. The relay arms on
      // the FIRST mark and must ignore every later one until the write ends.
      // An end-of-write derived from writeBusyReg instead of IWM Q7 drops at
      // the end of EVERY paced byte: it would relay on the first field,
      // disarm, re-arm on the second, and leave the read side on the LAST
      // sector written rather than the first.
      $display("3. a write spanning two fields relays once, to the FIRST of them");
      relay_case(1, (amark_at[3] - amark_at[1]) + 20, sector_of_field(1));

      // ── 4. a CPU STALL mid-format must not end the write ────────────────
      // ★ THIS IS THE CHECK THAT NEEDS `writeMode`, and the one that a
      // writeBusyReg-derived wrEnd fails. Feeding bytes back to back, the
      // drive is never idle at a cep boundary, so even a broken end-of-write
      // never fires mid-track and cases 1-3 pass either way (measured: that
      // mutant survives all of them). A real format does not have that
      // luxury -- an interrupt in the ROM's write loop leaves a gap, and with
      // wrEnd tied to per-byte busy the relay fires there, restarts the
      // layout in the middle of the format, disarms, and then re-arms on a
      // LATER address field. The disk comes back with the wrong sector first
      // and the ROM answers fmt1Err.
      //
      // The stall is placed after the first address field has gone by, so a
      // spurious relay there would arm again on the second and answer with
      // its sector instead of the first's.
      $display("4. a CPU stall mid-format must not count as the end of the write");
      relay_case_stall(1, (amark_at[3] - amark_at[1]) + 20, sector_of_field(1),
                       40,          // stall after 40 bytes: past field #1
                       2048);       // four byte-times of silence (128 cep each)

      // ── 5-7. WHOLE-REVOLUTION writes: the relay_ahead WRAP path ─────────
      // ★ Added in review 2026-09-19. Cases 1-4 write at most two sectors,
      // but a real format writes at least one full revolution, and that is
      // the only thing that exercises the encoder's
      // `relay_ahead == 0 ? rev_len - 1 : relay_ahead - 1` wrap. The gap the
      // relay leaves is rev_len - 5 - (bytes written after the mark), modulo
      // rev_len; the read-side decoder reports the field 5 bytes after its D5,
      // so the observed gap is that plus 5. Measured on the pre-fold tree:
      // 9332 / 6992 / 8610 read bytes for the three cases, i.e. exact.
      $display("5. a WHOLE-REVOLUTION format from field #0 (sector 0): the wrap path");
      relay_case(0, REV_LEN + 60, sector_of_field(0));

      $display("6. a 1.3-revolution format from field #3 (sector 6): wrap, then relay to the FIRST mark");
      relay_case(3, REV_LEN + 2400, sector_of_field(3));

      $display("7. a format of exactly one sector pitch from field #4 (sector 8)");
      relay_case(4, 782, sector_of_field(4));

      $display("");
      $display("tb_floppy_format_relay: %0d checks, %0d errors", checks, errors);
      if (errors == 0) $display("tb_floppy_format_relay: PASS");
      else             $display("tb_floppy_format_relay: FAIL");
      $finish;
   end

   // deadlock guard. Seven cases at 128 cep per written byte: the whole run
   // is ~1.35 s of simulated time (~12 min wall under Icarus), most of it
   // cases 5-6 writing a revolution and more.
   initial begin
      #3_000_000_000;
      $display("FAIL: timeout — the bench never completed");
      $finish;
   end

endmodule
