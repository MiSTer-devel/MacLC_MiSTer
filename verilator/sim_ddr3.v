// sim_ddr3.v — behavioral stand-in for the DDRAM port that backs the PDS
// Ethernet mailbox (rtl/pds/pds_enet.sv) in simulation. 136 KB covering the
// card window at ARM 0x1FF00000 (Avalon word 0x03FE0000): boardram, declROM,
// control block, CMD ring.
//
// The "daemon" side is played by whoever stages this memory:
//   +pds_magic            write the MAGIC gate word so the card decodes
//   +pds_rom=<file.hex>   $readmemh a lane-expanded declROM image into the
//                         ROM window (64-bit words, 8192 entries)
// or a testbench poking the array hierarchically.

module sim_ddr3 (
	input             clk,
	input      [28:0] addr,
	input       [7:0] burst,     // always 1 from pds_enet
	input             rd,
	input             we,
	input      [63:0] wdata,
	input       [7:0] be,
	output reg [63:0] rdata,
	output reg        rvalid,
	output            busy
);

	assign busy = 1'b0;

	// 0x4400 x 64-bit words = 136 KB (layout tops out at word 0x41FF)
	reg [63:0] mem [0:17407];

	wire [14:0] off = addr[14:0];   // window-relative (base low bits are zero)

	integer i;
	reg [1023:0] romfile;
	initial begin
		for (i = 0; i < 17408; i = i + 1) mem[i] = 64'h0;
		rvalid = 0;
		rdata  = 0;
		if ($test$plusargs("pds_magic"))
			mem[15'h4000] = 64'h4D634C43_45544831;
		if ($value$plusargs("pds_rom=%s", romfile))
			$readmemh(romfile, mem, 15'h2000, 15'h3FFF);
	end

	always @(posedge clk) begin
		rvalid <= 0;
		if (rd) begin
			rdata  <= mem[off];
			rvalid <= 1;
		end
		if (we) begin
			for (i = 0; i < 8; i = i + 1)
				if (be[i]) mem[off][i*8 +: 8] <= wdata[i*8 +: 8];
		end
	end

	// testbench "daemon" access (hierarchical task calls from tb_pds_enet.v)
	task poke64(input [14:0] w, input [63:0] v); mem[w] = v; endtask
	function [63:0] peek64(input [14:0] w); peek64 = mem[w]; endfunction

endmodule
