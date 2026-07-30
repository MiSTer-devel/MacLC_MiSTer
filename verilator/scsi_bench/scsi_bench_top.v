// scsi_bench_top.v — focused Verilator harness around rtl/ncr5380.sv +
// rtl/scsi.v (the complete LC-family word/longword SCSI pseudo-DMA read
// datapath). There is no CPU and no dataController here: the C++ driver
// (scsi_bench.cpp) plays BOTH the Mac SCSI Manager (register PIO + blind
// DACK reads, paced like the DTACK-gated TG68 bus) and the MiSTer HPS
// block device (io_rd/io_ack + sd_buff streaming).
//
// White-box taps use plain hierarchical references into the ncr5380 top
// scope (no generate-scope paths — target-side state comes out through the
// existing dbg_wr port, whose PSCW mux routes whichever target is in a
// DATA phase).

module scsi_bench_top
(
	input         clk,
	input         reset,

	// ---- host bus (C++ "CPU") ----
	input         bus_cs,
	input   [2:0] bus_rs,
	input         ior,
	input         iow,
	input         dack,
	input         dma_word,
	input         dma_longword,
	input         dma_second_word,
	output        dreq,
	output        o_irq,
	input  [15:0] wdata,
	output [15:0] rdata,

	// ---- io controller (C++ HPS model) ----
	input   [1:0] img_mounted,
	input  [31:0] img_size,
	output [31:0] io_lba_0,
	output [31:0] io_lba_1,
	output  [1:0] io_rd,
	output  [1:0] io_wr,
	input   [1:0] io_ack,
	input   [7:0] sd_buff_addr,
	input  [15:0] sd_buff_dout,
	input         sd_buff_wr,
	output [15:0] sd_buff_din_0,
	output [15:0] sd_buff_din_1,

	// ---- observability ----
	output [31:0] dbg_ncr,    // host-side pseudo-DMA state (see ncr5380.sv)
	output [31:0] dbg_ncr2,   // IRQ/deferral machine + counters
	output [31:0] dbg_wr,     // DATA-phase target: data_cnt/phase/io_busy/...
	// white-box latch-stack taps (ncr5380 top scope)
	output [15:0] tap_din_pair,
	output [15:0] tap_din_pair_next,
	output [15:0] tap_second_word_data,
	output        tap_suppress_ack,
	output        tap_second_pending,
	output  [2:0] tap_holdoff,
	output        tap_dma_ack,
	output        tap_scsi_req,
	output        tap_dma_en
);

wire [31:0] io_lba[2];
wire [15:0] sd_buff_din[2];
assign io_lba_0 = io_lba[0];
assign io_lba_1 = io_lba[1];
assign sd_buff_din_0 = sd_buff_din[0];
assign sd_buff_din_1 = sd_buff_din[1];

ncr5380 #(.DEVS(2)) ncr
(
	.clk(clk),
	.reset(reset),
	.cd_enable(1'b1),      // CD target (ID 3) selectable — cdvol mode pokes it
	.bus_cs(bus_cs),
	.bus_rs(bus_rs),
	.ior(ior),
	.iow(iow),
	.dack(dack),
	.dma_word(dma_word),
	.dma_longword(dma_longword),
	.dma_second_word(dma_second_word),
	.dreq(dreq),
	.o_irq(o_irq),
	.wdata(wdata),
	.rdata(rdata),

	.img_mounted(img_mounted),
	.img_size(img_size),
	.io_lba(io_lba),
	.io_rd(io_rd),
	.io_wr(io_wr),
	.io_ack(io_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr),

	.dbg_scsi(),
	.dbg_scsi2(),
	.dbg_scsi3(),
	.dbg_scsi4(),
	.dbg_scsi5(),
	.dbg_ncr(dbg_ncr),
	.dbg_ncr2(dbg_ncr2),
	.dbg_wr(dbg_wr)
);

assign tap_din_pair         = ncr.din_pair;
assign tap_din_pair_next    = ncr.din_pair_next;
assign tap_second_word_data = ncr.dma_second_word_data;
assign tap_suppress_ack     = ncr.dma_suppress_ack_latched;
assign tap_second_pending   = ncr.dma_longword_second_pending;
assign tap_holdoff          = ncr.dma_ack_holdoff;
assign tap_dma_ack          = ncr.dma_ack;
assign tap_scsi_req         = ncr.scsi_req;
assign tap_dma_en           = ncr.dma_en;

endmodule
