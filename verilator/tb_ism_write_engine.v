/* tb_ism_write_engine.v — Stage 2 gate: the ISM write engine, and the
 * ENGINE -> DECODER round trip that proves the two halves of our MFM write
 * path agree with each other.
 *
 * ★ SECTION 4 IS THE ONE THAT MATTERS. The engine generates the CRC bytes on
 * the guest's behalf (the guest pushes a one-byte TOKEN, ISM reg 2, and the
 * hardware writes both bytes); mfm_write_decoder.v then checks that CRC when
 * the same field comes back. If the two disagree about ANY of: the 0xCDB4
 * seed, which bytes feed the register, or that a mark byte resets it and is
 * not fed — then every sector we write fails its own CRC and nothing commits.
 * Two modules that each look right in isolation is exactly the failure this
 * section exists to catch, so it pushes a real field through the engine and
 * feeds the emitted stream straight into the decoder.
 *
 * ★ ONE CRC TOKEN MUST EMIT TWO BYTES (section 3). MAME keeps the M_CRC flag
 * in its shift register so the next byte-time emits `crc >> 8` again, which by
 * then holds the LOW half — `crc16(C, C>>8) == (C & 0xff) << 8`. A token that
 * emitted one byte, or that popped a second queue entry for the second byte,
 * would desynchronise every field by one byte. Section 3 checks the byte
 * COUNT and that the second byte costs no pop.
 *
 * ★ AN UNDERRUN MUST WRITE NOTHING (section 5). MAME raises error 0x01, calls
 * write_end and clears ACTION. The dangerous half is what does NOT happen: no
 * byte may reach the medium on a starved tick. A torn field is recoverable —
 * the decoder refuses it on CRC — but a field with one wrong byte written into
 * it is a silent corruption.
 *
 * The queue here is a bench model of swim.v's 2-entry FIFO: the engine sees
 * only the head word and an empty flag, and retires an entry with q_pop.
 *
 * Build + run (Icarus 12.x, from the REPO ROOT):
 *   /c/iverilog/bin/iverilog -g2012 -s tb_ism_write_engine \
 *     -o scratch/mfm/tb_iwe.vvp verilator/tb_ism_write_engine.v \
 *     rtl/ism_write_engine.v rtl/mfm_write_decoder.v
 *   /c/iverilog/bin/vvp scratch/mfm/tb_iwe.vvp
 */
`timescale 1ns/1ps

module tb_ism_write_engine;

   reg clk = 0;
   always #5 clk = ~clk;

   integer checks = 0;
   integer fails  = 0;
   task check(input cond, input [639:0] what);
      begin
         checks = checks + 1;
         if (!cond) begin fails = fails + 1; $display("  FAIL: %0s", what); end
      end
   endtask

   function [15:0] crc16;
      input [15:0] c;
      input  [7:0] d;
      integer i;
      reg [15:0] cc;
      begin
         cc = c ^ {d, 8'h00};
         for (i = 0; i < 8; i = i + 1)
            cc = cc[15] ? ((cc << 1) ^ 16'h1021) : (cc << 1);
         crc16 = cc;
      end
   endfunction
   localparam [15:0] CRC_SEED = 16'hCDB4;

   // ── the engine ─────────────────────────────────────────────────────────
   reg rst = 1, active = 0, tick = 0;
   reg [15:0] q_word  = 16'd0;
   reg        q_empty = 1'b1;
   wire       q_pop;
   wire [7:0] o_byte;
   wire       o_mark, o_stb, underrun;

   ism_write_engine eng (
      .clk(clk), .rst(rst),
      .active(active), .tick(tick),
      .q_word(q_word), .q_empty(q_empty), .q_pop(q_pop),
      .o_byte(o_byte), .o_mark(o_mark), .o_stb(o_stb),
      .underrun(underrun)
   );

   // ── the decoder, fed by the engine (section 4) ─────────────────────────
   reg        dec_rst = 1;
   reg        dec_en  = 0;           // route the engine's output into it
   wire       dec_ready = dec_en && o_stb;
   reg  [4:0] anchor_sector = 5'd7;
   wire       sector_valid, reject, amark;
   wire [4:0] dec_sector, amark_sector;
   wire [21:0] dec_addr;
   wire [6:0] amark_cyl;
   wire       amark_head;
   reg  [8:0] buf_addr = 9'd0;
   wire [7:0] buf_data;

   mfm_write_decoder dec (
      .clk(clk), .rst(dec_rst),
      .ready(dec_ready), .idata(o_byte), .imark(o_mark),
      .side(1'b0), .track(7'd3), .hd(1'b1),
      .anchor_sector(anchor_sector), .anchor_valid(1'b1),
      .sector_valid(sector_valid), .sector(dec_sector), .addr(dec_addr),
      .reject(reject),
      .amark(amark), .amark_sector(amark_sector),
      .amark_cyl(amark_cyl), .amark_head(amark_head),
      .buf_addr(buf_addr), .buf_data(buf_data)
   );

   // ── the bench's model of swim.v's 2-entry FIFO ─────────────────────────
   reg [15:0] fifo [0:1];
   reg  [1:0] fpos = 2'd0;
   always @(posedge clk) begin
      if (q_pop && fpos != 0) begin
         fifo[0] <= fifo[1];
         fpos    <= fpos - 2'd1;
      end
   end
   always @(*) begin
      q_word  = fifo[0];
      q_empty = (fpos == 2'd0);
   end

   task fifo_push(input [15:0] w);
      begin
         @(posedge clk);
         #1;
         if (fpos < 2'd2) begin fifo[fpos] = w; fpos = fpos + 2'd1; end
      end
   endtask

   // ── witnesses ──────────────────────────────────────────────────────────
   integer n_stb = 0, n_pop = 0, n_unr = 0;
   reg [7:0] emitted [0:1023];
   reg       emitted_mark [0:1023];
   integer   n_emit = 0;
   always @(posedge clk) begin
      if (o_stb) begin
         emitted[n_emit]      = o_byte;
         emitted_mark[n_emit] = o_mark;
         n_emit = n_emit + 1;
         n_stb  = n_stb + 1;
      end
      if (q_pop)   n_pop = n_pop + 1;
      if (underrun) n_unr = n_unr + 1;
   end

   // one byte-time. The engine is paced by a 1-clk tick; the real one is
   // floppy.v's edge-detected mfm_stb, ~16us apart.
   task byte_time;
      begin
         @(posedge clk);
         #1 tick = 1;
         @(posedge clk);
         #1 tick = 0;
         repeat (3) @(posedge clk);   // idle clocks between byte-times
      end
   endtask

   // push a word, then give the engine a byte-time to consume it
   task send(input [15:0] w);
      begin
         fifo_push(w);
         byte_time;
      end
   endtask

   task do_reset;
      begin
         #1 rst = 1; dec_rst = 1; active = 0; tick = 0; fpos = 0;
         repeat (4) @(posedge clk);
         #1 rst = 0; dec_rst = 0;
         repeat (2) @(posedge clk);
      end
   endtask

   integer i;
   reg [15:0] k;
   reg [7:0]  expect_hi, expect_lo;
   reg        ok;

   initial begin
      do_reset;

      // ─── 1. inactive: the engine writes nothing ─────────────────────────
      $display("1. an engine that is not armed never touches the medium");
      n_stb = 0; n_pop = 0; n_unr = 0;
      fifo_push({8'd0, 8'h55});
      byte_time; byte_time;
      check(n_stb == 0, "no byte may be emitted while inactive");
      check(n_pop == 0, "and nothing may be consumed");
      check(n_unr == 0, "an idle engine cannot underrun");

      // ─── 2. plain bytes pass through, one per byte-time ─────────────────
      $display("2. plain bytes: one out per byte-time, value for value");
      do_reset;
      #1 active = 1;
      n_stb = 0; n_pop = 0; n_emit = 0;
      send({8'd0, 8'h12});
      send({8'd0, 8'hAB});
      send({8'd0, 8'h00});
      check(n_stb == 3, "three bytes in, three bytes out");
      check(n_pop == 3, "each cost exactly one queue entry");
      check(emitted[0] === 8'h12 && emitted[1] === 8'hAB && emitted[2] === 8'h00,
            "the bytes emitted are the bytes queued, in order");
      check(!emitted_mark[0] && !emitted_mark[1] && !emitted_mark[2],
            "a plain byte is not marked");

      // ─── 3. one CRC token emits TWO bytes, and pops once ────────────────
      $display("3. one CRC token -> two bytes, one pop");
      do_reset;
      #1 active = 1;
      n_stb = 0; n_pop = 0; n_emit = 0;
      // a mark reseeds the CRC, then one byte feeds it, then the token
      send({7'd0, 1'b1, 8'hA1});      // MARK
      send({8'd0, 8'hFB});            // data address mark
      send({8'd0, 8'h5A});            // one payload byte
      k = crc16(crc16(CRC_SEED, 8'hFB), 8'h5A);
      expect_hi = k[15:8];
      expect_lo = k[7:0];
      n_pop = 0;
      send({6'd0, 1'b1, 1'b0, 8'h00});   // the CRC token (FIFO bit 9)
      byte_time;                          // the token's SECOND byte
      check(n_stb == 5, "the token produced two bytes, not one");
      check(n_pop == 1, "and cost exactly ONE queue entry");
      check(emitted[3] === expect_hi, "first CRC byte is the running CRC, high half");
      check(emitted[4] === expect_lo, "second CRC byte is its low half");

      // ─── 4. ENGINE -> DECODER: a field the engine wrote must decode ─────
      $display("4. a whole data field through the engine is accepted by the decoder");
      do_reset;
      #1 active = 1; dec_en = 1;
      n_stb = 0; n_emit = 0;
      // sync, three marks, data address mark, 512 payload bytes, CRC token
      for (i = 0; i < 12; i = i + 1) send({8'd0, 8'h00});
      for (i = 0; i < 3;  i = i + 1) send({7'd0, 1'b1, 8'hA1});
      send({8'd0, 8'hFB});
      for (i = 0; i < 512; i = i + 1) send({8'd0, (i[7:0] ^ 8'h3C)});
      send({6'd0, 1'b1, 1'b0, 8'h00});   // CRC token
      byte_time;                          // its second byte
      repeat (8) @(posedge clk);
      check(sector_valid === 1'b0, "the commit pulse is one clock, already gone");
      check(n_stb == 12 + 3 + 1 + 512 + 2, "the field is the length it should be");
      // the decoder must have accepted it, at the anchor's sector
      check(dec_sector === 5'd7, "the decoder placed it at the anchor's sector");
      check(dec_addr === 22'd0 + (((3*2+0)*18 + (7-1)) << 9),
            "and at the address that sector implies");
      ok = 1'b1;
      for (i = 0; i < 512; i = i + 1) begin
         #1 buf_addr = i[8:0];
         @(posedge clk);
         #1 if (buf_data !== (i[7:0] ^ 8'h3C)) ok = 1'b0;
      end
      check(ok, "every payload byte survived the engine and the decoder intact");
      #1 dec_en = 0;

      // ─── 5. an underrun writes NOTHING and says so ──────────────────────
      $display("5. a starved byte-time emits no byte and raises underrun");
      do_reset;
      #1 active = 1;
      n_stb = 0; n_pop = 0; n_unr = 0;
      byte_time;                          // queue empty
      check(n_unr == 1, "a tick with an empty queue is an underrun");
      check(n_stb == 0, "and MUST NOT write a byte to the medium");
      check(n_pop == 0, "and cannot pop what is not there");

      // ─── 6. a mark byte is written, and reseeds the CRC ─────────────────
      $display("6. a mark byte reaches the medium and reseeds the CRC");
      do_reset;
      #1 active = 1;
      n_stb = 0; n_emit = 0;
      send({8'd0, 8'hFF});               // feed the CRC something first
      send({7'd0, 1'b1, 8'hA1});         // MARK: written, CRC reset, not fed
      send({8'd0, 8'hFE});
      k = crc16(CRC_SEED, 8'hFE);        // seeded AT the mark, FE fed after
      n_pop = 0;
      send({6'd0, 1'b1, 1'b0, 8'h00});
      byte_time;
      check(emitted[1] === 8'hA1, "the mark byte itself is written");
      check(emitted_mark[1] === 1'b1, "and is flagged as a mark");
      check(emitted[3] === k[15:8] && emitted[4] === k[7:0],
            "the CRC restarted at the mark: the bytes before it are excluded");

      $display("");
      $display("tb_ism_write_engine: %0d checks, %0d failures", checks, fails);
      if (fails == 0) $display("PASS"); else $display("FAIL");
      $finish;
   end

endmodule
