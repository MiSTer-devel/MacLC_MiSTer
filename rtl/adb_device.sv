// ============================================================================
// adb_device.sv — wire-level ADB keyboard (addr 2) + mouse (addr 3) device
// for the Macintosh LC Egret.
//
// The Egret HC05 bit-bangs the single open-collector ADB data line.  This module
// decodes the HC05's transmitted ADB commands (attention / sync / 8 command bits
// / stop) and drives Talk responses back with ADB cell timing, so the boot ROM's
// ADB enumeration finds the keyboard and mouse and the Egret reports a populated
// bus.  Keyboard/mouse data follow the lbmactwo_MiSTer/rtl/adb.sv device model
// (PS2 scan-code table, key FIFO, mouse register); the line-level framing is
// modeled on MAME src/mame/apple/macadb.cpp (the LST_* state machine).
//
// Open-collector convention (matches MAME egret.cpp m_adb_device_out):
//   host_line : line as driven by the Egret = ~adb_data_out  (1 = idle/high)
//   dev_line  : this device's drive (1 = released, 0 = pull low), wire-ANDed
//               with the Egret's drive to form the observed line.
//
// Timing is in clk32 (32 MHz) cycles, scaled from the real HC05's measured
// 4 MHz cell timing (egret_wrapper ADBLINE log): attention low ~6.7k, bit cell
// ~0.9k ("0" high ~350 / "1" high ~600).
// ============================================================================

module adb_device(
	input  wire        clk,        // clk32 (32 MHz)
	input  wire        reset,
	input  wire        host_line,  // = ~adb_data_out from the Egret (1 = idle/high)
	output reg         dev_line,   // open-collector: 1 = released, 0 = pull low
	input  wire [10:0] ps2_key,
	input  wire [24:0] ps2_mouse
);

	reg capslock;   // tracked for caps-lock toggle handling (internal)

	// ---- line cell timing (clk32 cycles) ----
	localparam [17:0] T_ATTN  = 18'd3000;  // line low longer than this = attention
	localparam [17:0] T_BITTH = 18'd470;   // high-phase longer than this decodes "1"
	localparam [17:0] D_SHORT = 18'd340;   // ADB short cell phase
	localparam [17:0] D_LONG  = 18'd600;   // ADB long  cell phase
	localparam [17:0] D_T1T   = 18'd1200;  // stop -> device-response gap (Tlt)
	localparam [17:0] D_SRQ   = 18'd2700;  // service-request low pulse (~3 bit cells); tunable

	localparam [3:0] ADDR_KBD   = 4'd2;
	localparam [3:0] ADDR_MOUSE = 4'd3;
	reg [3:0] kbd_addr, mouse_addr;

	// ---- response buffer ----
	reg [7:0] resp0, resp1;
	reg [1:0] resp_len;

	// ---- keyboard state (PS2 -> ADB key FIFO) ----
	// MLAB: 64 bits was burning a full M10K block (m10k-repack 2026-07-17)
	(* ramstyle = "MLAB" *) reg  [7:0] kbdFifo [0:7];
	reg  [2:0] kbdFifoRd, kbdFifoWr;
	wire       kbdFifoEmpty = (kbdFifoRd == kbdFifoWr);

	// ---- mouse state ----
	reg  [6:0] mouseX, mouseY;
	reg        mouseButton;
	reg        mouse_evt;       // movement/button event pending
	reg        mouse_init;      // report the idle state once after reset/enumeration

	// ---- PS2 keyboard synchronizer + scan-code decode ----
	reg        kstb_s1, kstb_s2, kstb_s3, kstb_d;
	reg  [9:0] keyRaw_s1, keyRaw_s2;
	reg  [7:0] keyData;
	reg        key_pending;
	wire       key_edge   = (kstb_s3 != kstb_d);
	wire [8:0] key_sc     = keyRaw_s2[8:0];
	wire       press      = keyRaw_s2[9];
	wire       capslock_key = (keyRaw_s2[8:0] == 9'h58);

	// ---- PS2 mouse synchronizer ----
	reg        mstb_s1, mstb_s2, mstb_s3, mstb_d;
	reg  [8:0] mX_s1, mX_s2, mY_s1, mY_s2;
	reg        mBtn_s1, mBtn_s2;
	wire       mouse_edge = (mstb_s3 != mstb_d);

	// ---- line edge detection ----
	reg        hl_d;
	wire       fall = hl_d & ~host_line;
	wire       rise = ~hl_d & host_line;
	reg [17:0] dur;

	// ---- main state machine ----
	localparam [3:0]
		S_IDLE = 4'd0, S_ATTN = 4'd1, S_BITS = 4'd2, S_TSTOP = 4'd3,
		S_T1T  = 4'd4, S_SEND = 4'd5,
		// Listen receive (host -> device data packet, e.g. Register 3 address reassign)
		S_LRX_WAIT = 4'd6, S_LRX_START = 4'd7, S_LRX_BITS = 4'd8, S_LRX_DONE = 4'd9,
		// Service Request: hold the bus low after a non-mouse poll while mouse data is pending
		S_SRQ = 4'd10;
	reg [3:0]  st;
	reg [7:0]  command;
	reg [3:0]  bitcnt;
	reg [17:0] sendtmr;
	reg [3:0]  send_stage;
	reg [7:0]  send_sr;
	reg [3:0]  send_bits;
	reg [1:0]  send_byte;
	reg        cur_bit;
	reg [15:0] lrx_sr;       // Listen data shift register (16-bit Register 3 payload)
	reg        lrx_target;   // which device this Listen addresses: 1 = mouse, 0 = keyboard
`ifdef USE_ADB_ISSP
	reg [7:0]  dbg_listen_seen;  // count of Listen R3 detected (entered S_LRX)
	reg [7:0]  dbg_listen_done;  // count of Listen receive completed (reached S_LRX_DONE)
`endif

	wire [3:0] cmd_addr = command[7:4];
	wire [1:0] cmd_type = command[3:2];
	wire [1:0] cmd_reg  = command[1:0];

	// Service Request: assert when EITHER emulated device (mouse addr 3 / keyboard
	// addr 2) has pending data and the command just seen wasn't a poll of that
	// device. Covers both so neither starves the other (the Egret autopolls only
	// the last-active device; others must SRQ to get serviced).
	wire srq_want = (mouse_evt    && cmd_addr != mouse_addr) ||
	                (!kbdFifoEmpty && cmd_addr != kbd_addr);

	always @(posedge clk) begin
		if (reset) begin
			hl_d <= 1'b1; dur <= 0; st <= S_IDLE; dev_line <= 1'b1;
			command <= 0; bitcnt <= 0;
			kbd_addr <= ADDR_KBD; mouse_addr <= ADDR_MOUSE;
			resp_len <= 0; resp0 <= 0; resp1 <= 0;
			sendtmr <= 0; send_stage <= 0; send_sr <= 0; send_bits <= 0;
			send_byte <= 0; cur_bit <= 0;
			lrx_sr <= 0; lrx_target <= 0;
`ifdef USE_ADB_ISSP
			dbg_listen_seen <= 0; dbg_listen_done <= 0;
`endif
			kbdFifoRd <= 0; kbdFifoWr <= 0;
			mouseX <= 0; mouseY <= 0; mouseButton <= 0; mouse_evt <= 0; mouse_init <= 1'b1;
			kstb_s1 <= ps2_key[10]; kstb_s2 <= ps2_key[10]; kstb_s3 <= ps2_key[10]; kstb_d <= ps2_key[10];
			keyRaw_s1 <= 0; keyRaw_s2 <= 0; keyData <= 8'h7F; key_pending <= 0; capslock <= 0;
			mstb_s1 <= ps2_mouse[24]; mstb_s2 <= ps2_mouse[24]; mstb_s3 <= ps2_mouse[24]; mstb_d <= ps2_mouse[24];
			mX_s1 <= 0; mX_s2 <= 0; mY_s1 <= 0; mY_s2 <= 0; mBtn_s1 <= 0; mBtn_s2 <= 0;
		end else begin
			// ---- synchronizers (free running) ----
			hl_d <= host_line;
			kstb_s1 <= ps2_key[10];   kstb_s2 <= kstb_s1;   kstb_s3 <= kstb_s2;
			keyRaw_s1 <= ps2_key[9:0]; keyRaw_s2 <= keyRaw_s1;
			mstb_s1 <= ps2_mouse[24];  mstb_s2 <= mstb_s1;   mstb_s3 <= mstb_s2;
			mX_s1 <= {ps2_mouse[4], ps2_mouse[15:8]};  mX_s2 <= mX_s1;
			mY_s1 <= {ps2_mouse[5], ps2_mouse[23:16]}; mY_s2 <= mY_s1;
			mBtn_s1 <= ps2_mouse[0];   mBtn_s2 <= mBtn_s1;

			// duration counter (cycles since last observed-line edge)
			if (fall || rise) dur <= 0;
			else if (dur != 18'h3FFFF) dur <= dur + 18'd1;

			// ---- PS2 keyboard: decode scan code on the synchronized strobe edge ----
			key_pending <= 1'b0;
			if (key_edge) begin
				kstb_d <= kstb_s3;
				if (capslock_key && press) capslock <= ~capslock;
				key_pending <= 1'b1;
				case (key_sc) // Scan Code Set 2 -> ADB scan codes
			  9'h000: keyData[6:0] <= 7'h7F;
			  9'h001: keyData[6:0] <= 7'h65;	//F9
			  9'h002: keyData[6:0] <= 7'h7F;
			  9'h003: keyData[6:0] <= 7'h60;	//F5
			  9'h004: keyData[6:0] <= 7'h63;	//F3
			  9'h005: keyData[6:0] <= 7'h7A;	//F1
			  9'h006: keyData[6:0] <= 7'h78;	//F2
			  9'h007: keyData[6:0] <= 7'h7F;//7'h6F;	//F12 <OSD>
			  9'h008: keyData[6:0] <= 7'h7F;
			  9'h009: keyData[6:0] <= 7'h6D;	//F10
			  9'h00a: keyData[6:0] <= 7'h64;	//F8
			  9'h00b: keyData[6:0] <= 7'h61;	//F6
			  9'h00c: keyData[6:0] <= 7'h76;	//F4
			  9'h00d: keyData[6:0] <= 7'h30;	//TAB
			  9'h00e: keyData[6:0] <= 7'h32;	//~ (`)
			  9'h00f: keyData[6:0] <= 7'h7F;
			  9'h010: keyData[6:0] <= 7'h7F;
			  9'h011: keyData[6:0] <= 7'h37;	//LEFT ALT (command)
			  9'h012: keyData[6:0] <= 7'h38;	//LEFT SHIFT
			  9'h013: keyData[6:0] <= 7'h7F;
			  9'h014: keyData[6:0] <= 7'h36;	//CTRL
			  9'h015: keyData[6:0] <= 7'h0C;	//q
			  9'h016: keyData[6:0] <= 7'h12;	//1
			  9'h017: keyData[6:0] <= 7'h7F;
			  9'h018: keyData[6:0] <= 7'h7F;
			  9'h019: keyData[6:0] <= 7'h7F;
			  9'h01a: keyData[6:0] <= 7'h06;	//z
			  9'h01b: keyData[6:0] <= 7'h01;	//s
			  9'h01c: keyData[6:0] <= 7'h00;	//a
			  9'h01d: keyData[6:0] <= 7'h0D;	//w
			  9'h01e: keyData[6:0] <= 7'h13;	//2
			  9'h01f: keyData[6:0] <= 7'h7F;
			  9'h020: keyData[6:0] <= 7'h7F;
			  9'h021: keyData[6:0] <= 7'h08;	//c
			  9'h022: keyData[6:0] <= 7'h07;	//x
			  9'h023: keyData[6:0] <= 7'h02;	//d
			  9'h024: keyData[6:0] <= 7'h0E;	//e
			  9'h025: keyData[6:0] <= 7'h15;	//4
			  9'h026: keyData[6:0] <= 7'h14;	//3
			  9'h027: keyData[6:0] <= 7'h7F;
			  9'h028: keyData[6:0] <= 7'h7F;
			  9'h029: keyData[6:0] <= 7'h31;	//SPACE
			  9'h02a: keyData[6:0] <= 7'h09;	//v
			  9'h02b: keyData[6:0] <= 7'h03;	//f
			  9'h02c: keyData[6:0] <= 7'h11;	//t
			  9'h02d: keyData[6:0] <= 7'h0F;	//r
			  9'h02e: keyData[6:0] <= 7'h17;	//5
			  9'h02f: keyData[6:0] <= 7'h7F;
			  9'h030: keyData[6:0] <= 7'h7F;
			  9'h031: keyData[6:0] <= 7'h2D;	//n
			  9'h032: keyData[6:0] <= 7'h0B;	//b
			  9'h033: keyData[6:0] <= 7'h04;	//h
			  9'h034: keyData[6:0] <= 7'h05;	//g
			  9'h035: keyData[6:0] <= 7'h10;	//y
			  9'h036: keyData[6:0] <= 7'h16;	//6
			  9'h037: keyData[6:0] <= 7'h7F;
			  9'h038: keyData[6:0] <= 7'h7F;
			  9'h039: keyData[6:0] <= 7'h7F;
			  9'h03a: keyData[6:0] <= 7'h2E;	//m
			  9'h03b: keyData[6:0] <= 7'h26;	//j
			  9'h03c: keyData[6:0] <= 7'h20;	//u
			  9'h03d: keyData[6:0] <= 7'h1A;	//7
			  9'h03e: keyData[6:0] <= 7'h1C;	//8
			  9'h03f: keyData[6:0] <= 7'h7F;
			  9'h040: keyData[6:0] <= 7'h7F;
			  9'h041: keyData[6:0] <= 7'h2B;	//<,
			  9'h042: keyData[6:0] <= 7'h28;	//k
			  9'h043: keyData[6:0] <= 7'h22;	//i
			  9'h044: keyData[6:0] <= 7'h1F;	//o
			  9'h045: keyData[6:0] <= 7'h1D;	//0
			  9'h046: keyData[6:0] <= 7'h19;	//9
			  9'h047: keyData[6:0] <= 7'h7F;
			  9'h048: keyData[6:0] <= 7'h7F;
			  9'h049: keyData[6:0] <= 7'h2F;	//>.
			  9'h04a: keyData[6:0] <= 7'h2C;	//FORWARD SLASH
			  9'h04b: keyData[6:0] <= 7'h25;	//l
			  9'h04c: keyData[6:0] <= 7'h29;	//;
			  9'h04d: keyData[6:0] <= 7'h23;	//p
			  9'h04e: keyData[6:0] <= 7'h1B;	//-
			  9'h04f: keyData[6:0] <= 7'h7F;
			  9'h050: keyData[6:0] <= 7'h7F;
			  9'h051: keyData[6:0] <= 7'h7F;
			  9'h052: keyData[6:0] <= 7'h27;	//'"
			  9'h053: keyData[6:0] <= 7'h7F;
			  9'h054: keyData[6:0] <= 7'h21;	//[
			  9'h055: keyData[6:0] <= 7'h18;	// = 
			  9'h056: keyData[6:0] <= 7'h7F;
			  9'h057: keyData[6:0] <= 7'h7F;
			  9'h058: keyData[6:0] <= 7'h39;	//CAPSLOCK
			  9'h059: keyData[6:0] <= 7'h7B;	//RIGHT SHIFT
			  9'h05a: keyData[6:0] <= 7'h24;	//ENTER
			  9'h05b: keyData[6:0] <= 7'h1E;	//]
			  9'h05c: keyData[6:0] <= 7'h7F;
			  9'h05d: keyData[6:0] <= 7'h2A;	//BACKSLASH
			  9'h05e: keyData[6:0] <= 7'h7F;
			  9'h05f: keyData[6:0] <= 7'h7F;
			  9'h060: keyData[6:0] <= 7'h7F;
			  9'h061: keyData[6:0] <= 7'h7F;	//international left shift cut out (German '<>' key), 0x56 Set#1 code
			  9'h062: keyData[6:0] <= 7'h7F;
			  9'h063: keyData[6:0] <= 7'h7F;
			  9'h064: keyData[6:0] <= 7'h7F;
			  9'h065: keyData[6:0] <= 7'h7F;
			  9'h066: keyData[6:0] <= 7'h33;	//BACKSPACE
			  9'h067: keyData[6:0] <= 7'h7F;
			  9'h068: keyData[6:0] <= 7'h7F;
			  9'h069: keyData[6:0] <= 7'h53;	//KP 1
			  9'h06a: keyData[6:0] <= 7'h7F;
			  9'h06b: keyData[6:0] <= 7'h56;	//KP 4
			  9'h06c: keyData[6:0] <= 7'h59;	//KP 7
			  9'h06d: keyData[6:0] <= 7'h7F;
			  9'h06e: keyData[6:0] <= 7'h7F;
			  9'h06f: keyData[6:0] <= 7'h7F;
			  9'h070: keyData[6:0] <= 7'h52;	//KP 0
			  9'h071: keyData[6:0] <= 7'h41;	//KP .
			  9'h072: keyData[6:0] <= 7'h54;	//KP 2
			  9'h073: keyData[6:0] <= 7'h57;	//KP 5
			  9'h074: keyData[6:0] <= 7'h58;	//KP 6
			  9'h075: keyData[6:0] <= 7'h5B;	//KP 8
			  9'h076: keyData[6:0] <= 7'h35;	//ESCAPE
			  9'h077: keyData[6:0] <= 7'h47;	//NUMLOCK (Mac keypad clear?)
			  9'h078: keyData[6:0] <= 7'h67;	//F11 <OSD>
			  9'h079: keyData[6:0] <= 7'h45;	//KP +
			  9'h07a: keyData[6:0] <= 7'h55;	//KP 3
			  9'h07b: keyData[6:0] <= 7'h4E;	//KP -
			  9'h07c: keyData[6:0] <= 7'h43;	//KP *
			  9'h07d: keyData[6:0] <= 7'h5C;	//KP 9
			  9'h07e: keyData[6:0] <= 7'h7F;	//SCROLL LOCK / KP )
			  9'h07f: keyData[6:0] <= 7'h7F;
			  9'h080: keyData[6:0] <= 7'h7F;
			  9'h081: keyData[6:0] <= 7'h7F;
			  9'h082: keyData[6:0] <= 7'h7F;
			  9'h083: keyData[6:0] <= 7'h62;	//F7
			  9'h084: keyData[6:0] <= 7'h7F;
			  9'h085: keyData[6:0] <= 7'h7F;
			  9'h086: keyData[6:0] <= 7'h7F;
			  9'h087: keyData[6:0] <= 7'h7F;
			  9'h088: keyData[6:0] <= 7'h7F;
			  9'h089: keyData[6:0] <= 7'h7F;
			  9'h08a: keyData[6:0] <= 7'h7F;
			  9'h08b: keyData[6:0] <= 7'h7F;
			  9'h08c: keyData[6:0] <= 7'h7F;
			  9'h08d: keyData[6:0] <= 7'h7F;
			  9'h08e: keyData[6:0] <= 7'h7F;
			  9'h08f: keyData[6:0] <= 7'h7F;
			  9'h090: keyData[6:0] <= 7'h7F;
			  9'h091: keyData[6:0] <= 7'h7F;
			  9'h092: keyData[6:0] <= 7'h7F;
			  9'h093: keyData[6:0] <= 7'h7F;
			  9'h094: keyData[6:0] <= 7'h7F;
			  9'h095: keyData[6:0] <= 7'h7F;
			  9'h096: keyData[6:0] <= 7'h7F;
			  9'h097: keyData[6:0] <= 7'h7F;
			  9'h098: keyData[6:0] <= 7'h7F;
			  9'h099: keyData[6:0] <= 7'h7F;
			  9'h09a: keyData[6:0] <= 7'h7F;
			  9'h09b: keyData[6:0] <= 7'h7F;
			  9'h09c: keyData[6:0] <= 7'h7F;
			  9'h09d: keyData[6:0] <= 7'h7F;
			  9'h09e: keyData[6:0] <= 7'h7F;
			  9'h09f: keyData[6:0] <= 7'h7F;
			  9'h0a0: keyData[6:0] <= 7'h7F;
			  9'h0a1: keyData[6:0] <= 7'h7F;
			  9'h0a2: keyData[6:0] <= 7'h7F;
			  9'h0a3: keyData[6:0] <= 7'h7F;
			  9'h0a4: keyData[6:0] <= 7'h7F;
			  9'h0a5: keyData[6:0] <= 7'h7F;
			  9'h0a6: keyData[6:0] <= 7'h7F;
			  9'h0a7: keyData[6:0] <= 7'h7F;
			  9'h0a8: keyData[6:0] <= 7'h7F;
			  9'h0a9: keyData[6:0] <= 7'h7F;
			  9'h0aa: keyData[6:0] <= 7'h7F;
			  9'h0ab: keyData[6:0] <= 7'h7F;
			  9'h0ac: keyData[6:0] <= 7'h7F;
			  9'h0ad: keyData[6:0] <= 7'h7F;
			  9'h0ae: keyData[6:0] <= 7'h7F;
			  9'h0af: keyData[6:0] <= 7'h7F;
			  9'h0b0: keyData[6:0] <= 7'h7F;
			  9'h0b1: keyData[6:0] <= 7'h7F;
			  9'h0b2: keyData[6:0] <= 7'h7F;
			  9'h0b3: keyData[6:0] <= 7'h7F;
			  9'h0b4: keyData[6:0] <= 7'h7F;
			  9'h0b5: keyData[6:0] <= 7'h7F;
			  9'h0b6: keyData[6:0] <= 7'h7F;
			  9'h0b7: keyData[6:0] <= 7'h7F;
			  9'h0b8: keyData[6:0] <= 7'h7F;
			  9'h0b9: keyData[6:0] <= 7'h7F;
			  9'h0ba: keyData[6:0] <= 7'h7F;
			  9'h0bb: keyData[6:0] <= 7'h7F;
			  9'h0bc: keyData[6:0] <= 7'h7F;
			  9'h0bd: keyData[6:0] <= 7'h7F;
			  9'h0be: keyData[6:0] <= 7'h7F;
			  9'h0bf: keyData[6:0] <= 7'h7F;
			  9'h0c0: keyData[6:0] <= 7'h7F;
			  9'h0c1: keyData[6:0] <= 7'h7F;
			  9'h0c2: keyData[6:0] <= 7'h7F;
			  9'h0c3: keyData[6:0] <= 7'h7F;
			  9'h0c4: keyData[6:0] <= 7'h7F;
			  9'h0c5: keyData[6:0] <= 7'h7F;
			  9'h0c6: keyData[6:0] <= 7'h7F;
			  9'h0c7: keyData[6:0] <= 7'h7F;
			  9'h0c8: keyData[6:0] <= 7'h7F;
			  9'h0c9: keyData[6:0] <= 7'h7F;
			  9'h0ca: keyData[6:0] <= 7'h7F;
			  9'h0cb: keyData[6:0] <= 7'h7F;
			  9'h0cc: keyData[6:0] <= 7'h7F;
			  9'h0cd: keyData[6:0] <= 7'h7F;
			  9'h0ce: keyData[6:0] <= 7'h7F;
			  9'h0cf: keyData[6:0] <= 7'h7F;
			  9'h0d0: keyData[6:0] <= 7'h7F;
			  9'h0d1: keyData[6:0] <= 7'h7F;
			  9'h0d2: keyData[6:0] <= 7'h7F;
			  9'h0d3: keyData[6:0] <= 7'h7F;
			  9'h0d4: keyData[6:0] <= 7'h7F;
			  9'h0d5: keyData[6:0] <= 7'h7F;
			  9'h0d6: keyData[6:0] <= 7'h7F;
			  9'h0d7: keyData[6:0] <= 7'h7F;
			  9'h0d8: keyData[6:0] <= 7'h7F;
			  9'h0d9: keyData[6:0] <= 7'h7F;
			  9'h0da: keyData[6:0] <= 7'h7F;
			  9'h0db: keyData[6:0] <= 7'h7F;
			  9'h0dc: keyData[6:0] <= 7'h7F;
			  9'h0dd: keyData[6:0] <= 7'h7F;
			  9'h0de: keyData[6:0] <= 7'h7F;
			  9'h0df: keyData[6:0] <= 7'h7F;
			  9'h0e0: keyData[6:0] <= 7'h7F;	//ps2 extended key
			  9'h0e1: keyData[6:0] <= 7'h7F;
			  9'h0e2: keyData[6:0] <= 7'h7F;
			  9'h0e3: keyData[6:0] <= 7'h7F;
			  9'h0e4: keyData[6:0] <= 7'h7F;
			  9'h0e5: keyData[6:0] <= 7'h7F;
			  9'h0e6: keyData[6:0] <= 7'h7F;
			  9'h0e7: keyData[6:0] <= 7'h7F;
			  9'h0e8: keyData[6:0] <= 7'h7F;
			  9'h0e9: keyData[6:0] <= 7'h7F;
			  9'h0ea: keyData[6:0] <= 7'h7F;
			  9'h0eb: keyData[6:0] <= 7'h7F;
			  9'h0ec: keyData[6:0] <= 7'h7F;
			  9'h0ed: keyData[6:0] <= 7'h7F;
			  9'h0ee: keyData[6:0] <= 7'h7F;
			  9'h0ef: keyData[6:0] <= 7'h7F;
			  9'h0f0: keyData[6:0] <= 7'h7F;	//ps2 release code
			  9'h0f1: keyData[6:0] <= 7'h7F;
			  9'h0f2: keyData[6:0] <= 7'h7F;
			  9'h0f3: keyData[6:0] <= 7'h7F;
			  9'h0f4: keyData[6:0] <= 7'h7F;
			  9'h0f5: keyData[6:0] <= 7'h7F;
			  9'h0f6: keyData[6:0] <= 7'h7F;
			  9'h0f7: keyData[6:0] <= 7'h7F;
			  9'h0f8: keyData[6:0] <= 7'h7F;
			  9'h0f9: keyData[6:0] <= 7'h7F;
			  9'h0fa: keyData[6:0] <= 7'h7F;	//ps2 ack code
			  9'h0fb: keyData[6:0] <= 7'h7F;
			  9'h0fc: keyData[6:0] <= 7'h7F;
			  9'h0fd: keyData[6:0] <= 7'h7F;
			  9'h0fe: keyData[6:0] <= 7'h7F;
			  9'h0ff: keyData[6:0] <= 7'h7F;
			  9'h100: keyData[6:0] <= 7'h7F;
			  9'h101: keyData[6:0] <= 7'h7F;
			  9'h102: keyData[6:0] <= 7'h7F;
			  9'h103: keyData[6:0] <= 7'h7F;
			  9'h104: keyData[6:0] <= 7'h7F;
			  9'h105: keyData[6:0] <= 7'h7F;
			  9'h106: keyData[6:0] <= 7'h7F;
			  9'h107: keyData[6:0] <= 7'h7F;
			  9'h108: keyData[6:0] <= 7'h7F;
			  9'h109: keyData[6:0] <= 7'h7F;
			  9'h10a: keyData[6:0] <= 7'h7F;
			  9'h10b: keyData[6:0] <= 7'h7F;
			  9'h10c: keyData[6:0] <= 7'h7F;
			  9'h10d: keyData[6:0] <= 7'h7F;
			  9'h10e: keyData[6:0] <= 7'h7F;
			  9'h10f: keyData[6:0] <= 7'h7F;
			  9'h110: keyData[6:0] <= 7'h7F;
			  9'h111: keyData[6:0] <= 7'h37;	//RIGHT ALT (command)
			  9'h112: keyData[6:0] <= 7'h7F;
			  9'h113: keyData[6:0] <= 7'h7F;
			  9'h114: keyData[6:0] <= 7'h7F;
			  9'h115: keyData[6:0] <= 7'h7F;
			  9'h116: keyData[6:0] <= 7'h7F;
			  9'h117: keyData[6:0] <= 7'h7F;
			  9'h118: keyData[6:0] <= 7'h7F;
			  9'h119: keyData[6:0] <= 7'h7F;
			  9'h11a: keyData[6:0] <= 7'h7F;
			  9'h11b: keyData[6:0] <= 7'h7F;
			  9'h11c: keyData[6:0] <= 7'h7F;
			  9'h11d: keyData[6:0] <= 7'h7F;
			  9'h11e: keyData[6:0] <= 7'h7F;
			  9'h11f: keyData[6:0] <= 7'h3A;	//WINDOWS OR APPLICATION KEY (option)
			  9'h120: keyData[6:0] <= 7'h7F;
			  9'h121: keyData[6:0] <= 7'h7F;
			  9'h122: keyData[6:0] <= 7'h7F;
			  9'h123: keyData[6:0] <= 7'h7F;
			  9'h124: keyData[6:0] <= 7'h7F;
			  9'h125: keyData[6:0] <= 7'h7F;
			  9'h126: keyData[6:0] <= 7'h7F;
			  9'h127: keyData[6:0] <= 7'h7F;
			  9'h128: keyData[6:0] <= 7'h7F;
			  9'h129: keyData[6:0] <= 7'h7F;
			  9'h12a: keyData[6:0] <= 7'h7F;
			  9'h12b: keyData[6:0] <= 7'h7F;
			  9'h12c: keyData[6:0] <= 7'h7F;
			  9'h12d: keyData[6:0] <= 7'h7F;
			  9'h12e: keyData[6:0] <= 7'h7F;
			  9'h12f: keyData[6:0] <= 7'h7F;	
			  9'h130: keyData[6:0] <= 7'h7F;
			  9'h131: keyData[6:0] <= 7'h7F;
			  9'h132: keyData[6:0] <= 7'h7F;
			  9'h133: keyData[6:0] <= 7'h7F;
			  9'h134: keyData[6:0] <= 7'h7F;
			  9'h135: keyData[6:0] <= 7'h7F;
			  9'h136: keyData[6:0] <= 7'h7F;
			  9'h137: keyData[6:0] <= 7'h7F;
			  9'h138: keyData[6:0] <= 7'h7F;
			  9'h139: keyData[6:0] <= 7'h7F;
			  9'h13a: keyData[6:0] <= 7'h7F;
			  9'h13b: keyData[6:0] <= 7'h7F;
			  9'h13c: keyData[6:0] <= 7'h7F;
			  9'h13d: keyData[6:0] <= 7'h7F;
			  9'h13e: keyData[6:0] <= 7'h7F;
			  9'h13f: keyData[6:0] <= 7'h7F;
			  9'h140: keyData[6:0] <= 7'h7F;
			  9'h141: keyData[6:0] <= 7'h7F;
			  9'h142: keyData[6:0] <= 7'h7F;
			  9'h143: keyData[6:0] <= 7'h7F;
			  9'h144: keyData[6:0] <= 7'h7F;
			  9'h145: keyData[6:0] <= 7'h7F;
			  9'h146: keyData[6:0] <= 7'h7F;
			  9'h147: keyData[6:0] <= 7'h7F;
			  9'h148: keyData[6:0] <= 7'h7F;
			  9'h149: keyData[6:0] <= 7'h7F;
			  9'h14a: keyData[6:0] <= 7'h4B;	//KP /
			  9'h14b: keyData[6:0] <= 7'h7F;
			  9'h14c: keyData[6:0] <= 7'h7F;
			  9'h14d: keyData[6:0] <= 7'h7F;
			  9'h14e: keyData[6:0] <= 7'h7F;
			  9'h14f: keyData[6:0] <= 7'h7F;
			  9'h150: keyData[6:0] <= 7'h7F;
			  9'h151: keyData[6:0] <= 7'h7F;
			  9'h152: keyData[6:0] <= 7'h7F;
			  9'h153: keyData[6:0] <= 7'h7F;
			  9'h154: keyData[6:0] <= 7'h7F;
			  9'h155: keyData[6:0] <= 7'h7F;
			  9'h156: keyData[6:0] <= 7'h7F;
			  9'h157: keyData[6:0] <= 7'h7F;
			  9'h158: keyData[6:0] <= 7'h7F;
			  9'h159: keyData[6:0] <= 7'h7F;
			  9'h15a: keyData[6:0] <= 7'h4C;	//KP ENTER
			  9'h15b: keyData[6:0] <= 7'h7F;
			  9'h15c: keyData[6:0] <= 7'h7F;
			  9'h15d: keyData[6:0] <= 7'h7F;
			  9'h15e: keyData[6:0] <= 7'h7F;
			  9'h15f: keyData[6:0] <= 7'h7F;
			  9'h160: keyData[6:0] <= 7'h7F;
			  9'h161: keyData[6:0] <= 7'h7F;
			  9'h162: keyData[6:0] <= 7'h7F;
			  9'h163: keyData[6:0] <= 7'h7F;
			  9'h164: keyData[6:0] <= 7'h7F;
			  9'h165: keyData[6:0] <= 7'h7F;
			  9'h166: keyData[6:0] <= 7'h7F;
			  9'h167: keyData[6:0] <= 7'h7F;
			  9'h168: keyData[6:0] <= 7'h7F;
			  9'h169: keyData[6:0] <= 7'h77;	//END
			  9'h16a: keyData[6:0] <= 7'h7F;
			  9'h16b: keyData[6:0] <= 7'h3B;	//ARROW LEFT
			  9'h16c: keyData[6:0] <= 7'h73;	//HOME
			  9'h16d: keyData[6:0] <= 7'h7F;
			  9'h16e: keyData[6:0] <= 7'h7F;
			  9'h16f: keyData[6:0] <= 7'h7F;
			  9'h170: keyData[6:0] <= 7'h72;	//INSERT = HELP
			  9'h171: keyData[6:0] <= 7'h75;	//DELETE (KP clear?)
			  9'h172: keyData[6:0] <= 7'h3D;	//ARROW DOWN
			  9'h173: keyData[6:0] <= 7'h7F;
			  9'h174: keyData[6:0] <= 7'h3C;	//ARROW RIGHT
			  9'h175: keyData[6:0] <= 7'h3E;	//ARROW UP
			  9'h176: keyData[6:0] <= 7'h7F;
			  9'h177: keyData[6:0] <= 7'h7F;
			  9'h178: keyData[6:0] <= 7'h7F;
			  9'h179: keyData[6:0] <= 7'h7F;
			  9'h17a: keyData[6:0] <= 7'h79;	//PGDN <OSD>
			  9'h17b: keyData[6:0] <= 7'h7F;
			  9'h17c: keyData[6:0] <= 7'h69;	//PRTSCR (F13)
			  9'h17d: keyData[6:0] <= 7'h74;	//PGUP <OSD>
			  9'h17e: keyData[6:0] <= 7'h71;	//ctrl+break (F15)
			  9'h17f: keyData[6:0] <= 7'h7F;
			  9'h180: keyData[6:0] <= 7'h7F;
			  9'h181: keyData[6:0] <= 7'h7F;
			  9'h182: keyData[6:0] <= 7'h7F;
			  9'h183: keyData[6:0] <= 7'h7F;
			  9'h184: keyData[6:0] <= 7'h7F;
			  9'h185: keyData[6:0] <= 7'h7F;
			  9'h186: keyData[6:0] <= 7'h7F;
			  9'h187: keyData[6:0] <= 7'h7F;
			  9'h188: keyData[6:0] <= 7'h7F;
			  9'h189: keyData[6:0] <= 7'h7F;
			  9'h18a: keyData[6:0] <= 7'h7F;
			  9'h18b: keyData[6:0] <= 7'h7F;
			  9'h18c: keyData[6:0] <= 7'h7F;
			  9'h18d: keyData[6:0] <= 7'h7F;
			  9'h18e: keyData[6:0] <= 7'h7F;
			  9'h18f: keyData[6:0] <= 7'h7F;
			  9'h190: keyData[6:0] <= 7'h7F;
			  9'h191: keyData[6:0] <= 7'h7F;
			  9'h192: keyData[6:0] <= 7'h7F;
			  9'h193: keyData[6:0] <= 7'h7F;
			  9'h194: keyData[6:0] <= 7'h7F;
			  9'h195: keyData[6:0] <= 7'h7F;
			  9'h196: keyData[6:0] <= 7'h7F;
			  9'h197: keyData[6:0] <= 7'h7F;
			  9'h198: keyData[6:0] <= 7'h7F;
			  9'h199: keyData[6:0] <= 7'h7F;
			  9'h19a: keyData[6:0] <= 7'h7F;
			  9'h19b: keyData[6:0] <= 7'h7F;
			  9'h19c: keyData[6:0] <= 7'h7F;
			  9'h19d: keyData[6:0] <= 7'h7F;
			  9'h19e: keyData[6:0] <= 7'h7F;
			  9'h19f: keyData[6:0] <= 7'h7F;
			  9'h1a0: keyData[6:0] <= 7'h7F;
			  9'h1a1: keyData[6:0] <= 7'h7F;
			  9'h1a2: keyData[6:0] <= 7'h7F;
			  9'h1a3: keyData[6:0] <= 7'h7F;
			  9'h1a4: keyData[6:0] <= 7'h7F;
			  9'h1a5: keyData[6:0] <= 7'h7F;
			  9'h1a6: keyData[6:0] <= 7'h7F;
			  9'h1a7: keyData[6:0] <= 7'h7F;
			  9'h1a8: keyData[6:0] <= 7'h7F;
			  9'h1a9: keyData[6:0] <= 7'h7F;
			  9'h1aa: keyData[6:0] <= 7'h7F;
			  9'h1ab: keyData[6:0] <= 7'h7F;
			  9'h1ac: keyData[6:0] <= 7'h7F;
			  9'h1ad: keyData[6:0] <= 7'h7F;
			  9'h1ae: keyData[6:0] <= 7'h7F;
			  9'h1af: keyData[6:0] <= 7'h7F;
			  9'h1b0: keyData[6:0] <= 7'h7F;
			  9'h1b1: keyData[6:0] <= 7'h7F;
			  9'h1b2: keyData[6:0] <= 7'h7F;
			  9'h1b3: keyData[6:0] <= 7'h7F;
			  9'h1b4: keyData[6:0] <= 7'h7F;
			  9'h1b5: keyData[6:0] <= 7'h7F;
			  9'h1b6: keyData[6:0] <= 7'h7F;
			  9'h1b7: keyData[6:0] <= 7'h7F;
			  9'h1b8: keyData[6:0] <= 7'h7F;
			  9'h1b9: keyData[6:0] <= 7'h7F;
			  9'h1ba: keyData[6:0] <= 7'h7F;
			  9'h1bb: keyData[6:0] <= 7'h7F;
			  9'h1bc: keyData[6:0] <= 7'h7F;
			  9'h1bd: keyData[6:0] <= 7'h7F;
			  9'h1be: keyData[6:0] <= 7'h7F;
			  9'h1bf: keyData[6:0] <= 7'h7F;
			  9'h1c0: keyData[6:0] <= 7'h7F;
			  9'h1c1: keyData[6:0] <= 7'h7F;
			  9'h1c2: keyData[6:0] <= 7'h7F;
			  9'h1c3: keyData[6:0] <= 7'h7F;
			  9'h1c4: keyData[6:0] <= 7'h7F;
			  9'h1c5: keyData[6:0] <= 7'h7F;
			  9'h1c6: keyData[6:0] <= 7'h7F;
			  9'h1c7: keyData[6:0] <= 7'h7F;
			  9'h1c8: keyData[6:0] <= 7'h7F;
			  9'h1c9: keyData[6:0] <= 7'h7F;
			  9'h1ca: keyData[6:0] <= 7'h7F;
			  9'h1cb: keyData[6:0] <= 7'h7F;
			  9'h1cc: keyData[6:0] <= 7'h7F;
			  9'h1cd: keyData[6:0] <= 7'h7F;
			  9'h1ce: keyData[6:0] <= 7'h7F;
			  9'h1cf: keyData[6:0] <= 7'h7F;
			  9'h1d0: keyData[6:0] <= 7'h7F;
			  9'h1d1: keyData[6:0] <= 7'h7F;
			  9'h1d2: keyData[6:0] <= 7'h7F;
			  9'h1d3: keyData[6:0] <= 7'h7F;
			  9'h1d4: keyData[6:0] <= 7'h7F;
			  9'h1d5: keyData[6:0] <= 7'h7F;
			  9'h1d6: keyData[6:0] <= 7'h7F;
			  9'h1d7: keyData[6:0] <= 7'h7F;
			  9'h1d8: keyData[6:0] <= 7'h7F;
			  9'h1d9: keyData[6:0] <= 7'h7F;
			  9'h1da: keyData[6:0] <= 7'h7F;
			  9'h1db: keyData[6:0] <= 7'h7F;
			  9'h1dc: keyData[6:0] <= 7'h7F;
			  9'h1dd: keyData[6:0] <= 7'h7F;
			  9'h1de: keyData[6:0] <= 7'h7F;
			  9'h1df: keyData[6:0] <= 7'h7F;
			  9'h1e0: keyData[6:0] <= 7'h7F;	//ps2 extended key(duplicate, see $e0)
			  9'h1e1: keyData[6:0] <= 7'h7F;
			  9'h1e2: keyData[6:0] <= 7'h7F;
			  9'h1e3: keyData[6:0] <= 7'h7F;
			  9'h1e4: keyData[6:0] <= 7'h7F;
			  9'h1e5: keyData[6:0] <= 7'h7F;
			  9'h1e6: keyData[6:0] <= 7'h7F;
			  9'h1e7: keyData[6:0] <= 7'h7F;
			  9'h1e8: keyData[6:0] <= 7'h7F;
			  9'h1e9: keyData[6:0] <= 7'h7F;
			  9'h1ea: keyData[6:0] <= 7'h7F;
			  9'h1eb: keyData[6:0] <= 7'h7F;
			  9'h1ec: keyData[6:0] <= 7'h7F;
			  9'h1ed: keyData[6:0] <= 7'h7F;
			  9'h1ee: keyData[6:0] <= 7'h7F;
			  9'h1ef: keyData[6:0] <= 7'h7F;
			  9'h1f0: keyData[6:0] <= 7'h7F;	//ps2 release code(duplicate, see $f0)
			  9'h1f1: keyData[6:0] <= 7'h7F;
			  9'h1f2: keyData[6:0] <= 7'h7F;
			  9'h1f3: keyData[6:0] <= 7'h7F;
			  9'h1f4: keyData[6:0] <= 7'h7F;
			  9'h1f5: keyData[6:0] <= 7'h7F;
			  9'h1f6: keyData[6:0] <= 7'h7F;
			  9'h1f7: keyData[6:0] <= 7'h7F;
			  9'h1f8: keyData[6:0] <= 7'h7F;
			  9'h1f9: keyData[6:0] <= 7'h7F;
			  9'h1fa: keyData[6:0] <= 7'h7F;	//ps2 ack code(duplicate see $fa)
			  9'h1fb: keyData[6:0] <= 7'h7F;
			  9'h1fc: keyData[6:0] <= 7'h7F;
			  9'h1fd: keyData[6:0] <= 7'h7F;
			  9'h1fe: keyData[6:0] <= 7'h7F;
			  9'h1ff: keyData[6:0] <= 7'h7F;
				endcase
				keyData[7] <= ~press;   // 1 = key-up, 0 = key-down
			end

			// push decoded key into the FIFO (one cycle after decode)
			if (key_pending && keyData[6:0] != 7'h7F) begin
				kbdFifo[kbdFifoWr] <= keyData;
				kbdFifoWr <= kbdFifoWr + 3'd1;
			end

			// ---- PS2 mouse: update on the synchronized strobe edge ----
			if (mouse_edge) begin
				mstb_d <= mstb_s3;
				if (mX_s2 != 9'd0 || mY_s2 != 9'd0 || mBtn_s2 != mouseButton) begin
					// clamp signed-9 delta to signed-7 (matches lbmactwo)
					if (~mX_s2[8] & |mX_s2[7:6])       mouseX <= 7'h3F;
					else if (mX_s2[8] & ~mX_s2[6])     mouseX <= 7'h40;
					else                                mouseX <= mX_s2[6:0];
					if (~mY_s2[8] & |mY_s2[7:6])       mouseY <= 7'h40;
					else if (mY_s2[8] & ~mY_s2[6])     mouseY <= 7'h3F;
					else                                mouseY <= -mY_s2[6:0];
					mouseButton <= mBtn_s2;
					mouse_evt   <= 1'b1;
				end
			end

			// ---- ADB line state machine ----
			case (st)
			S_IDLE: begin
				dev_line <= 1'b1;
				if (rise && (dur > T_ATTN)) begin
					st <= S_ATTN; command <= 0; bitcnt <= 0;
				end
			end
			S_ATTN: begin
				if (fall) begin st <= S_BITS; command <= 0; bitcnt <= 0; end
			end
			S_BITS: begin
				if (fall) begin
					command <= {command[6:0], (dur > T_BITTH)};
					bitcnt  <= bitcnt + 4'd1;
					if (bitcnt == 4'd7) st <= S_TSTOP;
				end
			end
			S_TSTOP: begin
				if (rise) begin
					resp_len <= 2'd0;
					if (cmd_type == 2'b00 && cmd_reg == 2'b00) begin
						kbd_addr <= ADDR_KBD; mouse_addr <= ADDR_MOUSE; mouse_init <= 1'b1;
						st <= S_T1T; sendtmr <= D_T1T; dev_line <= 1'b1;
					end
					// Listen Register 3 to one of our addresses = address reassignment.
					// The host (Egret) follows the command with a 16-bit data packet that
					// carries the new bus address; receive it in S_LRX_* and relocate.
					// The OS does this during ADBReInit when System loads; without it the
					// device is lost off its default address and the mouse/keyboard freeze.
					else if (cmd_type == 2'b10 && cmd_reg == 2'b11 &&
					         (cmd_addr == kbd_addr || cmd_addr == mouse_addr)) begin
						lrx_target <= (cmd_addr == mouse_addr);  // 1 = mouse, 0 = keyboard
						lrx_sr <= 16'd0; bitcnt <= 4'd0;
						st <= S_LRX_WAIT; dev_line <= 1'b1;
`ifdef USE_ADB_ISSP
						dbg_listen_seen <= dbg_listen_seen + 8'd1;
`endif
					end
					else if (cmd_type == 2'b11) begin // Talk
						if (cmd_addr == kbd_addr) begin
							case (cmd_reg)
								2'd3: begin resp0 <= {1'b0,1'b1,1'b1,1'b0,kbd_addr}; resp1 <= 8'h02; resp_len <= 2'd2; end
								2'd2: begin resp0 <= 8'hFF; resp1 <= 8'hFF; resp_len <= 2'd2; end
								2'd0: begin
									if (!kbdFifoEmpty) begin
										resp0 <= kbdFifo[kbdFifoRd];
										if (kbdFifoRd + 3'd1 != kbdFifoWr) begin
											resp1 <= kbdFifo[kbdFifoRd + 3'd1];
											kbdFifoRd <= kbdFifoRd + 3'd2;
										end else begin
											resp1 <= 8'hFF;
											kbdFifoRd <= kbdFifoRd + 3'd1;
										end
										resp_len <= 2'd2;
									end
								end
								default: ;
							endcase
						end
						else if (cmd_addr == mouse_addr) begin
							case (cmd_reg)
								2'd3: begin resp0 <= {1'b0,1'b1,1'b1,1'b0,mouse_addr}; resp1 <= 8'h01; resp_len <= 2'd2; end
								2'd0: begin
									if (mouse_evt) begin
										resp0 <= {~mouseButton, mouseY};
										resp1 <= {1'b1, mouseX};
										resp_len <= 2'd2;
										mouse_evt <= 1'b0; mouseX <= 0; mouseY <= 0;
									end else if (mouse_init) begin
										resp0 <= 8'h80; resp1 <= 8'h80; resp_len <= 2'd2;
										mouse_init <= 1'b0;
									end
								end
								default: ;
							endcase
						end
						// SRQ: if a device has data but this poll wasn't for it, hold the
						// bus low after the command so the Egret services it next.
						if (srq_want) begin
							dev_line <= 1'b0; sendtmr <= D_SRQ; st <= S_SRQ;
						end else begin
							st <= S_T1T; sendtmr <= D_T1T; dev_line <= 1'b1;
						end
					end
					else begin
						// Flush / Listen to another register / Talk to another address: no response
						if (srq_want) begin
							dev_line <= 1'b0; sendtmr <= D_SRQ; st <= S_SRQ;  // SRQ
						end else begin
							st <= S_T1T; sendtmr <= D_T1T; dev_line <= 1'b1;
						end
					end
				end
			end
			S_SRQ: begin
				// Hold the bus low to signal a pending mouse event (ADB Service Request),
				// then drop into the normal response/idle path. The Egret detects the low
				// and follows up by polling the mouse (Talk R0), which then sends data.
				if (sendtmr != 0) sendtmr <= sendtmr - 18'd1;
				else begin dev_line <= 1'b1; st <= S_T1T; sendtmr <= D_T1T; end
			end
			S_T1T: begin
				if (sendtmr != 0) sendtmr <= sendtmr - 18'd1;
				else if (resp_len == 0) begin st <= S_IDLE; dev_line <= 1'b1; end
				else begin
					st <= S_SEND; send_stage <= 0; send_byte <= 0;
					send_sr <= resp0; send_bits <= 4'd8;
					dev_line <= 1'b0; sendtmr <= D_SHORT;
				end
			end
			S_SEND: begin
				if (sendtmr != 0) sendtmr <= sendtmr - 18'd1;
				else case (send_stage)
					4'd0: begin dev_line <= 1'b1; sendtmr <= D_LONG; send_stage <= 4'd1; end
					4'd1: begin cur_bit <= send_sr[7]; dev_line <= 1'b0;
						sendtmr <= send_sr[7] ? D_SHORT : D_LONG; send_stage <= 4'd2; end
					4'd2: begin dev_line <= 1'b1; sendtmr <= cur_bit ? D_LONG : D_SHORT; send_stage <= 4'd3; end
					4'd3: begin
						if (send_bits == 4'd1) begin
							if (send_byte + 2'd1 < resp_len) begin
								send_byte <= send_byte + 2'd1; send_sr <= resp1; send_bits <= 4'd8;
								cur_bit <= resp1[7]; dev_line <= 1'b0;
								sendtmr <= resp1[7] ? D_SHORT : D_LONG; send_stage <= 4'd2;
							end else begin
								dev_line <= 1'b0; sendtmr <= D_SHORT; send_stage <= 4'd4;
							end
						end else begin
							send_sr <= {send_sr[6:0],1'b0}; send_bits <= send_bits - 4'd1;
							cur_bit <= send_sr[6]; dev_line <= 1'b0;
							sendtmr <= send_sr[6] ? D_SHORT : D_LONG; send_stage <= 4'd2;
						end
					end
					4'd4: begin dev_line <= 1'b1; sendtmr <= D_LONG; send_stage <= 4'd5; end
					default: begin dev_line <= 1'b1; st <= S_IDLE; end
				endcase
			end
			// ---- Listen data reception (host -> device, e.g. Register 3 reassign) ----
			// Mirrors the command receive framing: sample each data bit at the falling
			// edge from the preceding high-phase length (long high = 1). The packet is a
			// start bit then 16 data bits; a long-low attention re-syncs to a new command.
			S_LRX_WAIT: begin
				if (rise && (dur > T_ATTN)) begin st <= S_ATTN; command <= 0; bitcnt <= 0; end
				else if (fall) st <= S_LRX_START;   // start-bit low begins
			end
			S_LRX_START: begin
				if (rise && (dur > T_ATTN)) begin st <= S_ATTN; command <= 0; bitcnt <= 0; end
				else if (fall) begin st <= S_LRX_BITS; bitcnt <= 4'd0; end  // consume start bit
			end
			S_LRX_BITS: begin
				if (rise && (dur > T_ATTN)) begin st <= S_ATTN; command <= 0; bitcnt <= 0; end
				else if (fall) begin
					lrx_sr <= {lrx_sr[14:0], (dur > T_BITTH)};  // sample data bit (long high = 1)
					bitcnt <= bitcnt + 4'd1;
					if (bitcnt == 4'd15) st <= S_LRX_DONE;       // 16 data bits captured
				end
			end
			S_LRX_DONE: begin
				// Register 3 payload: byte0 bits[3:0] = new address, byte1 = handler ID.
				// Honor only a VALID relocation: handler != self-test (0xFF) AND a real
				// ADB address (1..15). A garbage 0 capture must NOT relocate the device
				// to address 0 — the host never polls address 0, so that kills it.
				if (lrx_sr[7:0] != 8'hFF && lrx_sr[11:8] != 4'd0) begin
					if (lrx_target) mouse_addr <= lrx_sr[11:8];
					else            kbd_addr   <= lrx_sr[11:8];
				end
`ifdef USE_ADB_ISSP
				dbg_listen_done <= dbg_listen_done + 8'd1;
`endif
				st <= S_IDLE; dev_line <= 1'b1;
			end
			default: st <= S_IDLE;
			endcase
		end
	end

`ifdef SIMULATION
	always @(posedge clk)
		if (!reset && st == S_TSTOP && rise)
			$display("ADBDEV[%0t]: cmd=%02x (addr=%0d type=%0d reg=%0d) resp_len=%0d",
			         $time, command, command[7:4], command[3:2], command[1:0], resp_len);
	always @(posedge clk)
		if (!reset && st == S_LRX_DONE && lrx_sr[7:0] != 8'hFF)
			$display("ADBDEV[%0t]: Listen R3 reassign %s -> addr %0d (handler %02x)",
			         $time, lrx_target ? "mouse" : "kbd", lrx_sr[11:8], lrx_sr[7:0]);
`endif

`ifdef USE_ADB_ISSP
	// JTAG In-System Sources & Probes (read-only) — JTAG observability without SignalTap.
	// Read live in Quartus: Tools > In-System Sources and Probes Editor, instance "ADB".
	//   probe[7:0]   = last ADB command byte (addr<<4 | type<<2 | reg)
	//   probe[11:8]  = mouse_addr  (boot default 3; should change after System ADBReInit)
	//   probe[15:12] = kbd_addr    (boot default 2)
	//   probe[31:16] = last Listen-Register-3 payload {addr/flags byte, handler byte}
	// Enabled via the USE_ADB_ISSP macro in MacLC.qsf; absent from release/Verilator builds.
	// ---- mouse/keyboard data-path diagnostics (separate block; does not touch FSM) ----
	reg [7:0] dbg_mtalk, dbg_ktalk, dbg_mmove, dbg_mresp;
	reg [7:0] dbg_kbd_evt, dbg_ksrq;
	always @(posedge clk) begin
		if (reset) begin
			dbg_mtalk<=0; dbg_ktalk<=0; dbg_mmove<=0; dbg_mresp<=0;
			dbg_kbd_evt<=0; dbg_ksrq<=0;
		end
		else begin
			if (st == S_TSTOP && rise && cmd_type == 2'b11 && cmd_reg == 2'd0) begin
				if (cmd_addr == mouse_addr) begin
					dbg_mtalk <= dbg_mtalk + 8'd1;          // OS polled the mouse (Talk R0)
					if (mouse_evt) dbg_mresp <= dbg_mresp + 8'd1;  // device had data to send
				end
				if (cmd_addr == kbd_addr) dbg_ktalk <= dbg_ktalk + 8'd1; // OS polled the keyboard
			end
			if (mouse_edge && (mX_s2 != 9'd0 || mY_s2 != 9'd0 || mBtn_s2 != mouseButton))
				dbg_mmove <= dbg_mmove + 8'd1;             // PS2 movement reached adb_device
			// keyboard data-path diagnostics:
			//   kbd_evt = a decoded key was pushed into kbdFifo (the PS2->ADB path works)
			//   ksrq    = a command NOT addressed to the keyboard was seen while the kbd FIFO
			//             held data, so the device asserted a Service Request to be polled.
			// Reading kbd_evt>0, ksrq>0, but ktalk static => Egret ignores the kbd SRQ.
			if (key_pending && keyData[6:0] != 7'h7F)
				dbg_kbd_evt <= dbg_kbd_evt + 8'd1;
			if (st == S_TSTOP && rise && !kbdFifoEmpty && cmd_addr != kbd_addr)
				dbg_ksrq <= dbg_ksrq + 8'd1;
		end
	end
	// [7:0]=command [11:8]=mouse_addr [15:12]=kbd_addr [23:16]=mtalk [31:24]=mmove
	// [39:32]=mresp [47:40]=ktalk [55:48]=kbd_evt [63:56]=ksrq
	wire [63:0] adb_probe_bus = { dbg_ksrq, dbg_kbd_evt, dbg_ktalk, dbg_mresp,
	                              dbg_mmove, dbg_mtalk, kbd_addr, mouse_addr, command };
	altsource_probe #(
		.sld_auto_instance_index ("YES"),
		.sld_instance_index      (0),
		.instance_id             ("ADB"),
		.probe_width             (64),
		.source_width            (0),
		.source_initial_value    ("0"),
		.enable_metastability    ("NO")
	) u_adb_issp (
		.probe  (adb_probe_bus),
		.source ()
	);
`endif

endmodule
