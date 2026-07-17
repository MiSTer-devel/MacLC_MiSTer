/* verilator lint_off UNUSED */

/* based on minimigmac by Benjamin Herrenschmidt */

/* Read registers */
`define RREG_CDR        3'h0    /* Current SCSI data */
`define RREG_ICR        3'h1    /* Initiator Command */
`define RREG_MR         3'h2    /* Mode register */
`define RREG_TCR        3'h3    /* Target Command */
`define RREG_CSR        3'h4    /* SCSI bus status */
`define RREG_BSR        3'h5    /* Bus and status */
`define RREG_IDR        3'h6    /* Input data */
`define RREG_RST        3'h7    /* Reset */

/* Write registers */
`define WREG_ODR        3'h0    /* Output data */
`define WREG_ICR        3'h1    /* Initiator Command */
`define WREG_MR         3'h2    /* Mode register */
`define WREG_TCR        3'h3    /* Target Command */
`define WREG_SER        3'h4    /* Select Enable */
`define WREG_DMAS       3'h5    /* Start DMA Send */
`define WREG_DMATR      3'h6    /* Start DMA Target receive */
`define WREG_IDMAR      3'h7    /* Start DMA Initiator receive */

/* MR bit numbers */
`define MR_DMA_MODE     1
`define MR_ARB          0

/* ICR bit numbers */
`define ICR_A_RST       7
`define ICR_TEST_MODE   6
`define ICR_DIFF_ENBL   5
`define ICR_A_ACK       4
`define ICR_A_BSY       3
`define ICR_A_SEL       2
`define ICR_A_ATN       1
`define ICR_A_DATA      0

/* TCR bit numbers */
`define TCR_A_REQ       3
`define TCR_A_MSG       2
`define TCR_A_CD        1
`define TCR_A_IO        0

module ncr5380
(
	input    		clk,
	input 	     	reset,

	/* Bus interface. 3-bit address, to be wired
	 * appropriately upstream (to A4..A6) plus one
	 * more bit (A9) wired as dack.
	 */
	input         bus_cs,
	input   [2:0] bus_rs,
	input         ior,
	input         iow,
	input         dack,
	input         dma_word,
	input         dma_longword,
	input         dma_second_word,
	output        dreq,
	// Latched 5380 interrupt (phase-mismatch during armed DMA). Reserved for
	// a pseudo-VIA IFR bit-3 hookup (LC has no VIA2); see port notes.
	output        o_irq,
	input  [15:0] wdata,
	output [15:0] rdata,

	// connections to io controller
	input  [DEVS-1:0] img_mounted,
	input      [31:0] img_size,
	
	output reg [31:0] io_lba[DEVS],
	output [DEVS-1:0] io_rd,
	output [DEVS-1:0] io_wr,
	input  [DEVS-1:0] io_ack,

	input        [7:0] sd_buff_addr,
	input       [15:0] sd_buff_dout,
	output      [15:0] sd_buff_din[DEVS],
	input              sd_buff_wr,

	// ---- BlueSCSI Toolbox dedicated block interface (primary target / ID 6) --
	input         tb_mounted,
	output [31:0] tb_lba,
	output        tb_rd,
	output        tb_wr,
	input         tb_ack,
	output [15:0] tb_buff_din,

	// CD audio PCM from the CDROM target's playback engine
	output signed [15:0] cd_snd_l,
	output signed [15:0] cd_snd_r,

	// ---- CD-ROM target (SCSI ID 3) dedicated block interface ----------------
	// Own hps_io slot; read-only. cd_enable = OSD "CD-ROM Drive" option: when
	// off the target never answers selection (bus looks exactly like pre-CD
	// builds — the A/B lever if the new target ever misbehaves on HW).
	input         cd_enable,
	input         cd_img_mounted,
	output [31:0] cd_io_lba,
	output        cd_io_rd,
	output        cd_io_wr,
	input         cd_io_ack,
	output [15:0] cd_sd_buff_din,

	// JTAG debug: selection/arbitration state for the hardware hang
	output      [15:0] dbg_scsi,
	// JTAG debug: post-selection phase + HPS disk handshake
	//   [13:11] target_phase[1]  [10:8] target_phase[0]
	//   [5:4] io_rd  [3:2] io_wr  [1:0] io_ack
	output      [15:0] dbg_scsi2,
	// JTAG debug: per-target REQ/ACK handshake observations
	//   [15:8] target1 dbg_hs   [7:0] target0 dbg_hs
	output      [15:0] dbg_scsi3,
	// JTAG debug: bus-reset count + per-target completion flags
	//   [15:8] scsi_rst assertion count (saturating)
	//   [7:4]  target1 dbg_hs2   [3:0] target0 dbg_hs2
	output      [15:0] dbg_scsi4,
	// JTAG debug: per-target command-type bitmap
	//   [15:8] target1 dbg_cmd   [7:0] target0 dbg_cmd
	output      [15:0] dbg_scsi5,
	// JTAG debug (PSNC): NCR5380 host-side pseudo-DMA state (why DREQ stops).
	//   [0]=dreq [1]=scsi_req [2]=scsi_ack [3]=dma_en [4]=dma_ack
	//   [5]=dma_ack_busy [8:6]=dma_ack_holdoff [9]=mr_dma_mode [10]=bsr_pmatch
	//   [11]=dma_word_latched [12]=dma_longword_latched [13]=longword_second_pending
	//   [17:14]=tcr [31:18]=dma_wr_count (i_dma_wr OR i_dma_rd pulses, both directions)
	output      [31:0] dbg_ncr,
	// JTAG debug (PSWL): write loss-mechanism + IRQ/deferral machine state.
	//   [7:0]=blind_wr_count (i_dma_wr while dreq==0 = Mac wrote w/o DREQ)
	//   [8]=dma_en [9]=bsr_pmatch [10]=dreq [11]=bsr_eodma [12]=dma_armed
	//   [13]=irq_latch [14]=scsi_req_bus [15]=req_deferred
	//   [31:16]=req_drop_count (scsi_req 1->0 edges while dma_en — REQ pauses)
	output      [31:0] dbg_ncr2,
	// JTAG debug (PSCW): write-stall snapshot of whichever target is in the
	// WRITE data phase (PHASE_DATA_IN=3); defaults to target 1 (the
	// OSD-mounted disk usually lands there). Layout = scsi.v dbg_wrstall:
	//   [15:0]=data_cnt [18:16]=phase [19]=data_complete [20]=io_wr [21]=io_ack
	//   [22]=io_busy [23]=sd_buff_sel [24]=cmd_write [30:25]=tlen [31]=req
	output      [31:0] dbg_wr,
	// JTAG CDA0/CDA1: CD-audio engine + CD target command visibility
	output      [31:0] dbg_cda0,
	output      [31:0] dbg_cda1
);
	parameter DEVS = 2;
	// Read-prefetch ring depth for the CD target. 3 => 8 sectors / 4KB = two
	// 2048-byte CD blocks buffered. Kept smaller than the disks' RING_LOG=5:
	// the sector-buffer M10K budget is nearly full (scsi.v RING_LOG notes) and
	// the CD is never the boot device, so latency-hiding matters less.
	parameter CD_RING_LOG = 3;

	reg  [7:0] mr;        /* Mode Register */
	reg  [7:0] icr;       /* Initiator Command Register */
	reg  [3:0] tcr;       /* Target Command Register */
	wire [7:0] csr;       /* SCSI bus status register */
	reg        arb_active;
	reg  [7:0] arb_count;

	/* Data in and out latches and associated
	* control logic for DMA
	*/
	reg  [7:0] din;
	reg  [7:0] dout;
	reg        dma_en;

	/* --- Main host-side interface --- */

	/* Register & DMA accesses decodes */
	reg dma_wr;
	reg reg_wr;
	reg dma_ack;
	reg [2:0] dma_ack_holdoff;
	reg [3:0] dma_settle;
	reg dma_word_latched;
	reg dma_longword_latched;
	reg dma_second_word_latched;
	reg dma_suppress_ack_latched;
	reg dma_longword_second_pending;
	reg [15:0] dma_second_word_data;
	reg [7:0] dma_write_low_byte;
	reg old_dma_rd;
	reg old_dma_wr;
	reg old_reg_wr;

	/* dma_settle: post-ACK-train data-path settle time. The target advances
	 * data_cnt two clocks after each ACK falling edge (old_ack/stb_adv
	 * pipeline in scsi.v) and its sector-buffer dpram q outputs update one
	 * clock after that, so the byte pair presented on din_pair/din_pair_next
	 * is stale for 3 clocks after the last ACK of a train retires (and the
	 * scsi_dpram look-ahead prefetch controller needs up to 3 more port-B
	 * cycles to refresh q_c/q_d after the advance — see scsi_dpram). DREQ used
	 * to re-assert inside that window; the TG68 bus samples DTACK(=~DREQ) on
	 * the phi2 grid and latches data two clocks later, which lands INSIDE the
	 * stale window on one of the two phase parities — the host then re-reads
	 * the previous byte/word (stream shifted -1/-2) or, for longwords,
	 * pre-latches a duplicate second word. Holding dma_ack_busy through the
	 * settle window makes DREQ mean "presented data is valid", for every
	 * host sampling alignment. (verilator/scsi_bench reproduces all three.)
	 */
	wire dma_ack_busy = dma_ack | (dma_ack_holdoff != 3'd0) | (dma_settle != 4'd0);
	assign dreq = scsi_req & dma_en & !dma_ack_busy;

	wire i_dma_rd = bus_cs &  dack & ior;
	wire i_dma_wr = bus_cs &  dack & iow;
	wire i_reg_wr = bus_cs & ~dack & iow;
	// Host read of the Current SCSI Bus Status register (REQ poll) — used by the
	// target's block-boundary REQ pulse to know the host has observed REQ=0.
	wire csr_rd = bus_cs & ~dack & ior & (bus_rs == `RREG_CSR);

	always @(posedge clk or posedge reset) begin
		if (reset) begin
			old_dma_rd <= 0;
			old_dma_wr <= 0;
			old_reg_wr <= 0;
			dma_wr <= 0;
			dma_ack <= 0;
			dma_ack_holdoff <= 0;
			dma_settle <= 0;
			reg_wr <= 0;
			dma_word_latched <= 0;
			dma_longword_latched <= 0;
			dma_second_word_latched <= 0;
			dma_suppress_ack_latched <= 0;
			dma_longword_second_pending <= 0;
			dma_second_word_data <= 16'h0000;
			dma_write_low_byte <= 8'h00;
		end else begin
			old_dma_rd <= i_dma_rd;
			old_dma_wr <= i_dma_wr;
			old_reg_wr <= i_reg_wr;

			dma_wr <= 0;
			dma_ack <= 0;
			reg_wr <= 0;

			/* Re-arm the settle window on every ACK pulse; after the last
			 * pulse of a train it counts down 8..1 so dma_ack_busy (and
			 * therefore !DREQ) covers the target's data_cnt+dpram update
			 * pipeline (see dma_settle declaration). 8 = 1 (ACK-fall detect
			 * in scsi.v) + 2 (stb_adv -> data_cnt) + 1 (dpram q) + 3
			 * (scsi_dpram look-ahead prefetch: read addr+1, read addr+2,
			 * restore port B — the pdma-prefetch redesign that replaced the
			 * ram_c/ram_d mirror arrays) + 1 margin.
			 */
			if (dma_ack) dma_settle <= 4'd8;
			else if (dma_settle != 4'd0) dma_settle <= dma_settle - 4'd1;

			if(~old_dma_rd & i_dma_rd) begin
				dma_word_latched <= dma_word;
				dma_longword_latched <= dma_longword;
				dma_second_word_latched <= dma_second_word;
				dma_suppress_ack_latched <= dma_longword_second_pending & dma_second_word;
				dma_longword_second_pending <= (dma_longword_second_pending & dma_second_word) ? 1'b0 :
				                               (dma_word & dma_longword & !dma_second_word);
				/* NOTE: dma_second_word_data is NOT captured here. The CPU
				 * asserts the bus cycle before DREQ gates it (DTACK holds it
				 * off), so this rising edge can land while a previous ACK
				 * train is still advancing the target — din_pair_next would
				 * be mid-update garbage (the "second word duplicates the
				 * first" corruption). It is captured at the END of the first
				 * longword cycle below, where DREQ-gated completion plus the
				 * settle window guarantee it is valid.
				 */
			end
			if(~old_dma_wr & i_dma_wr) begin
				dma_word_latched <= dma_word;
				dma_longword_latched <= dma_longword;
				dma_second_word_latched <= dma_second_word;
				dma_write_low_byte <= wdata[7:0];
				dma_wr <= 1;
			end
			if(~old_reg_wr & i_reg_wr) reg_wr <= 1;
			if (dma_ack_holdoff != 3'd0) begin
				/* Keep DREQ dropped while the target observes the ACK low edge.
				 * A 68020 longword pseudo-DMA read is two 16-bit bus cycles;
				 * only the first cycle should consume the four SCSI bytes.
				 */
				dma_ack <= dma_ack_holdoff[0];
				dma_ack_holdoff <= dma_ack_holdoff - 3'd1;
			end else if((old_dma_wr & ~i_dma_wr) |
			            (old_dma_rd & ~i_dma_rd &
			             !dma_suppress_ack_latched)) begin
				/* First cycle of a longword read is ending: capture the pair
				 * the target presents at +2/+3 as the (ACK-suppressed) second
				 * word, BEFORE the ACK train below consumes all four bytes.
				 * The cycle completed => DREQ was up => the pair is settled.
				 */
				if (old_dma_rd & ~i_dma_rd &
				    dma_longword_latched & dma_word_latched & !dma_second_word_latched)
					dma_second_word_data <= din_pair_next;
				dma_ack <= dma_en & bsr_pmatch;
				if (dma_en & bsr_pmatch)
					dma_ack_holdoff <= (old_dma_rd & ~i_dma_rd) ?
						(dma_longword_latched ? 3'd6 : (dma_word_latched ? 3'd2 : 3'd0)) :
						(dma_word_latched ? 3'd2 : 3'd0);
			end
		end
	end

	/* System bus reads */
	wire [7:0] rdata8 =
	               dack                ? cur_data         :
	               bus_rs == `RREG_CDR ? cur_data         :
	               bus_rs == `RREG_ICR ? icr_read         :
	               bus_rs == `RREG_MR  ? mr               :
	               bus_rs == `RREG_TCR ? { 4'h0, tcr }    :
	               bus_rs == `RREG_CSR ? csr              :
	               bus_rs == `RREG_BSR ? bsr              :
	               bus_rs == `RREG_IDR ? cur_data         :
	               bus_rs == `RREG_RST ? 8'h00            :
	               8'hff;
	assign rdata = (dack && dma_word) ? cur_data_pair : { rdata8, rdata8 };

	/* Data out latch (in DMA mode, this is one cycle after we've
	* asserted ACK)
	*/
	always@(posedge clk) if(reg_wr && bus_rs == `WREG_ODR) dout <= wdata[15:8];
	else if(dma_wr) dout <= wdata[15:8];

	/* Current data register. Approximate MAME's nscsi bus: reads see the
	 * wired-OR of active initiator and target data drivers.
	 */
	wire       out_en = icr[`ICR_A_DATA] | mr[`MR_ARB];
	wire [7:0] dma_write_data = (dma_ack_holdoff == 3'd1 && dma_word_latched) ? dma_write_low_byte : dout;
	wire [7:0] scsi_bus_data = (out_en ? dma_write_data : 8'h00) | din;
	wire [7:0] cur_data = scsi_bus_data;
	wire [15:0] cur_data_pair = out_en ? { dout, dout } : (dma_suppress_ack_latched ? dma_second_word_data : din_pair);

	/* ICR read wires */
	wire [7:0] icr_read = { icr[`ICR_A_RST],
	                        icr_aip,
	                        icr_la,
	                        icr[`ICR_A_ACK],
	                        icr[`ICR_A_BSY],
	                        icr[`ICR_A_SEL],
	                        icr[`ICR_A_ATN],
	                        icr[`ICR_A_DATA] };

	/* ICR write */
	always@(posedge clk or posedge reset) begin
		if (reset) begin
			icr <= 0;
		end else if (reg_wr && (bus_rs == `WREG_ICR)) begin
			icr <= wdata;
		end else if (arb_active && arb_count == 8'd0) begin
			icr[`ICR_A_BSY] <= 1'b1;
		end
	end
   
	/* MR write */
	always@(posedge clk or posedge reset) begin
		if (reset) mr <= 8'b0;
		else if (reg_wr && (bus_rs == `WREG_MR)) mr <= wdata;
	end

	/* Minimal initiator arbitration. The Mac II ROM writes MR.ARB and then
	 * polls ICR.AIP until arbitration completes. Treat a free bus as won
	 * after a short delay and assert BSY for the initiator.
	 */
	always@(posedge clk or posedge reset) begin
		if (reset) begin
			arb_active <= 1'b0;
			arb_count <= 8'd0;
		end else begin
			if (reg_wr && (bus_rs == `WREG_MR)) begin
				if (wdata[`MR_ARB] && !mr[`MR_ARB]) begin
					arb_active <= 1'b1;
					arb_count <= 8'd64;
				end else if (!wdata[`MR_ARB]) begin
					arb_active <= 1'b0;
					arb_count <= 8'd0;
				end
			end else if (arb_active) begin
				if (arb_count != 8'd0) begin
					arb_count <= arb_count - 8'd1;
				end else begin
					arb_active <= 1'b0;
				end
			end
		end
	end
   
	/* TCR write */
	always@(posedge clk or posedge reset) begin
		if (reset) tcr <= 4'b0;
		else if (reg_wr && (bus_rs == `WREG_TCR)) tcr <= wdata[3:0];
	end
   
	/* DMA start send & receive registers. We currently ignore
	* the direction.
	*/
	always@(posedge clk or posedge reset) begin
		if (reset) begin
			dma_en <= 0;
		end else begin
			if (!mr[`MR_DMA_MODE]) begin
				dma_en <= 0;
			end else if (reg_wr && (bus_rs == `WREG_DMAS)) begin
				dma_en <= 1;
			end else if (reg_wr && (bus_rs == `WREG_IDMAR)) begin
				dma_en <= 1;
			end
		end
	end

	/* Latched 5380 interrupt + DMA-armed tracking (LBMacTwo b760944 port).
	 * Starting a DMA transfer (write to Start DMA Send / Start DMA Initiator
	 * Receive) arms the phase-mismatch monitor; while MR.DMA_MODE is set and
	 * armed, a FALLING edge of phase-match latches IRQ — this is how drivers
	 * detect that a pseudo-DMA transfer ended (target moved to STATUS).
	 * Reading the RESET PARITY/INTERRUPT register (reg 7) clears it.
	 * Mirrors Snow controller.rs. Makes BSR.IRQ truthful for polled drivers;
	 * o_irq is for a future pseudo-VIA IFR bit-3 hookup (level-driven, per
	 * MAME src/devices/machine/pseudovia.cpp) if OS 7 still needs it.
	 */
	reg  irq_latch;
	reg  dma_armed;
	reg  pmatch_d;
	wire rst_rd = bus_cs & ~dack & ior & (bus_rs == `RREG_RST);
	reg  old_rst_rd;
	always @(posedge clk or posedge reset) begin
		if (reset) begin
			irq_latch  <= 1'b0;
			dma_armed  <= 1'b0;
			pmatch_d   <= 1'b1;
			old_rst_rd <= 1'b0;
		end else begin
			old_rst_rd <= rst_rd;
			pmatch_d   <= bsr_pmatch;
			// Completion-IRQ latch — fixes the System 7 "Welcome" wedge. Keep
			// dma_armed across a DMA-mode clear and latch the IRQ on the target's
			// DATA->STATUS phase-mismatch regardless of MR.DMA_MODE (the real 5380
			// latches EOP/phase-mismatch in HW). The driver often clears DMA mode
			// just before the phase change; the old MR.DMA_MODE-gated latch dropped
			// the IRQ and the HD SC 4.3 async path slept on a completion that never
			// came (ParamBlockRec.ioResult never cleared). Cleared on the latch, a
			// reg-7 read, or bus reset.
			if (reg_wr && (bus_rs == `WREG_DMAS || bus_rs == `WREG_IDMAR))
				dma_armed <= 1'b1;
			if (~old_rst_rd & rst_rd)
				irq_latch <= 1'b0;
			if (dma_armed && pmatch_d && !bsr_pmatch) begin
				irq_latch <= 1'b1;
				dma_armed <= 1'b0;
			end
			if (scsi_rst) begin
				irq_latch <= 1'b0;
				dma_armed <= 1'b0;
			end
		end
	end
	assign o_irq = irq_latch;

	/* Deferred bus-visible REQ (Snow controller.rs `set_req` semantics —
	 * LBMacTwo 2d025c5, PROVEN the System 7 Welcome-wedge exit). The SCSI
	 * Manager's between-chunk settle loop (decoded live from the System's
	 * polled TIB engine: `btst #5,CSR / beq exit / btst #3,BSR / bne loop`)
	 * exits only when a CSR read returns REQ=0. On a real 5380 + drive the
	 * per-byte handshake gives it that window; Snow instead DEFERS every
	 * REQ assertion until the next CSR read ("MacII has a race condition
	 * where it will get stuck if REQ is immediately set on a Data -> Status
	 * transition"). Mirror Snow: when bus-visible REQ rises, hide it from
	 * CSR until one full CSR read completes (that read returns REQ=0 and
	 * disarms; the next shows 1). BSR.DRQ is NOT deferred (Snow's get_drq
	 * includes the pending REQ), so DRQ-polled transfer loops and DACK
	 * pacing are unaffected.
	 */
	reg req_deferred;
	reg old_req_bus_d;
	reg old_csr_rd_d;
	always @(posedge clk or posedge reset) begin
		if (reset) begin
			req_deferred  <= 1'b0;
			old_req_bus_d <= 1'b0;
			old_csr_rd_d  <= 1'b0;
		end else begin
			old_req_bus_d <= scsi_req_bus;
			old_csr_rd_d  <= csr_rd;
			if (~old_req_bus_d & scsi_req_bus)
				req_deferred <= 1'b1;       // new REQ: hidden until a CSR read
			else if (req_deferred & old_csr_rd_d & ~csr_rd)
				req_deferred <= 1'b0;       // CSR read completed: reveal REQ
			if (!scsi_req_bus)
				req_deferred <= 1'b0;
		end
	end

	/* CSR (read only). We don't do parity */
	assign csr = { scsi_rst, scsi_bsy, scsi_req_bus & ~req_deferred, scsi_msg,
	               scsi_cd, scsi_io, scsi_sel, 1'b0 };

	/* Bus and Status register */
	/* BSR (read only). We don't do a few things... */
	/* End-of-DMA: Snow semantics — asserted whenever the bus is NOT in a
	 * data phase (free/STATUS/MESSAGE). Drivers check this after pseudo-DMA
	 * chunks. (Real chip latches the EOP pin; we have no EOP.) */
	wire bsr_eodma = ~(scsi_bsy & ~scsi_cd & ~scsi_msg);
	wire bsr_dmarq = scsi_req_bus & dma_en;
	wire bsr_perr = 1'b0;	/* We don't do parity */
	wire bsr_irq = irq_latch;
	wire bsr_pmatch = 
	         tcr[`TCR_A_MSG] == scsi_msg &&
	         tcr[`TCR_A_CD ] == scsi_cd  &&
	         tcr[`TCR_A_IO ] == scsi_io;

	wire bsr_berr = 1'b0;	/* XXX ? Does MacOS use this ? */
	wire [7:0] bsr = { bsr_eodma, bsr_dmarq, bsr_perr, bsr_irq,
	                   bsr_pmatch, bsr_berr, scsi_atn, scsi_ack };

   /* --- Simulated SCSI Signals --- */

   /* BSY logic (simplified arbitration, see notes) */
	wire scsi_bsy =
	    icr[`ICR_A_BSY] |
	    |target_bsy |
	    cd_bsy |
	    //scsi2_bsy |
	    //scsi6_bsy |
	    mr[`MR_ARB];

	/* Keep AIP visible while the ROM is requesting arbitration. */
	wire icr_aip = mr[`MR_ARB];
	wire icr_la = 0;

	/* Other ORed SCSI signals */
	wire scsi_sel = icr[`ICR_A_SEL];
	wire scsi_rst = icr[`ICR_A_RST];
	wire scsi_ack = icr[`ICR_A_ACK] | dma_ack;
	wire scsi_atn = icr[`ICR_A_ATN];

	/* Mux target signals */
	reg scsi_cd, scsi_io, scsi_msg, scsi_req;
	reg scsi_req_bus;  // bus-visible REQ (no HPS-fetch dropouts in data phases)

	always begin
		integer i;
		scsi_cd = 0;
		scsi_io = 0;
		scsi_msg = 0;
		scsi_req = 0;
		scsi_req_bus = 0;
		din = 8'h00;
		din_pair = 16'h0000;
		din_pair_next = 16'h0000;

		for (i = 0; i < DEVS; i = i + 1) begin
			if (target_bsy[i]) begin
				scsi_cd = target_cd[i];
				scsi_io = target_io[i];
				scsi_msg = target_msg[i];
				scsi_req = target_req[i];
				scsi_req_bus = target_req_bus[i];
				din = target_dout[i];
				din_pair = target_dout_pair[i];
				din_pair_next = target_dout_pair_next[i];
			end
		end

		if (cd_bsy) begin
			scsi_cd = cd_cd;
			scsi_io = cd_io;
			scsi_msg = cd_msg;
			scsi_req = cd_req;
			scsi_req_bus = cd_req_bus;
			din = cd_dout;
			din_pair = cd_dout_pair;
			din_pair_next = cd_dout_pair_next;
		end
	end

	// input signals from targets
	wire [DEVS-1:0] target_mounted;
	wire [2:0]      target_phase[DEVS];
	wire [7:0]      target_hs[DEVS];
	wire [3:0]      target_hs2[DEVS];
	wire [7:0]      target_cmd[DEVS];
	wire [31:0]     target_wrsnap[DEVS];   // JTAG debug: first-word-write capture
	wire [31:0]     target_selsnap[DEVS];  // JTAG debug: selection/command handshake
	wire [31:0]     target_wrstall[DEVS];  // JTAG debug: write-stall snapshot (PSCW)
	wire [DEVS-1:0] target_bsy;

	// Count SCSI bus resets (Mac asserting ICR.RST) -- the abort/retry signal.
	// Resets only on the global module reset, so it survives scsi_rst.
	reg [7:0] dbg_rst_count;
	reg       dbg_rst_d;
	always @(posedge clk or posedge reset) begin
		if (reset) begin
			dbg_rst_count <= 8'd0;
			dbg_rst_d     <= 1'b0;
		end else begin
			dbg_rst_d <= scsi_rst;
			if (scsi_rst && !dbg_rst_d && dbg_rst_count != 8'hFF)
				dbg_rst_count <= dbg_rst_count + 8'd1;
		end
	end
	wire [DEVS-1:0] target_msg;
	wire [DEVS-1:0] target_io;
	wire [DEVS-1:0] target_cd;
	wire [DEVS-1:0] target_req;
	wire [DEVS-1:0] target_req_bus;  // bus-visible REQ (continuity across HPS fetches)
	wire      [7:0] target_dout[DEVS];
	wire     [15:0] target_dout_pair[DEVS];
	wire     [15:0] target_dout_pair_next[DEVS];

	// BlueSCSI Toolbox per-target transport wires; only index 0 (the primary
	// ID-6 target, TOOLBOX_ENABLE) drives real values — others tie off to 0.
	wire     [31:0] tb_lba_g[DEVS];
	wire [DEVS-1:0] tb_rd_g, tb_wr_g;
	wire     [15:0] tb_buff_din_g[DEVS];
	reg      [15:0] din_pair;
	reg      [15:0] din_pair_next;

	wire cd_bsy;
	wire cd_msg;
	wire cd_io;
	wire cd_cd;
	wire cd_req;
	wire cd_req_bus;
	wire [7:0] cd_dout;
	wire [15:0] cd_dout_pair;
	wire [15:0] cd_dout_pair_next;

	// CD-ROM target (SCSI ID 3, MAME maclc.cpp attaches NSCSI_CDROM_APPLE
	// there). Same wedge-hardened scsi.v target as the disks, in CDROM mode:
	// read-only, 2048-byte logical blocks over hps_io slot VD_CDROM, AppleCD
	// command set. Supersedes the scsi_empty_cd stub (kept in scsi.v,
	// no longer instantiated). Responds to selection whenever cd_enable —
	// media-less selection returns the AppleCD no-disc sense, which is how
	// the driver's insertion poll works.
	scsi #(.ID(3'd3), .CDROM(1), .RING_LOG(CD_RING_LOG)) cdrom_target
	(
		.clk    ( clk ),
		.rst    ( scsi_rst ),
		.sys_rst( reset ),
		.cd_snd_l ( cd_snd_l ),
		.cd_snd_r ( cd_snd_r ),
		.dbg_cda0 ( dbg_cda0 ),
		.dbg_cda1 ( dbg_cda1 ),
		.sel    ( scsi_sel ),
		.cd_enable ( cd_enable ),
		// Selection requires a free bus — a wedged-BUSY device must not let a
		// second selection create two active targets sharing the broadcast ACK
		// stream (LBMacTwo corruption fix 4376c8f).
		.bus_busy ( |target_bsy ),
		.atn    ( scsi_atn ),

		.ack    ( scsi_ack ),
		.host_csr_rd ( csr_rd ),
		.host_data_rd ( i_dma_rd ),

		.bsy    ( cd_bsy  ),
		.msg    ( cd_msg  ),
		.cd     ( cd_cd   ),
		.io     ( cd_io   ),
		.req    ( cd_req  ),
		.req_bus( cd_req_bus ),
		.dout   ( cd_dout ),
		.dout_pair ( cd_dout_pair ),
		.dout_pair_next ( cd_dout_pair_next ),

		.din    ( scsi_bus_data ),

		.img_mounted( cd_img_mounted ),
		.img_blocks( img_size ),
		.io_lba ( cd_io_lba ),
		.io_rd  ( cd_io_rd ),
		.io_wr  ( cd_io_wr ),
		// io_ack/sd_buff_wr are framed by the SLOT's HPS session (cd_io_ack),
		// NOT the SCSI bus state: the CD-audio TOC/frame fetches run while the
		// target is bus-IDLE (cd_bsy=0 is the CA grant condition), so the old
		// '& cd_bsy' gates starved the blob capture of every write strobe —
		// blob RAM stayed zeros, MCDA magic never matched (HW 2026-07-17;
		// fill() provably served 4D 43 44 41). Harmless for data ops: ack
		// frames those transfers too. scsi.v's idle-phase consumers are safe
		// (sd_buff_sel held in PHASE_IDLE; rd_hps_blk cmd_read-guarded).
		.io_ack ( cd_io_ack ),

		.sd_buff_addr( sd_buff_addr ),
		.sd_buff_dout( sd_buff_dout ),
		.sd_buff_din( cd_sd_buff_din ),
		.sd_buff_wr( sd_buff_wr & cd_io_ack ),

		// No Toolbox on the CD target.
		.tb_mounted ( 1'b0 ),
		.tb_lba     ( ),
		.tb_rd      ( ),
		.tb_wr      ( ),
		.tb_ack     ( 1'b0 ),
		.tb_buff_din( ),

		.dbg_mounted( ),
		.dbg_phase( ),
		.dbg_hs( ),
		.dbg_hs2( ),
		.dbg_cmd( ),
		.dbg_dma_word( dma_word_latched ),
		.dbg_dma_long( dma_longword_latched ),
		.dbg_dma_lowbyte( dma_write_low_byte ),
		.dbg_wrsnap( ),
		.dbg_selsnap( ),
		.dbg_wrstall( )
	);

	generate
		genvar i;
		for (i = 0; i < DEVS; i = i + 1) begin : target
			// connect a target
			scsi #(.ID(3'd6 - i[2:0]), .TOOLBOX_ENABLE(i == 0)) target
			(
				.clk    ( clk ),
				.rst    ( scsi_rst ),
				.sel    ( scsi_sel ),
				.cd_enable ( 1'b0 ),   // disk target: CDROM=0, selection uses mounted
				// Free-bus selection gate (4376c8f); own bsy bit is harmless —
				// the gate is only evaluated in the target's IDLE phase.
				.bus_busy ( (|target_bsy) | cd_bsy ),
				.atn    ( scsi_atn ),

				.ack    ( scsi_ack ),
				.host_csr_rd ( csr_rd ),
				.host_data_rd ( i_dma_rd ),

				.bsy    ( target_bsy[i]  ),
				.msg    ( target_msg[i]  ),
				.cd     ( target_cd[i]   ),
				.io     ( target_io[i]   ),
				.req    ( target_req[i]  ),
				.req_bus( target_req_bus[i] ),
				.dout   ( target_dout[i] ),
				.dout_pair ( target_dout_pair[i] ),
				.dout_pair_next ( target_dout_pair_next[i] ),

				.din    ( scsi_bus_data ),

				// connection to io controller to read and write sectors
				// to sd card
				.img_mounted(img_mounted[i]),
				.img_blocks(img_size),
				.io_lba ( io_lba[i] ),
				.io_rd  ( io_rd[i] ),
				.io_wr  ( io_wr[i] ),
				.io_ack ( io_ack[i] & target_bsy[i] ),

				.sd_buff_addr( sd_buff_addr ),
				.sd_buff_dout( sd_buff_dout ),
				.sd_buff_din( sd_buff_din[i] ),
				.sd_buff_wr( sd_buff_wr & target_bsy[i] ),

				// Toolbox transport: only target 0 (ID 6) is wired to the slot.
				.tb_mounted ( (i == 0) ? tb_mounted : 1'b0 ),
				.tb_lba     ( tb_lba_g[i] ),
				.tb_rd      ( tb_rd_g[i] ),
				.tb_wr      ( tb_wr_g[i] ),
				.tb_ack     ( (i == 0) ? tb_ack : 1'b0 ),
				.tb_buff_din( tb_buff_din_g[i] ),

				.dbg_mounted( target_mounted[i] ),
				.dbg_phase( target_phase[i] ),
				.dbg_hs( target_hs[i] ),
				.dbg_hs2( target_hs2[i] ),
				.dbg_cmd( target_cmd[i] ),
				.dbg_dma_word( dma_word_latched ),
				.dbg_dma_long( dma_longword_latched ),
				.dbg_dma_lowbyte( dma_write_low_byte ),
				.dbg_wrsnap( target_wrsnap[i] ),
				.dbg_selsnap( target_selsnap[i] ),
				.dbg_wrstall( target_wrstall[i] )
			);
		end
	endgenerate

	// BlueSCSI Toolbox: surface the primary target's transport to the module port.
	assign tb_lba      = tb_lba_g[0];
	assign tb_rd       = tb_rd_g[0];
	assign tb_wr       = tb_wr_g[0];
	assign tb_buff_din = tb_buff_din_g[0];

	// JTAG debug: capture the selection/arbitration handshake state.
	//  [15]    out_en       (initiator driving the data bus?)
	//  [14]    scsi_sel     (SEL asserted)
	//  [13]    scsi_bsy     (any BSY on the bus)
	//  [12:11] target_bsy   (which target asserted BSY)
	//  [10:9]  target_mounted (per-target disk-present state)
	//  [8]     icr[ICR_A_DATA]
	//  [7:0]   scsi_bus_data (ID bits driven during selection)
	assign dbg_scsi = { out_en, scsi_sel, scsi_bsy, target_bsy[1:0],
	                    target_mounted[1:0], icr[`ICR_A_DATA],
	                    scsi_bus_data };

	// NOTE: the 2'b0 gap at [7:6] makes this a full 16 bits so the phase fields
	// land at [13:11]/[10:8] as the header comment (and the probe decode)
	// expect. Without it the 14-bit concat right-justified and shifted the
	// phases down 2 bits, garbling the decode (lbmactwo's "phase 6/7 red
	// herring", fixed there 2026-06-10 — same latent bug existed here).
	assign dbg_scsi2 = { 2'b0, target_phase[1], target_phase[0],
	                     2'b0, io_rd[1:0], io_wr[1:0], io_ack[1:0] };

	assign dbg_scsi3 = { target_hs[1], target_hs[0] };

	assign dbg_scsi4 = { dbg_rst_count, target_hs2[1], target_hs2[0] };

	assign dbg_scsi5 = { target_cmd[1], target_cmd[0] };

	// ---- JTAG probe feeds (PSNC / PSWL / PSCW) — synthesizable, mirror
	// ---- lbmactwo's dbg_min decode layouts exactly. ----------------------
	// dma_wr_count: rising edges of i_dma_wr OR i_dma_rd — pseudo-DMA beats
	// in BOTH directions. Frozen while dreq=1 during a wedge = "DREQ ignored".
	reg [13:0] dma_wr_count;
	always @(posedge clk) begin
		if (reset) dma_wr_count <= 14'd0;
		else if ((~old_dma_wr & i_dma_wr) | (~old_dma_rd & i_dma_rd))
			dma_wr_count <= dma_wr_count + 14'd1;
	end
	assign dbg_ncr = { dma_wr_count, tcr[3:0], dma_longword_second_pending,
	                   dma_longword_latched, dma_word_latched, bsr_pmatch,
	                   mr[`MR_DMA_MODE], dma_ack_holdoff, dma_ack_busy, dma_ack,
	                   dma_en, scsi_ack, scsi_req, dreq };

	// blind_wr_count: host pseudo-DMA writes while DREQ=0 (blind writes);
	// req_drop_count: REQ 1->0 edges while dma_en (HPS-flush REQ pauses).
	reg [15:0] blind_wr_count;
	reg [15:0] req_drop_count;
	reg        old_scsi_req_dbg;
	always @(posedge clk) begin
		if (reset) begin
			blind_wr_count   <= 16'd0;
			req_drop_count   <= 16'd0;
			old_scsi_req_dbg <= 1'b0;
		end else begin
			old_scsi_req_dbg <= scsi_req;
			if (~old_dma_wr & i_dma_wr & ~dreq & (blind_wr_count != 16'hFFFF))
				blind_wr_count <= blind_wr_count + 16'd1;
			if (old_scsi_req_dbg & ~scsi_req & dma_en & (req_drop_count != 16'hFFFF))
				req_drop_count <= req_drop_count + 16'd1;
		end
	end
	assign dbg_ncr2 = { req_drop_count,
	                    req_deferred, scsi_req_bus, irq_latch, dma_armed,
	                    bsr_eodma, dreq, bsr_pmatch, dma_en,
	                    blind_wr_count[7:0] };

	// PSCW mux: route whichever target is in the WRITE data phase
	// (PHASE_DATA_IN=3); defaults to target 1 (the OSD-mounted disk usually
	// lands on t1, so the idle snapshot is the real disk).
	reg [31:0] dbg_wr_mux;
	always begin : pscw_mux
		integer j;
		dbg_wr_mux = target_wrstall[DEVS-1];
		// Route whichever target is in a DATA phase — WRITE (PHASE_DATA_IN=3) or
		// READ (PHASE_DATA_OUT=2). The read case was added for the pseudo-DMA
		// stall snapshot (PSDS/PSD3) so data_cnt/io_busy/phase are valid during a
		// READ stall, not just a write.
		for (j = 0; j < DEVS; j = j + 1)
			if (target_phase[j] == 3'd3 || target_phase[j] == 3'd2) dbg_wr_mux = target_wrstall[j];
	end
	assign dbg_wr = dbg_wr_mux;

	// NOTE: lbmactwo's JTAG In-System Source/Probe (altsource_probe) blocks for
	// target_wrsnap/target_selsnap were removed in the MacLC port — this core has
	// no Quartus ISSP infrastructure and does not depend on the Altera primitive.
	// The dbg_* module outputs are still driven (left unconnected upstream); the
	// per-target wrsnap/selsnap snapshot wires are simply unused here.

`ifdef SIMULATION
	// Host-side stall watchdog: when a target holds REQ but the host stops
	// ACKing for a long time, dump the pseudo-DMA state so we can see whether
	// the host is starved of DREQ (dma_en cleared, holdoff stuck, pmatch lost).
	reg [31:0] hstall;
	reg        old_scsi_ack_w;
	always @(posedge clk) begin
		old_scsi_ack_w <= scsi_ack;
		if (scsi_req && !scsi_ack) begin
			hstall <= hstall + 1'd1;
			if (hstall == 32'd320000 && $test$plusargs("scsi_stall_debug"))
				$display("NCR_STALL req=%b ack=%b dreq=%b dma_en=%b dma_ack=%b ack_busy=%b holdoff=%0d mr_dma=%b icr=%02h tcr=%01h pmatch=%b io=%b cd=%b msg=%b",
				         scsi_req, scsi_ack, dreq, dma_en, dma_ack, dma_ack_busy, dma_ack_holdoff,
				         mr[`MR_DMA_MODE], icr, tcr, bsr_pmatch, scsi_io, scsi_cd, scsi_msg);
		end else
			hstall <= 0;
	end

	// Byte-slip post-hoc detector (2026-06-10 +1-insertion forensics): the
	// host pushing a pseudo-DMA WRITE while the bus phase no longer matches
	// TCR means the target completed its data phase EARLY relative to the
	// host's byte count — i.e. somewhere in the burst the target consumed a
	// phantom byte. The target-side overrun check can miss this case because
	// dma_ack is suppressed once pmatch drops; this one cannot.
	reg old_dma_wr_slip;
	always @(posedge clk) begin
		old_dma_wr_slip <= i_dma_wr;
		if (~old_dma_wr_slip & i_dma_wr & dma_en & ~bsr_pmatch)
			$display("NCR_WR_PHASE_MISMATCH: pseudo-DMA write w/ phase mismatch (leftover host bytes - insertion upstream?) wdata=%04x tcr=%01h io=%b cd=%b msg=%b",
			         wdata, tcr, scsi_io, scsi_cd, scsi_msg);
	end

	// Recovery-poke detector (Snow-derived hypothesis, 2026-06-10): our REQ
	// drops bus-visibly for the whole ~ms HPS fetch/flush at every 512-byte
	// boundary (and io_busy even carries into the NEXT command's CMD phase).
	// Real drives/Snow pre-buffer, so the System 7 driver's between-chunk
	// PIO poll always sees a live bus; on a dead-looking bus it may bail
	// into a recovery path that pokes registers manually. A manual ICR ACK
	// pulse while MR.DMA_MODE is set would inject exactly ONE phantom byte
	// into the target's stream = the forensic +1 insertion. This catches it.
	reg old_icr_ack_dbg;
	always @(posedge clk) begin
		old_icr_ack_dbg <= icr[`ICR_A_ACK];
		if (~old_icr_ack_dbg & icr[`ICR_A_ACK] & mr[`MR_DMA_MODE])
			$display("NCR_MANUAL_ACK_IN_DMA: ICR ACK poke while DMA mode (driver recovery path?) odr=%02x tcr=%01h req=%b dreq=%b dma_en=%b",
			         dout, tcr, scsi_req, dreq, dma_en);
	end
`endif

endmodule
