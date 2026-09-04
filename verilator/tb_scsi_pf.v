/* tb_scsi_pf.v — unit test for the scsi_dpram look-ahead prefetch coherency.
 *
 * WHY THIS EXISTS (2026-08-14): the pdma-prefetch redesign (2026-07-17)
 * replaced the ram_c/ram_d mirror copies with a prefetch controller that
 * reads look-ahead bytes through idle port-B cycles into q_c/q_d holding
 * registers. Its PF_RDD discard path had a latent hole, found by the
 * MacLC_pocket fork (docs/mystery_b_root_cause.md there): a snooped fetch
 * DECLINED TO PUBLISH pf_c_addr/pf_d_addr/pf_valid but did not INVALIDATE.
 * If an earlier fetch had already published the same addresses, pf_valid
 * stayed 1 and the addresses still compared equal, so pf_stale stayed false
 * and no refetch ever launched — while q_c/q_d had just captured PRE-WRITE
 * data from a port-A/port-B read collision (no_rw_check M10K returns old
 * data). Stale, marked valid, permanent. Downstream that cost one 16-bit
 * word ($2C00 -> $0000) inside a compressed code resource and a
 * deterministic Sad-Mac ~15-20 s into every boot of the affected disk.
 *
 * The poisoning alignment is cadence-sensitive: with a back-to-back fill
 * (gap 1) the RDC read of addr N+1 happens AFTER the write to N+1 landed,
 * so the discarded capture is coincidentally fresh and the miss is benign.
 * Only a fill whose write to N+1 lands IN the RDC read cycle (gap 2 from
 * the write to N) captures old data. Hence the gap sweep below.
 *
 * WHAT IT CHECKS (scsi_dpram instantiated directly, golden model beside it):
 *   1. prime: sequential fill, prefetch publishes; q_c/q_d match golden
 *   2. gap sweep: rewrite addr_c then addr_d with gap g = 1..6 cycles;
 *      after quiescence q_c/q_d MUST match golden. g=2 is the poisoning
 *      alignment (fails before the PF_RDD invalidate fix, passes after).
 *   3. C-side flavor: double rewrite of addr_c aligned so the second write
 *      collides with the steal-launch read (the 2026-07-29 snoop clause
 *      marks it; the discard must invalidate for the refetch to happen).
 *   4. randomized soak: random port-A writes / port-B writes / mac_addr
 *      moves; after every >=12-cycle quiet window q_c/q_d must equal
 *      golden[mac_addr+1]/golden[mac_addr+2].
 *
 * Build + run (Verilator 5.x, from verilator/):
 *   verilator --binary -j 0 -Wno-fatal --timescale 1ns/1ps -I../rtl \
 *     --Mdir /tmp/obj_scsipf --top-module tb_scsi_pf tb_scsi_pf.v ../rtl/scsi.v
 *   /tmp/obj_scsipf/Vtb_scsi_pf
 * PASS criterion: last line "RESULT: PASS", exit 0.
 * (scsi.v is pulled in only for module scsi_dpram; the scsi/ncr top levels
 *  are not instantiated.)
 */

`timescale 1ns/1ps

module tb_scsi_pf;

reg clock = 0;
always #5 clock = ~clock;

localparam AW = 9;

reg  [AW-1:0] address_a = 0;
reg  [7:0]    data_a    = 0;
reg           wren_a    = 0;
wire [7:0]    q_a;

reg  [AW-1:0] address_b = 0;
reg  [7:0]    data_b    = 0;
reg           wren_b    = 0;
wire [7:0]    q_b;

reg  [AW-1:0] mac_addr  = 0;
wire [AW-1:0] address_c = mac_addr + 1'b1;
wire [AW-1:0] address_d = mac_addr + 2'd2;
wire [7:0]    q_c, q_d;

scsi_dpram #(.ADDRWIDTH(AW)) dut (
	.clock(clock),
	.address_a(address_a), .data_a(data_a), .wren_a(wren_a), .q_a(q_a),
	.address_b(address_b), .data_b(data_b), .wren_b(wren_b), .q_b(q_b),
	.address_c(address_c), .q_c(q_c),
	.address_d(address_d), .q_d(q_d)
);

// golden model: what the RAM really holds
reg [7:0] gold [0:(1<<AW)-1];
integer gi;
initial for (gi = 0; gi < (1<<AW); gi = gi + 1) gold[gi] = 8'h00;
always @(posedge clock) begin
	if (wren_a) gold[address_a] <= data_a;
	if (wren_b) gold[address_b] <= data_b;
end

integer errors = 0;
integer checks = 0;

task wr_a(input [AW-1:0] a, input [7:0] d);
	begin
		@(negedge clock);
		address_a <= a; data_a <= d; wren_a <= 1;
		@(negedge clock);
		wren_a <= 0;
	end
endtask

task idle(input integer n);
	integer k;
	begin
		for (k = 0; k < n; k = k + 1) @(negedge clock);
	end
endtask

task check_cd(input [127:0] tag);
	begin
		checks = checks + 1;
		if (q_c !== gold[address_c] || q_d !== gold[address_d]) begin
			errors = errors + 1;
			$display("FAIL [%0s] mac=%0d q_c=%02x (want %02x) q_d=%02x (want %02x)",
			         tag, mac_addr, q_c, gold[address_c], q_d, gold[address_d]);
		end else begin
			$display("ok   [%0s] mac=%0d q_c=%02x q_d=%02x", tag, mac_addr, q_c, q_d);
		end
	end
endtask

integer g, i;
integer quiet;
reg [31:0] lfsr = 32'hC0FFEE01;
task lfsr_step; begin
	lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
end endtask

initial begin
	// ---- 1. prime: sequential fill 0..7, then let the prefetch publish ----
	idle(4);
	for (i = 0; i < 8; i = i + 1) wr_a(i[AW-1:0], 8'h10 + i[7:0]);
	idle(12);
	check_cd("prime");

	// ---- 2. gap sweep: rewrite addr_c (=1), then addr_d (=2) g cycles on --
	// g counts negedges between the two writes' launch cycles. g=2 lands the
	// addr_d write in the refetch's PF_RDC read cycle: the port-B read of
	// addr_d collides with the port-A write (old data), the capture is
	// poisoned, and only an INVALIDATING discard triggers the healing
	// refetch. All other gaps must pass too (fresh capture or clean miss).
	for (g = 1; g <= 6; g = g + 1) begin
		wr_a(9'd1, 8'h20 + g[7:0]);          // snoop hit on pf_c_addr
		if (g > 1) idle(g - 1);
		wr_a(9'd2, 8'h30 + g[7:0]);          // the poisoning candidate
		idle(14);                             // >= worst-case refetch chain
		check_cd({"gap", "0" + g[7:0]});
	end

	// ---- 3. C-side flavor: two writes to addr_c, second in the ------------
	// steal-launch read cycle (gap 1 -> snoop sets, launch next cycle reads
	// addr_c while the second write lands on it).
	wr_a(9'd1, 8'hA1);
	wr_a(9'd1, 8'hA2);                        // back-to-back: lands in launch
	idle(14);
	check_cd("c-side1");
	wr_a(9'd1, 8'hA3);
	idle(1);
	wr_a(9'd1, 8'hA4);                        // gap 2 variant
	idle(14);
	check_cd("c-side2");

	// ---- 4. randomized soak ----------------------------------------------
	quiet = 0;
	for (i = 0; i < 20000; i = i + 1) begin
		@(negedge clock);
		lfsr_step;
		wren_a <= 0; wren_b <= 0;
		if (lfsr[3:0] < 4) begin              // ~25%: port-A write near window
			address_a <= {5'd0, lfsr[19:16]};
			data_a    <= lfsr[15:8];
			wren_a    <= 1;
			quiet = 0;
		end else if (lfsr[3:0] == 5) begin    // ~6%: port-B write
			address_b <= {5'd0, lfsr[23:20]};
			data_b    <= lfsr[15:8];
			wren_b    <= 1;
			quiet = 0;
		end else if (lfsr[3:0] == 6) begin    // ~6%: Mac side advances
			mac_addr  <= {6'd0, lfsr[18:16]};
			address_b <= {6'd0, lfsr[18:16]};
			quiet = 0;
		end else begin
			quiet = quiet + 1;
			if (quiet == 12) begin
				checks = checks + 1;
				if (q_c !== gold[address_c] || q_d !== gold[address_d]) begin
					errors = errors + 1;
					$display("FAIL [soak i=%0d] mac=%0d q_c=%02x (want %02x) q_d=%02x (want %02x)",
					         i, mac_addr, q_c, gold[address_c], q_d, gold[address_d]);
				end
			end
		end
	end

	$display("checks=%0d errors=%0d", checks, errors);
	if (errors == 0) $display("RESULT: PASS");
	else             $display("RESULT: FAIL");
	$finish;
end

endmodule
