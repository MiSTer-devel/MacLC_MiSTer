/* tb_floppy_write.v — Phase 3 gate: the IWM write handshake, end to end.
 *
 * WHY THIS BENCH IS THE GATE (docs/floppy_write_plan.md Phase 3, section 2.1).
 * The ROM's write primitive polls the IWM handshake in an UNBOUNDED loop, so a
 * wrong handshake does not fail a write -- it HANGS the machine. That makes the
 * first hardware run of this code a hang test, and it is worth arriving at that
 * run having already proven, offline, that:
 *   - the handshake's shape is right (busy asserts on accept, clears one byte
 *     time later, and the drive accepts exactly one byte per byte time), and
 *   - a whole sector written through it decodes back to the RIGHT sector at the
 *     RIGHT address, byte-exactly.
 * The second is what makes the first meaningful: a handshake that paces
 * perfectly while delivering the wrong bytes would pass a timing-only test.
 *
 * WHERE THE STIMULUS COMES FROM. The bytes written are the real
 * rtl/floppy_track_encoder.v's own output for that track -- the same source
 * Phase 2 decodes. So this bench closes the loop the guest actually closes:
 * encoder -> (bytes the CPU would write back) -> IWM write register -> pacing
 * -> rtl/floppy_track_decoder.v -> the (sector, addr) tuple. Feeding synthetic
 * GCR instead would test the decoder against a second guess at the format.
 *
 * `writeReq` IS A LEVEL, NOT A PULSE, and the bench drives it as one on
 * purpose. In the core, swim.v holds dataRegWrite for the whole CPU access, so
 * several cen ticks see it asserted; floppy.v's !writeBusyReg guard is what
 * turns that into one byte. Driving a tidy one-cycle pulse here would pass
 * while leaving that guard -- the part that actually does the work -- untested.
 * Case 2 asserts the multi-tick level yields exactly one byte.
 *
 * EDGE DISCIPLINE: stimulus changes #1 after a clock edge, never at one.
 *
 * Build + run (Icarus 12.x, from the REPO ROOT):
 *   python scripts/gcr_gen_image.py --hex
 *   /c/iverilog/bin/iverilog -g2012 -s tb_floppy_write \
 *     -o scratch/gcr_phase3/tb_wr.vvp verilator/tb_floppy_write.v \
 *     rtl/floppy_track_encoder.v rtl/floppy_track_decoder.v
 *   /c/iverilog/bin/vvp scratch/gcr_phase3/tb_wr.vvp
 *
 * NOTE this bench instantiates the encoder and decoder plus a FAITHFUL COPY of
 * floppy.v's write engine (see wr_engine below), not floppy.v itself: floppy.v
 * needs SDRAM, drive registers and the MFM path to do anything at all. The copy
 * is the gate's one weakness -- it can drift. Any edit to floppy.v's write
 * engine must be mirrored here, and the block is deliberately kept a
 * line-for-line transcription so a diff between the two is readable.
 */
`timescale 1ns/1ps

module tb_floppy_write;

   localparam CEP_DIV   = 4;     // clk_sys 32.5MHz -> cep/cen at 8.125MHz
   localparam BYTE_CEPS = 128;   // one disk byte time, as diskDataByteTimer

   reg clk = 0;
   always #5 clk = ~clk;

   // cep and cen never coincide, exactly as in the core
   reg [1:0] phase = 0;
   always @(posedge clk) phase <= phase + 1'b1;
   wire cep = (phase == 2'd0);
   wire cen = (phase == 2'd2);

   reg _reset = 0;
   reg side = 0, sides = 1;
   reg [6:0] track = 0;

   // ---- source of truth: the shipping encoder ------------------------------
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
   reg        writeReq = 0;
   reg [7:0]  writeData = 0;
   reg        writeProtect = 0;
   reg        _enable = 0;        // active low: 0 = this drive is selected
   reg        insertDisk = 1;
   reg        cstin = 0;          // driveRegs[DRIVE_REG_CSTIN], 1 = no disk
   reg        writePathReset = 0;

   reg        writeBusyReg;
   reg [6:0]  writeByteTimer;
   reg [7:0]  pendingWriteByte;
   reg        writeUnderrunReg;
   reg        decReady;

   always @(posedge clk or negedge _reset) begin
      if (_reset == 1'b0) begin
         writeBusyReg     <= 1'b0;
         writeByteTimer   <= 7'd0;
         pendingWriteByte <= 8'd0;
         writeUnderrunReg <= 1'b0;
         decReady         <= 1'b0;
      end else if (writePathReset) begin
         writeBusyReg     <= 1'b0;
         writeByteTimer   <= 7'd0;
         decReady         <= 1'b0;
      end else begin
         decReady <= 1'b0;
         if (cep && writeBusyReg) begin
            if (_enable == 1'b1) begin
               writeBusyReg     <= 1'b0;
               writeUnderrunReg <= 1'b1;
            end else if (writeByteTimer == 7'd127) begin
               writeBusyReg <= 1'b0;
               decReady     <= 1'b1;
            end else begin
               writeByteTimer <= writeByteTimer + 1'b1;
            end
         end
         if (writeReq && _enable == 1'b0 && !writeProtect && !writeBusyReg &&
             !cstin && insertDisk) begin
            pendingWriteByte <= writeData;
            writeBusyReg     <= 1'b1;
            writeByteTimer   <= 7'd0;
            writeUnderrunReg <= 1'b0;
         end
      end
   end

   // ---- the decoder under test ---------------------------------------------
   wire        secValid, secReject, secAmark, secFmtMark, secFmtDs;
   wire [3:0]  secNum, secAmarkSector;
   wire [21:0] secAddr;
   reg  [8:0]  buf_addr = 0;
   wire [7:0]  buf_data;

   floppy_track_decoder dec (
      .clk(clk), .ready(decReady), .rst(!_reset || writePathReset),
      .side(side), .sides(sides), .track(track),
      .idata(pendingWriteByte),
      .sector_valid(secValid), .sector(secNum), .addr(secAddr),
      .reject(secReject),
      .amark(secAmark), .amark_sector(secAmarkSector),
      .fmt_mark(secFmtMark), .fmt_ds(secFmtDs),
      .buf_addr(buf_addr), .buf_data(buf_data)
   );

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

   integer accepted [0:15];
   integer bad_payload [0:15];
   integer bad_addr [0:15];
   integer n_valid, n_reject, n_underrun_seen;
   reg [7:0] recovered [0:511];
   reg [21:0] sv_addr;
   integer sv_sector;

   integer k;
   task read_buf;
      begin
         for (k = 0; k < 512; k = k + 1) begin
            #1 buf_addr = k[8:0];
            @(posedge clk);
            #1 recovered[k] = buf_data;
         end
      end
   endtask

   integer c;
   task check_sector;
      input integer sec;
      input [21:0] a;
      begin
         if (recovered[0] !== track || recovered[1] !== {7'd0, side} ||
             recovered[2] !== sec[7:0])
            bad_payload[sec] = bad_payload[sec] + 1;
         for (c = 3; c < 512; c = c + 1)
            if (recovered[c] !== ((track*7 + side*13 + sec*29 + c) & 8'hFF))
               bad_payload[sec] = bad_payload[sec] + 1;
         for (c = 0; c < 512; c = c + 1)
            if (recovered[c] !== mem[a + c])
               bad_addr[sec] = bad_addr[sec] + 1;
      end
   endtask

   // secValid, secReject and decReady are ONE-CLOCK pulses, and they fire after
   // writeBusyReg drops -- so a task that polls them right after waiting for
   // busy to clear misses every one. Latch them here instead and let the main
   // loop service the latch when it is safe to stall.
   reg        pend_valid = 0;
   reg [3:0]  pend_sec;
   reg [21:0] pend_addr;
   integer    dec_ready_count = 0;
   always @(posedge clk) begin
      if (secValid) begin
         pend_valid <= 1'b1; pend_sec <= secNum; pend_addr <= secAddr;
      end
      if (secReject)  n_reject        <= n_reject + 1;
      if (decReady)   dec_ready_count <= dec_ready_count + 1;
   end

   // cep is REGISTERED, so at a posedge it still holds the value the DUT is
   // acting on; sampling it after the edge (as an @(posedge clk); #1; if (cep)
   // loop does) reads the NEXT tick and counts one short.
   reg     counting = 0;
   integer cep_count = 0;
   always @(posedge clk) if (counting && cep) cep_count <= cep_count + 1;

   task service_valid;
      begin
         if (pend_valid) begin
            sv_sector = pend_sec; sv_addr = pend_addr;
            n_valid = n_valid + 1;
            accepted[sv_sector] = accepted[sv_sector] + 1;
            read_buf;
            check_sector(sv_sector, sv_addr);
            #1 pend_valid = 1'b0;
         end
      end
   endtask

   // ---- one CPU write of `b`, at the cadence the real IWM produces ---------
   // Holds writeReq across several cen ticks (a CPU access is ~10 of them at
   // 16.25MHz E-paced VPA), then waits out the byte time.
   integer w;
   task cpu_write_byte;
      input [7:0] b;
      input integer hold_cens;
      begin
         #1 writeData = b; writeReq = 1'b1;
         for (w = 0; w < hold_cens; w = w + 1) begin
            @(posedge clk); while (!cen) @(posedge clk);
            #1;
         end
         @(posedge clk); #1 writeReq = 1'b0;
         // wait for the engine to finish pacing this byte and hand it over
         while (writeBusyReg) begin @(posedge clk); #1; end
         // decReady pulses at the edge that cleared busy; the decoder consumes
         // on the NEXT one and may then drain up to three buf_mem writes in
         // S_GRPC. Give it room before looking at the result.
         repeat (8) @(posedge clk);
         #1;
         service_valid;
      end
   endtask

   // ---- advance the encoder one byte --------------------------------------
   task enc_step;
      begin
         repeat (CEP_DIV*2) @(posedge clk);
         #1 enc_ready = 1;
         @(posedge clk);
         #1 enc_ready = 0;
      end
   endtask

   integer i, t0, t1;
   reg [8*96-1:0] msg;

   task do_reset;
      begin
         #1 _reset = 0; writeReq = 0; writeProtect = 0; _enable = 0;
            insertDisk = 1; cstin = 0; writePathReset = 0;
         repeat (4) @(posedge clk);
         @(negedge clk); #1 _reset = 1;
         @(negedge clk); #1;
         for (i = 0; i < 16; i = i + 1) begin
            accepted[i] = 0; bad_payload[i] = 0; bad_addr[i] = 0;
         end
         n_valid = 0; n_reject = 0; n_underrun_seen = 0;
         #1 pend_valid = 0; dec_ready_count = 0; cep_count = 0; counting = 0;
      end
   endtask

   initial begin
      $readmemh("scratch/gcr_phase0/image.hex", mem);
      $display("tb_floppy_write: IWM write handshake + round-trip");

      // =====================================================================
      // 1. Handshake shape: busy asserts on accept and clears one byte time
      //    later, and decReady pulses exactly once for that byte.
      // =====================================================================
      do_reset;
      chk(writeBusyReg === 1'b0, "busy should be clear after reset");
      chk(writeUnderrunReg === 1'b0, "underrun should be clear after reset");

      #1 writeData = 8'hD5; writeReq = 1'b1;
      @(posedge clk); while (!cen) @(posedge clk);
      @(posedge clk); #1 writeReq = 1'b0;
      chk(writeBusyReg === 1'b1, "busy must assert once the drive takes the byte");
      chk(pendingWriteByte === 8'hD5, "the accepted byte must be the one written");

      #1 cep_count = 0; counting = 1'b1;
      while (writeBusyReg) begin @(posedge clk); #1; end
      #1 counting = 1'b0;
      t0 = cep_count;
      $sformat(msg, "byte time was %0d cep ticks, expected %0d", t0, BYTE_CEPS);
      chk(t0 == BYTE_CEPS, msg);
      // decReady is set at the edge that cleared busy, so the counting always
      // block sees it on the NEXT edge -- give it that edge before looking.
      repeat (4) @(posedge clk); #1;
      chk(dec_ready_count == 1, "exactly one decReady should follow one byte");

      // =====================================================================
      // 2. A held writeReq yields exactly ONE byte, not one per cen tick.
      //    This is the !writeBusyReg guard -- the part a pulse-shaped stimulus
      //    would never reach.
      // =====================================================================
      // A 68020 access on this machine is E-paced VPA, ~1.23us, so it spans
      // ~10 cen ticks against a 15.75us byte time -- it cannot outlast one
      // byte. Hold it for 12 and require exactly one handover.
      //
      // ★ Held LONGER than a byte time it would hand over a second byte, and
      // that is recorded here as reachable-on-paper-only rather than asserted
      // against: it needs a bus access 13x longer than this machine produces.
      // Back-to-back CPU writes are a different thing and are handled
      // correctly -- the second finds busy still set and is ignored, which is
      // exactly what the IWM does and what the ROM's poll loop expects.
      do_reset;
      #1 writeData = 8'hAA; writeReq = 1'b1;
      for (i = 0; i < 12; i = i + 1) begin
         @(posedge clk); while (!cen) @(posedge clk); #1;
      end
      #1 writeReq = 1'b0;
      while (writeBusyReg) begin @(posedge clk); #1; end
      repeat (8) @(posedge clk); #1;
      t1 = dec_ready_count;
      $sformat(msg, "a held writeReq handed over %0d bytes, expected 1", t1);
      chk(t1 == 1, msg);

      // =====================================================================
      // 3. Refusals. Each must refuse SILENTLY -- no byte taken, and (except
      //    for deselect) no underrun, because an underrun the ROM did not
      //    cause is a good way to make it retry forever.
      // =====================================================================
      do_reset; #1 writeProtect = 1'b1;
      #1 writeData = 8'h96; writeReq = 1'b1;
      repeat (CEP_DIV*8) @(posedge clk); #1 writeReq = 1'b0;
      chk(writeBusyReg === 1'b0, "write-protected: must not accept a byte");
      chk(writeUnderrunReg === 1'b0, "write-protected: must not report underrun");

      do_reset; #1 insertDisk = 1'b0;
      #1 writeData = 8'h96; writeReq = 1'b1;
      repeat (CEP_DIV*8) @(posedge clk); #1 writeReq = 1'b0;
      chk(writeBusyReg === 1'b0, "no disk: must not accept a byte");

      do_reset; #1 cstin = 1'b1;
      #1 writeData = 8'h96; writeReq = 1'b1;
      repeat (CEP_DIV*8) @(posedge clk); #1 writeReq = 1'b0;
      chk(writeBusyReg === 1'b0, "CSTIN says no disk: must not accept a byte");

      do_reset; #1 _enable = 1'b1;
      #1 writeData = 8'h96; writeReq = 1'b1;
      repeat (CEP_DIV*8) @(posedge clk); #1 writeReq = 1'b0;
      chk(writeBusyReg === 1'b0, "drive not selected: must not accept a byte");

      // =====================================================================
      // 4. Deselect MID-BYTE is the one case that must raise underrun: the
      //    byte was taken and then never reached the media.
      // =====================================================================
      do_reset;
      #1 writeData = 8'hAD; writeReq = 1'b1;
      @(posedge clk); while (!cen) @(posedge clk);
      @(posedge clk); #1 writeReq = 1'b0;
      chk(writeBusyReg === 1'b1, "deselect case: the byte should be in flight");
      repeat (CEP_DIV*8) @(posedge clk);
      #1 _enable = 1'b1;                       // yank the drive select
      repeat (CEP_DIV*4) @(posedge clk); #1;
      chk(writeBusyReg === 1'b0, "deselect mid-byte must abandon the byte");
      chk(writeUnderrunReg === 1'b1, "deselect mid-byte must raise underrun");

      // =====================================================================
      // 5. A disk change mid-field must abandon it, so a half-decoded sector
      //    cannot complete with the NEXT image's bytes and commit itself to
      //    the wrong disk (plan section 7, inherited defect 3).
      // =====================================================================
      do_reset;
      #1 writeData = 8'hD5; writeReq = 1'b1;
      @(posedge clk); while (!cen) @(posedge clk);
      @(posedge clk); #1 writeReq = 1'b0;
      chk(writeBusyReg === 1'b1, "media-change case: byte should be in flight");
      repeat (CEP_DIV*4) @(posedge clk);
      #1 writePathReset = 1'b1;
      @(posedge clk); @(posedge clk); #1 writePathReset = 1'b0;
      #1;
      chk(writeBusyReg === 1'b0, "a disk change must abandon the in-flight byte");

      // =====================================================================
      // 6. THE ROUND-TRIP. Write a whole track's GCR stream through the IWM
      //    write register and require every sector back, byte-exact and at the
      //    right address.
      // =====================================================================
      do_reset;
      // the encoder needs its own reset release; it shares _reset
      for (i = 0; i < 10000; i = i + 1) begin
         cpu_write_byte(enc_odata, 3);   // 3 cen ticks of held request
         enc_step;
      end

      $sformat(msg, "round-trip: %0d sectors accepted, expected 12", n_valid);
      chk(n_valid >= 12, msg);
      for (i = 0; i < 12; i = i + 1) begin
         $sformat(msg, "round-trip: sector %0d never came back", i);
         chk(accepted[i] > 0, msg);
         $sformat(msg, "round-trip: sector %0d payload wrong (%0d bytes)", i, bad_payload[i]);
         chk(bad_payload[i] == 0, msg);
         $sformat(msg, "round-trip: sector %0d addr wrong (%0d bytes)", i, bad_addr[i]);
         chk(bad_addr[i] == 0, msg);
      end
      $sformat(msg, "round-trip: %0d rejects on a clean stream", n_reject);
      chk(n_reject == 0, msg);
      $display("  round-trip: %0d sectors, %0d rejects", n_valid, n_reject);

      $display("");
      if (fails == 0) $display("tb_floppy_write: PASS - %0d checks", checks);
      else            $display("tb_floppy_write: FAIL - %0d of %0d checks failed", fails, checks);
      $finish;
   end

endmodule
