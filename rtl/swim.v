/* SWIM (Sander/Wozniak Integrated Machine)

   Dual-mode floppy controller supporting:
   - IWM mode (backward compatible) - the mode the ROM boots in
   - ISM mode (SWIM native) - activated by a specific write sequence

   Mapped to $F16000 - $F17FFF

	IWM mode: The 16 IWM one-bit registers are {8'hDF, 8'b111xxxx1, 8'hFF}:
		0	$0		ca0L		CA0 off (0)
		1	$200	ca0H		CA0 on (1)
		2	$400	ca1L		CA1 off (0)
		3	$600	ca1H		CA1 on (1)
		4	$800	ca2L		CA2 off (0)
		5	$A00	ca2H		CA2 on (1)
		6	$C00	ph3L		LSTRB off (low)
		7	$E00	ph3H		LSTRB on (high)
		8	$1000	mtrOff	ENABLE disk enable off
		9	$1200	mtrOn		ENABLE disk enable on
		10	$1400	intDrive	SELECT select internal drive
		11	$1600	extDrive	SELECT select external drive
		12	$1800	q6L		Q6 off
		13	$1A00	q6H		Q6 on
		14	$1C00	q7L		Q7 off, read register
		15	$1E00	q7H		Q7 on, write register

	ISM mode registers (offset 0-7):
		Read:
		0 - FIFO data pop
		1 - FIFO mark pop
		2 - Error register (cleared on read)
		3 - Param[idx] (auto-increment)
		4 - Phases (ca0-ca2, lstrb)
		5 - Setup register
		6 - Mode register
		7 - Handshake (FIFO status)

		Write:
		0 - Push data to FIFO
		1 - Push data+mark to FIFO
		2 - Push CRC to FIFO
		3 - Write param[idx] (auto-increment)
		4 - Set phases
		5 - Set setup register
		6 - Mode clear (AND ~data)
		7 - Mode set (OR data)

	Notes from IWM manual:
	Serial data is shifted in/out MSB first, with a bit transferred every 2 microseconds.
	When writing data, a 1 is written as a transition on writeData at a bit cell boundary time, and a 0 is written as no transition.
	When reading data, a falling transition within a bit cell window is considered to be a 1, and no falling transition is considered a 0.
	When reading data, the read data register will latch the shift register when a 1 is shifted into the MSB.
	The read data register will be cleared 14 fclk periods (about 2 microseconds) after a valid data read takes place-- a valid data read
	   being defined as both /DEV being low and D7 (the MSB) outputting a one from the read data register for at least one fclk period.
*/

module swim
(
	input clk,
	input cep,
	input cen,

	input _reset,
	input selectSWIM,
	input _cpuRW,
	input _cpuUDS,  // LC V8 maps the SWIM on the UPPER byte (even addresses), not LDS like Mac Plus
	input [15:0] dataIn,
	input [3:0] cpuAddrRegHi,
	input SEL, // from VIA
	input driveSel, // internal drive select, 0 - upper, 1 - lower
	output [15:0] dataOut,
	input [1:0] insertDisk,
	output [1:0] diskEject,
	input [1:0] diskSides,
	input [1:0] diskMFM,    // disk is MFM-format (ISM path): {ext,int}
	input [1:0] diskHD,     // disk is 1.44MB HD: {ext,int}

	output [1:0] diskMotor,
	output [1:0] diskAct,

	// interface to fetch data for internal drive
	output [21:0] dskReadAddrInt,
	input dskReadAckInt,
	output [21:0] dskReadAddrExt,
	input dskReadAckExt,
	input [7:0] dskReadData,

	// --- diagnostic passthroughs (PFLP probes; internal drive only) ---
	output [31:0] dbg_ism_flpe,  // {5'b0, ism_error, arm_cnt, ovr_cnt, unr_cnt} — JTAG FLPE
	output [15:0] dbg_flp_byte_cnt,
	output [15:0] dbg_flp_miss_cnt,
	output [7:0]  dbg_flp_disk_data,
	output [6:0]  dbg_flp_track,
	output        dbg_flp_side,
	output [15:0] dbg_flp_step_cnt,
	output [7:0]  dbg_iwm_latch,     // live IWM read-data latch
	output        dbg_flp_byte_stb,  // 1-clk delivered-byte strobe (capture ring)
	output [7:0]  dbg_flp_raw,      // pre-encoder SDRAM fetch latch (internal drive)
	// {ism_mode_reg, ism_setup, 8'b0, diskEnableInt, driveSel, devsel_int,
	//  devsel_ext, selonly_int, ism_mode, motor_reg, 1'b0} — what the driver
	// actually PROGRAMMED. Needed because the 08-04 capture showed _enable
	// still high after keying it on the ISM drive-select code, i.e. that code
	// is not what we assume (reference doc says bits 2:1, gated by b7).
	output [31:0] dbg_ism_state,
	output [15:0] dbg_flp_strb_cnt,
	output [15:0] dbg_flp_strb_en_cnt,
	output [23:0] dbg_flp_strb_last,
	output [8:0]  dbg_flp_rej_step,
	output [7:0]  dbg_flp_status,
	output [21:0] dbg_flp_gcr_addr, // live GCR fetch address (internal drive)
	// {b1_hot[15:0], b5_hot[15:0]} over handshake READS — the two bits the
	// ROM's `d5 & 0x22` field verdict is made of; and pops taken with the
	// FIFO at 2 entries (b1/b0 then describe the NEXT byte, not the popped
	// one). See the VERDICT-BIT forensics block below.
	output [31:0] dbg_ism_verdict,
	output [15:0] dbg_ism_pop2
);

	wire [7:0] dataInLo = dataIn[7:0];
	reg [7:0] dataOutLo;
	// LC V8 reads the SWIM on the upper byte (D15-D8); lower byte is don't-care.
	assign dataOut = { dataOutLo, 8'hBE };

	// ================================================================
	// ISM mode state
	// ================================================================
	reg        ism_mode;           // 0=IWM mode, 1=ISM mode
	reg [7:0]  ism_mode_reg;       // ISM mode register
	reg [7:0]  ism_setup;          // ISM setup register
	reg [7:0]  ism_error;          // ISM error register (cleared on read)
	// MLAB: 128 bits was burning a full M10K block (m10k-repack 2026-07-17)
	(* ramstyle = "MLAB" *) reg [7:0]  ism_param[0:15];    // 16-byte parameter RAM
	reg [3:0]  ism_param_idx;      // Auto-incrementing param index
	reg [15:0] ism_fifo[0:1];      // 2-entry FIFO (data + mark/CRC flags)
	reg [1:0]  ism_fifo_pos;       // FIFO fill level (0=empty, 1=one, 2=full)
	// Generator-side staging ring (2026-08-04, the deterministic floppy copy
	// error): the CPU-visible FIFO stays 2 entries — the ROM self-test and
	// every handshake/error readback keep their exact semantics — but MFM
	// deliveries land here first and drain into the FIFO as the CPU makes
	// room. The old ceiling was one dropped byte (read overrun, error 0x01,
	// garbled field -> Finder "disk error") whenever the poll loop stalled
	// >~49us (2 entries x 16.25us); tb_ism_gaptest reproduces that at 60us.
	// 16 staged entries raise the ceiling to ~290us of CPU stall.
	(* ramstyle = "MLAB" *) reg [15:0] ism_stage[0:15];
	reg [3:0]  ism_stage_rd, ism_stage_wr;
	reg [4:0]  ism_stage_cnt;
	reg [1:0]  iwm_to_ism_counter; // Mode switch sequence detector

	// ISM FIFO entry layout: [7:0] data byte, [8] MARK (A1 sync), [9] CRC token
	// (CPU write-side placeholder), [10] CRC0 (running CRC == 0 at this byte).
	localparam FIFO_B_MARK = 8;
	localparam FIFO_B_CRC  = 9;
	localparam FIFO_B_CRC0 = 10;

	// IWM state
	reg ca0, ca1, ca2, lstrb, selectExternalDrive, q6, q7;
	reg ca0Next, ca1Next, ca2Next, lstrbNext, selectExternalDriveNext, q6Next, q7Next;
	wire advanceDriveHead; // prevents overrun when debugging, does not exit on a real Mac!
	reg [7:0] writeData;
	reg [7:0] readDataLatch;
	assign dbg_iwm_latch = readDataLatch;  // PFLP live view
	wire _iwmBusy, _writeUnderrun;
	assign _iwmBusy = 1'b1; // for writes, a value of 1 here indicates the IWM write buffer is empty
	assign _writeUnderrun = 1'b1;

	// floppy disk drives
	reg diskEnableExt, diskEnableInt;
	reg diskEnableExtNext, diskEnableIntNext;
	wire newByteReadyInt;
	wire [7:0] readDataInt;
	wire senseInt = readDataInt[7]; // bit 7 doubles as the sense line here
	wire newByteReadyExt;
	wire [7:0] readDataExt;
	wire senseExt = readDataExt[7]; // bit 7 doubles as the sense line here

	// MFM (ISM) read stream from each drive: byte+flags registered at each
	// 16/32 us delivery, with a one-cep-period strobe (sampled here on cen).
	wire [7:0] mfm_byte_int, mfm_byte_ext;
	wire mfm_mark_int, mfm_mark_ext, mfm_crc0_int, mfm_crc0_ext;
	wire mfm_stb_int, mfm_stb_ext;

	// F6: in ISM mode the drive select/enable comes from the ISM Mode register
	// (bit7 gate + the bits2:1 code) — MAME swim1.cpp devsel — NOT from the IWM
	// soft-switch enables (which the driver turns OFF before the MFM session;
	// without this the whole session talks to a disabled drive).
	//
	// ★ THE MAC LC HAS NO EXTERNAL FLOPPY DRIVE, so every ISM drive-select code
	// addresses the one internal drive. This used to decode 01=INT / 10=EXT, and
	// the real driver programs 10 — which routed the whole MFM session to the
	// absent external drive (2026-08-04 root cause of the floppy copy "disk
	// error"). Two failures followed, and BOTH match the hardware capture:
	//   - the internal drive's _enable never asserted, so every drive-register
	//     write was dropped. dbg_rej_step counted 5 well-formed STEPs discarded;
	//     driveTrack stayed 0, and since mfm_track_encoder takes .track(driveTrack)
	//     the engine served cylinder 0 forever while the driver read files
	//     further out. The volume still mounted and listed perfectly because the
	//     MDB and the catalog nodes the Finder needs all live on cyl 0.
	//   - mfm_byte_sel/ism_sense muxed off the EXTERNAL drive, which has no disk
	//     and so never strobes a byte: ism_error = UNDERRUN with ovr = 0 and the
	//     internal drive's byte_cnt frozen — exactly what the HUD showed.
	// Any non-zero code therefore selects the internal drive; 00 still means
	// "deselected", so an explicit release is still honoured.
	wire ism_drive_sel  = (ism_mode_reg[2:1] != 2'b00);
	wire ism_devsel_int = ism_mode && ism_mode_reg[7] && ism_drive_sel;
	wire ism_devsel_ext = 1'b0;   // no external drive on the LC

	// Drive-register ENABLE is drive SELECT ONLY — motor-on must not gate it.
	// (2026-08-04 root cause of the floppy copy "disk error".) The devsel wires
	// above AND in ism_mode_reg[7] = motor on, and they used to drive floppy.v's
	// _enable, which qualifies every drive-register write. A seek issued while
	// the motor bit was clear was therefore dropped on the floor: the head never
	// left cylinder 0, the MFM encoder kept serving cylinder 0 (it takes
	// .track(driveTrack)), and every read past cyl 0 failed while the volume
	// still mounted and listed perfectly (MDB + the catalog nodes the Finder
	// needs all live on cyl 0). Hardware HUD capture: 67 lstrb falling edges,
	// only 4 with _enable low, and among the rejected ones a perfectly formed
	// STEP ({ca1,ca0,SEL}=2, ca2=0). Reproduced byte-exactly by tb_ism_step
	// phase 5. On real hardware /ENBL follows drive select; motor-on only spins
	// the media. The devsel wires keep the motor term because the DATA path
	// (mfm_spinning via .ism_sel, sense/byte muxing) genuinely wants it.
	wire ism_selonly_int = ism_mode && ism_drive_sel;
	wire ism_selonly_ext = 1'b0;

	// One CPU bus access = one ISM action. The 68k holds UDS across many cen
	// ticks, so ISM register semantics (param auto-increment, FIFO pop/push,
	// the IWM->ISM switch counter) must fire ONCE per access: latch the access
	// while UDS is low, commit side effects on the deassert edge (acc_end).
	// Read data stays stable through the access; effects land at its close.
	wire       swim_acc = selectSWIM && (_cpuUDS == 1'b0);
	reg        swim_acc_d;
	reg  [3:0] acc_addr_l;
	reg        acc_rw_l;
	reg  [7:0] acc_data_l;
	wire       acc_end = swim_acc_d && !swim_acc;

	reg  [3:0] ism_phase_oe;   // Phases reg high nibble (output enables) — F2
	// FLPE probe counters (2026-08-04, the deterministic floppy copy error):
	// count read-side overruns (error[0]: generator pushed into a full FIFO =
	// the CPU polled too slowly), underrun/CPU-side faults (error[2]), and
	// read-arms. Plain always block of its own — Quartus single-driver law.
	reg [2:0] dbg_err_d = 0;
	reg       dbg_ra_d = 0;
	reg [7:0] dbg_flpe_ovr = 0, dbg_flpe_unr = 0, dbg_flpe_arm = 0;
	reg        mfm_synced;     // mark-hunt state: deliver to FIFO only once an
	                           // A1 mark has been seen since the last read-arm
	reg        ism_arm_d;      // for the ACTION-rising (read-arm) edge — F8

	// Head-select (SEL/HDSEL) source. On the Mac LC this is V8 VIA1 Port-A bit5 in
	// EVERY mode: maclc.cpp never wires the SWIM's hdsel_cb, so ISM Mode bit5 does
	// nothing (v8.cpp:258 drives write_hdsel from PA5). The MFM session and the
	// high sense-register bank (0xC-0xF, incl. the 0xD MFMModeOn verify) are all
	// reached with PA5, not Mode[5]. (Reverts the 06-13 "Fix C" effSEL=Mode[5],
	// which left SEL stuck 0 in ISM and made side 1 / high sense regs unreadable.)
	// F11, MAME 0.264 ground truth. On hdsel_cb machines (Quadras) Mode[5] matters.
	wire effSEL = SEL;

	floppy floppyInt
	(
		.clk(clk),
		.cep(cep),
		.cen(cen),

		._reset(_reset),
		.ca0(ca0),
		.ca1(ca1),
		.ca2(ca2),
		.SEL(effSEL),
		.lstrb(lstrb),
		._enable(ism_mode ? ~ism_selonly_int : ~(diskEnableInt & driveSel)),
		.writeData(writeData),
		.readData(readDataInt),
		.advanceDriveHead(advanceDriveHead),
		.newByteReady(newByteReadyInt),
		.insertDisk(insertDisk[0]),
		.diskSides(diskSides[0]),
		.diskEject(diskEject[0]),

		.motor(diskMotor[0]),
		.act(diskAct[0]),

		.dskReadAddr(dskReadAddrInt),
		.dskReadAck(dskReadAckInt),
		.dskReadData(dskReadData),
		.ism_active(ism_mode),
		.ism_action(ism_mode && ism_mode_reg[3]),
		.ism_sel(ism_devsel_int),
		.mfm_disk(diskMFM[0]),
		.mfm_hd(diskHD[0]),
		.mfm_byte(mfm_byte_int),
		.mfm_mark(mfm_mark_int),
		.mfm_crc0(mfm_crc0_int),
		.mfm_stb(mfm_stb_int),

		.dbg_byte_cnt(dbg_flp_byte_cnt),
		.dbg_miss_cnt(dbg_flp_miss_cnt),
		.dbg_disk_image_data(dbg_flp_disk_data),
		.dbg_drive_track(dbg_flp_track),
		.dbg_drive_side(dbg_flp_side),
		.dbg_step_cnt(dbg_flp_step_cnt),
		.dbg_byte_stb(dbg_flp_byte_stb),
		.dbg_raw_byte(dbg_flp_raw),
		.dbg_gcr_addr(dbg_flp_gcr_addr),
		.dbg_strb_cnt(dbg_flp_strb_cnt),
		.dbg_strb_en_cnt(dbg_flp_strb_en_cnt),
		.dbg_strb_last(dbg_flp_strb_last),
		.dbg_rej_step(dbg_flp_rej_step),
		.dbg_status(dbg_flp_status)
	);

	floppy floppyExt
	(
		.clk(clk),
		.cep(cep),
		.cen(cen),

		._reset(_reset),
		.ca0(ca0),
		.ca1(ca1),
		.ca2(ca2),
		.SEL(effSEL),
		.lstrb(lstrb),
		._enable(ism_mode ? ~ism_selonly_ext : ~diskEnableExt),
		.writeData(writeData),
		.readData(readDataExt),
		.advanceDriveHead(advanceDriveHead),
		.newByteReady(newByteReadyExt),
		.insertDisk(insertDisk[1]),
		.diskSides(diskSides[1]),
		.diskEject(diskEject[1]),

		.motor(diskMotor[1]),
		.act(diskAct[1]),

		.dskReadAddr(dskReadAddrExt),
		.dskReadAck(dskReadAckExt),
		.dskReadData(dskReadData),
		.ism_active(ism_mode),
		.ism_action(ism_mode && ism_mode_reg[3]),
		.ism_sel(ism_devsel_ext),
		.mfm_disk(diskMFM[1]),
		.mfm_hd(diskHD[1]),
		.mfm_byte(mfm_byte_ext),
		.mfm_mark(mfm_mark_ext),
		.mfm_crc0(mfm_crc0_ext),
		.mfm_stb(mfm_stb_ext)
	);

	wire [7:0] readData = selectExternalDrive ? readDataExt : readDataInt;
	wire newByteReady = selectExternalDrive ? newByteReadyExt : newByteReadyInt;

	// ISM-selected drive's MFM delivery + sense. Sense in ISM mode is polled
	// through Handshake bit3 and must follow the ISM devsel (both drives
	// disabled -> readData floats FF -> pull-up 1, matching hardware).
	wire [7:0] mfm_byte_sel = ism_devsel_ext ? mfm_byte_ext : mfm_byte_int;
	wire mfm_mark_sel = ism_devsel_ext ? mfm_mark_ext : mfm_mark_int;
	wire mfm_crc0_sel = ism_devsel_ext ? mfm_crc0_ext : mfm_crc0_int;
	wire mfm_stb_sel  = ism_devsel_ext ? mfm_stb_ext  : mfm_stb_int;
	wire ism_sense    = ism_devsel_ext ? senseExt : senseInt;
	// ISM read armed: (mode & 0x18) == 0x08 (ACTION on, WRITE off) — swim1.cpp.
	wire ism_arm = ism_mode && ism_mode_reg[3] && !ism_mode_reg[4];
	// MFM delivery additionally requires the MFM read datapath (Setup bit2=0
	// selects MFM vs GCR on the READ side — swim1.cpp:377).
	wire ism_read_active = ism_arm && !ism_setup[2];

	always @(posedge clk) begin
		dbg_err_d <= ism_error;
		dbg_ra_d  <= ism_read_active;
		if (~dbg_err_d[0] & ism_error[0] & (dbg_flpe_ovr != 8'hFF)) dbg_flpe_ovr <= dbg_flpe_ovr + 1'd1;
		if (~dbg_err_d[2] & ism_error[2] & (dbg_flpe_unr != 8'hFF)) dbg_flpe_unr <= dbg_flpe_unr + 1'd1;
		if (~dbg_ra_d  & ism_read_active & (dbg_flpe_arm != 8'hFF)) dbg_flpe_arm <= dbg_flpe_arm + 1'd1;
	end
	assign dbg_ism_flpe = {5'b0, ism_error, dbg_flpe_arm, dbg_flpe_ovr, dbg_flpe_unr};

	// ── VERDICT-BIT forensics (2026-08-05) ─────────────────────────────────
	// The ROM decides a field good/bad from ONE handshake sample taken at the
	// CRC-low byte: `d5 & 0x22` (ROM a6ef86/a6ef96) = b5 (error pending) OR
	// b1 (running CRC != 0 on the NEWEST fifo entry). Everything else about a
	// sector can be perfect and the field is still rejected -> retry ->
	// -69/-72 -> retries exhausted -> the -81 sectNFErr the guest reports.
	//
	// Neither bit leaves any trace in the existing counters, which is why a
	// whole-disk copy shows miss_cnt=0, ovr=0 and still fails ~1 file in 6.
	// These count, over handshake READS only (the sample the ROM actually
	// takes), how often each verdict bit was hot, plus how often the CPU
	// popped with the FIFO holding TWO entries — the state in which b1/b0
	// describe the byte AFTER the one being popped (a real SWIM1's 2-deep
	// FIFO cannot run further ahead; our 16-deep staging ring can hold that
	// state for a whole field, which would make the poisoning persistent
	// across the ROM's retries exactly as observed).
	wire hs_read_now = acc_end && ism_mode && acc_rw_l && (acc_addr_l[2:0] == 3'h7);
	// ★ POISONED sample, detected exactly: the byte the CPU is about to pop is
	// a CRC byte (crc0 set, so the field IS good) while the FIFO also holds a
	// NEWER byte whose running CRC is nonzero — the newer one is what b1
	// reports, so the ROM reads "CRC bad" for a field it read perfectly.
	// (Counting raw b1-hot reads is useless: b1 is legitimately hot for every
	// byte except a field's last CRC byte, so it saturates in seconds —
	// measured 65535 during a mount on build c150e907.)
	wire hs_poison_now = (ism_fifo_pos == 2'd2) &&
	                      ism_fifo[0][FIFO_B_CRC0] &&
	                     ~ism_fifo[1][FIFO_B_CRC0];
	reg [15:0] dbg_hs_b1 = 0, dbg_hs_b5 = 0, dbg_pop2 = 0;
	always @(posedge clk) begin
		if (cen) begin
			if (hs_read_now && hs_poison_now && dbg_hs_b1 != 16'hFFFF)
				dbg_hs_b1 <= dbg_hs_b1 + 1'd1;
			if (hs_read_now && (ism_error != 0) && dbg_hs_b5 != 16'hFFFF)
				dbg_hs_b5 <= dbg_hs_b5 + 1'd1;
			if (ism_pop_req && ism_fifo_pos == 2'd2 && dbg_pop2 != 16'hFFFF)
				dbg_pop2 <= dbg_pop2 + 1'd1;
		end
	end
	assign dbg_ism_verdict = {dbg_hs_b1, dbg_hs_b5};
	assign dbg_ism_pop2    = dbg_pop2;
	assign dbg_ism_state = {ism_mode_reg, ism_setup, 8'b0,
	                        diskEnableInt, driveSel, ism_devsel_int, ism_devsel_ext,
	                        ism_selonly_int, ism_mode, diskEnableExt, 1'b0};

	// ISM FIFO transaction requests (consumed in the clocked block below).
	// CPU pop/push commit at acc_end; the generator pushes on the delivery
	// strobe, but only once the mark hunt has synced (or at the syncing A1).
	// ★ A Data/Mark read with ACTION clear is NOT a pop (Snow ism.rs:228 —
	// `if !self.ism_mode.action() { return Some(0xFF); }`). The LC ROM's
	// session teardown/init probes the data and mark registers with the
	// engine disarmed (a6ea9e/a6eaf0/a6eb64); popping there hits an empty
	// FIFO and latches ism_error[2].
	//
	// That latched error is NOT cosmetic: Handshake b5 = "error pending", and
	// the ROM's per-field verdict is ONE handshake sample tested as
	// `d5 & 0x22` (a6ef86/a6ef96). While the error stays latched, every
	// handshake read reports b5, so a field whose data was read perfectly is
	// rejected -> retry -> retries exhausted -> the -81 sectNFErr / -65
	// offLinErr the guest shows as "couldn't be read, a disk error occurred".
	// Measured on hardware (build d0cbdd30, HUD row 7): 14 underrun onsets ->
	// 553 handshake reads with b5 hot across one whole-disk copy, while the
	// b1 (CRC-on-newest) poisoning count was exactly 0.
	wire ism_pop_req  = acc_end && ism_mode && acc_rw_l && ism_mode_reg[3] &&
	                    (acc_addr_l[2:0] == 3'h0 || acc_addr_l[2:0] == 3'h1);
	wire ism_cpu_push = acc_end && ism_mode && !acc_rw_l &&
	                    (acc_addr_l[2:0] == 3'h0 || acc_addr_l[2:0] == 3'h1 ||
	                     acc_addr_l[2:0] == 3'h2);
	wire ism_gen_push = ism_read_active && mfm_stb_sel &&
	                    (mfm_synced || mfm_mark_sel);
	wire [15:0] ism_gen_word = {5'b0, mfm_crc0_sel, 1'b0, mfm_mark_sel, mfm_byte_sel};
	// staging flow control: push on delivery (unless full), drain into the
	// 2-entry FIFO on quiet cycles (CPU FIFO events only fire at acc_end)
	wire stage_push  = ism_gen_push && (ism_stage_cnt != 5'd16);
	wire stage_drain = (ism_stage_cnt != 5'd0) && (ism_fifo_pos < 2'd2) && !acc_end;
	wire [15:0] ism_cpu_word = (acc_addr_l[2:0] == 3'h2) ? 16'h0200 :
	                           (acc_addr_l[2:0] == 3'h1) ? {7'b0, 1'b1, acc_data_l} :
	                                                       {8'b0, acc_data_l};

`ifdef SIMULATION
	reg [7:0]  dbg_arm_cnt = 0;
	reg [15:0] dbg_pop_cnt = 0;
	reg [15:0] dbg_hs_cnt = 0;
	reg [7:0]  dbg_hs_last = 0;
	reg [15:0] dbg_hs_rpt = 0;
	reg [15:0] dbg_mode_cnt = 0;
	reg [7:0]  dbg_err_cnt = 0;
	// live Handshake value (same expression as the read mux)
	wire [7:0] dbg_hs_now = {
		ism_mode_reg[4] ? (ism_fifo_pos <= 1) : (ism_fifo_pos != 0),
		ism_mode_reg[4] ? (ism_fifo_pos == 0) : (ism_fifo_pos == 2),
		(ism_error != 0),
		1'b0,
		ism_sense,
		1'b0,
		(ism_fifo_pos != 0) && ~ism_fifo[(ism_fifo_pos == 2'd2) ? 1 : 0][FIFO_B_CRC0],
		(ism_fifo_pos != 0) &&  ism_fifo[(ism_fifo_pos == 2'd2) ? 1 : 0][FIFO_B_MARK]};
`endif

	reg [4:0] iwmMode;
	/* IWM mode register: S C M H L
 	 S	Clock speed:
			0 = 7 MHz
			1 = 8 MHz
		Should always be 1 for Macintosh.
	 C	Bit cell time:
			0 = 4 usec/bit (for 5.25 drives)
			1 = 2 usec/bit (for 3.5 drives) (Macintosh mode)
	 M	Motor-off timer:
			0 = leave drive on for 1 sec after program turns
			    it off
			1 = no delay (Macintosh mode)
		Should be 0 for 5.25 and 1 for 3.5.
	 H	Handshake protocol:
			0 = synchronous (software must supply proper
			    timing for writing data)
			1 = asynchronous (IWM supplies timing) (Macintosh Mode)
		Should be 0 for 5.25 and 1 for 3.5.
	 L	Latch mode:
			0 = read-data stays valid for about 7 usec
			1 = read-data stays valid for full byte time (Macintosh mode)
		Should be 0 for 5.25 and 1 for 3.5.
	*/

	// ISM register address = (addr>>9)&7 = the LOW 3 bits of cpuAddrRegHi.
	// MAME swim1.cpp ism_read/ism_write use `offset & 7`, and the maclc ROM's own
	// behaviour confirms it: it does WR $F16800(n=4) then RD $F17800(n=12) and the
	// value reads back, so both alias to ISM reg 4 (Phases) — only n&7 makes 4==12.
	// (Was cpuAddrRegHi[3:1] = n>>1, which scrambled every ISM register and broke
	// all ISM-mode floppy access.  See docs/findings_mame_floppy_driveid_2026-06-13.md.)
	wire [2:0] ism_reg_addr = cpuAddrRegHi[2:0];

	// ================================================================
	// IWM bit register updates (active in IWM mode only)
	// ================================================================
	always @(*) begin
		ca0Next <= ca0;
		ca1Next <= ca1;
		ca2Next <= ca2;
		lstrbNext <= lstrb;
		diskEnableExtNext <= diskEnableExt;
		diskEnableIntNext <= diskEnableInt;
		selectExternalDriveNext <= selectExternalDrive;
		q6Next <= q6;
		q7Next <= q7;

		if (!ism_mode && selectSWIM == 1'b1 && _cpuUDS == 1'b0) begin
			case (cpuAddrRegHi[3:1])
				3'h0: // ca0
					ca0Next <= cpuAddrRegHi[0];
				3'h1: // ca1
					ca1Next <= cpuAddrRegHi[0];
				3'h2: // ca2
					ca2Next <= cpuAddrRegHi[0];
				3'h3: // lstrb
					lstrbNext <= cpuAddrRegHi[0];
				3'h4: // disk enable
					if (selectExternalDrive)
						diskEnableExtNext <= cpuAddrRegHi[0];
					else
						diskEnableIntNext <= cpuAddrRegHi[0];
				3'h5: // external drive
					selectExternalDriveNext <= cpuAddrRegHi[0];
				3'h6: // Q6
					q6Next <= cpuAddrRegHi[0];
				3'h7: // Q7
					q7Next <= cpuAddrRegHi[0];
			endcase
		end
	end

	// IWM bit register update is merged into the write logic block below
	// to avoid multiple drivers on ca0/ca1/ca2/lstrb (Quartus requirement)

	// ================================================================
	// Read mux: IWM mode vs ISM mode
	// ================================================================
	always @(*) begin
		dataOutLo = 8'hEF;

		if (ism_mode) begin
			// ISM mode reads
			case (ism_reg_addr)
				// Data ($0) / Mark ($1): head of the real 2-entry FIFO. The pop
				// side-effect commits at access end (acc_end), so the value is
				// stable for the whole CPU access. Empty pop floats FF (Snow
				// ism.rs; the underrun error is raised in the pop transaction).
				// With ACTION clear this is a disarmed probe, not a pop: return
				// FF and leave the FIFO/error alone (Snow ism.rs:228). See the
				// ism_pop_req comment — a spurious error here poisons the ROM's
				// `d5 & 0x22` field verdict through Handshake b5.
				3'h0, 3'h1:
					dataOutLo = (!ism_mode_reg[3] || ism_fifo_pos == 0)
					            ? 8'hFF : ism_fifo[0][7:0];
				3'h2: // Error register
					dataOutLo = ism_error;
				3'h3: // Param[idx]
					dataOutLo = ism_param[ism_param_idx];
				3'h4: // Phases: all 8 written bits read back (low nibble = the
				      // live phase lines, high nibble = latched output enables).
				      // The ROM's SWIM self-test walks F5,F6,..F0 through here. F2.
					dataOutLo = {ism_phase_oe, lstrb, ca2, ca1, ca0};
				3'h5: // Setup register
					dataOutLo = ism_setup;
				3'h6: // Mode register
					dataOutLo = ism_mode_reg;
				// Handshake ($7) — MAME swim1.cpp:224-250. Read mode: b7 = FIFO
				// not-empty (data available), b6 = full; write mode inverts to
				// space-available. b5 = error pending, b3 = drive sense (b2 is
				// rddata, not sense — 0.264 correction). b1/b0 describe the
				// NEWEST fifo entry (0.264 groundtruth): b1 = 0 when its
				// running CRC == 0 (good), b0 = it is a MARK; both read 0 with
				// an empty FIFO. b7=0 between fields is the hunt-loop poll.
				3'h7:
					dataOutLo = {
						ism_mode_reg[4] ? (ism_fifo_pos <= 1) : (ism_fifo_pos != 0),
						ism_mode_reg[4] ? (ism_fifo_pos == 0) : (ism_fifo_pos == 2),
						(ism_error != 0),
						1'b0,
						ism_sense,
						1'b0,
						(ism_fifo_pos != 0) && ~ism_fifo[(ism_fifo_pos == 2'd2) ? 1 : 0][FIFO_B_CRC0],
						(ism_fifo_pos != 0) &&  ism_fifo[(ism_fifo_pos == 2'd2) ? 1 : 0][FIFO_B_MARK]};
			endcase
		end
		else begin
			// IWM mode reads (original logic)
			case ({q7Next,q6Next})
				2'b00: // data-in register: MAME iwm dispatch is `active ? data : FF`
				       // — an idle controller floats the data bus high. (Was
				       // readDataLatch unconditionally; matches lbmactwo/MAME.)
					dataOutLo <= (diskEnableExt | diskEnableInt) ? readDataLatch : 8'hFF;
				2'b01: // IWM status register: bit7=sense, bit5=ACTIVE (any drive
				       // selected — MAME ORs the enables; was AND = never active
				       // unless both drives on). bits4:0 = IWM mode. F9.
					dataOutLo <= { (selectExternalDriveNext ? senseExt : senseInt), 1'b0, diskEnableExt | diskEnableInt, iwmMode };
				2'b10: // handshake
					dataOutLo <= { _iwmBusy, _writeUnderrun, 6'b000000 };
				2'b11: // IWM mode register (write-only) or write data register
					dataOutLo <= 0;
			endcase
		end
	end

	// ================================================================
	// Write logic: IWM mode (with ISM switch detection) + ISM mode
	// ================================================================
	always @(posedge clk or negedge _reset) begin
		if (_reset == 1'b0) begin
			iwmMode <= 0;
			writeData <= 0;
			ism_mode <= 0;
			ism_mode_reg <= 0;
			ism_setup <= 0;
			ism_error <= 0;
			ism_param_idx <= 0;
			ism_fifo_pos <= 0;
			ism_stage_rd <= 0; ism_stage_wr <= 0; ism_stage_cnt <= 0;
			iwm_to_ism_counter <= 0;
			ism_fifo[0] <= 0;
			ism_fifo[1] <= 0;
			// IWM bit registers (merged here to avoid multiple drivers)
			ca0 <= 0;
			ca1 <= 0;
			ca2 <= 0;
			lstrb <= 0;
			diskEnableExt <= 0;
			diskEnableInt <= 0;
			selectExternalDrive <= 0;
			q6 <= 0;
			q7 <= 0;
			swim_acc_d <= 1'b0;
			acc_addr_l <= 4'h0;
			acc_rw_l <= 1'b1;
			acc_data_l <= 8'h00;
			ism_phase_oe <= 4'h0;
			mfm_synced <= 1'b0;
			ism_arm_d <= 1'b0;
		end
		else if(cen) begin
			// Default: update IWM bit registers from combinational next-state
			ca0 <= ca0Next;
			ca1 <= ca1Next;
			ca2 <= ca2Next;
			lstrb <= lstrbNext;
			diskEnableExt <= diskEnableExtNext;
			diskEnableInt <= diskEnableIntNext;
			selectExternalDrive <= selectExternalDriveNext;
			q6 <= q6Next;
			q7 <= q7Next;

			// IWM-mode writes (level-held across the access, idempotent; all
			// ISM register semantics commit once per access at acc_end below).
			// Mode-vs-data dispatch matches MAME: with {q7,q6}=11 a write goes
			// to the data register if a drive is enabled, else to the IWM mode
			// register. The IWM->ISM switch detector no longer lives here —
			// it keys on offset-0xF accesses (F1), see below.
			if (_cpuRW == 0 && selectSWIM == 1'b1 && _cpuUDS == 1'b0 && !ism_mode) begin
				if ({q7Next,q6Next} == 2'b11) begin
					if (diskEnableExt | diskEnableInt)
						writeData <= dataInLo;
					else
						iwmMode <= dataInLo[4:0];
				end
			end

			// --- SWIM access bookkeeping: latch the access while UDS is low;
			// side effects commit once, at the deassert edge (acc_end).
			swim_acc_d <= swim_acc;
			if (swim_acc) begin
				acc_addr_l <= cpuAddrRegHi;
				acc_rw_l   <= _cpuRW;
				acc_data_l <= dataInLo;

				// MAME's "any non-0xF SWIM access resets the switch counter" is
				// applied LEVEL-wise, not at acc_end: cen is clk_sys/4, so two
				// back-to-back CPU accesses can share a single sampled UDS-low
				// window and merge into one acc_end. A missed reset is the one
				// error that matters here — it lets an unrelated run of mode
				// register writes complete the 1,0,1,1 pattern and drop us into
				// ISM behind the driver's back. Resetting early is harmless: the
				// deliberate switch sequence is four consecutive 0xF writes.
				if (!ism_mode && cpuAddrRegHi != 4'hF) iwm_to_ism_counter <= 0;
			end

			// ============================================================
			// ISM FIFO transactions. Generator deliveries land in the
			// staging ring; the drain refills the 2-entry CPU FIFO on
			// cycles without CPU FIFO events (those only fire at acc_end),
			// so every CPU-visible semantic (pop order, handshake bits,
			// self-test full-at-2) is unchanged. A reg0 pop of a MARK byte
			// flags Error b1; pop-empty / cpu-push-full flag Error b2;
			// a delivery with the STAGE full drops the byte and flags
			// Error b0 (read overrun) exactly as the 2-deep design did —
			// the threshold just moved from ~49us of poll stall to ~290us.
			// ============================================================
			// stage_cnt arithmetic first: any FIFO-clear later in this
			// block overrides it (last nonblocking write wins).
			ism_stage_cnt <= ism_stage_cnt + {4'd0, stage_push} - {4'd0, stage_drain};
			if (stage_push) begin
				ism_stage[ism_stage_wr] <= ism_gen_word;
				ism_stage_wr <= ism_stage_wr + 4'd1;
			end
			if (ism_gen_push && ism_stage_cnt == 5'd16)
				ism_error[0] <= 1'b1;          // overrun: delivered byte lost
				                               // (MAME swim1 read-side push-full
				                               // = error 0x01, byte dropped;
				                               // CPU-side push-full stays 0x04)
			if (stage_drain) begin
				ism_fifo[ism_fifo_pos[0]] <= ism_stage[ism_stage_rd];
				ism_fifo_pos <= ism_fifo_pos + 2'd1;
				ism_stage_rd <= ism_stage_rd + 4'd1;
			end
			if (ism_pop_req) begin
				if (ism_fifo_pos != 0) begin
					ism_fifo[0]  <= ism_fifo[1];
					ism_fifo_pos <= ism_fifo_pos - 2'd1;
					if (acc_addr_l[2:0] == 3'h0 && ism_fifo[0][FIFO_B_MARK]) ism_error[1] <= 1'b1;
				end else
					ism_error[2] <= 1'b1;          // underrun
			end
			else if (ism_cpu_push) begin
				if (ism_fifo_pos < 2'd2) begin
					ism_fifo[ism_fifo_pos[0]] <= ism_cpu_word;
					ism_fifo_pos <= ism_fifo_pos + 2'd1;
				end else
					ism_error[2] <= 1'b1;
			end

			// Mark-hunt: the first delivered A1 after a read-arm sets sync;
			// bytes before it (gaps, partial fields) are dropped, which is
			// what makes Handshake b7 read 0 between fields while hunting.
			if (ism_read_active && mfm_stb_sel && !mfm_synced && mfm_mark_sel)
				mfm_synced <= 1'b1;

			// ============================================================
			// ISM register side effects — once per CPU access, at acc_end
			// ============================================================
			if (acc_end && ism_mode) begin
				if (!acc_rw_l) begin
					case (acc_addr_l[2:0])
						// 0/1/2 (FIFO pushes) are in the transaction above
						3'h3: begin // Param[idx] write, auto-increment
							ism_param[ism_param_idx] <= acc_data_l;
							ism_param_idx <= ism_param_idx + 1'b1;
						end
						3'h4: begin // Phases: low nibble drives the lines (the
						            // shared lstrb edge in floppy.v serves ISM
						            // strobes too); high nibble latched for the
						            // 8-bit readback the ROM self-test needs. F2.
							ca0   <= acc_data_l[0];
							ca1   <= acc_data_l[1];
							ca2   <= acc_data_l[2];
							lstrb <= acc_data_l[3];
							ism_phase_oe <= acc_data_l[7:4];
						end
						3'h5:
							ism_setup <= acc_data_l;
						3'h6: begin // Mode clear (AND ~data)
							ism_mode_reg  <= ism_mode_reg & ~acc_data_l;
							ism_param_idx <= 0;  // MAME: ModeClr always resets param idx
							if (acc_data_l[6]) begin
								ism_mode <= 0;   // bit6 cleared -> back to IWM
								iwm_to_ism_counter <= 0;
`ifdef SIMULATION
								$display("SWIM: ISM -> IWM (ModeClr %02x) @%0t", acc_data_l, $time);
`endif
							end
							if ((ism_mode_reg & ~acc_data_l) & 8'h01) begin
								ism_fifo_pos <= 0;
								ism_stage_rd <= 0; ism_stage_wr <= 0; ism_stage_cnt <= 0;
							end
						end
						3'h7: begin // Mode set (OR data)
							ism_mode_reg <= ism_mode_reg | acc_data_l;
							if ((ism_mode_reg | acc_data_l) & 8'h01) begin
								ism_fifo_pos <= 0;
								ism_stage_rd <= 0; ism_stage_wr <= 0; ism_stage_cnt <= 0;
							end
						end
						default: ;
					endcase
				end
				else begin
					// read side effects (FIFO pops are in the transaction above)
					if (acc_addr_l[2:0] == 3'h2) ism_error <= 0;
					if (acc_addr_l[2:0] == 3'h3) ism_param_idx <= ism_param_idx + 1'b1;
				end
			end

			// ============================================================
			// IWM->ISM switch detector — MAME swim1.cpp: the counter runs
			// ONLY on offset-0xF accesses (write: data bit6, pattern
			// 1,0,1,1; a read acts as data=0); ANY other SWIM access resets
			// it. Drive enables are irrelevant — the LC ROM performs the
			// switch with all drives disabled (and GCR sector-write data,
			// which false-fired the old data-keyed detector, goes to offset
			// 0xD, which now resets instead). F1.
			// ============================================================
			if (acc_end && !ism_mode) begin
				if (acc_addr_l == 4'hF) begin
					if (acc_rw_l ? 1'b0 : acc_data_l[6]) begin
						case (iwm_to_ism_counter)
							2'd0: iwm_to_ism_counter <= 2'd1;
							2'd1: iwm_to_ism_counter <= 2'd0;
							2'd2: iwm_to_ism_counter <= 2'd3;
							2'd3: begin // 1,0,1,1 complete -> enter ISM
								ism_mode      <= 1;
								ism_mode_reg  <= 8'h40;
								ism_error     <= 0;
								ism_fifo_pos  <= 0;
								ism_param_idx <= 0;
								mfm_synced    <= 1'b0;
								iwm_to_ism_counter <= 0;
`ifdef SIMULATION
								$display("SWIM: switched to ISM mode @%0t", $time);
`endif
							end
						endcase
					end else
						iwm_to_ism_counter <= (iwm_to_ism_counter == 2'd1) ? 2'd2 : 2'd0;
				end
				else
					iwm_to_ism_counter <= 0;
			end

			// F8: entering read mode ((mode & 0x18) == 0x08 rising) restarts
			// the mark hunt and empties the FIFO — the per-field re-arm the
			// driver performs 18+ times per revolution.
			ism_arm_d <= ism_arm;
			if (ism_arm && !ism_arm_d) begin
				mfm_synced   <= 1'b0;
				ism_fifo_pos <= 0;
				ism_stage_rd <= 0; ism_stage_wr <= 0; ism_stage_cnt <= 0;
			end

`ifdef SIMULATION
			if (ism_arm && !ism_arm_d && dbg_arm_cnt < 8'd80) begin
				dbg_arm_cnt <= dbg_arm_cnt + 1'd1;
				$display("SWIM-ISM: read ARM mode=%02x setup=%02x dev={e%b,i%b} @%0t",
				         ism_mode_reg, ism_setup, ism_devsel_ext, ism_devsel_int, $time);
			end
			if (ism_read_active && mfm_stb_sel && !mfm_synced && mfm_mark_sel && dbg_arm_cnt < 8'd80)
				$display("SWIM-ISM: mark-sync @%0t", $time);
			if (ism_pop_req && ism_fifo_pos != 0 && dbg_pop_cnt < 16'd4000) begin
				dbg_pop_cnt <= dbg_pop_cnt + 1'd1;
				$display("SWIM-ISM: pop %02x m=%b c0=%b pos=%0d",
				         ism_fifo[0][7:0], ism_fifo[0][FIFO_B_MARK], ism_fifo[0][FIFO_B_CRC0], ism_fifo_pos);
			end
			if (ism_pop_req && ism_fifo_pos == 0 && dbg_err_cnt < 8'd60) begin
				dbg_err_cnt <= dbg_err_cnt + 1'd1;
				$display("SWIM-ISM: POP-EMPTY (underrun) @%0t", $time);
			end
			if (acc_end && ism_mode && acc_rw_l && acc_addr_l[2:0] == 3'h4)
				$display("SWIM-ISM: phases rd -> %02x", {ism_phase_oe, lstrb, ca2, ca1, ca0});
			// Handshake reads, run-length compressed (the hunt loop polls ~2000x
			// per sector gap; log transitions + a repeat count, hard-capped).
			if (acc_end && ism_mode && acc_rw_l && acc_addr_l[2:0] == 3'h7) begin
				if (dbg_hs_now != dbg_hs_last) begin
					if (dbg_hs_cnt < 16'd20000) begin
						dbg_hs_cnt <= dbg_hs_cnt + 1'd1;
						$display("SWIM-ISM: HS %02x (x%0d) -> %02x pos=%0d @%0t",
						         dbg_hs_last, dbg_hs_rpt, dbg_hs_now, ism_fifo_pos, $time);
					end
					dbg_hs_last <= dbg_hs_now;
					dbg_hs_rpt  <= 16'd1;
				end else if (dbg_hs_rpt != 16'hFFFF)
					dbg_hs_rpt <= dbg_hs_rpt + 1'd1;
			end
			// Mode register writes (set/clear) — the per-sector re-arm fingerprint
			if (acc_end && ism_mode && !acc_rw_l &&
			    (acc_addr_l[2:0] == 3'h6 || acc_addr_l[2:0] == 3'h7) && dbg_mode_cnt < 16'd1200) begin
				dbg_mode_cnt <= dbg_mode_cnt + 1'd1;
				$display("SWIM-ISM: Mode%s %02x -> mode=%02x @%0t",
				         (acc_addr_l[2:0] == 3'h6) ? "Clr" : "Set", acc_data_l,
				         (acc_addr_l[2:0] == 3'h6) ? (ism_mode_reg & ~acc_data_l)
				                                   : (ism_mode_reg | acc_data_l), $time);
			end
			if (acc_end && ism_mode && !acc_rw_l && acc_addr_l[2:0] == 3'h5)
				$display("SWIM-ISM: Setup <= %02x @%0t", acc_data_l, $time);
			if (acc_end && ism_mode && acc_rw_l && acc_addr_l[2:0] == 3'h2 && ism_error != 0 && dbg_err_cnt < 8'd60) begin
				dbg_err_cnt <= dbg_err_cnt + 1'd1;
				$display("SWIM-ISM: Error rd -> %02x (cleared) @%0t", ism_error, $time);
			end
`endif
		end
	end

	// ================================================================
	// IWM read data latch (unchanged from original)
	// ================================================================
	wire iwmRead = (_cpuRW == 1'b1 && selectSWIM == 1'b1 && _cpuUDS == 1'b0 && !ism_mode);
	wire anyDiskEnable = diskEnableExt | diskEnableInt;
	reg [3:0] readLatchClearTimer;
	reg [11:0] readDataArmDelay;   // post-enable squelch (~126 us at 8.125 MHz cen)
	reg anyDiskEnableD;
	wire readDataArmed = (readDataArmDelay == 12'd0);
	always @(posedge clk or negedge _reset) begin
		if (_reset == 1'b0) begin
			readDataLatch <= 0;
			readLatchClearTimer <= 0;
			readDataArmDelay <= 0;
			anyDiskEnableD <= 0;
		end
		else if(cen) begin
			anyDiskEnableD <= anyDiskEnable;

			if (readDataArmDelay != 0) begin
				readDataArmDelay <= readDataArmDelay - 1'b1;
			end

			// a countdown timer governs how long after a data latch read before the latch is cleared
			if (readLatchClearTimer != 0) begin
				readLatchClearTimer <= readLatchClearTimer - 1'b1;
			end

			// MAME clears the IWM data register when the controller enters active
			// read mode; squelch briefly so the mount's first data poll never sees
			// a stale idle-drive byte. (Ported from lbmactwo iwm.v, HW-validated.)
			if (anyDiskEnable && !anyDiskEnableD) begin
				readDataLatch <= 0;
				readLatchClearTimer <= 0;
				readDataArmDelay <= 12'h400;
			end

			// the conclusion of a valid CPU read from the IWM will start the timer to clear the latch
			else if (iwmRead && readDataLatch[7]) begin
				readLatchClearTimer <= 4'hD; // clear latch 14 clocks after the conclusion of a valid read
			end

			// when the drive indicates that a new byte is ready, latch it (only
			// with a drive enabled and the post-enable squelch elapsed)
			// NOTE: the real IWM must self-synchronize with the incoming data to determine when to latch it
			if (anyDiskEnable && readDataArmed && newByteReady) begin
				readDataLatch <= readData;
			end
			else if (readLatchClearTimer == 1'b1) begin
				readDataLatch <= 0;
			end
		end
	end
	assign advanceDriveHead = readLatchClearTimer == 1'b1; // prevents overrun when debugging, does not exist on a real Mac!
endmodule
