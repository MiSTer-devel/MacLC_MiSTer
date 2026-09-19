/* tb_floppy_sd_writer.v — Phase 4b gate: a committed sector reaches the card,
 * fetched from SDRAM at write time.
 *
 * WHAT THIS COVERS THAT tb_floppy_commit.v CANNOT. That bench proves the
 * sector reaches SDRAM byte-exactly. This one starts where it stops: the
 * sector-number queue, the SDRAM fetch through the eth-port protocol, the
 * DC42 block assembly (including block 0 from the loader's header store), the
 * eject-time checksum scan, the hps_io sd_wr/sd_ack handshake, and every path
 * that must REFUSE to write. The refusals matter more than the happy path —
 * this is the first module in the chain that can damage the user's file, and
 * every defect class here writes a well-formed block at a plausible offset.
 *
 * ★ THE BYTE ORDER IS THE HEADLINE CHECK (section 1). SDRAM words are in the
 * internal convention (even byte high); hps_io's wire word is the opposite and
 * floppy_loader.v swaps on the way in. If this module's output swap does not
 * mirror that one, every byte pair on the card comes out transposed — an image
 * that mounts, passes its per-sector checksums, and is quietly wrong.
 *
 * ★ EVERY SDRAM ADDRESS IS CHECKED against the image region (the memory model
 * fails the run on a stray one): a wrong-address fetch is the SDRAM-sourced
 * design's own version of the wrong-LBA bug.
 *
 * ★ THE ACK TIMEOUT MUST RE-PRESENT, NOT RETIRE (section 5): hps_io captures
 * sd_lba in one poll and acks in a later one, so a retired block plus a late
 * ack would stream whatever is in the buffer to the captured LBA.
 *
 * ★ A REFUSAL MUST RETIRE EXACTLY ONE ENTRY (section 3). `q_head` is a
 * registered read of `q_mem[rd_ptr]` and lags a pop by a cycle; the refuse
 * path is the only one that stays in P_IDLE across it, so before the P_SKIP
 * state it popped again against the stale head - refusing one sector twice
 * and losing the NEXT one, unwritten and uncounted. A single queued entry
 * has nothing behind it to lose, which is why the one-commit case passed
 * either way; the section queues three.
 *
 * ★ A REMOUNT MUST ABORT THE FSM (sections 10-11). sd_ack is per slot: the
 * loader's acks for the new image would otherwise walk a running FSM into an
 * sd_wr against the loader's LBA. Found in the Phase 4 review, kept here.
 *
 * ★ THE DESIGN'S OWN CLAIMS (sections 15-16): a sector re-written while still
 * queued is written twice with the NEWEST data both times, because the data is
 * fetched from SDRAM at write time; and a full queue REFUSES, raising the
 * witness count, rather than overwriting anything. QDEPTH_BITS is overridden to 3
 * (8 entries) so the full case is reachable; shipping depth is 1024.
 *
 * ACK_TIMEOUT_BITS is overridden to 6 so the timeout is reachable; the
 * shipping default (24) is ~0.5 s at clk_sys.
 *
 * Build + run (Icarus 12.x, from the REPO ROOT):
 *   /c/iverilog/bin/iverilog -g2012 -s tb_floppy_sd_writer \
 *     -o scratch/phase4/tb_sdw.vvp verilator/tb_floppy_sd_writer.v \
 *     rtl/floppy_sd_writer.v
 *   /c/iverilog/bin/vvp scratch/phase4/tb_sdw.vvp
 */
`timescale 1ns/1ps

module tb_floppy_sd_writer;

   reg clk = 0;
   always #5 clk = ~clk;

   localparam [23:0] IMG_BASE = 24'h600000;
   localparam        IMG_WORDS = 524288;          // 1 MB region

   reg         reset       = 1'b1;
   reg         img_mounted = 1'b0;
   reg         commit_done = 1'b0;
   reg  [21:0] commit_addr = 22'd0;
   reg         write_ok    = 1'b1;
   reg         loader_busy = 1'b0;
   reg         dc42        = 1'b0;
   reg         flush_req   = 1'b0;
   reg  [12:0] file_blocks = 13'd1600;   // an 800K raw image
   reg         file_tail   = 1'b0;       // ...with no partial block after them

   wire  [5:0] hdr_addr;
   reg  [15:0] hdr_data;
   wire        mem_req;
   wire [23:0] mem_addr;
   reg         mem_ack = 1'b0;
   reg  [15:0] mem_dout = 16'd0;

   wire [31:0] sd_lba;
   wire        sd_wr;
   reg         sd_ack = 1'b0;
   reg   [7:0] sd_buff_addr = 8'd0;
   wire [15:0] sd_buff_din;
   wire        busy;
   wire [31:0] dbg;

   floppy_sd_writer #(.ACK_TIMEOUT_BITS(6), .QDEPTH_BITS(3)) dut
   (
      .clk(clk), .reset(reset),
      .img_mounted(img_mounted),
      .commit_done(commit_done), .commit_addr(commit_addr),
      .write_ok(write_ok), .loader_busy(loader_busy),
      .dc42(dc42), .flush_req(flush_req), .file_blocks(file_blocks),
      .file_tail(file_tail),
      .img_base(IMG_BASE),
      .hdr_addr(hdr_addr), .hdr_data(hdr_data),
      .mem_req(mem_req), .mem_addr(mem_addr), .mem_ack(mem_ack), .mem_dout(mem_dout),
      .sd_lba(sd_lba), .sd_wr(sd_wr), .sd_ack(sd_ack),
      .sd_buff_addr_i({5'd0, sd_buff_addr}),
      .sd_buff_din(sd_buff_din),
      .busy(busy), .dbg(dbg)
   );

   integer checks = 0;
   integer fails  = 0;
   task check(input cond, input [639:0] what);
      begin
         checks = checks + 1;
         if (!cond) begin fails = fails + 1; $display("  FAIL: %0s", what); end
      end
   endtask

   // ── SDRAM model on the eth-port protocol ───────────────────────────────
   // ack rises 3 cycles after req with the word, falls only after req drops.
   // Any address outside the image region is a failure of the run.
   reg [15:0] sdram [0:IMG_WORDS-1];
   reg  [2:0] mlat = 0;
   integer    bad_addr = 0;
   integer    mem_reads = 0;
   always @(posedge clk) begin
      if (mem_req && !mem_ack) begin
         mlat <= mlat + 1;
         if (mlat == 2) begin
            if (mem_addr < IMG_BASE || mem_addr >= IMG_BASE + IMG_WORDS) begin
               bad_addr = bad_addr + 1;
               mem_dout <= 16'hDEAD;
            end else
               mem_dout <= sdram[mem_addr - IMG_BASE];
            mem_ack   <= 1;
            mem_reads = mem_reads + 1;
         end
      end else if (!mem_req) begin
         mem_ack <= 0; mlat <= 0;
      end
   end

   // ── the loader's header store: registered read port ───────────────────
   reg [15:0] hdr [0:63];
   always @(posedge clk) hdr_data <= hdr[hdr_addr];

   // sector s of the payload = words s*256 .. s*256+255, filled with a seed
   task fill_sector(input [12:0] s, input [15:0] seed);
      integer i;
      begin
         for (i = 0; i < 256; i = i + 1) sdram[s*256 + i] = seed + i[15:0];
      end
   endtask

   task pulse_commit(input [12:0] sector);
      begin
         @(posedge clk);
         commit_addr <= {sector, 9'd0};
         commit_done <= 1'b1;
         @(posedge clk);
         commit_done <= 1'b0;
      end
   endtask

   // the word hps_io must receive for file block `blk`, word `k`
   function [15:0] exp_word(input [12:0] blk, input integer k, input use_cksum, input [31:0] cks);
      reg [15:0] w;
      begin
         if (dc42 && blk == 0 && k < 42) begin
            if (use_cksum && k == 36)      w = cks[31:16];
            else if (use_cksum && k == 37) w = cks[15:0];
            else                           w = hdr[k];
         end else if (dc42)
            w = sdram[blk*256 + k - 42];
         else
            w = sdram[blk*256 + k];
         exp_word = {w[7:0], w[15:8]};   // wire order
      end
   endfunction

   // Answer a write the way hps_io does: raise sd_ack, walk sd_buff_addr over
   // the block while it is high, then drop it. Checks every word.
   task serve_block(input [12:0] blk, input use_cksum, input [31:0] cks);
      integer i;
      begin
         @(posedge clk);
         sd_ack <= 1'b1;
         for (i = 0; i < 256; i = i + 1) begin
            @(posedge clk);
            sd_buff_addr <= i[7:0];
            @(posedge clk);          // the module's read is registered
            @(posedge clk);
            check(sd_buff_din === exp_word(blk, i, use_cksum, cks),
                  "block word must be the SDRAM/header word in hps_io byte order");
         end
         @(posedge clk);
         sd_ack <= 1'b0;
         repeat (4) @(posedge clk);
      end
   endtask

   // a loader-style ack on the shared slot (after a remount): data flows IN,
   // the writer must ignore it entirely
   task loader_ack;
      integer i;
      begin
         @(posedge clk); sd_ack <= 1'b1;
         for (i = 0; i < 256; i = i + 1) begin @(posedge clk); sd_buff_addr <= i[7:0]; @(posedge clk); end
         @(posedge clk); sd_ack <= 1'b0; repeat (4) @(posedge clk);
      end
   endtask

   task wait_wr(input integer limit, output ok);
      integer n;
      begin
         n = 0; ok = 0;
         while (n < limit && !ok) begin
            @(posedge clk);
            if (sd_wr) ok = 1;
            n = n + 1;
         end
      end
   endtask

   // the DC42 data checksum over payload words 0 .. nwords-1, as mk_dc42.py
   function [31:0] model_cksum(input integer nwords);
      integer i; reg [31:0] s, a;
      begin
         s = 0;
         for (i = 0; i < nwords; i = i + 1) begin
            a = s + {16'd0, sdram[i]};
            s = {a[0], a[31:1]};
         end
         model_cksum = s;
      end
   endfunction

   // run a complete eject flush for a DC42 whose dataSize is dsize bytes,
   // checking block 0 comes back with the model checksum substituted
   task run_flush(input integer dsize);
      reg got; reg [31:0] cks;
      begin
         hdr[32] = dsize[31:16]; hdr[33] = dsize[15:0];
         @(posedge clk); flush_req <= 1'b1;
         @(posedge clk); flush_req <= 1'b0;
         @(posedge clk);
         check(busy, "the flush makes the writer busy");
         cks = model_cksum(dsize / 2);
         wait_wr(200000, got);
         check(got && sd_lba === 32'd0, "after the SDRAM scan, block 0 is written");
         serve_block(13'd0, 1'b1, cks);
         check(!busy, "flush complete");
      end
   endtask

   integer i;
   reg     got;
   reg [31:0] lba_first;
   integer reads_before;

   initial begin
      for (i = 0; i < IMG_WORDS; i = i + 1) sdram[i] = 16'h0000;
      for (i = 0; i < 64; i = i + 1) hdr[i] = 16'h4800 + i[15:0];   // a fake header
      hdr[36] = 16'h1234; hdr[37] = 16'h5678;                         // stale checksum
      repeat (4) @(posedge clk);
      reset <= 1'b0;
      repeat (4) @(posedge clk);

      // ─── 1. the happy path, and the byte order ──────────────────────────
      $display("1. commit -> fetch from SDRAM -> sd_wr at the right LBA, bytes in hps_io order");
      fill_sector(13'd7, 16'h1000);
      pulse_commit(13'd7);
      wait_wr(4000, got);
      check(got, "sd_wr must be asserted after a commit");
      check(sd_lba === 32'd7, "sd_lba must be the sector number");
      serve_block(13'd7, 1'b0, 32'd0);
      check(!busy, "busy must fall once the block has drained");
      check(bad_addr == 0, "every SDRAM address was inside the image");

      // ─── 2. write_ok low: nothing may reach the card ────────────────────
      $display("2. write_ok low refuses the sector outright");
      write_ok <= 1'b0;
      fill_sector(13'd9, 16'h2000);
      pulse_commit(13'd9);
      wait_wr(4000, got);
      check(!got, "a commit with write_ok low must never raise sd_wr");
      check(!busy, "and must not leave the queue busy");
      write_ok <= 1'b1;

      // --- 3. past the end of the image: refuse, do not wrap ──────────────
      $display("3. a block at or past file_blocks is retired unwritten");
      pulse_commit(13'd1600);              // == file_blocks
      wait_wr(4000, got);
      check(!got, "an out-of-range block must not be written");
      check(!busy, "and must be retired rather than left queued");
      check(dbg[23:16] === 8'd1, "the refusal is counted");

      // ...and the refusal must retire exactly ONE entry. q_head is a
      // registered read of q_mem[rd_ptr], so for a cycle after the pop it
      // still shows the entry just refused; a refuse path that stayed in
      // P_IDLE would pop again against that stale head - refusing the same
      // sector twice and dropping the sector behind it, unwritten and
      // uncounted. One entry has nothing behind it to lose, which is why
      // the single-commit case above passes either way: queue THREE.
      $display("   ...and the two sectors queued behind it still land, in order");
      loader_busy <= 1'b1;
      fill_sector(13'd25, 16'h6100);
      fill_sector(13'd26, 16'h6200);
      pulse_commit(13'd1601);              // past file_blocks: refused
      pulse_commit(13'd25);
      pulse_commit(13'd26);
      repeat (4) @(posedge clk);
      loader_busy <= 1'b0;
      wait_wr(4000, got);
      check(got && sd_lba === 32'd25, "the sector behind a refusal is written, at its own LBA");
      serve_block(13'd25, 1'b0, 32'd0);
      wait_wr(4000, got);
      check(got && sd_lba === 32'd26, "and the one behind THAT is not swallowed by the refusal");
      serve_block(13'd26, 1'b0, 32'd0);
      check(!busy, "the queue drains completely");
      check(dbg[23:16] === 8'd2, "one further refusal counted, not two");
      check(dbg[15:8] === 8'd3, "three blocks have now landed, none lost");
      check(bad_addr == 0, "every SDRAM address was inside the image");

      // ─── 4. a remount drops what was queued against the old image ──────
      $display("4. img_mounted drops the queued sector");
      loader_busy <= 1'b1;
      fill_sector(13'd11, 16'h4000);
      pulse_commit(13'd11);
      repeat (4) @(posedge clk);
      check(busy, "the sector is queued while the loader owns the slot");
      @(posedge clk); img_mounted <= 1'b1;
      @(posedge clk); img_mounted <= 1'b0;
      loader_busy <= 1'b0;
      wait_wr(4000, got);
      check(!got, "a sector captured before a remount must never be written");
      check(!busy, "and the queue must be empty again");

      // ─── 5. ack timeout re-presents the SAME block ──────────────────────
      $display("5. an ack timeout re-presents, never retires");
      fill_sector(13'd13, 16'h5000);
      pulse_commit(13'd13);
      wait_wr(4000, got);
      check(got, "first presentation");
      lba_first = sd_lba;
      wait_wr(400, got);                   // never ack; the timeout fires
      check(got, "the request must be presented again after the timeout");
      check(sd_lba === lba_first, "the re-presented LBA must be unchanged");
      check(busy, "busy must stay high while a write is still owed");
      serve_block(13'd13, 1'b0, 32'd0);    // same data
      check(!busy, "and clears once the late ack is finally served");

      // ─── 6. two queued sectors drain in order ───────────────────────────
      $display("6. queued sectors drain in commit order");
      loader_busy <= 1'b1;
      fill_sector(13'd21, 16'h6000);
      fill_sector(13'd22, 16'h7000);
      pulse_commit(13'd21);
      pulse_commit(13'd22);
      loader_busy <= 1'b0;
      wait_wr(4000, got);
      check(got && sd_lba === 32'd21, "the first committed sector goes first");
      serve_block(13'd21, 1'b0, 32'd0);
      wait_wr(4000, got);
      check(got && sd_lba === 32'd22, "then the second");
      serve_block(13'd22, 1'b0, 32'd0);
      check(!busy, "both drained");

      // --- 7. DC42: one sector becomes TWO blocks assembled from SDRAM -----
      $display("7. DC42 sector -> blocks N and N+1 from SDRAM, no card read");
      dc42        <= 1'b1;
      file_blocks <= 13'd1637;             // tagged 800K DC42: 838484 B = 1637 whole
      file_tail   <= 1'b1;                 // ...plus a 340-byte partial block
      fill_sector(13'd30, 16'h0700);
      fill_sector(13'd31, 16'h0800);
      fill_sector(13'd32, 16'h0900);
      pulse_commit(13'd31);
      wait_wr(4000, got);
      check(got && sd_lba === 32'd31, "the first block is N");
      serve_block(13'd31, 1'b0, 32'd0);    // [tail of 30][head of 31]
      wait_wr(4000, got);
      check(got && sd_lba === 32'd32, "then N+1");
      serve_block(13'd32, 1'b0, 32'd0);    // [tail of 31][head of 32]
      check(!busy, "the sector is done only once BOTH blocks have landed");
      check(bad_addr == 0, "still no stray SDRAM address");

      // --- 8. the file's final PARTIAL block is written (plan Phase 6D) ----
      // ★ THIS SECTION IS THE REVERSAL. Before 6D the straddling sector was
      // refused, on the premise that writing a partial block would extend the
      // file. Main clips the write to the file's real end instead
      // (user_io.cpp:3502-3514), so the writer sends its full 512-byte buffer
      // and only the bytes that exist land. The mutant that still refuses it
      // fails the first check below.
      $display("8. a sector straddling the partial tail block IS written");
      fill_sector(13'd1635, 16'h1500);
      fill_sector(13'd1636, 16'h1600);
      fill_sector(13'd1637, 16'h1700);     // the words behind the tail block
      pulse_commit(13'd1636);              // needs blocks 1636 AND 1637
      wait_wr(4000, got);
      check(got && sd_lba === 32'd1636, "the sector's first block is written");
      serve_block(13'd1636, 1'b0, 32'd0);
      wait_wr(4000, got);
      check(got && sd_lba === 32'd1637, "and the PARTIAL tail block follows it");
      serve_block(13'd1637, 1'b0, 32'd0);
      check(!busy, "both blocks landed: the sector is whole, not torn");
      check(bad_addr == 0, "the tail block's SDRAM fetch stayed inside the image");

      // ...and one block further on is still past the end.
      $display("   ...and the block AFTER the tail is still refused");
      pulse_commit(13'd1637);              // would need 1637 AND 1638
      wait_wr(4000, got);
      check(!got, "nothing exists past the partial tail");
      check(!busy, "retired instead");

      // ...and with no tail declared, the old rule stands unchanged: a raw
      // image is always a whole number of blocks and must not gain one.
      $display("   ...and a file with NO partial tail refuses it as before");
      file_tail <= 1'b0;
      pulse_commit(13'd1636);
      wait_wr(4000, got);
      check(!got, "file_tail low: the straddling sector is refused");
      check(!busy, "retired instead");
      file_tail <= 1'b1;

      // --- 9. eject -> the DC42 data checksum is recomputed and written ---
      $display("9. guest eject: SDRAM scan, then block 0 with the new checksum");
      fill_sector(13'd0, 16'h0A00);
      fill_sector(13'd1, 16'h0B00);
      fill_sector(13'd4, 16'h0C00);
      pulse_commit(13'd4);                 // make the mount dirty
      wait_wr(4000, got); serve_block(13'd4, 1'b0, 32'd0);
      wait_wr(4000, got); serve_block(13'd5, 1'b0, 32'd0);
      check(!busy, "sector done");
      reads_before = mem_reads;
      run_flush(1024);                     // dataSize 1024 B = 512 words scanned
      check(mem_reads - reads_before == 512 + 214,
            "the scan read exactly dataSize/2 words, then 214 for block 0's payload half");

      // --- 10. a remount in the middle of a block fetch aborts it ----------
      $display("10. img_mounted mid-fetch: FSM idle, no sd_wr on the loader's acks");
      fill_sector(13'd6, 16'h0D00);
      pulse_commit(13'd6);
      wait (mem_req);                      // the fetch has started
      @(posedge clk); img_mounted <= 1'b1; loader_busy <= 1'b1;
      @(posedge clk); img_mounted <= 1'b0;
      @(posedge clk);
      check(!mem_req && !sd_wr, "request lines drop at the mount pulse");
      check(!busy, "and the writer is idle, queue dropped");
      loader_ack;                          // the loader's first block on the shared slot
      wait_wr(4000, got);
      check(!got, "no sd_wr may follow the loader's ack");
      loader_busy <= 1'b0;

      // --- 11. a remount during the eject scan abandons the flush ----------
      $display("11. img_mounted mid-scan: flush abandoned, no header write");
      pulse_commit(13'd4);
      wait_wr(4000, got); serve_block(13'd4, 1'b0, 32'd0);
      wait_wr(4000, got); serve_block(13'd5, 1'b0, 32'd0);
      hdr[32] = 16'd0; hdr[33] = 16'd1024;
      @(posedge clk); flush_req <= 1'b1;
      @(posedge clk); flush_req <= 1'b0;
      wait (dut.pstate == 4'd12);          // F_SCAN_REQ: the scan is running
      @(posedge clk); img_mounted <= 1'b1; loader_busy <= 1'b1;
      @(posedge clk); img_mounted <= 1'b0;
      @(posedge clk);
      check(!busy && !mem_req && !sd_wr, "the flush is abandoned at the mount pulse");
      for (i = 0; i < 4; i = i + 1) loader_ack;
      wait_wr(4000, got);
      check(!got, "no header write may reach the new image");
      loader_busy <= 1'b0;

      // --- 12. Floppy Write switched off AFTER writing: eject still flushes -
      $display("12. write_ok low at eject: the checksum is still rewritten");
      pulse_commit(13'd4);
      wait_wr(4000, got); serve_block(13'd4, 1'b0, 32'd0);
      wait_wr(4000, got); serve_block(13'd5, 1'b0, 32'd0);
      write_ok <= 1'b0;
      run_flush(1024);
      write_ok <= 1'b1;

      // --- 13. eject while the session's only sector is still QUEUED --------
      $display("13. eject with the only sector still queued: sector first, then the flush");
      loader_busy <= 1'b1;
      pulse_commit(13'd4);
      check(dut.dirty === 1'b0, "precondition: nothing has landed yet this mount");
      @(posedge clk); flush_req <= 1'b1;
      @(posedge clk); flush_req <= 1'b0;
      loader_busy <= 1'b0;
      wait_wr(4000, got);
      check(got && sd_lba === 32'd4, "the queued sector drains first");
      serve_block(13'd4, 1'b0, 32'd0);
      wait_wr(4000, got); serve_block(13'd5, 1'b0, 32'd0);
      wait_wr(200000, got);
      check(got && sd_lba === 32'd0, "then block 0: the flush latched on the queued sector");
      serve_block(13'd0, 1'b1, model_cksum(512));
      check(!busy, "flush complete");

      // --- 14. eject after a sector that was REFUSED: nothing to rewrite ----
      $display("14. eject when nothing of ours reached the file: header left alone");
      loader_busy <= 1'b1;
      pulse_commit(13'd1637);              // refused: starts at the partial tail,
                                           // so its second block is past the end
      @(posedge clk); flush_req <= 1'b1;
      @(posedge clk); flush_req <= 1'b0;
      loader_busy <= 1'b0;
      wait_wr(4000, got);
      check(!got, "nothing is written");
      check(!busy, "the latched flush is dropped once the queue proves clean");

      // --- 15. re-written while queued: written twice, NEWEST data both times
      $display("15. a sector re-committed while queued is written twice from live SDRAM");
      dc42 <= 1'b0; file_blocks <= 13'd1600; file_tail <= 1'b0;
      loader_busy <= 1'b1;
      fill_sector(13'd40, 16'h4000);
      pulse_commit(13'd40);
      fill_sector(13'd40, 16'h4100);       // the guest rewrote it before it drained
      pulse_commit(13'd40);
      loader_busy <= 1'b0;
      wait_wr(4000, got); check(got && sd_lba === 32'd40, "first write of sector 40");
      serve_block(13'd40, 1'b0, 32'd0);    // expects the CURRENT sdram contents (seed 4100)
      wait_wr(4000, got); check(got && sd_lba === 32'd40, "second write of sector 40");
      serve_block(13'd40, 1'b0, 32'd0);
      check(!busy, "queue empty");

      // --- 16. queue full: refuse and raise the witness, never overwrite -----
      $display("16. a full queue refuses the commit and raises the witness");
      loader_busy <= 1'b1;
      for (i = 0; i < 9; i = i + 1) begin   // depth is 8 in this bench
         fill_sector(13'd100 + i[12:0], 16'h5000 + i[15:0]);
         pulse_commit(13'd100 + i[12:0]);
      end
      repeat (2) @(posedge clk);           // let the refusing edge's registers settle
      check(dbg[31:24] === 8'd1, "exactly one commit was refused");
      loader_busy <= 1'b0;
      for (i = 0; i < 8; i = i + 1) begin
         wait_wr(4000, got);
         check(got && sd_lba === 32'd100 + i, "the eight accepted sectors drain in order");
         serve_block(13'd100 + i[12:0], 1'b0, 32'd0);
      end
      wait_wr(200, got);
      check(!got, "the refused ninth is gone, not smuggled in");
      check(!busy, "queue empty");

      // --- 17. DC42 sector 0: block 0 carries the loader's header words ------
      $display("17. DC42 sector 0 -> block 0 = header (stale checksum kept) + sector 0 head");
      dc42 <= 1'b1; file_blocks <= 13'd1637; file_tail <= 1'b1;
      fill_sector(13'd0, 16'h0E00);
      fill_sector(13'd1, 16'h0F00);
      pulse_commit(13'd0);
      wait_wr(4000, got); check(got && sd_lba === 32'd0, "block 0");
      serve_block(13'd0, 1'b0, 32'd0);     // words 0..41 = hdr[] incl. the stale 1234/5678
      wait_wr(4000, got); check(got && sd_lba === 32'd1, "block 1");
      serve_block(13'd1, 1'b0, 32'd0);
      check(!busy, "done");
      check(bad_addr == 0, "no stray SDRAM address anywhere in the run");

      $display("");
      $display("tb_floppy_sd_writer: %0d checks, %0d failures", checks, fails);
      if (fails == 0) $display("PASS");
      else            $display("FAIL");
      $finish;
   end

   initial begin
      #200_000_000;
      $display("tb_floppy_sd_writer: TIMEOUT");
      $finish;
   end

endmodule
