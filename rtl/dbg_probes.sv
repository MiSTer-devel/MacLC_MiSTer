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
// Probe deck (15 instances; LBMacTwo's JTAG hub ceiling was ~20 on a much
// fuller device — headroom is fine, but if a future fit fails trim PASC/
// PAUD/PVID first):
//
//   PADR  cpuAddr snapshot              PSTA  bus/decoder/IRQ state
//   PACT  bus-cycle counter             PIFA  last instruction-fetch addr
//   PIFD  live {IF addr16, opcode16}    PDRD  live {I/O rd addr field, data}
//   PSCS  last SCSI reg read + value    PSC3  phases/max-phase/io+sd acks
//   PSCW  write-stall snapshot          PSNC  pseudo-DMA engine state
//   PSWL  IRQ/deferral machine state    PSC6  {rst/completion, last opcodes}
//   PASC  ASC irq vs CPU-write cadence  PAUD  audio sample min/max
//   PVID  video mode/vbl/CLUT/VRAM activity
//   PBL0-6  CPU bus-latency meter (fetch/data/VPA split) — scripts/buslat.tcl
module dbg_probes (
    input wire        clk,

    // CPU bus
    input wire [23:0] cpuAddr,
    input wire [7:0]  cpuAddrHi,   // cpuAddr[31:24] — 32-bit qualifier
    input wire        cpuReset_n,    // system/Egret-driven CPU reset (active low)
    input wire        resetInstr_n,  // 68k RESET-instruction output (active low)
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

    // sound (ASC)
    input wire        asc_irq,
    input wire signed [15:0] asc_sample_l,

    // video (V8 / Ariel)
    input wire [7:0]  pvia_video_config,
    input wire        v8_vblank,

    // BERR investigation (#3 cold-boot reboot loop): the real hardware
    // bus-error signals (NOT the $8-vector-read inference PEXC/PFR use, which
    // false-alarms on routine supervisor reads).
    input wire        cpu_berr,    // asserted BERR to the CPU (fc7_berr | sdma_berr)
    input wire        fc7_berr,    // FC=7 CPU-space probe BERR (already gated by !AS)
    input wire        sdma_berr,   // SCSI pseudo-DMA watchdog BERR (the suspected #3 killer)

    // #3 ROM re-init detector
    input wire        memoryOverlayOn  // ROM overlay active (1 = ROM mapped at $0)
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

    // ---- PEXC / PEX2 / PEX3: exception-vector latches ----------------------
    // vec_fetch fires on a supervisor read of the low vector table
    // ($000008-$000024: buserr=2, addrerr=3, ILLEGAL=4, div0=5, CHK=6,
    // TRAPV=7, priv=8, trace=9). Line-A ($28) and line-F ($2C) are EXCLUDED:
    // the Mac OS dispatches every system call through line-A, which would
    // overwrite the interesting fatal vector thousands of times a second.
    // The vector read happens while if_addr still holds the faulting
    // instruction's fetch address.
    //   PEXC (rolling, last fatal) = {if_addr[23:0], vec#[3:0], cnt wrap4}
    //   PEX2 (STICKY, first ILLEGAL vec 4) = pifd_pair at the fault =
    //        {fetch addr16, OPCODE16} of the last completed fetch
    //   PEX3 (STICKY, first ILLEGAL) = {if_addr[23:0], illegal_cnt[7:0]}
    // Note: the boot ROM's hardware probes take INTENTIONAL bus errors and
    // a soft restart re-runs them — hence rolling for PEXC but sticky
    // first-ILLEGAL for PEX2/PEX3 (the Sad Mac 0F/0003 class).
    // cpuAddrHi == 0 qualifier: without it, 32-bit device probes (e.g. the
    // ROM's $FE000010 PDS slot read) alias into the low vector window on the
    // 24-bit cpuAddr slice and fire false "exceptions".
    wire vec_fetch = cpuAS_n_d && !cpuAS_n && cpuRW &&
                     cpuFC[2] && (cpuFC[1:0] != 2'b11) &&
                     (cpuAddrHi == 8'd0) &&
                     (cpuAddr[23:6] == 18'd0) &&
                     (cpuAddr[5:0] >= 6'h08) && (cpuAddr[5:0] <= 6'h24);
    wire illegal_fetch = vec_fetch && (cpuAddr[5:2] == 4'd4);
    reg [3:0]  vec_cnt     = 4'd0;
    reg [7:0]  illegal_cnt = 8'd0;
    reg        illegal_seen = 1'b0;
    reg [31:0] pexc_r = 32'd0;
    reg [31:0] pex2_r = 32'd0;
    reg [31:0] pex3_r = 32'd0;
    always @(posedge clk) begin
        if (vec_fetch) begin
            pexc_r  <= {if_addr, cpuAddr[5:2], vec_cnt + 4'd1};
            vec_cnt <= vec_cnt + 4'd1;
        end
        if (illegal_fetch) begin
            if (illegal_cnt != 8'hFF) illegal_cnt <= illegal_cnt + 8'd1;
            if (!illegal_seen) begin
                illegal_seen <= 1'b1;
                pex2_r <= pifd_pair;
                pex3_r <= {if_addr, 8'd1};
            end else
                pex3_r[7:0] <= illegal_cnt + 8'd1;
        end
    end

    altsource_probe #(
        .instance_id ("PEXC"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_pexc (.probe(pexc_r), .source(), .source_clk(clk), .source_ena(1'b1));

    altsource_probe #(
        .instance_id ("PEX2"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_pex2 (.probe(pex2_r), .source(), .source_clk(clk), .source_ena(1'b1));

    altsource_probe #(
        .instance_id ("PEX3"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_pex3 (.probe(pex3_r), .source(), .source_clk(clk), .source_ena(1'b1));

    // ---- PFR0-3: restart flight recorder, rev 2 ------------------------------
    // Findings from rev 1: the mid-boot restart asserts NO reset line and does
    // NOT execute RESET — it is a software transfer into ROM init. Leading
    // theory: a deterministic SCSI bus error near dack=14592 is "handled" by
    // the OS, but TG68's bus-fault frame is malformed, so the handler's RTE
    // lands at garbage (ROM init). This rev captures exactly that:
    //   * arms only after 4096 instruction fetches (rev-1 froze on the
    //     core-load reset with an empty trail)
    //   * cause 1/2 (reset-line falls) kept, gated by armed
    //   * cause 4: BUS-ERROR vector fetch while dack_beats > 14000 — the
    //     death-adjacent bus error. Freezes the pre-trail {pc0=faulting IF,
    //     pc1=previous IF}, then waits for the handler's RTE opcode ($4E73)
    //     and captures the 2 fetch addresses that follow = WHERE RTE LANDED.
    // Readout: PFR0={0,frozen,cause,pre_pc0} PFR1={rst_falls,instr_falls,pre_pc1}
    //          PFR2={0,rte_caught,rte_pc0} PFR3={berr_trig_count,rte_pc1}
    reg [23:0] fr_pc0 = 24'd0, fr_pc1 = 24'd0;
    reg [23:0] fr_rte_pc0 = 24'd0, fr_rte_pc1 = 24'd0;
    reg        fr_frozen = 1'b0;
    reg [2:0]  fr_cause  = 3'd0;
    reg [1:0]  fr_post   = 2'd0;   // 0=pre, 1=waiting RTE, 2=capture rte_pc0, 3=done
    reg        fr_rte_caught = 1'b0;
    reg [3:0]  fr_rst_falls = 4'd0, fr_instr_falls = 4'd0;
    reg [7:0]  fr_berr_trigs = 8'd0;
    reg [11:0] fr_arm_cnt = 12'd0;
    wire       fr_armed = (fr_arm_cnt == 12'hFFF);
    reg        cpuReset_n_d = 1'b1, resetInstr_n_d = 1'b1;
    reg [31:0] pifd_d = 32'd0;
    wire [13:0] fr_dack = scsi_dbg_ncr[31:18];
    wire fr_berr_vec  = vec_fetch && (cpuAddr[5:2] == 4'd2);   // bus-error vector read
    wire fr_berr_trig = fr_berr_vec && (fr_dack > 14'd14000);
    always @(posedge clk) begin
        cpuReset_n_d   <= cpuReset_n;
        resetInstr_n_d <= resetInstr_n;
        pifd_d         <= pifd_pair;
        if (if_cycle && !fr_armed) fr_arm_cnt <= fr_arm_cnt + 12'd1;
        if (fr_armed) begin
            if (cpuReset_n_d   && !cpuReset_n   && fr_rst_falls   != 4'hF) fr_rst_falls   <= fr_rst_falls + 4'd1;
            if (resetInstr_n_d && !resetInstr_n && fr_instr_falls != 4'hF) fr_instr_falls <= fr_instr_falls + 4'd1;
        end
        if (fr_berr_trig && fr_berr_trigs != 8'hFF) fr_berr_trigs <= fr_berr_trigs + 8'd1;
        if (!fr_frozen) begin
            if (if_cycle) begin
                fr_pc1 <= fr_pc0;
                fr_pc0 <= cpuAddr;
            end
            if (fr_armed && cpuReset_n_d && !cpuReset_n) begin
                fr_frozen <= 1'b1; fr_cause <= 3'd1; fr_post <= 2'd3;
            end else if (fr_armed && resetInstr_n_d && !resetInstr_n) begin
                fr_frozen <= 1'b1; fr_cause <= 3'd2; fr_post <= 2'd3;
            end else if (fr_berr_trig) begin
                fr_frozen <= 1'b1; fr_cause <= 3'd4; fr_post <= 2'd1;
            end
        end else begin
            case (fr_post)
                2'd1: // waiting for the handler's RTE to complete a fetch
                    if (pifd_pair != pifd_d && pifd_pair[15:0] == 16'h4E73)
                        fr_post <= 2'd2;
                2'd2: // first fetch after RTE = where it landed
                    if (if_cycle) begin
                        fr_rte_pc0 <= cpuAddr; fr_rte_caught <= 1'b1; fr_post <= 2'd3;
                    end
                2'd3: // one more fetch for context, then done
                    if (if_cycle && fr_rte_caught && fr_rte_pc1 == 24'd0)
                        fr_rte_pc1 <= cpuAddr;
                default: ;
            endcase
        end
    end

    altsource_probe #(
        .instance_id ("PFR0"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_pfr0 (.probe({4'd0, fr_frozen, fr_cause, fr_pc0}), .source(), .source_clk(clk), .source_ena(1'b1));
    altsource_probe #(
        .instance_id ("PFR1"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_pfr1 (.probe({fr_rst_falls, fr_instr_falls, fr_pc1}), .source(), .source_clk(clk), .source_ena(1'b1));
    altsource_probe #(
        .instance_id ("PFR2"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_pfr2 (.probe({7'd0, fr_rte_caught, fr_rte_pc0}), .source(), .source_clk(clk), .source_ena(1'b1));
    altsource_probe #(
        .instance_id ("PFR3"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_pfr3 (.probe({fr_berr_trigs, fr_rte_pc1}), .source(), .source_clk(clk), .source_ena(1'b1));

    // (PBER/PBEA bus-error probes removed 2026-06-14 — they PROVED #3 is not a
    // bus error: sdma_berr never fired, cpu_berr was 100% routine fc7 probes, and
    // there was no BERR->reset correlation. Their probe budget is reused by the
    // PRC0/PRT re-init trail below. cpu_berr/fc7_berr/sdma_berr inputs are now
    // unused here; PSDT.berr_fires + PEXC still cover bus-error visibility.)

    // ---- PRC0 / PRT1-3: #3 reboot isolation (SCSI-abort trail + init entry) ----
    // The reboot has NO clean HW signature (no _cpuReset/RESET/BERR/overlay), and
    // address-based boot-entry detection missed (cold boot runs the overlay at
    // $00008C, the restart re-enters at an unknown high-ROM point). So capture two
    // complementary things, address-independently:
    //  (1) SCSI-ABORT PC TRAIL — freeze the 2 most recent IF PCs at the 2nd SCSI
    //      bus reset (dbg_rst_count = scsi_dbg4[15:8] increments). The driver
    //      asserts RST when it ABORTS a transfer; that abort is the prime suspect
    //      for what drives the System restart. PRT1 = CPU PC asserting the reset,
    //      PRT2 = the fetch before it -> disassemble = the SCSI driver abort path.
    //  (2) BOOT-INIT ENTRY BY OPCODE — detect `move.w #$2700,sr` ($46FC then
    //      $2700) in the fetch stream (the init's first instruction, wherever it
    //      enters). sr2700_cnt = how many inits ran (cold boot = 1; +1 if the
    //      reboot re-runs SR setup); PRT3 = the latest such entry PC = where init
    //      (re-)enters. (Replaced the address-based PRC0/PRT.)
    wire fetch_cplt = ifd_wait && !cpuAS_n_d && cpuAS_n;   // a fetch completed (PIFD commit pt)
    reg [15:0] op_prev = 16'd0;
    reg [23:0] pc_prev = 24'd0, pc_prev2 = 24'd0;
    reg [7:0]  sr2700_cnt = 8'd0;
    reg [23:0] sr_entry = 24'd0;          // latest move#$2700,sr PC (the init entry)
    reg [7:0]  rstc_d = 8'd0, busrst_cnt = 8'd0;
    reg        trail_frozen = 1'b0;
    reg [23:0] trail_pc1 = 24'd0, trail_pc2 = 24'd0;
    always @(posedge clk) begin
        // (2) opcode-based boot-init detection (address-independent)
        if (fetch_cplt) begin
            if (op_prev == 16'h46FC && cpu_din == 16'h2700) begin
                if (sr2700_cnt != 8'hFF) sr2700_cnt <= sr2700_cnt + 8'd1;
                sr_entry <= pc_prev;       // pc_prev = PC of the $46FC = init entry
            end
            op_prev  <= cpu_din;
            pc_prev2 <= pc_prev;
            pc_prev  <= if_addr;
        end
        // (1) SCSI bus-reset PC trail
        rstc_d <= scsi_dbg4[15:8];
        if (scsi_dbg4[15:8] != rstc_d) begin       // a SCSI bus reset occurred
            if (busrst_cnt != 8'hFF) busrst_cnt <= busrst_cnt + 8'd1;
            if (busrst_cnt >= 8'd1 && !trail_frozen) begin   // freeze at the 2nd
                trail_frozen <= 1'b1;
                trail_pc1 <= if_addr;
                trail_pc2 <= pc_prev;
            end
        end
    end
    reg [31:0] prc_r, pt1_r, pt2_r, pt3_r;
    always @(posedge clk) begin
        prc_r <= {busrst_cnt, sr2700_cnt, 15'd0, trail_frozen};
        pt1_r <= {8'd0, trail_pc1};
        pt2_r <= {8'd0, trail_pc2};
        pt3_r <= {8'd0, sr_entry};
    end

    altsource_probe #(
        .instance_id ("PRC0"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_prc0 (.probe(prc_r), .source(), .source_clk(clk), .source_ena(1'b1));
    altsource_probe #(
        .instance_id ("PRT1"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_prt1 (.probe(pt1_r), .source(), .source_clk(clk), .source_ena(1'b1));
    altsource_probe #(
        .instance_id ("PRT2"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_prt2 (.probe(pt2_r), .source(), .source_clk(clk), .source_ena(1'b1));
    altsource_probe #(
        .instance_id ("PRT3"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_prt3 (.probe(pt3_r), .source(), .source_clk(clk), .source_ena(1'b1));

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

    // ---- PBL0-6: CPU bus-latency meter (in-game slowdown, 2026-07-03) -----
    // Classifies every terminated CPU bus cycle and accumulates its duration
    // (clk_sys ticks AS held low, fall->rise, saturating at 255):
    //   prog = instruction fetch (FC 2/6), DTACK-terminated
    //   data = operand space (FC 1/5), DTACK-terminated
    //   vpa  = any cycle VPA answered (E-clock I/O + IACK) — separate class
    //          because its E-sync latency is architectural on a real Mac too,
    //          and it would otherwise poison the memory-latency averages.
    // BERR-terminated cycles (boot-time fc7 probes) land in prog/data with
    // their timeout length; they are boot-only noise, ignore in gameplay runs.
    //
    // Readout (scripts/buslat.tcl samples twice dt apart, all mod-2^32):
    //   PBL0 clk_sys free-run           -> dt = delta/32.5e6 s
    //   PBL1/PBL2 prog count/tick sum   -> avg fetch latency = d2/d1
    //   PBL3/PBL4 data count/tick sum   -> avg data latency  = d4/d3
    //   PBL6 vpa tick sum                (vpa count in PBL5[15:0], wrap16)
    //   bus occupancy = (d2+d4+d6)/d0
    //   PBL5 = {max_prog[7:0], max_data[7:0], vpa_cnt[15:0]}, maxes since load
    reg [31:0] bl_clk = 32'd0;
    reg [31:0] bl_prog_cnt = 32'd0, bl_prog_sum = 32'd0;
    reg [31:0] bl_data_cnt = 32'd0, bl_data_sum = 32'd0;
    reg [31:0] bl_vpa_sum  = 32'd0;
    reg [15:0] bl_vpa_cnt  = 16'd0;
    reg [7:0]  bl_max_prog = 8'd0, bl_max_data = 8'd0;
    reg [7:0]  bl_cur = 8'd0;
    reg        bl_active = 1'b0, bl_is_prog = 1'b0, bl_vpa_seen = 1'b0;
    always @(posedge clk) begin
        bl_clk <= bl_clk + 32'd1;
        if (cpuAS_n_d && !cpuAS_n) begin              // AS fell: cycle starts
            bl_active   <= 1'b1;
            bl_cur      <= 8'd1;
            bl_is_prog  <= (cpuFC == 3'b010) || (cpuFC == 3'b110);
            bl_vpa_seen <= !cpuVPA_n;
        end else if (bl_active && !cpuAS_n) begin     // in progress
            if (bl_cur != 8'hFF) bl_cur <= bl_cur + 8'd1;
            if (!cpuVPA_n) bl_vpa_seen <= 1'b1;
        end else if (bl_active && cpuAS_n) begin      // AS rose: cycle done
            bl_active <= 1'b0;
            if (bl_vpa_seen) begin
                bl_vpa_cnt <= bl_vpa_cnt + 16'd1;
                bl_vpa_sum <= bl_vpa_sum + {24'd0, bl_cur};
            end else if (bl_is_prog) begin
                bl_prog_cnt <= bl_prog_cnt + 32'd1;
                bl_prog_sum <= bl_prog_sum + {24'd0, bl_cur};
                if (bl_cur > bl_max_prog) bl_max_prog <= bl_cur;
            end else begin
                bl_data_cnt <= bl_data_cnt + 32'd1;
                bl_data_sum <= bl_data_sum + {24'd0, bl_cur};
                if (bl_cur > bl_max_data) bl_max_data <= bl_cur;
            end
        end
    end

    altsource_probe #(
        .instance_id ("PBL0"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_pbl0 (.probe(bl_clk), .source(), .source_clk(clk), .source_ena(1'b1));
    altsource_probe #(
        .instance_id ("PBL1"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_pbl1 (.probe(bl_prog_cnt), .source(), .source_clk(clk), .source_ena(1'b1));
    altsource_probe #(
        .instance_id ("PBL2"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_pbl2 (.probe(bl_prog_sum), .source(), .source_clk(clk), .source_ena(1'b1));
    altsource_probe #(
        .instance_id ("PBL3"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_pbl3 (.probe(bl_data_cnt), .source(), .source_clk(clk), .source_ena(1'b1));
    altsource_probe #(
        .instance_id ("PBL4"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_pbl4 (.probe(bl_data_sum), .source(), .source_clk(clk), .source_ena(1'b1));
    altsource_probe #(
        .instance_id ("PBL5"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_pbl5 (.probe({bl_max_prog, bl_max_data, bl_vpa_cnt}), .source(), .source_clk(clk), .source_ena(1'b1));
    altsource_probe #(
        .instance_id ("PBL6"), .probe_width (32), .source_width(1),
        .sld_auto_instance_index ("YES")
    ) cp_pbl6 (.probe(bl_vpa_sum), .source(), .source_clk(clk), .source_ena(1'b1));

endmodule
