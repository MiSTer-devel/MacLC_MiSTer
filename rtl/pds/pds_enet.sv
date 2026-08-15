/*
 * pds_enet.sv — Asante MacCON i LC Ethernet card (LC PDS pseudo-slot $E).
 *
 * Architecture is the Minimig A2065's, adapted (see docs/pds_ethernet_scope.md):
 * the FPGA side is a dumb front-end — slot decode, DP8390 register doorbell +
 * read shadows, and the card's 64K buffer RAM + declaration ROM served from a
 * DDR3 shared-memory window. The DP8390 itself (ring buffers, TX/RX, filters)
 * and the bridge to a real network interface run in the maclc_eth daemon on
 * the HPS, which polls the same DDR3 window via /dev/mem.
 *
 * Unlike the A2065 (mailbox at DDR3 clock, CDC handshakes everywhere) this
 * module runs entirely in clk_sys and the top drives DDRAM_CLK = clk_sys, so
 * there is no clock crossing anywhere.
 *
 * Guest-visible map (MAME nubus_asntmc3b.cpp pdslc_macconilc, ground truth):
 *   $FE0D'0000-$FE0D'FFFF  buffer RAM (64K)          also 24-bit $ED'0000
 *   $FE0E'0000-$FE0E'003F  DP8390 registers          also 24-bit $EE'0000
 *       reg byte on D[15:8] at (base + N*4), register index = ~addr[5:2]
 *       (A5..A2 wired inverted on the real card);
 *       16-bit access (UDS+LDS) anywhere in the window = remote-DMA data port
 *   $FE FF'0000-$FE FF'FFFF declaration ROM window (daemon stages the
 *       byte-lane-expanded image; the 16K ROM with byteLanes=$A5 occupies the
 *       top 32K, ROM bytes on even addresses)
 *   IRQ: active-high INT -> pseudo-VIA slot-IFR reg $02 bit $20 (slot $E).
 *
 * DDR3 window (ARM phys 0x1FF00000, same reserved area the A2065 uses; only
 * one core is ever loaded so there is no conflict):
 *   +0x00000  64K  boardram        (byte A of guest space = DDR3 byte A)
 *   +0x10000  64K  declROM window  (ARM-staged, lane-expanded, read-only)
 *   +0x20000       control block, 64-bit words:
 *       +0x00 MAGIC       (ARM->FPGA) 64'h4D634C43_45544831 "MacLCETH1" gate
 *       +0x08 CMD_WPTR    (FPGA->ARM) doorbell ring write index
 *       +0x10..+0x38 REG SHADOWS (ARM->FPGA) 6 words = 48 bytes, byte k of
 *             word n = 8390 register (n*8+k) in page-major order
 *             (page0 regs 0-15, page1 regs 0-15, page2 regs 0-15)
 *       +0x40 INT         (ARM->FPGA) bit0 = 8390 INT line state
 *       +0x48 RPC         (ARM->FPGA) data-port read response:
 *             bit0 = valid, [15:8] = seq echo, [31:16] = data
 *       +0x50 GEOMETRY    (ARM only, self-documentation)
 *   +0x20800  2K   CMD ring, 256 x 64-bit, entry:
 *             bit0 = valid, [3:1] = tag, [7:4] = 8390 reg addr (true, already
 *             un-inverted), [23:8] = data, [31:24] = seq (data-port reads)
 *       tags: 0 = REG_WR (data[7:0])         1 = DATAPORT_WR (data[15:0])
 *             2 = DATAPORT_RD (seq)          3 = READ_NOTIFY (clear-on-read
 *             counter regs CNTR0-2 were read) 4 = RESET (guest warm restart)
 *
 * Doorbell discipline (the A2065 lesson, kept): register writes stretch DTACK
 * only until the ring entry + write pointer are IN DDR3 — never until the
 * daemon runs, which would deadlock the guest against host scheduling. Reads
 * are answered instantly from the shadows. Only boardram/declROM accesses and
 * data-port reads stretch for a DDR3 round trip, and the data-port read RPC
 * carries a watchdog (the SCSI pseudo-DMA lesson: a stalled cycle must
 * complete eventually, never hang the machine).
 *
 * Presence: the card decodes only if the daemon's MAGIC was valid at the
 * moment the guest came out of reset (and the OSD option is on). No daemon =
 * pseudo-slot $E stays exactly as today (open-bus $FFFF ack in the tops).
 * MAGIC is sampled once per poll round; a daemon death mid-session leaves the
 * DDR3-backed RAM/ROM serving fine, register writes still complete (they only
 * wait on DDR3), and the data-port watchdog covers the one path that waits on
 * the daemon.
 */

module pds_enet #(
	// data-port read RPC watchdog: 2^DP_WD_BITS clk_sys (~129 ms at 22).
	// Parameterized so the testbench can exercise the timeout path quickly.
	parameter DP_WD_BITS = 22
) (
	input             clk_sys,
	input             rst_core,      // hard reset (POR / core load), active high
	input             rst_guest,     // guest reset (RESET instruction etc.), active high
	input             ena_osd,       // OSD "Ethernet" option

	// CPU bus (clk_sys, TG68 16-bit bus conventions of the tops)
	input      [31:0] cpuAddr,
	input      [15:0] cpuDataIn,     // CPU write data (cpuDataOut of the tops)
	input             _cpuAS,
	input             _cpuUDS,
	input             _cpuLDS,
	input             _cpuRW,        // 1 = read

	output            card_sel,      // card claims this bus cycle (gate VPA/DTACK/din in top)
	output            card_ack,      // cycle may complete (data valid on reads)
	output     [15:0] card_dout,
	output            irq,           // active high -> pds_slot_irq

	// DDR3 / DDRAM port (clk_sys — top must drive DDRAM_CLK = clk_sys)
	output reg [28:0] mem_addr,
	output reg  [7:0] mem_burst,
	output reg        mem_rd,
	output reg        mem_we,
	output reg [63:0] mem_wdata,
	output reg  [7:0] mem_be,
	input      [63:0] mem_rdata,
	input             mem_rvalid,
	input             mem_busy
);

	// ── DDR3 window layout (64-bit word addresses) ──────────────────────────
	localparam [28:0] AV_BASE  = 29'h03FE0000;   // ARM 0x1FF00000
	localparam [14:0] AV_BRAM  = 15'h0000;       // +0x00000, 8192 words
	localparam [14:0] AV_ROM   = 15'h2000;       // +0x10000, 8192 words
	localparam [14:0] AV_MAGIC = 15'h4000;       // control block
	localparam [14:0] AV_WPTR  = 15'h4001;
	localparam [14:0] AV_SHAD  = 15'h4002;       // 6 words
	localparam [14:0] AV_INT   = 15'h4008;
	localparam [14:0] AV_RPC   = 15'h4009;
	localparam [14:0] AV_RPTR  = 15'h400B;      // daemon's ring read index
	localparam [14:0] AV_RING  = 15'h4100;       // 256 words

	localparam [63:0] MAGIC_V  = 64'h4D634C43_45544831;

	localparam [2:0] TAG_REG_WR      = 3'd0;
	localparam [2:0] TAG_DATAPORT_WR = 3'd1;
	localparam [2:0] TAG_DATAPORT_RD = 3'd2;
	localparam [2:0] TAG_READ_NOTIFY = 3'd3;
	localparam [2:0] TAG_RESET       = 3'd4;

	// ── slot decode ─────────────────────────────────────────────────────────
	// 32-bit standard slot space $FExx'xxxx; 24-bit slot window $00Ex'xxxx.
	// (The V8 ignores A30-A24, but the Slot Manager and drivers use the
	// canonical forms; everything else in $F1-$FE keeps the top's open-bus
	// ack, so decoding only the canonical forms is both safe and sufficient —
	// matches what MAME installs.)
	wire        form32 = (cpuAddr[31:24] == 8'hFE);
	wire        form24 = (cpuAddr[31:24] == 8'h00) && (cpuAddr[23:20] == 4'hE);
	wire [23:0] sub    = form32 ? cpuAddr[23:0] : {4'h0, cpuAddr[19:0]};

	wire sel_ram = (form32 | form24) && (sub[23:16] == 8'h0D);
	wire sel_reg = (form32 | form24) && (sub[23:6] == 18'h03800); // $0E0000-$0E003F
	wire sel_rom = form32 && (sub[23:16] == 8'hFF);

	wire ds_any  = ~_cpuUDS | ~_cpuLDS;
	wire cyc     = !_cpuAS && ds_any;   // strobes valid: direction + data good

	assign card_sel = present && (sel_ram | sel_reg | sel_rom) && !_cpuAS;

	wire req = present && (sel_ram | sel_reg | sel_rom) && cyc;

	// Register-window access classification (MAME dp_w/dp_r mem_mask rules,
	// translated to the 16-bit bus): byte on D[15:8] at longword+0 = register;
	// 16-bit UDS+LDS = remote-DMA data port; anything else is unmodelled on
	// the real card (MAME fatalerrors) — we serve $FFFF and never stall.
	wire reg_byte  = sel_reg && (sub[1] == 1'b0) && !_cpuUDS && _cpuLDS;
	wire reg_word  = sel_reg && !_cpuUDS && !_cpuLDS;
	// any other reg-window shape (LDS-only byte, odd-word byte) is unmodelled
	// on the real card — classification falls through to K_STUB ($FFFF, no stall)

	wire [3:0] reg_idx = ~sub[5:2];   // A5..A2 wired inverted on the card

	// ── local 8390 CR copy (page resolution for shadow reads) ───────────────
	// CR itself reads from this copy (page bits must reflect a just-completed
	// write immediately), except TXP which the daemon owns via the shadow.
	reg  [7:0] cr_local;

	// ── shadows / INT / RPC / MAGIC (poll results) ──────────────────────────
	reg [63:0] shad [0:5];
	reg        int_state;
	reg        magic_ok;
	reg        rpc_valid;
	reg  [7:0] rpc_seq_echo;
	reg [15:0] rpc_data;

	// presence: latched while the guest is in reset, held stable across the
	// whole session so the Slot Manager never sees the card flicker.
	reg        present;

	wire [5:0] shad_idx  = {cr_local[7:6], reg_idx};      // page-major
	wire [7:0] shad_byte = shad[shad_idx[5:3]][{shad_idx[2:0], 3'b000} +: 8];
	wire [7:0] txp_bit   = shad[0][7:0];                  // page0 reg0 = CR shadow

	// CR is common to all three pages on the 8390 — always serve the local
	// copy (page bits must reflect a just-completed write immediately), with
	// TXP taken from the daemon's shadow since the daemon owns transmit.
	wire [7:0] reg_rdata = (reg_idx == 4'h0)
	                       ? {cr_local[7:3], txp_bit[2], cr_local[1:0]}
	                       : shad_byte;

	// clear-on-read tally counters: page 0, regs $0D/$0E/$0F
	wire cntr_read = reg_byte && _cpuRW && (cr_local[7:6] == 2'b00) && (reg_idx >= 4'hD);

	// ── CPU-side request handshake (all clk_sys, no CDC) ────────────────────
	localparam H_IDLE = 2'd0, H_RUN = 2'd1, H_DONE = 2'd2;
	reg  [1:0] hstate;
	reg [15:0] dout_r;
	reg        req_is_wr;
	reg [23:0] req_sub;
	reg  [1:0] req_be;         // {UDS, LDS}
	reg [15:0] req_wdata;
	reg  [2:0] req_kind;
	localparam K_RAM = 3'd0, K_ROM = 3'd1, K_REGRD = 3'd2, K_REGWR = 3'd3,
	           K_DPWR = 3'd4, K_DPRD = 3'd5, K_STUB = 3'd6;

	assign card_ack  = (hstate == H_DONE);
	assign card_dout = dout_r;

	// ── doorbell / mailbox FSM ──────────────────────────────────────────────
	localparam S_IDLE      = 4'd0;
	localparam S_CMD_W     = 4'd1;   // ring entry write in flight
	localparam S_WPTR_W    = 4'd2;   // wptr publish in flight
	localparam S_MEM_RD_W  = 4'd3;
	localparam S_MEM_RD_D  = 4'd4;
	localparam S_MEM_WR_W  = 4'd5;
	localparam S_POLL_W    = 4'd6;
	localparam S_POLL_D    = 4'd7;
	localparam S_WPTR_INIT = 4'd8;

	reg  [3:0] state;
	// 32-bit monotonic doorbell count (ring index = wptr[7:0]); published in
	// full so the daemon can tell a ring wrap from an FPGA reset (the A2065
	// publishes its cmd_wr_idx the same way).
	reg [31:0] wptr;
	reg        wptr_published;
	reg [63:0] cmd_entry;      // pending ring entry (one deep)
	reg        cmd_queued;
	reg        cmd_for_cpu;    // the stalled CPU cycle completes on publish
	reg [15:0] poll_div;
	reg  [3:0] poll_step;      // walks MAGIC, SHAD0-5, INT, RPC
	reg  [3:0] poll_step_q;
	reg        rst_guest_d;
	reg  [7:0] dp_seq;
	reg        dp_wait;        // data-port read outstanding
	reg [DP_WD_BITS-1:0] dp_wd;   // RPC watchdog (see parameter)

	// ring backpressure: the daemon publishes its read index (AV_RPTR, polled
	// below); if a doorbell burst gets ~200 entries ahead (possible only if a
	// driver bulk-transfers through the remote-DMA data port) the publish
	// stalls — bounded by cmd_wait_ctr (~2 ms) so a dead daemon can never
	// hang the guest, it just loses entries it wasn't reading anyway.
	reg [31:0] rptr_sh;
	reg [15:0] cmd_wait_ctr;
	wire       ring_full = (wptr - rptr_sh) >= 32'd200;

	// notify drop: if a doorbell is already queued when a counter read happens,
	// drop the notify (stats-only impact) rather than stall a read cycle.
	wire       notify_ok = !cmd_queued && (state == S_IDLE) && !dp_wait;

	// fast RPC polling while a data-port read is outstanding, and while the
	// doorbell is backpressured (rptr_sh must refresh to release it)
	wire       poll_due  = (dp_wait || (cmd_queued && ring_full))
	                                 ? (poll_div[4:0] == 5'h1F)
	                     : magic_ok ? (poll_div[9:0] == 10'h3FF)
	                     : (poll_div == 16'hFFFF);

	wire [28:0] bram_word = AV_BASE + {14'b0, AV_BRAM} + {16'b0, req_sub[15:3]};
	wire [28:0] rom_word  = AV_BASE + {14'b0, AV_ROM } + {16'b0, req_sub[15:3]};
	wire  [2:0] lane      = req_sub[2:0];   // byte lane of D[15:8] byte

	integer i;
	always @(posedge clk_sys) begin
		if (rst_core) begin
			state       <= S_IDLE;
			hstate      <= H_IDLE;
			mem_rd      <= 0;
			mem_we      <= 0;
			mem_burst   <= 8'd1;
			mem_addr    <= 0;
			mem_wdata   <= 0;
			mem_be      <= 8'hFF;
			wptr        <= 0;
			wptr_published <= 0;
			cmd_queued  <= 0;
			cmd_for_cpu <= 0;
			poll_div    <= 0;
			poll_step   <= 0;
			poll_step_q <= 0;
			rst_guest_d <= 0;
			magic_ok    <= 0;
			int_state   <= 0;
			rpc_valid   <= 0;
			rpc_seq_echo<= 0;
			rpc_data    <= 0;
			present     <= 0;
			cr_local    <= 8'h21;      // 8390 reset state: STP|page0
			dp_seq      <= 0;
			dp_wait     <= 0;
			dp_wd       <= '0;
			rptr_sh     <= 0;
			cmd_wait_ctr<= 0;
			dout_r      <= 16'hFFFF;
			req_is_wr   <= 0;
			req_sub     <= 0;
			req_be      <= 0;
			req_wdata   <= 0;
			req_kind    <= K_STUB;
			for (i = 0; i < 6; i = i + 1) shad[i] <= 64'h0;
		end else begin
			mem_rd <= 0;
			mem_we <= 0;
			poll_div <= poll_div + 1'b1;

			// presence can only change while the guest is held in reset; once
			// running it is frozen so the Slot Manager never sees the card
			// flicker. Sticky-rise on MAGIC within the reset window: rst_core
			// is hard-reset only, so a warm restart keeps the mailbox state
			// and just re-evaluates presence (and a daemon death mid-session
			// deliberately does NOT clear it — DDR3 keeps serving RAM/ROM and
			// the data-port watchdog covers the one daemon-dependent path).
			rst_guest_d <= rst_guest;
			if (rst_guest) begin
				if (!ena_osd)      present <= 1'b0;
				else if (magic_ok) present <= 1'b1;
				cr_local <= 8'h21;
				// tell the daemon to reset its 8390 model (once per reset entry)
				if (!rst_guest_d && present && !cmd_queued && magic_ok) begin
					cmd_entry   <= {32'b0, 24'b0, 4'b0, TAG_RESET, 1'b1};
					cmd_queued  <= 1'b1;
					cmd_for_cpu <= 1'b0;
				end
			end

			// ── CPU handshake ────────────────────────────────────────────
			case (hstate)
			H_IDLE: if (req) begin
				req_is_wr <= !_cpuRW;
				req_sub   <= sub;
				req_be    <= {~_cpuUDS, ~_cpuLDS};
				req_wdata <= cpuDataIn;
				dout_r    <= 16'hFFFF;
				// classify
				if (sel_ram)            req_kind <= K_RAM;
				else if (sel_rom)       req_kind <= K_ROM;
				else if (reg_byte)      req_kind <= _cpuRW ? K_REGRD : K_REGWR;
				else if (reg_word)      req_kind <= _cpuRW ? K_DPRD  : K_DPWR;
				else                    req_kind <= K_STUB;
				hstate <= H_RUN;
			end
			H_RUN: begin
				case (req_kind)
				K_REGRD: begin
					dout_r <= {reg_rdata, 8'hFF};
					if (cntr_read && notify_ok) begin
						cmd_entry   <= {40'b0, 16'b0, reg_idx, TAG_READ_NOTIFY, 1'b1};
						cmd_queued  <= 1'b1;
						cmd_for_cpu <= 1'b0;
					end
					hstate <= H_DONE;
				end
				K_REGWR: begin
					if (!cmd_queued) begin
						if (reg_idx == 4'h0) cr_local <= req_wdata[15:8];
						cmd_entry   <= {40'b0, 8'b0, req_wdata[15:8], reg_idx, TAG_REG_WR, 1'b1};
						cmd_queued  <= 1'b1;
						cmd_for_cpu <= 1'b1;   // H_DONE comes from the publish path
					end
				end
				K_DPWR: begin
					if (!cmd_queued) begin
						cmd_entry   <= {40'b0, req_wdata, 4'b0, TAG_DATAPORT_WR, 1'b1};
						cmd_queued  <= 1'b1;
						cmd_for_cpu <= 1'b1;
					end
				end
				K_DPRD: begin
					if (!dp_wait && !cmd_queued) begin
						cmd_entry   <= {32'b0, dp_seq + 8'd1, 16'b0, 4'b0, TAG_DATAPORT_RD, 1'b1};
						cmd_queued  <= 1'b1;
						cmd_for_cpu <= 1'b0;
						dp_seq      <= dp_seq + 8'd1;
						dp_wait     <= 1'b1;
						dp_wd       <= '0;
					end
					if (dp_wait) begin
						dp_wd <= dp_wd + 1'b1;
						if (rpc_valid && rpc_seq_echo == dp_seq) begin
							dout_r  <= rpc_data;
							dp_wait <= 1'b0;
							hstate  <= H_DONE;
						end else if (&dp_wd) begin
							dout_r  <= 16'hFFFF;   // daemon gone — never hang the guest
							dp_wait <= 1'b0;
							hstate  <= H_DONE;
						end
					end
				end
				K_STUB: begin
					dout_r <= 16'hFFFF;
					hstate <= H_DONE;
				end
				default: ;   // K_RAM / K_ROM complete via the mailbox FSM below
				endcase
			end
			H_DONE: begin
				if (_cpuAS || !ds_any) hstate <= H_IDLE;
			end
			default: hstate <= H_IDLE;
			endcase

			// ── mailbox FSM ──────────────────────────────────────────────
			if (cmd_queued && ring_full && state == S_IDLE) begin
				if (!(&cmd_wait_ctr)) cmd_wait_ctr <= cmd_wait_ctr + 1'b1;
			end else if (!cmd_queued)
				cmd_wait_ctr <= 0;

			case (state)
			S_IDLE: begin
				if (!wptr_published) begin
					mem_addr  <= AV_BASE + {14'b0, AV_WPTR};
					mem_wdata <= 64'd0;
					mem_be    <= 8'hFF;
					mem_we    <= 1;
					state     <= S_WPTR_INIT;
				end else if (cmd_queued && (!ring_full || (&cmd_wait_ctr))) begin
					mem_addr  <= AV_BASE + {14'b0, AV_RING} + {21'b0, wptr[7:0]};
					mem_wdata <= cmd_entry;
					mem_be    <= 8'hFF;
					mem_we    <= 1;
					state     <= S_CMD_W;
				end else if (hstate == H_RUN && (req_kind == K_RAM || req_kind == K_ROM)) begin
					mem_addr <= (req_kind == K_RAM) ? bram_word : rom_word;
					if (req_is_wr && req_kind == K_RAM) begin
						// boardram write: byte-enable the targeted lanes.
						// Guest byte A lives at DDR3 byte lane (A&7): the
						// D[15:8] byte (even address) at `lane`, the D[7:0]
						// byte at lane+1 — so replicate the word SWAPPED so
						// even lanes carry D[15:8].
						mem_wdata <= {4{req_wdata[7:0], req_wdata[15:8]}};
						mem_be    <= ({7'b0, req_be[1]} << lane) | ({7'b0, req_be[0]} << (lane + 3'd1));
						mem_we    <= 1;
						state     <= S_MEM_WR_W;
					end else begin
						mem_rd    <= 1;
						state     <= S_MEM_RD_W;
					end
				end else if (poll_due) begin
					poll_step_q <= poll_step;
					mem_addr <= AV_BASE + {14'b0,
					            (poll_step == 4'd0) ? AV_MAGIC :
					            (poll_step == 4'd7) ? AV_INT   :
					            (poll_step == 4'd8) ? AV_RPC   :
					            (poll_step == 4'd9) ? AV_RPTR  :
					                                  AV_SHAD + {11'b0, poll_step - 4'd1}};
					mem_rd   <= 1;
					state    <= S_POLL_W;
				end
			end

			S_CMD_W: begin
				if (!mem_busy) begin
					mem_addr  <= AV_BASE + {14'b0, AV_WPTR};
					mem_wdata <= {32'b0, wptr + 32'd1};
					mem_be    <= 8'hFF;
					mem_we    <= 1;
					wptr      <= wptr + 32'd1;
					state     <= S_WPTR_W;
				end else mem_we <= 1;
			end

			S_WPTR_W: begin
				if (!mem_busy) begin
					cmd_queued <= 0;
					if (cmd_for_cpu) begin
						cmd_for_cpu <= 0;
						hstate      <= H_DONE;   // register/data-port write retires
					end
					state <= S_IDLE;
				end else mem_we <= 1;
			end

			S_WPTR_INIT: begin
				if (!mem_busy) begin
					wptr_published <= 1;
					state <= S_IDLE;
				end else mem_we <= 1;
			end

			S_MEM_RD_W: begin
				if (!mem_busy) state <= S_MEM_RD_D;
				else mem_rd <= 1;
			end

			S_MEM_RD_D: begin
				if (mem_rvalid) begin
					dout_r[15:8] <= mem_rdata[{lane,          3'b000} +: 8];
					dout_r[7:0]  <= mem_rdata[{lane + 3'd1,   3'b000} +: 8];
					hstate <= H_DONE;
					state  <= S_IDLE;
				end
			end

			S_MEM_WR_W: begin
				if (!mem_busy) begin
					hstate <= H_DONE;
					state  <= S_IDLE;
				end else mem_we <= 1;
			end

			S_POLL_W: begin
				if (!mem_busy) state <= S_POLL_D;
				else mem_rd <= 1;
			end

			S_POLL_D: begin
				if (mem_rvalid) begin
					case (poll_step_q)
					4'd0: magic_ok <= (mem_rdata == MAGIC_V);
					4'd7: int_state <= mem_rdata[0];
					4'd8: begin
						rpc_valid    <= mem_rdata[0];
						rpc_seq_echo <= mem_rdata[15:8];
						rpc_data     <= mem_rdata[31:16];
					end
					4'd9: rptr_sh <= mem_rdata[31:0];
					default: shad[poll_step_q[2:0] - 3'd1] <= mem_rdata;
					endcase
					// walk the full set only when the card is live; otherwise
					// just keep sampling MAGIC.
					if (magic_ok || poll_step_q != 4'd0)
						poll_step <= (poll_step_q == 4'd9) ? 4'd0 : poll_step_q + 4'd1;
					state <= S_IDLE;
				end
			end

			default: state <= S_IDLE;
			endcase
		end
	end

	assign irq = int_state && present;

endmodule
