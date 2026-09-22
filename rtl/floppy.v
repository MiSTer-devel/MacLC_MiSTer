/* Synchronous 8-bit replica of 3.5 inch floppy disk drive.

	Differences from the true floppy interace at the Mac's DB-19 port:
	True interface has a writeReq control line, only 1-bit readData and writeData, and no clk.
	True interface does not have newByteReady signal. Instead the IWM must watch the data in bit and synchronize with it to
	   determine the timing and framing of bytes.
	
*/

/* Disk register (read):
	    State-control lines       Register
  CA2    CA1    CA0    SEL    addressed    Information in register

  0      0      0      0      DIRTN        Head step direction (0=toward track 79, 1=toward track 0)
  0      0      0      1      CSTIN        Disk in place (0=disk is inserted)
  0      0      1      0      STEP         Drive head stepping (setting to 0 performs a step, returns to 1 when step is complete)
  0      0      1      1      WRTPRT       Disk locked (0=locked)
  0      1      0      0      MOTORON      Drive motor running (0=on, 1=off)
  0      1      0      1      TKO          Head at track 0 (0=at track 0)
  0		1		 1		  0		SWITCHED   	 Disk switched (1=yes; set on media REMOVAL, survives the
                                          next insert, cleared only by the DskchgClear strobe —
                                          MAME mac_floppy m_dskchg, sense reads !m_dskchg)
  0      1      1      1      TACH         Tachometer (produces 60 pulses for each rotation of the drive motor)
  1      0      0      0      RDDATA0      Read data, lower head, side 0
  1      0      0      1      RDDATA1      Read data, upper head, side 1 
  1      0      1      0      SUPERDR      Drive is a Superdrive (0=no, 1=yes)
  1      1      0      0      SIDES        Single- or double-sided drive (0=single side, 1=double side)
  1      1      0      1      READY        0 = yes
  1      1      1      0      INSTALLED	 0 = yes
  1      1      1      1      DRVIN        400K/800K: Drive installed (0=drive is present), Superdrive: Inserted disk capacity (0=HD, 1=DD)
	
	Disk registers (write):
    Control lines      Register
  CA1    CA0    SEL    addressed    Register function

  0      0      0      DIRTN        Set stepping direction (0=toward track 79, 1=toward track 0)
  0      0      1      SWITCHED		Reset disk switched flag (writing 1 sets switch flag to 0)
  0      1      0      STEP         Step the drive head one track (setting to 0 performs a step, returns to 1 when step is complete)
  1      0      0      MOTORON      Turn on/off drive motor (0=on, 1=off)
  1      1      0      EJECT        Eject the disk (writing 1 ejects the disk)
	
*/

`define DRIVE_REG_DIRTN		0  /* R/W: step direction (0=toward track 79, 1=toward track 0) */
`define DRIVE_REG_CSTIN		1  /* R: disk in place (1 = no disk) */
	                           /* W: ?? reset disk switch flag ? */
`define DRIVE_REG_STEP		2  /* R: drive head is stepping (1 = complete) */
	                           /* W: 0 = step drive head */
`define DRIVE_REG_WRTPRT	3  /* R: 0 = disk is write-protected */
`define DRIVE_REG_MOTORON	4  /* R/W: 0 = motor on */
`define DRIVE_REG_TK0		5  /* R: 0 = head at track 0 */
`define DRIVE_REG_EJECT		6  /* R: disk switched (1=yes?)*/
	                           /* W: 1 = eject the disk */
`define DRIVE_REG_TACH		7  /* R: tach-o-meter */
`define DRIVE_REG_RDDATA0	8  /* R: activate lower head: side 0 */
`define DRIVE_REG_RDDATA1	9  /* R: activate upper head: side 1 */
`define DRIVE_REG_SUPERDR	10 /* R: drive is a superdrive (0=no, 1=yes) */
`define DRIVE_REG_SIDES		12 /* R: number of sides (0=single, 1=dbl) */
`define DRIVE_REG_READY		13 /* R: drive ready (head loaded) (0=ready) */
`define DRIVE_REG_INSTALLED	14 /* R: drive present (0 = yes ??) */
`define DRIVE_REG_DRVIN		15 /* R: 400K/800k: drive present (0=yes, 1=no), Superdrive: disk capacity (0=HD, 1=DD) */

module floppy
#(
	// 0 strips the ENTIRE write path: engine, decoder, committer, anchors. The
	// external drive never has media and has writeProtect tied high, so its
	// write path can do nothing, but instantiated it still costs a decoder
	// (about 1 M10K). Nothing drive-visible changes: it answers every register
	// exactly as before and simply cannot accept a byte.
	parameter WRITE_SUPPORT = 1,

	// MFM byte cadence, in cep ticks: 129 = 16us (HD), 259 = 32us (DD) at
	// 8.125 MHz. Parameterised ONLY so a bench can shrink a revolution from
	// ~4.3 M clocks to something that runs in seconds -- one MFM sector is 682
	// byte-times, so at the real cadence an Icarus bench that has to watch the
	// head cross a sector boundary runs for a quarter of an hour. No
	// synthesised instance overrides these; same technique as
	// floppy_sd.v's ACK_TIMEOUT_BITS.
	parameter [8:0] MFM_PERIOD_HD = 9'd129,
	parameter [8:0] MFM_PERIOD_DD = 9'd259
)
(
	input clk,
	input cep,
	input cen,

	input _reset,
	input ca0,				// PH0
	input ca1,				// PH1
	input ca2,				// PH2
	input SEL, 				// HDSEL from VIA
	input lstrb,			// aka PH3
	input _enable, 			
	input [7:0] writeData,		
	output [7:0] readData,

	// --- GCR write path -----------------------------------
	// writeData above is the CPU's byte; it is LIVE from Phase 3 on, having
	// been declared and never referenced before it. swim.v
	// hands over the UNREGISTERED bus value so it cannot lag writeReq by a
	// cycle -- the same reason MacPlus passes dataInLo directly.
	input        writeReq,       // LEVEL, not a pulse, while the CPU writes the
	                             // IWM data register for this drive. One CPU
	                             // access spans several cen ticks; the
	                             // !writeBusyReg guard below is what makes that
	                             // one byte. MacPlus's hardware-proven shape.
	input        writeProtect,   // 1 = refuse writes (OSD off / img_readonly /
	                             // a DC42 mount). Also drives WRTPRT.
	// IWM Q7: the CPU has put the drive in WRITE MODE. It bounds the write as
	// a whole for the encoder's format relay, and nothing
	// else consumes it. ★ writeBusyReg alone is NOT a substitute: it drops at
	// the end of every 128-cep byte, so a busy-derived wrEnd would pulse
	// between every byte of a track -- the relay would fire after the first
	// address field, restart the layout mid-format, and disarm.
	input        writeMode,
	output       writeBusy,      // 1 = buffer full, the CPU must wait
	                             // (swim.v inverts it for _iwmBusy)
	output       writeUnderrun,  // 1 = a byte in flight was abandoned
	// The Phase 2 contract tuple, as a witness. The committer consumes it
	// internally; these exist so the cone has a load and so a HUD can see it.
	output        wrSecValid,
	output [4:0]  wrSecNum,
	output [21:0] wrSecAddr,
	// SDRAM write port for committed sectors. Same LEVEL protocol as
	// floppy_sd.v's. wrSdAddr is an image BYTE offset, matching dskReadAddr
	// on the read side; the caller adds the image base and halves it for the
	// word-addressed download port, so only one place knows where images live.
	output [21:0] wrSdAddr,
	output [15:0] wrSdData,
	output        wrSdReq,
	input         wrSdAck,
	output        wrCommitDone,   // 1-clk pulse: a sector reached SDRAM
	output [21:0] wrCommitAddr,   // image BYTE offset of that sector's byte 0
	// Persistence tap for rtl/floppy_sd.v — a mirror of the
	// word stream the committer is writing to SDRAM, so the SD writer can
	// shadow the sector and push it out to the user's .dsk. Pure pass-through
	// of floppy_sd.v's sd_buf_* outputs; see its header for why
	// the tap is taken from the registered SDRAM word rather than re-read.
	output  [7:0] wrSdBufAddr,
	output [15:0] wrSdBufData,
	output        wrSdBufWr,
	
	input advanceDriveHead,  // prevents overrun when debugging, does not exist on a real Mac!
	output reg newByteReady,
	input insertDisk,
	// The mounted FILE is 819,200 bytes rather than 409,600 (MacPlus calls this
	// img800k). A ceiling on sidedness, not the answer to it -- see
	// doubleSidedDisk below.
	input diskSides,
	// The MEDIUM's own sidedness, from floppy_sd.v's mount-time volume
	// sniff. 1 = double-sided, or unknown.
	input mediaSides,
	output diskEject,

	output motor,
	output act,

	output [21:0] dskReadAddr,
	input dskReadAck,
	input [7:0] dskReadData,

	// MFM (ISM/SWIM) read path — 720K/1.44MB. The disk spins on its own: while
	// an MFM disk is in and the motor runs, a decoded byte falls off the head
	// every 16 us (HD) / 32 us (DD). Each delivery latches the encoder's output
	// and strobes mfm_stb for one cep period (the SWIM samples it on cen).
	input            ism_active, // SWIM is in ISM mode: the phase lines are ISM
	input            ism_action, // ISM Mode b3 (ACTION): the read/write engine runs
	                             // register traffic, not IWM drive commands
	input            ism_sel,    // ISM has THIS drive selected with Mode b7
	                             // (motor on) set — the ISM-mode motor command
	input            mfm_disk,   // this disk is MFM (use the MFM generator for fetch+bytes)
	input            mfm_hd,     // 1.44MB HD (18 spt) vs 720K DD (9 spt)
	output reg [7:0] mfm_byte,   // delivered decoded MFM byte
	output reg       mfm_mark,   // delivered byte is an address-mark (A1)
	output reg       mfm_crc0,   // delivered byte completes a valid CRC field
	output reg       mfm_stb,    // 1-cep-period delivery strobe
	// The sector whose field was passing under the head when THIS byte was
	// delivered, 1-based - the write path's positional anchor (plan section
	// 6.1). Latched with the byte, not sampled later: swim.v's staging ring
	// puts up to 16 byte-times between a delivered byte and the live head.
	output reg [4:0] mfm_sector,

	// --- ISM MFM write stream, from swim.v's ism_write_engine -------------
	input      [7:0] mfm_wr_byte,
	input            mfm_wr_mark,
	input            mfm_wr_stb,   // 1 clk per written byte
	// The anchor swim.v recovered from the staging-ring entry the CPU last
	// POPPED - i.e. the sector of the ID field the driver itself read before
	// deciding to write here. Never the live head position.
	input      [4:0] mfm_wr_anchor,
	input            mfm_wr_anchor_ok,

	// --- diagnostic ports (PFLP probes; safe to leave dangling when unused) ---
	// Ported from lbmactwo_MiSTer ac44312 (the debug deck that root-caused its
	// 800K "unreadable" bug). Counters wrap; the host reads deltas over a window.
	// dbg_byte_cnt : byte deliveries while the OS is actually reading (phases
	//                parked on RDDATA0/1 with the drive enabled).
	// dbg_miss_cnt : byte slots that expired in that same state with nothing to
	//                deliver (diskImageData empty = SDRAM refill starvation).
	output reg  [15:0] dbg_byte_cnt,
	output reg  [15:0] dbg_miss_cnt,
	output wire [7:0]  dbg_disk_image_data,  // live SDRAM-fed encoder byte
	output wire [6:0]  dbg_drive_track,
	output wire        dbg_drive_side,
	output reg  [15:0] dbg_step_cnt,         // STEP register writes committed
	output wire        dbg_byte_stb,         // 1-clk pulse: byte delivered THIS cycle
	                                         // (diskImageData is handed over AND
	                                         // cleared on this edge — sample it now)
	output wire [7:0]  dbg_raw_byte,         // pre-encoder SDRAM fetch latch (idata)
	output wire [21:0] dbg_gcr_addr,         // live GCR encoder fetch address
	// Media-change witness: one packed word for the HUD, so a failed swap on
	// hardware is attributable at a glance.
	//   [31] CSTIN reg (1 = no disk)   [30] disk_switched (1 = changed)
	//   [29] insertDisk                [28] ism_active
	//   [27:24] ejects ACCEPTED (sat)  [23:20] DskchgClear strobes (sat)
	//   [19:16] CSTIN transitions (sat, either direction)
	//   [15:8] entries into "parked on sense reg 1, enabled" (wrap)
	//   [7:0]  entries into "parked on sense reg 6, enabled" (wrap)
	output reg  [31:0] dbg_media,
	// Phase-strobe forensics: dbg_step_cnt at 0 cannot distinguish "the driver
	// never strobed a step" from "our decode rejected it". These record EVERY
	// lstrb falling edge with the address pattern presented at that edge, so
	// strb_cnt==0 means the driver never strobes, and strb_cnt>0 with
	// step_cnt==0 means we are rejecting what it sends.
	output reg  [15:0] dbg_strb_cnt,         // ALL lstrb falling edges seen
	output reg  [15:0] dbg_strb_en_cnt,      // ...of those, with _enable low
	output reg  [23:0] dbg_strb_last,        // last 4 edges, 6 bits each, newest low:
	                                         // {_enable, ca2, ca1, ca0, SEL, ism_active}
	// Latched when a PERFECTLY FORMED step is REJECTED (step pattern present
	// but _enable high). dbg_strb_last keeps only the last 4 edges, which on a
	// one-floppy machine are usually the driver idly polling the empty external
	// drive — so the mode register sampled 'now' need not be the mode in force
	// when a seek was actually dropped. This flags THAT instant.
	// [7:0] = rejected-step count (saturating), [8] = ever happened.
	output reg  [8:0]  dbg_rej_step,
	// Live drive status, so an underrun can be attributed: is the media even
	// spinning, and which term is holding it up? (2026-08-04: once the
	// drive-select fix let register writes land, MOTORON writes land too and
	// can stop the disk — mfm_spinning = mfm_disk && (motor||ism_sel) && !CSTIN.)
	output wire [7:0]  dbg_status,
	// MFM delivery-stall witness: a payload byte whose SDRAM fetch has not
	// landed stalls the byte-cell timer at zero. A real drive never stalls, so
	// any stall here is emulation artifact stretching the rotation. The GCR
	// counters above cannot see it - they count on diskDataByteTimer. Max
	// single stall (saturating) plus the number of deliveries that stalled.
	output reg  [15:0] dbg_mfm_stall_us,
	output reg  [7:0]  dbg_mfm_stall_cnt
);
	assign dbg_disk_image_data = diskImageData;
	assign dbg_drive_track     = driveTrack;
	assign dbg_drive_side      = driveSide;
	assign dbg_raw_byte        = dskReadDataLatch;
	assign dbg_gcr_addr        = gcrReadAddr;

	assign motor = ~driveRegs[`DRIVE_REG_MOTORON];
	assign dbg_status = {mfm_spinning, motor, ism_sel,
	                     driveRegs[`DRIVE_REG_MOTORON], driveSide, ism_active,
	                     ism_action, ~driveRegs[`DRIVE_REG_CSTIN]};
	assign act = lstrbEdge;

	reg [15:0] driveRegs;
	reg [6:0] driveTrack;
	reg driveSide;
	reg [7:0] diskDataIn; // incoming byte from the floppy disk
	
	// read drive registers
	// Drive-ID sense bits. Our register index = {ca2,ca1,ca0,SEL}; physically the
	// same wires as MAME's m_reg = {ss,ca2,ca1,ca0} (floppy.cpp mac_floppy::wpt_r).
	// THE OS IDENTIFIES THE DRIVE by reading sense regs 0xC,0xD,0xE,0xF and matching
	// a 4-bit pattern (wpt_r comment "Initial state of bits f-c = 2M,ready,MFM,rd1"):
	//   0000=400K GCR, 1010=800K GCR, x011=SuperDrive (x=is_2m of inserted disk).
	// ★ POLARITY (settled by the MAME 0.264 RUNTIME capture, which watched both
	// disks actually mount — findings_mame_floppy_groundtruth_2026-07-02.md §4;
	// it OVERTURNED the earlier source-reading guess that HD reports 1):
	//   is_2m = 1 -> DD disk -> the OS mounts via GCR/IWM  => SuperDrive+DD = 1011
	//   is_2m = 0 -> HD disk -> the OS mounts via MFM/ISM  => SuperDrive+HD = 0011
	// Do NOT "fix" this back; inverting it sends 800K disks down MFM and 1.44M
	// disks down GCR, and both then fail. HW-confirmed 2026-08-03: with is_2m=0
	// a 1.44M disk takes the ISM path (its dialog differs from the GCR one).
	// So we must report:
	//   reg 0xF (our [15] DRVIN)     = is_2m  = ~mfm_hd  (1 = DD disk, 0 = HD)
	//   reg 0xE (our [13] READY)     = 0      (0 = ready, Apple active-low)
	//   reg 0xD (our [11] MFMModeOn) = 1      (m_mfm dflt = has_mfm on a SuperDrive)
	//   reg 0xC (our [9]  RDDATA1)   = 1      (motor-off RdData reads 1)
	//   reg 0x5 (our [10] SUPERDR)   = 1      (the drive IS a SuperDrive)
	// Previously [9]=0 and [11]=mfm_disk, giving signature 0000(800K)/1010(1.44M) =
	// "GCR drive" -> the OS never saw a SuperDrive, never tried MFM. FIXED below.
	// See docs/findings_mame_floppy_driveid_2026-06-13.md (MAME 0.264 ground truth).
	// HW-VALIDATE: is_2m/DRVIN polarity; whether MFMModeOn must track $9/$D strobes.
	wire [15:0] driveRegsAsRead = {
		// DRVIN ($F): MAME is_2m — 1 = DD disk present, 0 = HD disk or empty.
		// (Was `mfm_hd` = 1-for-HD, INVERTED: the OS then routed 800K DD disks to
		// the MFM path and 1.44M HD disks to GCR, so BOTH failed. F3, MAME 0.264.)
		(~driveRegs[`DRIVE_REG_CSTIN] & ~mfm_hd),
		1'b0, // INSTALLED = yes
		1'b0, // READY = yes
		1'b1, // SIDES = double-sided drive
		m_mfm,    // ($B = MAME reg 0xD MFMModeOn): SuperDrive mode flag. Resets to 1
		          // (has_mfm); the $9 (MFMModeOn) strobe sets it, $D (GCRModeOn)
		          // clears it, and the OS reads it back to verify the mode switch
		          // took effect. Was constant 1, which derailed both mount paths.
		          // F4/F5, MAME 0.264.
		1'b1, // SUPERDR = yes (SuperDrive/FDHD)  (MAME reg 0x5)
		1'b1,     // RDDATA1 ($9 here = MAME reg 0xC). = 1: the other '1' in the
		          // SuperDrive identify signature x011 (motor-off RdData1 reads 1).
		1'b0, // RDDATA0
		driveRegs[`DRIVE_REG_TACH], // TACH: 60 pules for each rotation of the drive motor
		disk_switched, // SWITCHED ($6 here = MAME reg 0x3 DiskChg): 1 = media changed.
		          // Was hardwired 0 — so a host-side swap presented "the disk left
		          // and came back but nothing changed", a state no real machine
		          // produces. See the disk_switched block below.
		~(driveTrack == 7'h00), // TK0: track 0 indicator
		driveRegs[`DRIVE_REG_MOTORON], // motor on
		~writeProtect, // WRTPRT: 0 = locked, 1 = write enabled
		1'b1, // STEP = complete
		driveRegs[`DRIVE_REG_CSTIN], // disk in drive
		driveRegs[`DRIVE_REG_DIRTN] // step direction
	};

	// MFMModeOn flag (MAME m_mfm), read back as sense reg 0xD. SuperDrive powers up
	// with it SET (has_mfm); the seek-phase strobe $9 (MFMModeOn) sets it and $D
	// (GCRModeOn) clears it. Command = {SEL,ca2,ca1,ca0} latched on the LSTRB edge
	// (SEL = V8 PA5 on the LC; the same edge/phase logic serves ISM-mode Phases-
	// register strobes). The OS reads 0xD after strobing to confirm the mode. F4/F5.
	reg m_mfm;
	wire [3:0] strobeCmd = {SEL, ca2, ca1, ca0};
	always @(posedge clk or negedge _reset) begin
		if (!_reset)
			m_mfm <= 1'b1;
		else if (cep && _enable == 1'b0 && lstrbEdge == 1'b1) begin
			if (strobeCmd == 4'h9) m_mfm <= 1'b1;   // MFMModeOn
			if (strobeCmd == 4'hD) m_mfm <= 1'b0;   // GCRModeOn
		end
	end

	// SWITCHED / DiskChg flag (sense reg 6 = MAME mac_floppy reg 0x3, which
	// returns !m_dskchg). Mac drives have m_dskchg_writable, so:
	//   - reset is 0, "no change", even with an empty drive;
	//   - call_unload ASSERTS it (guest eject and host withdrawal both end
	//     there) and call_load does not touch it, so it survives the insert;
	//   - only the DskchgClear strobe ({SEL,ca2,ca1,ca0}=0xC) clears it.
	// The Sony driver polls NoDiskInPl+DiskChg as a PAIR and strobes the
	// clear itself; a CSTIN transition with this flag stuck 0 is a state no
	// real machine produces. Media removal is the FALL of insertDisk, which
	// a guest eject and a host swap both route through.
	reg disk_switched;
	reg insertDisk_d;
	always @(posedge clk or negedge _reset) begin
		if (!_reset) begin
			disk_switched <= 1'b0;
			insertDisk_d  <= 1'b0;
		end
		else if (cep) begin
			insertDisk_d <= insertDisk;
			if (insertDisk_d && !insertDisk)
				disk_switched <= 1'b1;
			else if (_enable == 1'b0 && lstrbEdge && strobeCmd == 4'hC) begin
				disk_switched <= 1'b0;
`ifdef SIMULATION
				$display("FLOPPY %m DskchgClear strobe (switched %b->0) @%0t",
				         disk_switched, $time);
`endif
			end
`ifdef SIMULATION
			if (insertDisk_d && !insertDisk)
				$display("FLOPPY %m media REMOVED -> disk_switched=1 @%0t", $time);
`endif
		end
	end

	reg dskReadAckD;
	always @(posedge clk) if(cen) dskReadAckD <= dskReadAck;

	// latch incoming data
	reg [7:0] dskReadDataLatch;
	always @(posedge clk) if(cep && dskReadAckD) dskReadDataLatch <= dskReadData;
		
	wire [7:0] dskReadDataEnc;
	wire [21:0] gcrReadAddr;   // GCR (IWM) encoder fetch addr
	wire [21:0] mfmReadAddr;   // MFM (ISM) encoder fetch addr

	reg old_newByteReady;
	always @(posedge clk) old_newByteReady <= newByteReady;

	// Format-relay nets. Declared at module level because the
	// encoder below needs them while the write path that drives them lives
	// inside the WRITE_SUPPORT generate; the no_wrpath branch ties them off.
	wire       wrRelayByte;
	wire       wrRelayMark;
	wire [3:0] wrRelayMarkSector;
	wire       wrRelayEnd;

	// GCR (IWM-mode) track encoder — 400K/800K
	floppy_track_encoder enc
	(

		.clk		( clk ),
		.ready	( ~old_newByteReady & newByteReady ),

		.rst     ( !_reset ),

		.side    ( driveSide ),
		.sides   ( doubleSidedDisk ),
		.track   ( driveTrack ),

		.addr    ( gcrReadAddr ),
		.idata   ( dskReadDataLatch ),
		.odata   ( dskReadDataEnc ),

		// format relay: the write stream as the decoder consumed it
		.wr_byte        ( wrRelayByte ),
		.wr_mark        ( wrRelayMark ),
		.wr_mark_sector ( wrRelayMarkSector ),
		.wr_end         ( wrRelayEnd )
	);

	// MFM (ISM-mode) track encoder — 720K/1.44MB. Free-runs at the byte-cell
	// rate below; shares the same SDRAM fetch latch (dskReadDataLatch) and head
	// position (driveTrack/driveSide) as the GCR path.
	wire [7:0] mfm_odata;
	wire       mfm_omark, mfm_ocrc0, mfm_needs_data, mfm_index;
	wire [4:0] mfm_osector;
	reg        mfm_ready_pulse;

	mfm_track_encoder menc
	(
		.clk    ( clk ),
		.ready  ( mfm_ready_pulse ),
		.rst    ( !_reset ),
		.side   ( driveSide ),
		.track  ( driveTrack ),
		.hd     ( mfm_hd ),
		.addr   ( mfmReadAddr ),
		.idata  ( dskReadDataLatch ),
		.odata  ( mfm_odata ),
		.omark  ( mfm_omark ),
		.osector( mfm_osector ),
		.ocrc0  ( mfm_ocrc0 ),
		.oneeds ( mfm_needs_data ),
		.oindex ( mfm_index )
	);

	// ---- MFM byte-cell delivery timer -----------------------------------
	// HD MFM = 500 kbit/s = 16 us/byte = 130 cep ticks @8.125 MHz; DD = 260.
	// Payload bytes (oneeds) additionally wait for a post-advance SDRAM fetch:
	// mfm_fresh means idata belongs to the encoder's CURRENT addr. One ack is
	// skipped after each advance so an in-flight pre-advance ack can't hand us
	// the previous byte's data. The internal-drive extra slot acks every ~2 us,
	// so a stall only stretches the odd byte (the driver is poll-driven).
	// The motor runs if EITHER path commanded it. In IWM mode that is the
	// MOTORON drive register (an LSTRB strobe); in ISM mode the driver spins the
	// drive with **Mode register bit 7 = motor on** (swim_ism_read_reference.md
	// §B) and need never touch MOTORON — so keying spinning on MOTORON alone
	// left the byte engine parked for the whole MFM session, the FIFO never
	// filled, Handshake b7 never set, and the driver saw an empty disk.
	wire       mfm_spinning = mfm_disk && (motor || ism_sel) &&
	                          ~driveRegs[`DRIVE_REG_CSTIN];
	// Byte cadence in cep ticks: 129 = 16us (HD), 259 = 32us (DD) at 8.125MHz.
	// Parameterised ONLY so a bench can shrink a revolution from ~4.3M clocks
	// to something it can run in seconds; the defaults are the real medium and
	// no synthesised instance overrides them. Same technique as
	// floppy_sd.v's ACK_TIMEOUT_BITS.
	wire [8:0] mfm_period   = mfm_hd ? MFM_PERIOD_HD : MFM_PERIOD_DD;
	reg  [8:0] mfm_timer;
	reg        mfm_fresh;
	reg        mfm_ack_skip;
	always @(posedge clk or negedge _reset) begin
		if (_reset == 1'b0) begin
			mfm_timer       <= 9'd0;
			mfm_fresh       <= 1'b0;
			mfm_ack_skip    <= 1'b0;
			mfm_ready_pulse <= 1'b0;
			mfm_stb         <= 1'b0;
			mfm_byte        <= 8'h00;
			mfm_mark        <= 1'b0;
			mfm_sector      <= 5'd1;
			mfm_crc0        <= 1'b0;
		end else begin
			mfm_ready_pulse <= 1'b0;   // 1-clk advance pulse to the encoder
			if (cep) begin
				mfm_stb <= 1'b0;
				// idata freshness: the fetch latch lands on cep && dskReadAckD
				if (dskReadAckD) begin
					if (mfm_ack_skip) mfm_ack_skip <= 1'b0;
					else              mfm_fresh    <= 1'b1;
				end
				if (!mfm_spinning) begin
					mfm_timer <= mfm_period;
				end
				else if (mfm_timer != 0) begin
					mfm_timer <= mfm_timer - 9'd1;
				end
				else if (!mfm_needs_data || mfm_fresh) begin
					// deliver the current byte, then advance the encoder
					mfm_byte        <= mfm_odata;
					mfm_mark        <= mfm_omark;
					mfm_crc0        <= mfm_ocrc0;
					mfm_sector      <= mfm_osector;
					mfm_stb         <= 1'b1;
					mfm_ready_pulse <= 1'b1;
					mfm_fresh       <= 1'b0;
					mfm_ack_skip    <= 1'b1;
					mfm_timer       <= mfm_period;
				end
				// else: payload byte not fetched yet — stall until an ack lands
			end
		end
	end

	// --- MFM delivery-stall witness (see the port comment). Own always block
	// (Quartus single-driver law); observation-only. ~1 us = 8 cep ticks at
	// 8.125 MHz. dbg_mfm_stall_cnt increments when a stall crosses ~1 us so
	// sub-us fetch latency (the normal case) is not counted.
	wire mfm_stalled = mfm_spinning && (mfm_timer == 9'd0) &&
	                   mfm_needs_data && !mfm_fresh;
	reg [2:0]  mfm_stall_pre;
	reg [15:0] mfm_stall_run;
	always @(posedge clk or negedge _reset) begin
		if (_reset == 1'b0) begin
			mfm_stall_pre    <= 3'd0;
			mfm_stall_run    <= 16'd0;
			dbg_mfm_stall_us  <= 16'd0;
			dbg_mfm_stall_cnt <= 8'd0;
		end
		else if (cep) begin
			if (mfm_stalled) begin
				mfm_stall_pre <= mfm_stall_pre + 3'd1;
				if (mfm_stall_pre == 3'd7 && mfm_stall_run != 16'hFFFF) begin
					mfm_stall_run <= mfm_stall_run + 16'd1;
					if (mfm_stall_run == 16'd0 && dbg_mfm_stall_cnt != 8'hFF)
						dbg_mfm_stall_cnt <= dbg_mfm_stall_cnt + 8'd1;
					if (mfm_stall_run >= dbg_mfm_stall_us)
						dbg_mfm_stall_us <= mfm_stall_run + 16'd1;
				end
			end
			else begin
				mfm_stall_pre <= 3'd0;
				mfm_stall_run <= 16'd0;
			end
		end
	end

`ifdef SIMULATION
	// --- MFM/ISM protocol trace (diff against the MAME 0.264 runtime capture,
	// scratch/mame_floppy_0702/decoded_1440k_v3.txt) ---
	reg [13:0] dbgsim_strobe_cnt = 0;
	reg [13:0] dbgsim_dlv_cnt = 0;
	reg        dbgsim_spin_d = 0;
	reg        dbgsim_idx_d = 0;
	// Sense-register reads, run-length compressed on (addr,value): the driver
	// polls one register thousands of times (e.g. NoReady until 0), so only
	// transitions are interesting. Compare with the MAME capture's SENSE TRUTH
	// TABLE. Our index is {ca2,ca1,ca0,SEL}; MAME's is {ss,ca2,ca1,ca0}.
	reg [3:0]  dbgsim_sns_addr = 4'hF;
	reg        dbgsim_sns_val = 1'b1;
	reg [15:0] dbgsim_sns_rpt = 0;
	reg [11:0] dbgsim_sns_cnt = 0;
	wire       dbgsim_sns_now = readData[7];
	always @(posedge clk) begin
		if (cep && _enable == 1'b0) begin
			if (driveReadAddr != dbgsim_sns_addr || dbgsim_sns_now != dbgsim_sns_val) begin
				if (dbgsim_sns_cnt < 12'd800) begin
					dbgsim_sns_cnt <= dbgsim_sns_cnt + 1'd1;
					$display("FLOPPY %m sense[%x]=%b (prev[%x]=%b x%0d) SEL=%b @%0t",
					         driveReadAddr, dbgsim_sns_now, dbgsim_sns_addr,
					         dbgsim_sns_val, dbgsim_sns_rpt, SEL, $time);
				end
				dbgsim_sns_addr <= driveReadAddr;
				dbgsim_sns_val  <= dbgsim_sns_now;
				dbgsim_sns_rpt  <= 16'd1;
			end else if (dbgsim_sns_rpt != 16'hFFFF)
				dbgsim_sns_rpt <= dbgsim_sns_rpt + 1'd1;
		end
	end
	always @(posedge clk) begin
		if (cep && _enable == 1'b0 && lstrbEdge && dbgsim_strobe_cnt < 14'd8000) begin
			dbgsim_strobe_cnt <= dbgsim_strobe_cnt + 1'd1;
			$display("FLOPPY %m strobe(fall) cmd=%x track=%0d mfm=%b motor(reg)=%b @%0t",
			         {SEL, ca2, ca1, ca0}, driveTrack, m_mfm, driveRegs[`DRIVE_REG_MOTORON], $time);
		end
		// MAME latches the command on the LSTRB RISING edge; we act on falling.
		// Log both so a mid-pulse SEL/phase change shows up as a cmd mismatch.
		if (cep && _enable == 1'b0 && lstrb && !lstrbPrev && dbgsim_strobe_cnt < 14'd8000)
			$display("FLOPPY %m strobe(rise) cmd=%x track=%0d @%0t",
			         {SEL, ca2, ca1, ca0}, driveTrack, $time);
		if (cep) begin
			dbgsim_spin_d <= mfm_spinning;
			if (mfm_spinning != dbgsim_spin_d)
				$display("FLOPPY %m mfm_spinning -> %b (motor=%b ism_sel=%b cstin=%b) trk=%0d side=%b @%0t",
				         mfm_spinning, motor, ism_sel, driveRegs[`DRIVE_REG_CSTIN], driveTrack, driveSide, $time);
			dbgsim_idx_d <= mfm_index;
			if (mfm_spinning && mfm_index && !dbgsim_idx_d)
				$display("FLOPPY %m index pulse trk=%0d side=%b @%0t", driveTrack, driveSide, $time);
			if (mfm_stb && dbgsim_dlv_cnt < 14'd8000) begin
				dbgsim_dlv_cnt <= dbgsim_dlv_cnt + 1'd1;
				$display("FLOPPY %m mfm dlv %02x m=%b c0=%b trk=%0d side=%b needs=%b addr=%0d latch=%02x @%0t",
				         mfm_byte, mfm_mark, mfm_crc0, driveTrack, driveSide,
				         mfm_needs_data, mfmReadAddr, dskReadDataLatch, $time);
			end
		end
	end
`endif

	// SDRAM fetch address: the MFM generator for MFM disks, else the GCR encoder.
	assign dskReadAddr = mfm_disk ? mfmReadAddr : gcrReadAddr;

	// MFM index sense. On a SuperDrive with an MFM disk, sense regs 0x4/0xC
	// (RdData0/1) read the index: 1 with motor off / no disk, else !idx (MAME
	// mac_floppy wpt_r). The MAME 0.264 runtime capture shows the Sony driver
	// polling this 7M times during the MFM session (through ISM Handshake bit3
	// with phases parked on RdData) with 0.70% of reads low — the once-per-rev
	// index pulse that bounds its sector searches. The GCR byte-stream register
	// must NOT appear here for MFM disks (its GCR alphabet is MSB-set, which
	// reads as a permanent "no index" 1).
	wire mfm_idx_sense = mfm_spinning ? ~mfm_index : 1'b1;
	
	// Double-sided = drive mechanism AND file size AND the medium. Ported from
	// MacPlus floppy.v; the drive term is a constant here, as the LC has a
	// SuperDrive and nothing else. Three ceilings, each load-bearing:
	//   - the file must be big enough to hold two sides (diskSides);
	//   - WITHIN a session the format byte of the last address field the
	//     write path decoded wins, since a One-Sided erase has just made the
	//     disk single-sided and no remount has happened;
	//   - ACROSS a remount the medium's own volume header decides
	//     (mediaSides), because fmtSeen is gone and the file is still its
	//     original size.
	// Without the last term a One-Sided erase of an 800K image comes back
	// advertised double-sided and the driver builds an 800K volume over a
	// side that was never formatted.
	// DECLARED HERE, DRIVEN BELOW: the encoder above needs this net, but the
	// format-byte latch that feeds it needs signals declared further down.
	wire doubleSidedDisk;
	
	wire [3:0] driveReadAddr = {ca2,ca1,ca0,SEL};
	
	// a byte is read or written every 128 clocks (2 us per bit * 8 bits = 16 us, @ 8 MHz = 128 clocks)
	// The CPU must poll for data at least this often, or else an overrun will occur.
	reg [6:0] diskDataByteTimer; 
	reg [7:0] diskImageData;	
	reg readyToAdvanceHead;
	always @(posedge clk or negedge _reset) begin
		if (_reset == 0) begin		
			driveSide <= 0;
			diskImageData <= 8'h00;
			diskDataIn <= 8'hFF;
			diskDataByteTimer <= 0;
			readyToAdvanceHead <= 1;
			newByteReady <= 1'b0;
		end 
		else begin			
			if(cep) begin
			// at time 0, latch a new byte and advance the drive head
			if (diskDataByteTimer == 0 && readyToAdvanceHead && diskImageData != 0) begin
				diskDataIn <= diskImageData;
				newByteReady <= 1;
				diskDataByteTimer <= 1;  // make timer run again

				// clear diskImageData after it's used, so we can tell when we get a new one from the disk
				diskImageData <= 0;

				// for debugging, don't advance the head until the IWM says it's ready
				readyToAdvanceHead <= 1'b1; // TEMP: treat IWM as always ready
			end

			// extraRomReadAck comes every hsync which is every 21us. The iwm data rates
			// is 8MHZ/128 = 16us
			else begin
				// a timer governs when the next disk byte will become available
				diskDataByteTimer <= diskDataByteTimer + 1'b1;

				newByteReady <= 1'b0;

				if (dskReadAck) begin
					// whenever ACK is received, store the data from the current diskImageAddr
					diskImageData <= dskReadDataEnc;  // xyz
 				end

				if (advanceDriveHead) begin
					readyToAdvanceHead <= 1'b1;
				end
			end

			// Head (side) select - the RDDATA0/RDDATA1 sense address.
			// IWM/GCR: latch continuously while the address is parked there,
			// since the phase lines are dedicated to the sense address during
			// GCR reads. ISM: the SAME lines double as drive-command strobes
			// and SEL doubles as the strobe-bank selector, so transient
			// combinations lie about the head - a re-init that raises SEL for a
			// strobe while the phases still park on F4 reads as RdData1 and
			// flips the head to side 1. In ISM, sample the head only while
			// ACTION is set: the driver parks F4/SEL before arming and never
			// touches them mid-read.
			if (ism_active ? ism_action : 1'b1) begin
				if (driveReadAddr == `DRIVE_REG_RDDATA0 && lstrb == 1'b0) begin
`ifdef SIMULATION
					if (driveSide != 1'b0)
						$display("FLOPPY %m driveSide 1->0 (ism=%b act=%b) @%0t", ism_active, ism_action, $time);
`endif
					driveSide <= 0;
				end
				if (driveReadAddr == `DRIVE_REG_RDDATA1 && lstrb == 1'b0) begin
`ifdef SIMULATION
					if (driveSide != 1'b1)
						$display("FLOPPY %m driveSide 0->1 (ism=%b act=%b) @%0t", ism_active, ism_action, $time);
`endif
					driveSide <= 1;
				end
			end
		end
	end
	end

	// --- diagnostic counters (PFLP probes) --------------------------------
	// Count only while the CPU is positioned to consume data (phases parked on
	// RDDATA0/1, drive enabled): dbg_byte_cnt = a byte was delivered on the
	// 128-clock slot boundary; dbg_miss_cnt = the slot boundary passed with
	// diskImageData still empty (the SDRAM extra-slot refill starved) or
	// delivery otherwise blocked. Healthy read: byte_cnt climbs at ~63 kB/s,
	// miss_cnt static. Observation-only — the delivery path is untouched.
	wire dbg_read_sel = (driveReadAddr == `DRIVE_REG_RDDATA0 ||
	                     driveReadAddr == `DRIVE_REG_RDDATA1) && (_enable == 1'b0);
	// Same-cycle delivery strobe for the MacLC.sv byte-capture ring: identical
	// qualification to the dbg_byte_cnt increment below. Must be consumed on
	// THIS clk edge — the delivery block latches diskImageData into diskDataIn
	// and zeroes it on the same edge, so one cycle later the byte is gone.
	assign dbg_byte_stb = cep && diskDataByteTimer == 0 && dbg_read_sel &&
	                      readyToAdvanceHead && (diskImageData != 0);
	always @(posedge clk or negedge _reset) begin
		if (_reset == 1'b0) begin
			dbg_byte_cnt <= 16'd0;
			dbg_miss_cnt <= 16'd0;
		end
		else if (cep && diskDataByteTimer == 0 && dbg_read_sel) begin
			if (readyToAdvanceHead && diskImageData != 0)
				dbg_byte_cnt <= dbg_byte_cnt + 16'd1;
			else
				dbg_miss_cnt <= dbg_miss_cnt + 16'd1;
		end
	end

	// create a signal on the falling edge of lstrb
	reg lstrbPrev;
	always @(posedge clk) if(cep) lstrbPrev <= lstrb;

	wire lstrbEdge = lstrb == 1'b0 && lstrbPrev == 1'b1;

	// Unconditional strobe recorder — see the dbg_strb_* port comments. Note
	// this samples the SAME lstrbEdge the register writes use, so a zero count
	// here also exonerates the edge detector itself.
	always @(posedge clk or negedge _reset) begin
		if (_reset == 1'b0) begin
			dbg_strb_cnt    <= 16'd0;
			dbg_strb_en_cnt <= 16'd0;
			dbg_strb_last   <= 24'd0;
			dbg_rej_step    <= 9'd0;
		end else if (cep && lstrbEdge) begin
			if (_enable == 1'b1 && ca2 == 1'b0 &&
			    {ca1, ca0, SEL} == `DRIVE_REG_STEP) begin
				dbg_rej_step[8] <= 1'b1;
				if (dbg_rej_step[7:0] != 8'hFF)
					dbg_rej_step[7:0] <= dbg_rej_step[7:0] + 8'd1;
			end
			if (dbg_strb_cnt != 16'hFFFF) dbg_strb_cnt <= dbg_strb_cnt + 16'd1;
			if (_enable == 1'b0 && dbg_strb_en_cnt != 16'hFFFF)
				dbg_strb_en_cnt <= dbg_strb_en_cnt + 16'd1;
			dbg_strb_last <= {dbg_strb_last[17:0],
			                  _enable, ca2, ca1, ca0, SEL, ism_active};
		end
	end

	// Media-change witness (see the dbg_media port comment). Observation-only,
	// own always block (Quartus single-driver law). The park counters count
	// ENTRIES into "phases parked on that sense register with the drive
	// enabled" — one per driver poll — because the parked state itself is a
	// level held across thousands of cycles.
	wire dbg_park1 = (_enable == 1'b0) && (driveReadAddr == `DRIVE_REG_CSTIN);
	wire dbg_park6 = (_enable == 1'b0) && (driveReadAddr == `DRIVE_REG_EJECT);
	reg  dbg_park1_d, dbg_park6_d, dbg_cstin_d;
	always @(posedge clk or negedge _reset) begin
		if (_reset == 1'b0) begin
			dbg_media   <= 32'd0;
			dbg_park1_d <= 1'b0;
			dbg_park6_d <= 1'b0;
			dbg_cstin_d <= 1'b1;
		end
		else if (cep) begin
			dbg_media[31] <= driveRegs[`DRIVE_REG_CSTIN];
			dbg_media[30] <= disk_switched;
			dbg_media[29] <= insertDisk;
			dbg_media[28] <= ism_active;
			dbg_park1_d <= dbg_park1;
			dbg_park6_d <= dbg_park6;
			dbg_cstin_d <= driveRegs[`DRIVE_REG_CSTIN];
			if (_enable == 1'b0 && (!ism_active || ism_sel) && lstrbEdge &&
			    driveWriteAddr == `DRIVE_REG_EJECT && ca2 == 1'b1 &&
			    dbg_media[27:24] != 4'hF)
				dbg_media[27:24] <= dbg_media[27:24] + 4'd1;
			if (_enable == 1'b0 && lstrbEdge && strobeCmd == 4'hC &&
			    dbg_media[23:20] != 4'hF)
				dbg_media[23:20] <= dbg_media[23:20] + 4'd1;
			if (dbg_cstin_d != driveRegs[`DRIVE_REG_CSTIN] &&
			    dbg_media[19:16] != 4'hF)
				dbg_media[19:16] <= dbg_media[19:16] + 4'd1;
			if (dbg_park1 && !dbg_park1_d)
				dbg_media[15:8] <= dbg_media[15:8] + 8'd1;
			if (dbg_park6 && !dbg_park6_d)
				dbg_media[7:0] <= dbg_media[7:0] + 8'd1;
		end
	end

	assign readData = _enable ? 8'hFF :
	                  (driveReadAddr == `DRIVE_REG_RDDATA0 || driveReadAddr == `DRIVE_REG_RDDATA1) ?
	                      (mfm_disk ? {mfm_idx_sense, 7'h00} : diskDataIn) :
							{ driveRegsAsRead[driveReadAddr], 7'h00 };
		
	// write drive registers
	wire [2:0] driveWriteAddr = {ca1,ca0,SEL};

	generate
	if (WRITE_SUPPORT) begin : wrpath

	// ================================================================
	// GCR write path. Ported from MacPlus_MiSTer rtl/floppy.v; the LC-specific
	// parts are marked below. It lives here, below driveWriteAddr/lstrbEdge,
	// because it reads them.
	//
	// The CPU hands over one byte at a time through the IWM data register. We
	// pace those bytes at the SAME 128-cep byte time the read side uses
	// (diskDataByteTimer, further up), then present each one to
	// floppy_track_decoder. A checksum-valid sector appears on the contract
	// tuple (wrSecValid / wrSecNum / wrSecAddr).
	//
	// writeUnderrun is raised ONLY for a byte abandoned by deselect. It is not
	// a general error flag: reporting an underrun the ROM did not cause is a
	// good way to make it retry forever.
	reg        writeBusyReg;
	reg [6:0]  writeByteTimer;
	reg [7:0]  pendingWriteByte;
	reg        writeUnderrunReg;
	reg        decReady;

	assign writeBusy     = writeBusyReg;
	assign writeUnderrun = writeUnderrunReg;

	// Any disk change resets the write path, so a half-decoded field cannot
	// complete using the NEXT image's bytes and commit itself to the wrong
	// disk. insertDisk is a level; both
	// its edges matter -- it drops at img_mounted and rises at the loader's
	// done. Reset to a constant 1: a non-constant async-reset value makes
	// Quartus infer a latch.
	reg insertDiskPrev;
	always @(posedge clk or negedge _reset)
		if (!_reset)   insertDiskPrev <= 1'b1;
		else if (cep)  insertDiskPrev <= insertDisk;
	wire insertDiskEdge = insertDisk && !insertDiskPrev;
	wire insertDiskFall = !insertDisk && insertDiskPrev;

	// ★ LC-SPECIFIC: the eject condition carries the (!ism_active || ism_sel)
	// qualifier that the media-change work landed on 2026-08-06. Without it the
	// ROM's register walks -- which run with Mode b7 clear -- look like ejects.
	// Keep this in step with the real eject block further down.
	wire ejectPulse = cep && _enable == 1'b0 && (!ism_active || ism_sel) &&
	                  lstrbEdge == 1'b1 &&
	                  driveWriteAddr == `DRIVE_REG_EJECT && ca2 == 1'b1;

	wire writePathReset = ejectPulse || (cep && (insertDiskEdge || insertDiskFall));

	always @(posedge clk or negedge _reset) begin
		if (_reset == 1'b0) begin
			writeBusyReg     <= 1'b0;
			writeByteTimer   <= 7'd0;
			pendingWriteByte <= 8'd0;
			writeUnderrunReg <= 1'b0;
			decReady         <= 1'b0;
		end else if (writePathReset) begin
			// abandon any in-flight write byte
			writeBusyReg     <= 1'b0;
			writeByteTimer   <= 7'd0;
			decReady         <= 1'b0;
		end else begin
			decReady <= 1'b0; // default; pulsed for exactly one cep below

			// byte pacing runs on the same clk8 cadence as diskDataByteTimer
			if (cep && writeBusyReg) begin
				if (_enable == 1'b1) begin
					// drive deselected mid-byte: it never reached the media
					writeBusyReg     <= 1'b0;
					writeUnderrunReg <= 1'b1;
				end else if (writeByteTimer == 7'd127) begin
					writeBusyReg <= 1'b0;
					decReady     <= 1'b1; // hand this byte to the decoder now
				end else begin
					writeByteTimer <= writeByteTimer + 1'b1;
				end
			end

			// A byte is accepted when the IWM registers one for this drive. cen
			// and cep never coincide, so this cannot race the pacing above.
			// CSTIN as well as insertDisk: CSTIN is set by an OS eject and is
			// NOT cleared by a remount, so it is the guest's view of "no disk".
			if (writeReq && _enable == 1'b0 && !writeProtect && !writeBusyReg &&
			    !driveRegs[`DRIVE_REG_CSTIN] && insertDisk) begin
				pendingWriteByte <= writeData;
				writeBusyReg     <= 1'b1;
				writeByteTimer   <= 7'd0;
				writeUnderrunReg <= 1'b0;
			end
		end
	end

	// ── the write as a whole, for the encoder's format relay ──
	// Ported verbatim from MacPlus floppy.v:280-294. wrEnd is delayed TWO
	// clocks so the encoder has seen the last address mark of the format
	// before the end arrives; that delay is part of the donor, not slack.
	reg  wrBusyPrev, wrEndD1;
	reg  wrEnd;
	wire wrBusy = (writeMode && _enable == 1'b0) || writeBusyReg;
	always @(posedge clk or negedge _reset) begin
		if (_reset == 1'b0) begin
			wrBusyPrev <= 1'b0;
			wrEndD1    <= 1'b0;
			wrEnd      <= 1'b0;
		end else begin
			if (cep) wrBusyPrev <= wrBusy;
			wrEndD1 <= (cep && wrBusyPrev && !wrBusy) || writePathReset;
			wrEnd   <= wrEndD1;
		end
	end

	wire wrSecAmark, wrSecFmtMark, wrSecFmtDs;
	wire [3:0] wrSecAmarkSector;
	wire [8:0] wrBufAddr;          // driven by the committer below

	// The relay's view of the write, published to the encoder outside this
	// generate. decReady is the byte the decoder consumed; the marks are the
	// GCR decoder's report of the address field that byte completed.
	assign wrRelayByte       = decReady;
	assign wrRelayMark       = wrSecAmark;
	assign wrRelayMarkSector = wrSecAmarkSector;
	assign wrRelayEnd        = wrEnd;

	// The sidedness ceiling declared above.
	reg fmtSeen;  // an address field's format byte has been seen since the mount
	reg fmtDs;
	always @(posedge clk) begin
		// cleared on the same eject/mount events as the decoder
		if (!_reset || writePathReset) begin
			fmtSeen <= 1'b0;
			fmtDs   <= 1'b0;
		end
		else if (wrSecFmtMark) begin
			fmtSeen <= 1'b1;
			fmtDs   <= wrSecFmtDs;
		end
	end

	assign doubleSidedDisk = diskSides && (fmtSeen ? fmtDs : mediaSides);

	// ── TWO DECODERS, ONE COMMITTER ───────────────────────────────
	// A drive's medium is GCR or MFM, never both at once, so the two decoders
	// are muxed into the single committer rather than duplicated. That the
	// committer is format-neutral is the Phase 3 carve-out paying off: it sees
	// a 22-bit image byte offset and a 512-byte read port and never learns
	// which encoding produced them.
	wire        gcrSecValid, mfmSecValid;
	wire  [3:0] gcrSecNum;
	wire  [4:0] mfmSecNum;
	wire [21:0] gcrSecAddr,  mfmSecAddr;
	wire  [7:0] gcrBufData,  mfmBufData;
	wire        gcrSecReject, mfmSecReject;

	wire        wrIsMfm   = mfm_disk;
	wire        wrSecValidMux = wrIsMfm ? mfmSecValid : gcrSecValid;
	wire [21:0] wrSecAddrMux  = wrIsMfm ? mfmSecAddr  : gcrSecAddr;
	wire  [7:0] wrBufData     = wrIsMfm ? mfmBufData  : gcrBufData;

	assign wrSecValid = wrSecValidMux;
	assign wrSecAddr  = wrSecAddrMux;
	assign wrSecNum   = wrIsMfm ? mfmSecNum : {1'b0, gcrSecNum};
	wire        wrSecReject   = wrIsMfm ? mfmSecReject : gcrSecReject;

	// ── the MFM write decoder ───────────────────────
	// Fed by swim.v's ism_write_engine. `track`/`side` are the PHYSICAL head
	// position and are what build the address; only the sector number comes
	// from the stream's own ID field or, failing that, the anchor.
	mfm_write_decoder mdec
	(
		.clk           ( clk ),
		.rst           ( !_reset || writePathReset ),

		.ready         ( mfm_wr_stb ),
		.idata         ( mfm_wr_byte ),
		.imark         ( mfm_wr_mark ),

		.side          ( driveSide ),
		.track         ( driveTrack ),
		.hd            ( mfm_hd ),

		.anchor_sector ( mfm_wr_anchor ),
		.anchor_valid  ( mfm_wr_anchor_ok ),

		.sector_valid  ( mfmSecValid ),
		.sector        ( mfmSecNum ),
		.addr          ( mfmSecAddr ),
		.reject        ( mfmSecReject ),

		.amark         (  ),
		.amark_sector  (  ),
		.amark_cyl     (  ),
		.amark_head    (  ),

		.buf_addr      ( wrBufAddr ),
		.buf_data      ( mfmBufData )
	);

	floppy_track_decoder dec
	(
		.clk          ( clk ),
		.ready        ( decReady ),
		.rst          ( !_reset || writePathReset ),

		.side         ( driveSide ),
		.sides        ( doubleSidedDisk ),
		.track        ( driveTrack ),

		.idata        ( pendingWriteByte ),

		.sector_valid ( gcrSecValid ),
		.sector       ( gcrSecNum ),
		.addr         ( gcrSecAddr ),
		.reject       ( gcrSecReject ),
		.amark        ( wrSecAmark ),
		.amark_sector ( wrSecAmarkSector ),
		.fmt_mark     ( wrSecFmtMark ),
		.fmt_ds       ( wrSecFmtDs ),

		.buf_addr     ( wrBufAddr ),
		.buf_data     ( gcrBufData )
	);

	// Declared before the instance that reads them. Style, not a fix -- see the
	// correction above the write path: a forward reference to a net declared
	// later in the same module resolves correctly.
	wire        wrCommitBusy;

	// ── Commit a verified sector to the SDRAM image ──────────────
	// Volatile ONLY: this reaches SDRAM, never the SD card. The guest's own
	// read-after-write verify is what makes that useful -- and it is also the
	// gate, because a Finder copy completes only if every sector decoded
	// byte-exactly (sector number, address, and all 512 payload bytes).
	floppy_write_committer wc
	(
		.clk            ( clk ),
		.rst            ( !_reset || writePathReset ),

		.sector_valid   ( wrSecValidMux ),
		.sector_addr    ( wrSecAddrMux ),
		.buf_addr       ( wrBufAddr ),
		.buf_data       ( wrBufData ),

		.wr_addr        ( wrSdAddr ),
		.wr_data        ( wrSdData ),
		.wr_req         ( wrSdReq ),
		.wr_ack         ( wrSdAck ),

		.busy           ( wrCommitBusy ),
		.done           ( wrCommitDone ),
		.committed_addr ( wrCommitAddr ),

		.sd_buf_addr    ( wrSdBufAddr ),
		.sd_buf_data    ( wrSdBufData ),
		.sd_buf_wr      ( wrSdBufWr )
	);

	// ── Write-path cone anchor ──────────────────────────────────────────────
	// Probes-off fits of this netlist have corrupted the floppy path on
	// hardware while STA passed, and the fix was to keep the cone loaded in
	// every build; the same applies to the write cone. Never remove, ifdef
	// or XOR-fold these - a reduction lets synthesis restructure the very
	// cone the anchor exists to pin.
	reg [7:0] wr_sec_cnt, wr_rej_cnt;
	always @(posedge clk or negedge _reset) begin
		if (!_reset) begin
			wr_sec_cnt <= 8'd0;
			wr_rej_cnt <= 8'd0;
		end else begin
			if (wrSecValid)    wr_sec_cnt <= wr_sec_cnt + 8'd1;
			if (wrSecReject)   wr_rej_cnt <= wr_rej_cnt + 8'd1;
		end
	end

	// Widths are spelled out per field so a later edit cannot silently truncate
	// one: each word must total exactly 32.
	(* preserve, noprune *) reg [31:0] wr_anchor0, wr_anchor1, wr_anchor2;
	always @(posedge clk) begin
		// ★ wrSecNum WIDENED 4 -> 5 for MFM (sectors 1..18; GCR needs only
		// 0..11), so a bit had to come from somewhere or this word would be
		// 33 bits and Quartus would drop the TOP one - silently corrupting
		// wr_sec_cnt in the JTAG probe. The reject counter gives it up: it is
		// a saturating-ish witness read for "is this nonzero and climbing",
		// not an exact total, so 7 bits (0..127) says the same thing. Caught
		// by Warning 10230 and by this block's own rule, one line above.
		//  8 + 7 + 5 + 1+1+1+1 + 1 + 7 = 32
		wr_anchor0 <= {wr_sec_cnt, wr_rej_cnt[6:0], wrSecNum,
		               writeBusyReg, writeUnderrunReg, writeProtect, insertDisk,
		               driveSide, driveTrack[6:0]};
		//  2 + 1+1+1+1 + 4 + 22 = 32
		wr_anchor1 <= {2'b0, wrSecValid, wrSecAmark, wrSecFmtMark, wrSecFmtDs,
		               wrSecAmarkSector, wrSecAddr};
		// the committer's own cone: its drain state and where it last landed.
		//  1 + 1 + 8 + 22 = 32
		wr_anchor2 <= {wrCommitBusy, wrCommitDone, wrBufData, wrCommitAddr};
	end

	end else begin : no_wrpath
		// Everything above is absent. The drive still answers every
		// register identically -- WRTPRT reads locked because
		// writeProtect is tied high for this instance -- it simply has
		// no machinery to accept a byte it could never accept anyway.
		assign writeBusy     = 1'b0;   // -> _iwmBusy reads 1, "buffer empty"
		assign writeUnderrun = 1'b0;   // -> _writeUnderrun reads 1, "no underrun"
		assign wrSecValid    = 1'b0;
		assign wrSecNum      = 4'd0;
		assign wrSecAddr     = 22'd0;
		assign wrSdAddr      = 22'd0;
		assign wrSdData      = 16'd0;
		assign wrSdReq       = 1'b0;
		assign wrCommitDone  = 1'b0;
		assign wrCommitAddr  = 22'd0;
		assign wrSdBufAddr   = 8'd0;
		assign wrSdBufData   = 16'd0;
		assign wrSdBufWr     = 1'b0;
		// The sidedness ceiling minus its format-byte term: with no write path
		// no address field can ever be decoded here, so this is exactly what
		// the other branch computes with fmtSeen low.
		assign doubleSidedDisk = diskSides && mediaSides;
		// ...and no write means nothing for the encoder's format relay.
		assign wrRelayByte       = 1'b0;
		assign wrRelayMark       = 1'b0;
		assign wrRelayMarkSector = 4'd0;
		assign wrRelayEnd        = 1'b0;
	end
	endgenerate

	
	// DRIVE_REG_DIRTN		0  /* R/W: step direction (0=toward track 79, 1=toward track 0) */
	always @(posedge clk or negedge _reset) begin
		if (_reset == 1'b0) begin		
			driveRegs[`DRIVE_REG_DIRTN] <= 1'b0;
		end 
		else if(cep && _enable == 1'b0 && lstrbEdge == 1'b1 && driveWriteAddr == `DRIVE_REG_DIRTN) begin
			driveRegs[`DRIVE_REG_DIRTN] <= ca2;
		end
	end


	// DRIVE_REG_CSTIN		1  /* R: disk in place (1 = no disk) */
										/* W: ?? reset disk switch flag ? */
	// disk in drive indicators
	reg [23:0] ejectIndicatorTimer;
	assign diskEject = (ejectIndicatorTimer != 0);
	
	always @(posedge clk or negedge _reset) begin
		if (_reset == 1'b0) begin
			driveRegs[`DRIVE_REG_CSTIN] <= 1'b1;
			ejectIndicatorTimer <= 24'd0;
		end
		else if(cep) begin
			// EJECT decode. In IWM mode this is the classic soft-switch strobe.
			// In ISM mode the Phases register drives the SAME ca0-2/LSTRB lines
			// and the ROM's register walks pass through $FF, whose falling edge
			// would decode here as EJECT+ca2 and eject the image on every mount.
			// A blanket !ism_active gate fixed that but made the guest
			// structurally unable to eject an MFM disk, which an installer's
			// disk swap needs. It is now qualified the way MAME forwards phase
			// strobes to a drive at all: only when the ISM has this drive
			// devsel'd. Real drive commands arrive with ism_sel HIGH while the
			// register walks run with Mode b7 CLEAR, so genuine ejects pass and
			// every walk is still blocked.
			if (_enable == 1'b0 && (!ism_active || ism_sel) && lstrbEdge == 1'b1 && driveWriteAddr == `DRIVE_REG_EJECT && ca2 == 1'b1) begin
				// eject the disk
				driveRegs[`DRIVE_REG_CSTIN] <= 1'b1;
				ejectIndicatorTimer <= 24'hFFFFFF;
`ifdef SIMULATION
				$display("FLOPPY %m EJECT accepted (ism=%b sel=%b) @%0t",
				         ism_active, ism_sel, $time);
`endif
			end
			else begin
				// CSTIN simply REPORTS what the host has mounted. It used to be
				// `else if (insertDisk) CSTIN <= 0;` with no else, so an insert
				// LATCHED the line low and only a guest EJECT strobe could raise
				// it: when the host withdrew the media the drive kept claiming a
				// disk was present, the guest never ran its unmount machinery,
				// and it held the previous volume's VCB over different SDRAM.
				// Eject still works - the strobe branch forces the line high and
				// MacLC.sv clears the mount flags while diskEject is asserted, so
				// insertDisk is low before the next cep evaluates this.
				driveRegs[`DRIVE_REG_CSTIN] <= ~insertDisk;
				if (ejectIndicatorTimer != 0)
					ejectIndicatorTimer <= ejectIndicatorTimer - 1'b1;
			end
		end
	end
									
	//`define DRIVE_REG_STEP		2  /* R: drive head stepping (1 = complete) */
												/* W: 0 = step drive head */
	always @(posedge clk or negedge _reset) begin
		if (_reset == 1'b0) begin
			driveTrack   <= 0;
			dbg_step_cnt <= 16'd0;
		end
		else if(cep && _enable == 1'b0 && lstrbEdge == 1'b1 && driveWriteAddr == `DRIVE_REG_STEP && ca2 == 1'b0) begin
			dbg_step_cnt <= dbg_step_cnt + 16'd1;  // PFLP: seek activity meter
			// DIRTN polarity: 0 = toward track 79, 1 = toward track 0, per the
			// register table at the top of this file. Briefly inverted on
			// 2026-08-04 and REVERTED the same day: the inversion was justified
			// by a 79-step run to the outer stop, but that measurement was taken
			// with the image mounted to the SECONDARY slot, so the internal drive
			// was empty and the driver was flailing at a disk that was not there
			// — an invalid reference. With the disk correctly in the internal
			// drive the inverted build could not move the head outward at all
			// (step_cnt=2, driveTrack=0, clamped), so the catalog past cylinder 0
			// was unreachable and the volume mounted then failed.
			if (driveRegs[`DRIVE_REG_DIRTN] == 1'b0 && driveTrack != 7'h4F) begin
				driveTrack <= driveTrack + 1'b1;
			end
			if (driveRegs[`DRIVE_REG_DIRTN] == 1'b1 && driveTrack != 0) begin
				driveTrack <= driveTrack - 1'b1;
			end
		end
	end
	
	// DRIVE_REG_MOTORON	4  /* R/W: 0 = motor on */
	always @(posedge clk or negedge _reset) begin
		if (_reset == 1'b0) begin		
			driveRegs[`DRIVE_REG_MOTORON] <= 1'b1;
		end 
		else if (cep && _enable == 1'b0 && lstrbEdge == 1'b1 && driveWriteAddr == `DRIVE_REG_MOTORON) begin
			driveRegs[`DRIVE_REG_MOTORON] <= ca2;
		end
	end

	// DRIVE_REG_TACH  7  Tachometer (produces 60 pulses for each rotation of the drive motor)
	/* Data from MESS, sonydriv.c:
	   Tracks	RPM   Timing Value
	   00-15:   500   timing value $117B (acceptable range {1135-11E9})
	   16-31:   550   timing value $???? (acceptable range {12C6-138A})
	   32-47:   600   timing value $???? (acceptable range {14A7-157F})
	   48-63:   675   timing value $???? (acceptable range {16F2-17E2})
	   64-79:   750   timing value $???? (acceptable range {19D0-1ADE})
		
		Experimentally determined toggle rates with 8.125 MHz CPU clock:
		TACH Half Period Clocks		Resulting Timing Value
					9996					$117B (4475)
					9122  				$1328 (4904)
					8292  				$1513 (5395)
					7463  				$176A (5994)
					6634					$1A56 (6742)
	*/
	
	reg [14:0] driveTachTimer;
	reg [14:0] driveTachPeriod;

	always @(*) begin
		if (mfm_disk) begin
			// SuperDrive MFM media (720K DD and 1.44MB HD) spin a CONSTANT
			// 300 RPM regardless of track (500 kbit/s CAV — swim_ism_read
			// reference §"MFM mode on"). The zoned table below is GCR-only.
			// Scaled from the experimentally-calibrated track-0 row:
			// 9996 clks @500 RPM -> x(500/300) = 16660 clks @300 RPM.
			// Without this the Welcome-time Sony driver install measured the
			// zoned GCR rate (500 RPM at track 0, 66% out of spec), failed
			// its drive-speed check, and System 6.0.8's floppy boot looped
			// at "Welcome to Macintosh" retrying the install (HW 2026-08-03;
			// MAME F616 tach-poll window is exactly this measurement).
			driveTachPeriod <= 15'd16660;
		end
		else case (driveTrack[6:4])
			0: // tracks 0-15
				driveTachPeriod <= 9996;
			1: // tracks 16-31
				driveTachPeriod <= 9122;
			2: // tracks 32-47
				driveTachPeriod <= 8292;
			3: // tracks 48-63
				driveTachPeriod <= 7463;
			default: // tracks 64-79
				driveTachPeriod <= 6634;
		endcase
	end
	
	always @(posedge clk or negedge _reset) begin
		if (_reset == 1'b0) begin		
			driveRegs[`DRIVE_REG_TACH] <= 1'b0;
			driveTachTimer <= 0;
		end 
		else if(cep) begin
			if (driveTachTimer == driveTachPeriod) begin
				driveTachTimer <= 0;
				driveRegs[`DRIVE_REG_TACH] <= ~driveRegs[`DRIVE_REG_TACH];
			end
			else begin
				driveTachTimer <= driveTachTimer + 1'b1;
			end
		end
	end	
endmodule
