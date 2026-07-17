// JTAG In-System probes for MacLC — ported from the LBMacTwo dbg_min.sv
// methodology (same instance IDs and layouts wherever a probe has an
// LBMacTwo twin, so the decode knowledge and reader tooling carry over).
//
// Read with:  bash scripts/read_probes.sh          (all probes, decoded)
//             quartus_stp_tcl -t scripts/sample_loop.tcl 120   (loop sampler)
//
// FPGA-ONLY: this module is instantiated from MacLC.sv (never sim.v), so
// the altsource_probe Altera primitive never reaches Verilator. Keep it
// that way — do NOT add it to the simulator top.
//
// Probe deck (14 instances here + PSDT/PSDS/PSD2/PSD3 in MacLC.sv = 18 hub
// nodes, back under LBMacTwo's ~20-node hub ceiling — the ~40-node deck's
// name table read back corrupted; keep it lean):
//
//   PADR  cpuAddr snapshot              PSTA  bus/decoder/IRQ state
//   PACT  bus-cycle counter             PIFA  last instruction-fetch addr
//   PIFD  live {IF addr16, opcode16}    PDRD  live {I/O rd addr field, data}
//   PSCS  last SCSI reg read + value    PSC2  selection-transaction snapshot
//   PSC3  phases/max-phase/io+sd acks   PSCW  write-stall snapshot
//   PSNC  pseudo-DMA engine state       PSWL  IRQ/deferral machine state
//   PSC6  {rst/completion, last opcodes}
//   PVID  video mode/vbl/CLUT/VRAM activity
//
// (2026-07-16 trim for the cd-audio fit: PEXC/PEX2/PEX3, PFR0-3, PRC0/PRT1-3
// and PBL0-6/PBH0 removed — closed/parked missions; recover from git history.)
module dbg_probes (
    input wire        clk,

    // CPU bus
    input wire [23:0] cpuAddr,
    input wire [2:0]  cpuFC,
    input wire        cpuAS_n,
    input wire        cpuRW,
    input wire        cpuDTACK_n,
    input wire        cpuVPA_n,
    input wire        cpuUDS_n,
    input wire        cpuLDS_n,
    input wire [2:0]  cpuIPL_n,
    input wire [15:0] cpu_din,        // muxed CPU read data (dataControllerDataOut)

    // address decoder selects
    input wire        selectSCSI,
    input wire        selectSCSIDMA,
    input wire        selectRAM,
    input wire        selectROM,
    input wire        selectVRAM,
    input wire        selectVIA,
    input wire        selectPseudoVIA,
    input wire        selectASC,
    input wire        selectAriel,
    input wire        selectIWM,
    input wire        selectSCC,

    // SCSI
    input wire        scsiDREQ,
    input wire        scsiIRQ,
    input wire [15:0] scsi_dbg,       // selection: out_en/SEL/BSY/bsy/mounted/data
    input wire [15:0] scsi_dbg2,      // phases + io handshake
    input wire [15:0] scsi_dbg4,      // bus-reset count + completion flags
    input wire [15:0] scsi_dbg5,      // last opcodes
    input wire [31:0] scsi_dbg_ncr,   // pseudo-DMA engine
    input wire [31:0] scsi_dbg_ncr2,  // IRQ/deferral machine
    input wire [31:0] scsi_dbg_wr,    // write-stall snapshot
    input wire [1:0]  img_mounted,
    input wire [1:0]  sd_rd,
    input wire [1:0]  sd_wr,
    input wire [1:0]  sd_ack,

    // video (V8 / Ariel)
    input wire [7:0]  pvia_video_config,
    input wire        v8_vblank
);

    // ---- PADR / PSTA / PACT: where is the CPU, what bus state, is it alive

    reg cpuAS_n_d;
    always @(posedge clk) cpuAS_n_d <= cpuAS_n;

    reg [31:0] padr_r;
    always @(posedge clk) padr_r <= {8'd0, cpuAddr};

    // PSTA layout:
    //   [24]=AS_n [23:21]=IPL_n [20]=scsiIRQ [19]=scsiDREQ [18]=selSCSIDMA
    //   [17]=selSCSI [16]=selVRAM [15]=selROM [14]=selRAM [13]=selASC
    //   [12]=selAriel [11]=selPseudoVIA [10]=selVIA [9]=selIWM [8]=selSCC
    //   [7]=VPA_n [6]=DTACK_n [5]=LDS_n [4]=UDS_n [3]=RW [2:0]=FC
    reg [31:0] psta_r;
    always @(posedge clk)
        psta_r <= {7'd0, cpuAS_n, cpuIPL_n, scsiIRQ, scsiDREQ,
                   selectSCSIDMA, selectSCSI, selectVRAM, selectROM, selectRAM,
                   selectASC, selectAriel, selectPseudoVIA, selectVIA,
                   selectIWM, selectSCC,
                   cpuVPA_n, cpuDTACK_n, cpuLDS_n, cpuUDS_n, cpuRW, cpuFC};

    reg [31:0] as_cycles;
    always @(posedge clk)
        if (cpuAS_n_d && !cpuAS_n) as_cycles <= as_cycles + 32'd1;

    altsource_probe #(
        .instance_id ("PADR"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_padr (.probe(padr_r), .source(), .source_clk(clk), .source_ena(1'b1));

    altsource_probe #(
        .instance_id ("PSTA"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_psta (.probe(psta_r), .source(), .source_clk(clk), .source_ena(1'b1));

    altsource_probe #(
        .instance_id ("PACT"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_pact (.probe(as_cycles), .source(), .source_clk(clk), .source_ena(1'b1));

    // ---- PIFA / PIFD: instruction-fetch sampler (the remote disassembler)
    // PIFA captures cpuAddr ONLY at real instruction-fetch cycles (AS falling
    // edge, read, FC in {2,6}); repeated JTAG samples of a stable wedge loop
    // histogram its PCs. PIFA[31:24] = wrap8 IF count (frozen = CPU wedged in
    // a zero-fetch state; advancing = loop alive).
    wire if_cycle = cpuAS_n_d && !cpuAS_n && cpuRW &&
                    (cpuFC == 3'b010 || cpuFC == 3'b110);
    reg [7:0]  if_cnt;
    reg [23:0] if_addr;
    always @(posedge clk)
        if (if_cycle) begin
            if_addr <= cpuAddr;
            if_cnt  <= if_cnt + 8'd1;
        end
    reg [31:0] pifa_r;
    always @(posedge clk) pifa_r <= {if_cnt, if_addr};

    // PIFD: live atomic {IF addr[15:0], fetched data[15:0]} pair, committed
    // at the END of the fetch bus cycle (AS rising edge), when the muxed
    // read data is valid and held. Repeated samples + scripts/loop_disasm.py
    // reconstruct RAM code we cannot otherwise read (the lbmactwo technique
    // that decoded the System 7 TIB settle loop).
    reg        ifd_wait;
    reg [15:0] ifd_addr;
    reg [31:0] pifd_pair;
    always @(posedge clk) begin
        if (if_cycle) begin
            ifd_wait <= 1'b1;
            ifd_addr <= cpuAddr[15:0];
        end else if (ifd_wait && !cpuAS_n_d && cpuAS_n) begin // AS rose: cycle done
            pifd_pair <= {ifd_addr, cpu_din};
            ifd_wait  <= 1'b0;
        end
    end
    reg [31:0] pifd_r;
    always @(posedge clk) pifd_r <= pifd_pair;

    altsource_probe #(
        .instance_id ("PIFA"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_pifa (.probe(pifa_r), .source(), .source_clk(clk), .source_ena(1'b1));

    altsource_probe #(
        .instance_id ("PIFD"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_pifd (.probe(pifd_r), .source(), .source_clk(clk), .source_ena(1'b1));

    // (PEXC/PEX2/PEX3 exception latches, PFR0-3 restart flight recorder and
    // PRC0/PRT1-3 reboot-isolation trail removed 2026-07-16 — the Sad-Mac
    // 0F/0003 and warm-boot classes are fixed and #3 is root-caused (SCSI
    // CSR read robustness); PBER/PBEA went earlier (2026-06-14) after
    // proving #3 is not a bus error. Recover any from git history.)

    // ---- PDRD: live atomic {I/O-read addr field, data} ---------------------
    // Same end-of-cycle commit for DATA-space reads in the $F00000 I/O region.
    // Answers "what is the wait loop polling and what does it see" directly.
    // addr field = cpuAddr[19:4]; full offset within $F00000 = field<<4:
    //   0x0xxx=VIA1  0x4xxx=SCC  0x6xxx=SCSI DACK  0x1000x=SCSI reg(x)
    //   0x12xxx=SCSI DACK  0x14xxx=ASC  0x16xxx=IWM  0x24xxx=Ariel
    //   0x26xxx=PseudoVIA (scripts/loop_disasm.py decodes this).
    wire io_rd_cycle = cpuAS_n_d && !cpuAS_n && cpuRW &&
                       (cpuFC == 3'b001 || cpuFC == 3'b101) &&
                       (cpuAddr[23:21] == 3'b111);
    reg        drd_wait;
    reg [15:0] drd_addr;
    reg [31:0] pdrd_pair;
    always @(posedge clk) begin
        if (io_rd_cycle) begin
            drd_wait <= 1'b1;
            drd_addr <= cpuAddr[19:4];
        end else if (drd_wait && !cpuAS_n_d && cpuAS_n) begin
            pdrd_pair <= {drd_addr, cpu_din};
            drd_wait  <= 1'b0;
        end
    end
    reg [31:0] pdrd_r;
    always @(posedge clk) pdrd_r <= pdrd_pair;

    altsource_probe #(
        .instance_id ("PDRD"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_pdrd (.probe(pdrd_r), .source(), .source_clk(clk), .source_ena(1'b1));

    // ---- PSCS: last SCSI register read + value (the poll target) ----------
    // {sdwr_seen[1:0], sdrd_seen[1:0], img_seen[1:0], 3'b0, last_reg[6:0],
    //  last_value[15:0]}  — last_reg = cpuAddr[6:0]; SCSI regs decode on
    // A6-A4, so reg# = last_reg[6:4].
    reg [15:0] scsi_last_rd;
    reg [6:0]  scsi_last_reg;
    reg [1:0]  img_seen, sdrd_seen, sdwr_seen;
    always @(posedge clk) begin
        if (selectSCSI && cpuRW && !cpuAS_n) begin
            scsi_last_rd  <= cpu_din;
            scsi_last_reg <= cpuAddr[6:0];
        end
        img_seen  <= img_seen  | img_mounted;
        sdrd_seen <= sdrd_seen | sd_rd;
        sdwr_seen <= sdwr_seen | sd_wr;
    end
    reg [31:0] pscs_r;
    always @(posedge clk)
        pscs_r <= {sdwr_seen, sdrd_seen, img_seen, 3'b0, scsi_last_reg, scsi_last_rd};

    altsource_probe #(
        .instance_id ("PSCS"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_pscs (.probe(pscs_r), .source(), .source_clk(clk), .source_ena(1'b1));

    // ---- PSC2: selection transaction visibility ---------------------------
    // scsi_dbg layout (ncr5380.sv): [15]=out_en [14]=SEL [13]=BSY
    // [12:11]=target_bsy [10:9]=target_MOUNTED [8]=ICR.A_DATA
    // [7:0]=scsi_bus_data (the ID bits driven during selection).
    // PSC2 = {at_sel_data[7:0], dbg_at_sel[15:8], dbg_scsi_live[15:0]}:
    //   [31:24] data byte on the bus at the LAST SEL assertion — the ID
    //           bits the targets actually saw (din[ID] match evidence)
    //   [23:16] upper byte of scsi_dbg latched at the last SEL assertion
    //           (out_en/BSY/target_bsy/MOUNTED at the selection moment)
    //   [15:0]  live scsi_dbg
    // Directly answers "is the target mounted and does it see its ID" for
    // the deaf-disk-after-reset state.
    reg [7:0] at_sel_data = 8'h00;
    reg [7:0] dbg_at_sel  = 8'h00;
    always @(posedge clk)
        if (scsi_dbg[14]) begin       // SEL asserted
            at_sel_data <= scsi_dbg[7:0];
            dbg_at_sel  <= scsi_dbg[15:8];
        end
    reg [31:0] psc2_r;
    always @(posedge clk) psc2_r <= {at_sel_data, dbg_at_sel, scsi_dbg};

    altsource_probe #(
        .instance_id ("PSC2"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_psc2 (.probe(psc2_r), .source(), .source_clk(clk), .source_ena(1'b1));

    // ---- PSC3: target phases + max-phase + io/sd handshake ----------------
    // LBMacTwo layout with the spare top nibble carrying the bus-reset count:
    //   [31:28]=rst_count[3:0] [23:21]=ph1 [20:18]=ph0 [17:16]=sd_ack_seen
    //   [15:14]=io_ack_seen [12:10]=max_ph1 [8:6]=max_ph0 [5:0]=live io_rd/wr/ack
    // phases: 0 IDLE,1 CMD_IN,2 DATA_OUT(rd),3 DATA_IN(wr),4 STATUS,5 MSG
    wire [2:0] ph0 = scsi_dbg2[10:8];
    wire [2:0] ph1 = scsi_dbg2[13:11];
    reg [2:0] max_ph0, max_ph1;
    reg [1:0] io_ack_seen, sd_ack_seen;
    always @(posedge clk) begin
        if (ph0 > max_ph0) max_ph0 <= ph0;
        if (ph1 > max_ph1) max_ph1 <= ph1;
        io_ack_seen <= io_ack_seen | scsi_dbg2[1:0];
        sd_ack_seen <= sd_ack_seen | sd_ack;
    end
    reg [31:0] psc3_r;
    always @(posedge clk)
        psc3_r <= {scsi_dbg4[11:8], 4'd0, ph1, ph0, sd_ack_seen, io_ack_seen,
                   1'b0, max_ph1, 1'b0, max_ph0, scsi_dbg2[5:0]};

    altsource_probe #(
        .instance_id ("PSC3"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_psc3 (.probe(psc3_r), .source(), .source_clk(clk), .source_ena(1'b1));

    // ---- PSCW / PSNC / PSWL: live SCSI engine snapshots (layouts in
    // ---- ncr5380.sv port comments; identical to lbmactwo) -----------------
    reg [31:0] pscw_r, psnc_r, pswl_r;
    always @(posedge clk) begin
        pscw_r <= scsi_dbg_wr;
        psnc_r <= scsi_dbg_ncr;
        pswl_r <= scsi_dbg_ncr2;
    end

    altsource_probe #(
        .instance_id ("PSCW"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_pscw (.probe(pscw_r), .source(), .source_clk(clk), .source_ena(1'b1));

    altsource_probe #(
        .instance_id ("PSNC"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_psnc (.probe(psnc_r), .source(), .source_clk(clk), .source_ena(1'b1));

    altsource_probe #(
        .instance_id ("PSWL"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_pswl (.probe(pswl_r), .source(), .source_clk(clk), .source_ena(1'b1));

    // ---- PSC6: {bus-reset count + completion flags, last opcodes} ---------
    //   [31:24]=rst_count [23:20]=t1 hs2 [19:16]=t0 hs2
    //   [15:8]=t1 last opcode [7:0]=t0 last opcode
    reg [31:0] psc6_r;
    always @(posedge clk) psc6_r <= {scsi_dbg4, scsi_dbg5};

    altsource_probe #(
        .instance_id ("PSC6"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_psc6 (.probe(psc6_r), .source(), .source_clk(clk), .source_ena(1'b1));

    // (PASC/PAUD audio probes removed — re-add from git history if the sound
    // path needs JTAG visibility again.)

    // ---- PVID: video liveness — {vbl_cnt, clut_wr_cnt, vram_wr_cnt, config}
    //   [31:24] vblank count (wrap8)      — frozen = video timing dead
    //   [23:16] Ariel CLUT write count    — is the OS loading the palette?
    //   [15:8]  CPU VRAM write count      — is the Mac drawing?
    //   [7:0]   pseudo-VIA video config   — programmed mode (depth etc.)
    reg vbl_d;
    reg [7:0] vbl_cnt, clut_wr_cnt, vram_wr_cnt;
    always @(posedge clk) begin
        vbl_d <= v8_vblank;
        if (v8_vblank && !vbl_d) vbl_cnt <= vbl_cnt + 8'd1;
        if (cpuAS_n_d && !cpuAS_n && selectAriel && !cpuRW)
            clut_wr_cnt <= clut_wr_cnt + 8'd1;
        if (cpuAS_n_d && !cpuAS_n && selectVRAM && !cpuRW)
            vram_wr_cnt <= vram_wr_cnt + 8'd1;
    end
    reg [31:0] pvid_r;
    always @(posedge clk) pvid_r <= {vbl_cnt, clut_wr_cnt, vram_wr_cnt, pvia_video_config};

    altsource_probe #(
        .instance_id ("PVID"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_pvid (.probe(pvid_r), .source(), .source_clk(clk), .source_ena(1'b1));

    // (PBL0-6 bus-latency meter and PBH0 latency-histogram bank removed
    // 2026-07-16 — the tick-rate mission is closed and the QuickDraw/icache
    // hunt is parked with its own probe-bearing builds. scripts/buslat.tcl
    // and scripts/bushist.tcl only work against those older RBFs.)

endmodule
