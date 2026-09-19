/* tb_floppy_track_decoder.v — Phase 2 gate: RTL encoder -> RTL decoder round-trip.
 *
 * WHY RTL-TO-RTL (docs/floppy_write_plan.md, Phase 2). Phase 0 already proved a
 * PYTHON decoder round-trips the real encoder's output. This bench proves the
 * thing we will actually synthesise does, against the exact byte stream THIS
 * core emits. A decoder validated only against a model shares that model's
 * misunderstandings; a decoder validated against the shipping encoder cannot.
 *
 * WHAT A FAILURE HERE WOULD MEAN downstream: Phase 3 commits whatever this
 * module declares valid straight into the SDRAM image, and Phase 4 writes it to
 * the user's file. A wrongly-ACCEPTED field is therefore a silent write of
 * wrong data. That is why the negative cases carry as much weight as the
 * positive ones, and why each of them names the sector that must disappear
 * rather than asserting that "an error happened somewhere".
 *
 * THE TWO POSITIVE CHECKS ARE INDEPENDENT, which is the point of using
 * scripts/gcr_gen_image.py's self-identifying pattern (bytes 0..2 of every
 * sector are track, side, sector; the rest is a keyed counter):
 *   1. recovered[0..2] == the (track, side, sector) the bench is driving
 *      -> the decoded PAYLOAD is this sector's data. Uses no address at all.
 *   2. recovered[k] == mem[dec_addr + k] for all 512 bytes
 *      -> `addr` points at exactly this sector in the image. This is the check
 *      Phase 3's committer rides on; a generic counter pattern would let a
 *      wrong-address fetch pass it, and this pattern cannot.
 *
 * ONE SHARED `ready` PULSE, AND WHY IT IS BYTE-ALIGNED. Both DUTs advance on
 * the same posedge. At that edge the decoder samples the encoder's PRE-edge
 * odata (the encoder's registers update in the NBA region), so it consumes byte
 * N while the encoder moves on to N+1. No skew, no staging register needed.
 *
 * `ready` IS A SPARSE PULSE, NOT A LEVEL — carried over from
 * tb_floppy_track_encoder.v, where the reasoning is written out in full: the
 * encoder's addr register settles in the idle cycles, and holding ready high
 * produces an address-pipeline artifact that cannot happen on hardware. The gap
 * is load-bearing for the DECODER too: S_GRPC drains up to three pending
 * buf_mem writes one per clock, and the real system's ~128-clock byte time is
 * what makes that safe. READY_GAP=8 leaves 7 idle cycles, comfortably over 3.
 *
 * EDGE DISCIPLINE: every stimulus change happens #1 AFTER a clock edge, never
 * at one. Driving at zero delay after @(posedge clk) leaves it to process
 * ordering whether the DUT sees the old or new value — a hazard that bit the
 * MacPlus benches four separate times.
 *
 * Build + run (Icarus 12.x, from the REPO ROOT so the relative paths resolve):
 *   python scripts/gcr_gen_image.py --hex
 *   /c/iverilog/bin/iverilog -g2012 -o scratch/gcr_phase2/tb_dec.vvp \
 *     verilator/tb_floppy_track_decoder.v \
 *     rtl/floppy_track_encoder.v rtl/floppy_track_decoder.v
 *   /c/iverilog/bin/vvp scratch/gcr_phase2/tb_dec.vvp
 *
 * Plusargs:
 *   +alltracks   sweep all 80 tracks x 2 sides (default: 0, 16, 40, 79 x 2)
 *   +single      SINGLE-SIDED (400K) geometry: sides=0 on both encoder and
 *                decoder, side 0 only, and a side-1 field must be REJECTED.
 *                Added 2026-09-16 when 400K writes were found to have no
 *                bench at all (both GCR benches hard-coded sides=1).
 *   +ncap=N      bytes fed per positive track (default 20000, >2 revolutions)
 *   +imghex=F    $readmemh source (default scratch/gcr_phase0/image.hex)
 *   +verbose     print every accepted sector
 */
`timescale 1ns/1ps

module tb_floppy_track_decoder;

   localparam READY_GAP    = 8;      // clk cycles per ready pulse (real HW: ~128)
   localparam SECTOR_PITCH = 782;    // bytes per sector as the encoder lays it out
   localparam FIELD_SPAN   = 708;    // D5 of D5AAAD -> the AA that completes the field
                                     //   3 mark + 1 sector + 699 groups + 4 sum + 2 trailer

   reg clk = 0;
   always #5 clk = ~clk;

   // ---- stimulus ------------------------------------------------------------
   reg        ready = 0;
   reg        rst   = 1;
   reg        side  = 0;
   reg        sides = 1;             // double-sided, matching the synthetic image
   reg [6:0]  track = 0;

   reg [7:0]  mem [0:819199];

   // ---- encoder (the shipping one, unmodified) ------------------------------
   wire [21:0] enc_addr;
   wire [7:0]  odata;
   wire [7:0]  enc_idata = mem[enc_addr];

   floppy_track_encoder enc (
      .clk(clk), .ready(ready), .rst(rst),
      .side(side), .sides(sides), .track(track),
      .addr(enc_addr), .idata(enc_idata), .odata(odata),
      // format relay idle (plan Phase 6A): this bench drives the read side only
      .wr_byte(1'b0), .wr_mark(1'b0), .wr_mark_sector(4'd0), .wr_end(1'b0)
   );

   // ---- corruption injector -------------------------------------------------
   // One byte of the stream, by index, replaced on its way to the decoder. The
   // encoder never sees it: we are corrupting the MEDIA, not the source data.
   integer byte_idx;
   // -1 = clean run. MUST be initialised: an `integer` powers up x, and
   // `x >= 0` is x, so the ternary below would feed the decoder x for the
   // whole run -- which looks exactly like "the decoder detects nothing".
   integer corrupt_idx = -1;
   reg [7:0] corrupt_val = 8'd0;

   wire [7:0] dec_idata = (corrupt_idx >= 0 && byte_idx == corrupt_idx)
                        ? corrupt_val : odata;

   // ---- decoder (the device under test) -------------------------------------
   wire        dec_valid, dec_reject, dec_amark, dec_fmt_mark, dec_fmt_ds;
   wire [3:0]  dec_sector, dec_amark_sector;
   wire [21:0] dec_addr;
   reg  [8:0]  buf_addr = 9'd0;
   wire [7:0]  buf_data;

   floppy_track_decoder dec (
      .clk(clk), .ready(ready), .rst(rst),
      .side(side), .sides(sides), .track(track),
      .idata(dec_idata),
      .sector_valid(dec_valid), .sector(dec_sector), .addr(dec_addr),
      .reject(dec_reject),
      .amark(dec_amark), .amark_sector(dec_amark_sector),
      .fmt_mark(dec_fmt_mark), .fmt_ds(dec_fmt_ds),
      .buf_addr(buf_addr), .buf_data(buf_data)
   );

   // ---- bookkeeping ---------------------------------------------------------
   integer checks = 0, fails = 0;
   integer verbose;

   task chk;
      input        cond;
      input [8*96-1:0] what;
      begin
         checks = checks + 1;
         if (!cond) begin
            fails = fails + 1;
            $display("  FAIL: %0s", what);
         end
      end
   endtask

   // Per-run results. Index by sector number (0..11 max on the densest zone).
   integer accept_count [0:15];   // times this sector was accepted in the run
   integer payload_bad  [0:15];   // byte mismatches vs the self-ID pattern
   integer addr_bad     [0:15];   // byte mismatches vs mem[dec_addr + k]
   integer valid_idx_of [0:15];   // stream index of the AA that completed it
   integer mark_idx_of  [0:15];   // stream index of that field's D5

   integer n_valid, n_reject, n_amark, n_fmt_mark;
   integer order_sector [0:15];   // acceptance order -> sector number
   integer n_order;

   // The clean stream of one revolution, kept so corruption values can be taken
   // FROM IT: a byte the encoder emitted in a nibble position is guaranteed to
   // be a valid GCR code, so "replace with a different valid code" needs no copy
   // of the forward table here (a copy could drift from the encoder's).
   reg [7:0] stream [0:16383];
   integer   stream_len;

   reg [7:0] recovered [0:511];

   integer last_mark_idx;
   reg [23:0] hist;

   integer sv_sector;
   reg [21:0] sv_addr;

   // ---- primitives ----------------------------------------------------------

   // Read the decoder's 512-byte buffer out at full clock rate. Safe because the
   // caller has stopped pulsing `ready`: the decoder is parked in S_SCAN and
   // cannot overwrite the buffer while we read it. (Reading it "live" between
   // fields would fit in the ~608 idle clocks by only ~90 clocks — no margin,
   // and nothing on hardware requires it.)
   integer rb;
   task read_buf;
      begin
         for (rb = 0; rb < 512; rb = rb + 1) begin
            #1 buf_addr = rb[8:0];
            @(posedge clk);   // buf_data <= buf_mem[buf_addr] on this edge
            #1 recovered[rb] = buf_data;
         end
      end
   endtask

   integer ck;
   task check_recovered;
      input integer sec;
      input [21:0]  a;
      begin
         // 1. the payload names itself — no address involved
         if (recovered[0] !== track || recovered[1] !== {7'd0, side} ||
             recovered[2] !== sec[7:0])
            payload_bad[sec] = payload_bad[sec] + 1;
         for (ck = 3; ck < 512; ck = ck + 1)
            if (recovered[ck] !== ((track * 7 + side * 13 + sec * 29 + ck) & 8'hFF))
               payload_bad[sec] = payload_bad[sec] + 1;

         // 2. `addr` lands on this exact sector in the image
         for (ck = 0; ck < 512; ck = ck + 1)
            if (recovered[ck] !== mem[a + ck])
               addr_bad[sec] = addr_bad[sec] + 1;
      end
   endtask

   // Feed exactly one byte. Records the field marks as they go past so the
   // negative cases can aim at a byte offset without assuming a layout.
   task feed_byte;
      begin
         repeat (READY_GAP - 1) @(posedge clk);
         #1 ready = 1;

         if (byte_idx < 16384) stream[byte_idx] = dec_idata;
         hist = {hist[15:0], dec_idata};
         if (hist == 24'hD5AAAD) last_mark_idx = byte_idx - 2;

         @(posedge clk);        // both DUTs advance on THIS edge
         #1 ready = 0;

         if (dec_reject)   n_reject   = n_reject   + 1;
         if (dec_amark)    n_amark    = n_amark    + 1;
         if (dec_fmt_mark) n_fmt_mark = n_fmt_mark + 1;

         if (dec_valid) begin
            sv_sector = dec_sector;
            sv_addr   = dec_addr;
            n_valid   = n_valid + 1;
            accept_count[sv_sector] = accept_count[sv_sector] + 1;
            valid_idx_of[sv_sector] = byte_idx;
            mark_idx_of [sv_sector] = last_mark_idx;
            if (n_order < 16) begin
               order_sector[n_order] = sv_sector;
               n_order = n_order + 1;
            end
            read_buf;
            check_recovered(sv_sector, sv_addr);
            if (verbose)
               $display("    t%0d s%0d sector %0d accepted at byte %0d, addr %0d",
                        track, side, sv_sector, byte_idx, sv_addr);
         end

         byte_idx = byte_idx + 1;
      end
   endtask

   integer ri;
   task reset_run;
      begin
         for (ri = 0; ri < 16; ri = ri + 1) begin
            accept_count[ri] = 0; payload_bad[ri] = 0; addr_bad[ri] = 0;
            valid_idx_of[ri] = -1; mark_idx_of[ri] = -1; order_sector[ri] = -1;
         end
         n_valid = 0; n_reject = 0; n_amark = 0; n_fmt_mark = 0; n_order = 0;
         byte_idx = 0; last_mark_idx = -1; hist = 24'd0; stream_len = 0;

         rst = 1;
         @(posedge clk);
         @(negedge clk);        // deassert away from the posedge: the encoder's
         #1 rst = 0;            // reset is `posedge clk or posedge rst`
         @(negedge clk);
         #1;                    // let combinational odata settle before byte 0
      end
   endtask

   integer fb;
   task run_stream;
      input integer tt;
      input         ss;
      input integer nbytes;
      begin
         track = tt[6:0];
         side  = ss;
         reset_run;
         for (fb = 0; fb < nbytes; fb = fb + 1) feed_byte;
         stream_len = (byte_idx < 16384) ? byte_idx : 16384;
      end
   endtask

   function integer spt_of;
      input integer t;
      begin
         if      (t < 16) spt_of = 12;
         else if (t < 32) spt_of = 11;
         else if (t < 48) spt_of = 10;
         else if (t < 64) spt_of = 9;
         else             spt_of = 8;
      end
   endfunction

   // ---- positive: every sector of a track, byte-exact, at the right address --
   integer ps, spt;
   reg [8*96-1:0] msg;
   task positive_track;
      input integer tt;
      input         ss;
      begin
         spt = spt_of(tt);
         run_stream(tt, ss, CYCLES);

         $sformat(msg, "t%0d s%0d: only %0d distinct sectors, want %0d", tt, ss, 0, spt);
         for (ps = 0; ps < spt; ps = ps + 1) begin
            $sformat(msg, "t%0d s%0d: sector %0d never accepted", tt, ss, ps);
            chk(accept_count[ps] > 0, msg);
            $sformat(msg, "t%0d s%0d: sector %0d payload wrong (%0d bytes)",
                     tt, ss, ps, payload_bad[ps]);
            chk(payload_bad[ps] == 0, msg);
            $sformat(msg, "t%0d s%0d: sector %0d addr wrong (%0d bytes)",
                     tt, ss, ps, addr_bad[ps]);
            chk(addr_bad[ps] == 0, msg);
         end
         for (ps = spt; ps < 16; ps = ps + 1) begin
            $sformat(msg, "t%0d s%0d: sector %0d is past spt=%0d and must not appear",
                     tt, ss, ps, spt);
            chk(accept_count[ps] == 0, msg);
         end
         $sformat(msg, "t%0d s%0d: %0d rejects on a clean stream, want 0", tt, ss, n_reject);
         chk(n_reject == 0, msg);
         $sformat(msg, "t%0d s%0d: no address fields reported (amark)", tt, ss);
         chk(n_amark > 0, msg);
         $sformat(msg, "t%0d s%0d: no format bytes verified (fmt_mark)", tt, ss);
         chk(n_fmt_mark > 0, msg);
         $display("  t%0d s%0d: %0d sectors accepted (spt=%0d), %0d amark, %0d fmt_mark, %0d reject",
                  tt, ss, n_valid, spt, n_amark, n_fmt_mark, n_reject);
      end
   endtask

   // ---- negative: the target sector must vanish, the others must survive ----
   //
   // ONE REVOLUTION ONLY. A 20000-byte capture holds 2+ revolutions, so every
   // sector appears twice; corrupt one copy and the other is still recovered —
   // a test that passes while proving nothing. This is the trap Phase 0's
   // negative suite documents, and it applies identically here.
   integer ns, target, surv_bad;
   task expect_only_missing;
      input integer tgt;
      input [8*64-1:0] label;
      begin
         $sformat(msg, "%0s: sector %0d was ACCEPTED", label, tgt);
         chk(accept_count[tgt] == 0, msg);

         surv_bad = 0;
         for (ns = 0; ns < spt; ns = ns + 1)
            if (ns != tgt)
               if (accept_count[ns] != 1 || payload_bad[ns] != 0 || addr_bad[ns] != 0)
                  surv_bad = surv_bad + 1;
         $sformat(msg, "%0s: collateral damage to %0d other sectors", label, surv_bad);
         chk(surv_bad == 0, msg);
      end
   endtask

   integer rev_bytes, tgt_sector, tgt_valid, tgt_mark, alt_idx;
   reg [7:0] alt_byte;

   // ---- main ----------------------------------------------------------------
   integer CYCLES;
   integer t, s;
   reg [8*256-1:0] imghex;
   reg alltracks;
   reg single;

   initial begin
      CYCLES  = 20000;
      imghex  = "scratch/gcr_phase0/image.hex";
      corrupt_idx = -1;
      alltracks = $test$plusargs("alltracks");
      single    = $test$plusargs("single");
      if (single) sides = 1'b0;
      verbose   = $test$plusargs("verbose");
      if ($value$plusargs("ncap=%d",   CYCLES)) ;
      if ($value$plusargs("imghex=%s", imghex)) ;

      $readmemh(imghex, mem);
      $display("tb_floppy_track_decoder: image=%0s ncap=%0d gap=%0d %0s",
               imghex, CYCLES, READY_GAP, alltracks ? "ALL TRACKS" : "representative");
      if (single) $display("tb_floppy_track_decoder: SINGLE-SIDED geometry (400K)");

      // === positive: RTL encoder -> RTL decoder round-trip ===================
      $display("--- positive: round-trip ---");
      if (alltracks) begin
         for (t = 0; t < 80; t = t + 1)
            for (s = 0; s < (single ? 1 : 2); s = s + 1)
               positive_track(t, s[0]);
      end else if (single) begin
         positive_track(0, 1'b0); positive_track(16, 1'b0);
         positive_track(40, 1'b0); positive_track(79, 1'b0);
      end else begin
         positive_track(0,  1'b0);  positive_track(0,  1'b1);
         positive_track(16, 1'b0);  positive_track(16, 1'b1);
         positive_track(40, 1'b0);  positive_track(40, 1'b1);
         positive_track(79, 1'b0);  positive_track(79, 1'b1);
      end

      // single-sided: a side-1 field must never be accepted (the decoder's
      // `side && !sides` reject), whatever the encoder puts on the stream
      if (single) begin
         $display("--- single-sided: side 1 must be rejected ---");
         run_stream(40, 1'b1, spt_of(40) * SECTOR_PITCH);
         chk(n_valid == 0, "single-sided disk accepted a side-1 field");
         chk(n_reject > 0, "single-sided disk: side-1 fields did not pulse reject");
      end

      // === the field layout this bench's offsets assume =====================
      // Asserted rather than assumed: every negative case below aims at a byte
      // relative to the completing AA, so if the layout is not what we think,
      // the corruption lands somewhere else and the tests mean nothing.
      spt       = spt_of(0);
      rev_bytes = spt * SECTOR_PITCH;
      run_stream(0, 1'b0, rev_bytes);
      chk(n_valid == spt, "one revolution did not yield exactly spt sectors");
      tgt_sector = order_sector[1];            // the SECOND accepted field, so
      tgt_valid  = valid_idx_of[tgt_sector];   // survival is checked both ways
      tgt_mark   = mark_idx_of[tgt_sector];
      $sformat(msg, "field span is %0d bytes, expected %0d", tgt_valid - tgt_mark, FIELD_SPAN);
      chk(tgt_valid - tgt_mark == FIELD_SPAN, msg);
      chk(stream[tgt_mark]   == 8'hD5, "field does not start D5");
      chk(stream[tgt_mark+1] == 8'hAA, "field mark byte 1 is not AA");
      chk(stream[tgt_mark+2] == 8'hAD, "field mark byte 2 is not AD");
      chk(stream[tgt_valid-1] == 8'hDE, "trailer byte 0 is not DE");
      chk(stream[tgt_valid]   == 8'hAA, "trailer byte 1 is not AA");
      $display("--- negative: one revolution of t0 s0, target sector %0d ---", tgt_sector);

      // --- 1. a payload byte changed to a DIFFERENT VALID GCR code ----------
      // Taken from the stream itself, so it is a code the encoder really emits:
      // the failure is then a genuine checksum mismatch, not an invalid nibble.
      alt_idx  = tgt_valid - 600;
      alt_byte = stream[tgt_valid - 601];
      if (alt_byte == stream[alt_idx]) alt_byte = stream[tgt_valid - 602];
      chk(alt_byte != stream[alt_idx], "could not find a different valid GCR byte");
      corrupt_idx = alt_idx; corrupt_val = alt_byte;
      run_stream(0, 1'b0, rev_bytes);
      expect_only_missing(tgt_sector, "corrupt payload byte");
      chk(n_reject > 0, "corrupt payload byte: dropped but no reject pulsed");

      // --- 2. a checksum byte changed to a different valid GCR code ---------
      alt_idx  = tgt_valid - 5;             // first of the 4 checksum bytes
      alt_byte = stream[tgt_valid - 600];
      if (alt_byte == stream[alt_idx]) alt_byte = stream[tgt_valid - 601];
      chk(alt_byte != stream[alt_idx], "could not find a different valid GCR byte");
      corrupt_idx = alt_idx; corrupt_val = alt_byte;
      run_stream(0, 1'b0, rev_bytes);
      expect_only_missing(tgt_sector, "corrupt checksum byte");
      chk(n_reject > 0, "corrupt checksum byte: dropped but no reject pulsed");

      // --- 3. a byte that is not in the 64-entry table at all ---------------
      corrupt_idx = tgt_valid - 300; corrupt_val = 8'h00;
      run_stream(0, 1'b0, rev_bytes);
      expect_only_missing(tgt_sector, "invalid encoded nibble");
      chk(n_reject > 0, "invalid encoded nibble: dropped but no reject pulsed");

      // --- 4. the DE AA trailer broken -------------------------------------
      corrupt_idx = tgt_valid - 1; corrupt_val = 8'hDF;
      run_stream(0, 1'b0, rev_bytes);
      expect_only_missing(tgt_sector, "broken DE AA trailer");
      chk(n_reject > 0, "broken trailer: dropped but no reject pulsed");

      // --- 5. the stream cut mid-field -------------------------------------
      // No reject is expected: a truncated field is simply never completed, and
      // the decoder sits waiting for bytes that do not come. What matters is
      // that it does not synthesise a sector out of a partial one.
      corrupt_idx = -1;
      run_stream(0, 1'b0, tgt_valid - 300);
      $sformat(msg, "truncated field: sector %0d recovered from a cut stream", tgt_sector);
      chk(accept_count[tgt_sector] == 0, msg);
      chk(accept_count[order_sector[0]] == 1, "truncated field: the field BEFORE the cut was lost");
      chk(n_valid == 1, "truncated field: unexpected number of sectors accepted");

      // --- 6. a corrupt ADDRESS field checksum ------------------------------
      // The behaviour here DIFFERS from the Phase 0 Python decoder, and the RTL
      // is the one that is right. Python pairs an address field with the data
      // field that follows it, so breaking the address checksum loses the
      // sector. This decoder scans for D5 AA AD independently and takes the
      // sector number from the DATA field, which carries its own checksum — so
      // the sector still decodes, and only fmt_mark (the format-byte report) is
      // suppressed. That independence is exactly the property section 4 of the
      // plan relies on: stage 1 needs no positional inference anywhere.
      //
      // The address field sits ahead of its data field; its 5 payload bytes are
      // t s h f c, and `c` is the byte just before the SYN1 run.
      corrupt_idx = -1;
      run_stream(0, 1'b0, rev_bytes);
      alt_idx = -1;
      for (ns = tgt_mark - 30; ns < tgt_mark; ns = ns + 1)
         if (ns > 2 && stream[ns-2] == 8'hD5 && stream[ns-1] == 8'hAA && stream[ns] == 8'h96)
            alt_idx = ns + 5;             // ...96 t s h f [c]
      chk(alt_idx > 0, "could not locate the address field ahead of the target");
      alt_byte = stream[tgt_valid - 600];
      if (alt_byte == stream[alt_idx]) alt_byte = stream[tgt_valid - 601];
      corrupt_idx = alt_idx; corrupt_val = alt_byte;
      run_stream(0, 1'b0, rev_bytes);
      chk(accept_count[tgt_sector] == 1,
          "corrupt address checksum: the DATA field must still decode");
      chk(payload_bad[tgt_sector] == 0 && addr_bad[tgt_sector] == 0,
          "corrupt address checksum: data field decoded but wrong");
      chk(n_fmt_mark == spt - 1,
          "corrupt address checksum: fmt_mark was not suppressed for that field");
      chk(n_amark == spt,
          "corrupt address checksum: amark should still report the sector number");

      // === report ===========================================================
      corrupt_idx = -1;
      $display("");
      if (fails == 0)
         $display("tb_floppy_track_decoder: PASS — %0d checks", checks);
      else
         $display("tb_floppy_track_decoder: FAIL — %0d of %0d checks failed", fails, checks);
      $finish;
   end

endmodule
