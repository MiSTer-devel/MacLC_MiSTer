/* tb_floppy_commit.v — Phase 3b gate: sector -> SDRAM, end to end.
 *
 * THE CHAIN IS THE WHOLE POINT. image -> the real floppy_track_encoder ->
 * GCR bytes -> the real IWM write pacing -> the real floppy_track_decoder ->
 * the real floppy_write_committer -> an SDRAM model, and then the model's
 * bytes are compared against the ORIGINAL image. Every stage is the shipping
 * module. A unit test of the committer alone, fed synthetic buffer contents,
 * would miss the one defect this port is most exposed to:
 *
 *   ★ THE BYTE-PAIR SWAP. floppy_track_decoder's buf_data is a REGISTERED read
 *   (valid one clock after buf_addr). MacPlus records that an earlier committer
 *   paired with a COMBINATIONAL read and captured one state earlier throughout;
 *   when the read was later made registered, every byte pair silently
 *   transposed. Nothing about that is visible in either module alone — only in
 *   the bytes that come out the far end. Hence this bench.
 *
 * AND THE PACKING IS NOT A FREE CHOICE. The word is {EVEN byte, ODD byte},
 * because that is what this core's read path already does
 * (MacLC.sv extra_rom_data_demux: odd -> [7:0], even -> [15:8]) and what
 * floppy_loader.v writes. So the model below unpacks with the READ path's
 * convention, not the committer's — if the committer packed the other way this
 * bench fails, which is the direction the check has to run.
 *
 * ACK IS SPARSE AND LATE, DELIBERATELY. The real download port grants roughly
 * every 2us, not every cycle. An ack-always-ready model would never exercise
 * the LEVEL handshake's hold, which is the part that silently drops a word if
 * it is torn down between RAS and CAS (the hazard rtl/sdram.v's dl_* comment
 * describes). ACK_GAP is deliberately not a multiple of the FSM's period.
 *
 * Build + run (Icarus 12.x, from the REPO ROOT):
 *   python scripts/gcr_gen_image.py --hex
 *   /c/iverilog/bin/iverilog -g2012 -s tb_floppy_commit \
 *     -o scratch/gcr_phase3/tb_commit.vvp verilator/tb_floppy_commit.v \
 *     rtl/floppy_track_encoder.v rtl/floppy_track_decoder.v \
 *     rtl/floppy_write_committer.v
 *   /c/iverilog/bin/vvp scratch/gcr_phase3/tb_commit.vvp
 */
`timescale 1ns/1ps

module tb_floppy_commit;

   localparam ACK_GAP = 7;   // cycles the SDRAM model makes a request wait

   reg clk = 0;
   always #5 clk = ~clk;

   reg [1:0] phase = 0;
   always @(posedge clk) phase <= phase + 1'b1;
   wire cep = (phase == 2'd0);
   wire cen = (phase == 2'd2);

   reg _reset = 0;
   reg side = 0, sides = 1;
   reg [6:0] track = 0;

   // ---- image + encoder ----------------------------------------------------
   reg [7:0] mem [0:819199];
   wire [21:0] enc_addr;
   wire [7:0]  enc_odata;
   reg         enc_ready = 0;
   floppy_track_encoder enc (
      .clk(clk), .ready(enc_ready), .rst(!_reset),
      .side(side), .sides(sides), .track(track),
      .addr(enc_addr), .idata(mem[enc_addr]), .odata(enc_odata),
      // format relay idle (plan Phase 6A): this bench drives the read side only
      .wr_byte(1'b0), .wr_mark(1'b0), .wr_mark_sector(4'd0), .wr_end(1'b0)
   );

   // ---- the write engine, transcribed from rtl/floppy.v --------------------
   reg        writeReq = 0, writeProtect = 0, _enable = 0, insertDisk = 1;
   reg        cstin = 0, writePathReset = 0;
   reg [7:0]  writeData = 0;
   reg        writeBusyReg, writeUnderrunReg, decReady;
   reg [6:0]  writeByteTimer;
   reg [7:0]  pendingWriteByte;

   always @(posedge clk or negedge _reset) begin
      if (!_reset) begin
         writeBusyReg <= 0; writeByteTimer <= 0; pendingWriteByte <= 0;
         writeUnderrunReg <= 0; decReady <= 0;
      end else if (writePathReset) begin
         writeBusyReg <= 0; writeByteTimer <= 0; decReady <= 0;
      end else begin
         decReady <= 1'b0;
         if (cep && writeBusyReg) begin
            if (_enable) begin writeBusyReg <= 0; writeUnderrunReg <= 1; end
            else if (writeByteTimer == 7'd127) begin
               writeBusyReg <= 0; decReady <= 1'b1;
            end else writeByteTimer <= writeByteTimer + 1'b1;
         end
         if (writeReq && !_enable && !writeProtect && !writeBusyReg &&
             !cstin && insertDisk) begin
            pendingWriteByte <= writeData;
            writeBusyReg <= 1'b1; writeByteTimer <= 7'd0; writeUnderrunReg <= 1'b0;
         end
      end
   end

   // ---- decoder ------------------------------------------------------------
   wire        secValid, secReject, secAmark, secFmtMark, secFmtDs;
   wire [3:0]  secNum, secAmarkSector;
   wire [21:0] secAddr;
   wire [8:0]  wcBufAddr;
   wire [7:0]  wcBufData;

   floppy_track_decoder dec (
      .clk(clk), .ready(decReady), .rst(!_reset || writePathReset),
      .side(side), .sides(sides), .track(track),
      .idata(pendingWriteByte),
      .sector_valid(secValid), .sector(secNum), .addr(secAddr),
      .reject(secReject),
      .amark(secAmark), .amark_sector(secAmarkSector),
      .fmt_mark(secFmtMark), .fmt_ds(secFmtDs),
      .buf_addr(wcBufAddr), .buf_data(wcBufData)
   );

   // ---- the committer under test -------------------------------------------
   wire [21:0] wc_addr, wc_committed;
   wire [15:0] wc_data;
   wire        wc_req, wc_busy, wc_done;
   reg         wc_ack = 0;

   floppy_write_committer wc (
      .clk(clk), .rst(!_reset || writePathReset),
      .sector_valid(secValid), .sector_addr(secAddr),
      .buf_addr(wcBufAddr), .buf_data(wcBufData),
      .wr_addr(wc_addr), .wr_data(wc_data),
      .wr_req(wc_req), .wr_ack(wc_ack),
      .busy(wc_busy), .done(wc_done), .committed_addr(wc_committed)
   );

   // ---- SDRAM model: sparse, late acks -------------------------------------
   // Stores by BYTE address using the READ path's unpack convention, so a
   // committer that packed the pair the other way is caught here.
   reg [7:0] sdram [0:819199];
   integer   ack_wait = 0, words_written = 0, done_count = 0;
   reg [21:0] last_committed;

   always @(posedge clk) begin
      if (!_reset) begin
         wc_ack <= 1'b0; ack_wait <= 0;
      end else begin
         if (wc_req && !wc_ack) begin
            if (ack_wait == ACK_GAP) begin
               sdram[wc_addr]        <= wc_data[15:8];  // EVEN byte, high half
               sdram[wc_addr + 22'd1] <= wc_data[7:0];  // ODD byte,  low half
               words_written <= words_written + 1;
               wc_ack   <= 1'b1;
               ack_wait <= 0;
            end else ack_wait <= ack_wait + 1;
         end else if (!wc_req) wc_ack <= 1'b0;
      end
      if (wc_done) begin
         done_count <= done_count + 1;
         last_committed <= wc_committed;
      end
   end

   // ---- bookkeeping ---------------------------------------------------------
   integer checks = 0, fails = 0;
   task chk;
      input cond;
      input [8*96-1:0] what;
      begin
         checks = checks + 1;
         if (!cond) begin fails = fails + 1; $display("  FAIL: %0s", what); end
      end
   endtask

   integer w, i;
   task cpu_write_byte;
      input [7:0] b;
      begin
         #1 writeData = b; writeReq = 1'b1;
         for (w = 0; w < 3; w = w + 1) begin
            @(posedge clk); while (!cen) @(posedge clk); #1;
         end
         @(posedge clk); #1 writeReq = 1'b0;
         while (writeBusyReg) begin @(posedge clk); #1; end
         // the committer needs ~256 * (4 + ACK_GAP) cycles; the next disk byte
         // is 128 cep away (512 clk), so a drain overlaps the following bytes.
         // That is exactly what happens on hardware, so it is left to overlap.
      end
   endtask

   task enc_step;
      begin
         repeat (8) @(posedge clk);
         #1 enc_ready = 1;
         @(posedge clk);
         #1 enc_ready = 0;
      end
   endtask

   integer bad, sec, base, n_checked;
   reg [8*96-1:0] msg;

   initial begin
      $readmemh("scratch/gcr_phase0/image.hex", mem);
      for (i = 0; i < 819200; i = i + 1) sdram[i] = 8'hEE;  // poison
      $display("tb_floppy_commit: encoder -> decoder -> committer -> SDRAM");

      #1 _reset = 0;
      repeat (4) @(posedge clk);
      @(negedge clk); #1 _reset = 1;
      @(negedge clk); #1;

      // one full revolution of track 0 side 0 = 12 sectors
      for (i = 0; i < 10000; i = i + 1) begin
         cpu_write_byte(enc_odata);
         enc_step;
      end
      // let the last drain finish
      repeat (20000) @(posedge clk);

      $sformat(msg, "committed %0d sectors, expected 12", done_count);
      chk(done_count >= 12, msg);
      $sformat(msg, "wrote %0d words, expected %0d", words_written, done_count*256);
      chk(words_written == done_count*256, msg);

      // every sector of track 0 side 0 must be byte-identical in SDRAM
      n_checked = 0;
      for (sec = 0; sec < 12; sec = sec + 1) begin
         base = sec * 512;                 // track 0 side 0: soff=0
         bad = 0;
         for (i = 0; i < 512; i = i + 1)
            if (sdram[base + i] !== mem[base + i]) bad = bad + 1;
         $sformat(msg, "sector %0d: %0d of 512 bytes wrong in SDRAM", sec, bad);
         chk(bad == 0, msg);
         if (bad == 0) n_checked = n_checked + 1;
      end
      $display("  %0d/12 sectors byte-identical in SDRAM, %0d words written",
               n_checked, words_written);

      // nothing outside those sectors may have been touched
      bad = 0;
      for (i = 12*512; i < 12*512 + 2048; i = i + 1)
         if (sdram[i] !== 8'hEE) bad = bad + 1;
      $sformat(msg, "%0d bytes written OUTSIDE the sectors that were committed", bad);
      chk(bad == 0, msg);

      // a reset mid-drain must abandon cleanly and drop the request
      #1 writePathReset = 1'b1;
      @(posedge clk); @(posedge clk); #1 writePathReset = 1'b0; #1;
      chk(wc_req === 1'b0, "reset mid-drain must drop wr_req");
      chk(wc_busy === 1'b0, "reset mid-drain must return the committer to idle");

      $display("");
      if (fails == 0) $display("tb_floppy_commit: PASS - %0d checks", checks);
      else            $display("tb_floppy_commit: FAIL - %0d of %0d checks failed", fails, checks);
      $finish;
   end

endmodule
