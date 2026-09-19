// eth_port_arb.v
//
// Share rtl/sdram.v's Ethernet DMA requester (eth_req/eth_we/eth_addr/eth_din
// -> eth_ack/eth_dout) between two clients: pds_enet (client A, priority) and
// the floppy SD writer (client B). Phase 4b of docs/floppy_write_plan.md.
//
// Why share rather than add a port: that requester is a proven LEVEL two-phase
// read/write handshake that starts only on idle edges and never touches
// cpu_done, and its clk_sys -> clk_64 crossing is already right. Adding a
// sibling port means editing the sequencer's start-priority chain in
// sdram.v, the most invariant-laden file in the core; an arbiter in front of
// the existing port leaves that file untouched.
//
// Protocol seen by each client is exactly the eth port's own: raise req with
// we/addr/din settled at least one edge earlier, hold until ack rises (read
// data valid in dout on that same edge), drop req, wait for ack to fall.
//
// Two rules make it safe:
//   1. The grant is LOCKED from the winner's req-rise until BOTH its req and
//      the port's ack are low again. A grant that moved while eth_ack was
//      still high would hand the next client an ack it never earned — the
//      same "done consumed by a request that never earned it" family every
//      stale-done bug in this core belongs to.
//   2. The muxed bundle is REGISTERED before it reaches the controller.
//      pds_enet's own note (rtl/pds/pds_enet.sv, cpu_waiting): combinational
//      depth on the term that drives eth_req across to clk_mem is what broke
//      hold there. The register costs one clk_sys per phase; a floppy block
//      is 256 words, so ~16 us per block against an 11 ms sector.
//
// Ack is only forwarded to the client holding the grant, so a client that
// raises req while the other's transaction is in flight sees nothing until
// its own turn; dout is shared and only meaningful with the client's own ack.
module eth_port_arb
(
	input             clk,
	input             reset,

	// client A — pds_enet, priority
	input             a_req,
	input             a_we,
	input      [23:0] a_addr,
	input      [15:0] a_din,
	output            a_ack,
	output     [15:0] a_dout,

	// client B — floppy_sd_writer (reads only in practice; we is honoured)
	input             b_req,
	input             b_we,
	input      [23:0] b_addr,
	input      [15:0] b_din,
	output            b_ack,
	output     [15:0] b_dout,

	// the controller's eth port
	output reg        m_req,
	output reg        m_we,
	output reg [23:0] m_addr,
	output reg [15:0] m_din,
	input             m_ack,
	input      [15:0] m_dout
);

	localparam G_NONE = 2'd0, G_A = 2'd1, G_B = 2'd2;
	reg [1:0] grant;

	assign a_ack  = (grant == G_A) && m_ack;
	assign b_ack  = (grant == G_B) && m_ack;
	assign a_dout = m_dout;
	assign b_dout = m_dout;

	always @(posedge clk) begin
		if (reset) begin
			grant <= G_NONE;
			m_req <= 1'b0;
			m_we  <= 1'b0;
		end else begin
			case (grant)
			G_NONE: begin
				m_req <= 1'b0;
				if (a_req) begin
					grant  <= G_A;
					m_we   <= a_we;
					m_addr <= a_addr;
					m_din  <= a_din;
				end else if (b_req) begin
					grant  <= G_B;
					m_we   <= b_we;
					m_addr <= b_addr;
					m_din  <= b_din;
				end
			end
			// bundle already registered on the grant edge, so m_req rises one
			// edge after m_addr settled — the shape the port asks for.
			G_A: begin
				m_req <= a_req;
				if (!a_req && !m_req && !m_ack) grant <= G_NONE;
			end
			G_B: begin
				m_req <= b_req;
				if (!b_req && !m_req && !m_ack) grant <= G_NONE;
			end
			default: grant <= G_NONE;
			endcase
		end
	end

endmodule
