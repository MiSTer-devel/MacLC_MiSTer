/* tb_eth_port_arb.v — rtl/eth_port_arb.v: two clients on one eth-port.
 *
 * What must hold (see the module header): the grant is locked from the
 * winner's req-rise until both its req and the port's ack are low again; the
 * loser never sees an ack that is not its own; the bundle reaching the
 * controller is registered and settles one edge before m_req rises; client A
 * wins a tie. The memory model below is the eth-port protocol as sdram.v
 * implements it: ack rises some cycles after req with data, and falls only
 * after req has dropped.
 *
 * Build + run (Icarus 12.x, from the REPO ROOT):
 *   /c/iverilog/bin/iverilog -g2012 -s tb_eth_port_arb \
 *     -o scratch/phase4/tb_arb.vvp verilator/tb_eth_port_arb.v rtl/eth_port_arb.v
 *   /c/iverilog/bin/vvp scratch/phase4/tb_arb.vvp
 */
`timescale 1ns/1ps

module tb_eth_port_arb;

   reg clk = 0;
   always #5 clk = ~clk;
   reg reset = 1;

   reg         a_req = 0, a_we = 0;  reg [23:0] a_addr = 0;  reg [15:0] a_din = 0;
   reg         b_req = 0, b_we = 0;  reg [23:0] b_addr = 0;  reg [15:0] b_din = 0;
   wire        a_ack, b_ack;  wire [15:0] a_dout, b_dout;
   wire        m_req, m_we;   wire [23:0] m_addr;  wire [15:0] m_din;
   reg         m_ack = 0;     reg  [15:0] m_dout = 0;

   eth_port_arb dut (
      .clk(clk), .reset(reset),
      .a_req(a_req), .a_we(a_we), .a_addr(a_addr), .a_din(a_din), .a_ack(a_ack), .a_dout(a_dout),
      .b_req(b_req), .b_we(b_we), .b_addr(b_addr), .b_din(b_din), .b_ack(b_ack), .b_dout(b_dout),
      .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_din(m_din), .m_ack(m_ack), .m_dout(m_dout));

   integer checks = 0, fails = 0;
   task check(input cond, input [639:0] what);
      begin checks = checks + 1; if (!cond) begin fails = fails + 1; $display("  FAIL: %0s", what); end end
   endtask

   // ── memory model: the eth port. Data = addr low half XOR a tag so the
   //    bench can tell whose word came back. Latency 3 cycles. ─────────────
   reg [2:0] lat = 0;
   reg [23:0] addr_at_req;   // m_addr must already be settled when m_req rises
   reg        addr_settled_ok = 1;
   reg [23:0] m_addr_d;
   always @(posedge clk) begin
      m_addr_d <= m_addr;
      if (m_req && !m_ack) begin
         if (lat == 0) begin
            // the edge after m_req rose: m_addr must equal what it was one edge earlier
            if (m_addr !== m_addr_d) addr_settled_ok = 0;
         end
         lat <= lat + 1;
         if (lat == 2) begin m_dout <= m_addr[15:0] ^ 16'hA5A5; m_ack <= 1; end
      end else if (!m_req) begin
         m_ack <= 0; lat <= 0;
      end
   end

   // ── cross-talk witnesses: a client may only see ack while ITS req is up
   //    or in its own turnaround (req just dropped, waiting for ack fall) ──
   integer a_bad = 0, b_bad = 0;
   reg a_owns = 0, b_owns = 0;  // set by the bench while a client's transaction is legitimately open
   always @(posedge clk) begin
      if (a_ack && !a_owns) a_bad = a_bad + 1;
      if (b_ack && !b_owns) b_bad = b_bad + 1;
   end

   // one full two-phase transaction for client A / B
   task xact_a(input [23:0] addr, output [15:0] data);
      begin
         @(posedge clk); a_addr <= addr; @(posedge clk); a_req <= 1; a_owns <= 1;
         wait (a_ack); @(posedge clk); data = a_dout; a_req <= 0;
         wait (!a_ack); @(posedge clk); a_owns <= 0;
      end
   endtask
   task xact_b(input [23:0] addr, output [15:0] data);
      begin
         @(posedge clk); b_addr <= addr; @(posedge clk); b_req <= 1; b_owns <= 1;
         wait (b_ack); @(posedge clk); data = b_dout; b_req <= 0;
         wait (!b_ack); @(posedge clk); b_owns <= 0;
      end
   endtask

   reg [15:0] da, db;
   integer i, n_ack_b_while_a;
   initial begin
      repeat (3) @(posedge clk); reset <= 0; repeat (2) @(posedge clk);

      $display("1. a single client A transaction round-trips its own address");
      xact_a(24'h600123, da);
      check(da === (16'h0123 ^ 16'hA5A5), "A gets the word for its own address");
      check(!m_req && !m_ack, "port idle afterwards");

      $display("2. a single client B transaction");
      xact_b(24'h6004F0, db);
      check(db === (16'h04F0 ^ 16'hA5A5), "B gets the word for its own address");

      $display("3. B requests while A is in flight: B waits, sees no ack until its turn");
      @(posedge clk); a_addr <= 24'h601000; b_addr <= 24'h602000;
      @(posedge clk); a_req <= 1; a_owns <= 1;
      @(posedge clk); b_req <= 1; b_owns <= 1;   // one edge later: A already granted
      n_ack_b_while_a = 0;
      wait (a_ack);
      check(m_addr === 24'h601000, "the port is serving A's address");
      check(!b_ack, "B has no ack while A is served");
      @(posedge clk); da = a_dout; a_req <= 0;
      wait (!a_ack); @(posedge clk); a_owns <= 0;
      check(da === (16'h1000 ^ 16'hA5A5), "A's data intact");
      wait (b_ack);
      check(m_addr === 24'h602000, "then the port serves B's address");
      @(posedge clk); db = b_dout; b_req <= 0;
      wait (!b_ack); @(posedge clk); b_owns <= 0;
      check(db === (16'h2000 ^ 16'hA5A5), "B's data intact");

      $display("4. simultaneous requests: A wins the tie, B follows");
      @(posedge clk); a_addr <= 24'h603000; b_addr <= 24'h604000;
      @(posedge clk); a_req <= 1; b_req <= 1; a_owns <= 1; b_owns <= 1;
      wait (a_ack || b_ack);
      check(a_ack && !b_ack, "A is served first");
      check(m_addr === 24'h603000, "with A's address");
      @(posedge clk); a_req <= 0; wait (!a_ack); @(posedge clk); a_owns <= 0;
      wait (b_ack); check(m_addr === 24'h604000, "B next");
      @(posedge clk); b_req <= 0; wait (!b_ack); @(posedge clk); b_owns <= 0;

      $display("5. back-to-back B words (the writer's block fill shape)");
      for (i = 0; i < 8; i = i + 1) begin
         xact_b(24'h600000 + i, db);
         check(db === (i[15:0] ^ 16'hA5A5), "each word matches its address");
      end

      $display("6. witnesses");
      check(a_bad == 0, "A never saw an ack outside its own transaction");
      check(b_bad == 0, "B never saw an ack outside its own transaction");
      check(addr_settled_ok, "m_addr was settled one edge before every m_req rise");

      $display("");
      $display("tb_eth_port_arb: %0d checks, %0d failures", checks, fails);
      if (fails == 0) $display("PASS"); else $display("FAIL");
      $finish;
   end

   initial begin #2_000_000; $display("tb_eth_port_arb: TIMEOUT"); $finish; end
endmodule
