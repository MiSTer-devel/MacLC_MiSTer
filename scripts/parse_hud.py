#!/usr/bin/env python3
"""Decode the USE_DBG_HUD binary pixel strip from a MiSTer screenshot.

HUD layout (MacLC.sv USE_DBG_HUD block): 8 rows x 32 cells, top-left corner.
Cell = 8px wide x 8 lines tall at core resolution (screenshot may be integer-
scaled; a ~1px right shift comes from the pipeline stage). MSB first,
white=1 / black=0.
  row 0  32'hA5C3F00F                          marker (self-calibration)
  row 1  {byte_cnt[15:0], miss_cnt[15:0]}
  row 2  {side, track[6:0], step_cnt[15:0], 5'b0, ism_error[2:0]}
  row 3  {10'b0, dskReadAddrInt[21:0]}         live fetch BYTE address
  row 4  {err_onset_cnt[7:0], arm[7:0], ovr[7:0], unr[7:0]}
  row 5  {e142_first[15:0], e142_last[15:0]}   Sony driver result codes
  row 6  {e142_nz_cnt[15:0], e142_all_cnt[15:0]}
  row 7  {strb_cnt[15:0], strb_en_cnt[15:0]}
  row 10 latch @ first nonzero $142 {side, track[6:0], 2'b0, addr[21:0]}

The $142 watcher (2026-08-05): the ROM Sony driver posts every MFM read
result as a word write to low-mem $142 (ROM a6ea60); nonzero = the exact
Mac error code behind the guest's "disk error" dialog.

Usage: parse_hud.py <frame.png> [more.png ...]
"""
import sys
import numpy as np
from PIL import Image

MARKER = 0xA5C3F00F
NROWS = 12

def find_and_decode(img):
    g = np.array(img.convert('L')) > 128
    H, W = g.shape
    for s in (1, 2, 3, 4):          # integer scale
        cw = 8 * s                   # cell width/height in screenshot px
        for y0 in range(0, min(40, H - NROWS * cw)):
            yc = y0 + cw // 2        # sample line of row 0
            for x0 in range(0, min(3 * s + 4, W - 32 * cw)):
                val = 0
                ok = True
                for i in range(32):
                    xc = x0 + i * cw + cw // 2
                    # 3-sample majority along x for noise robustness
                    v = int(g[yc, xc]) + int(g[yc, xc - 1]) + int(g[yc, xc + 1])
                    val = (val << 1) | (1 if v >= 2 else 0)
                if val != MARKER:
                    continue
                # locked: decode all rows at (x0, y0, s)
                words = []
                for r in range(NROWS):
                    yr = y0 + r * cw + cw // 2
                    w = 0
                    for i in range(32):
                        xc = x0 + i * cw + cw // 2
                        v = int(g[yr, xc]) + int(g[yr, xc - 1]) + int(g[yr, xc + 1])
                        w = (w << 1) | (1 if v >= 2 else 0)
                    words.append(w)
                return (x0, y0, s), words
    return None, None

def sec_geom(byte_addr):
    sec = byte_addr >> 9
    ts, s_in = divmod(sec, 18)
    cyl, head = divmod(ts, 2)
    return f"sector {sec} (cyl {cyl} head {head} sec {s_in}, +{byte_addr & 511} B)"

SONY_ERR = {
    0xFFC0: "-64 noDriveErr", 0xFFBF: "-65 offLinErr", 0xFFBE: "-66 noNybErr (byte poll budget expired)",
    0xFFBD: "-67 noAdrMkErr (address-mark hunt exhausted)",
    0xFFBC: "-68 dataVerErr (verify mismatch)",
    0xFFBB: "-69 badCksmErr (ID field CRC/error verdict)",
    0xFFBA: "-70 badBtSlpErr", 0xFFB9: "-71 noDtaMkErr (data-mark compare failed)",
    0xFFB8: "-72 badDCksum (data field CRC/error verdict)",
    0xFFB7: "-73 badDBtSlp", 0xFFB6: "-74 wrUnderrun", 0xFFB5: "-75 cantStepErr",
    0xFFB4: "-76 tk0BadErr", 0xFFB3: "-77 initIWMErr", 0xFFB2: "-78 twoSideErr",
    0xFFB1: "-79 spdAdjErr", 0xFFB0: "-80 seekErr", 0xFFAF: "-81 sectNFErr",
    0xFFAE: "-82 fmt1Err", 0xFFAD: "-83 fmt2Err (ROM a6e7dc posts this literal)",
    0xFFAC: "-84 verErr",
}

def sony_err(v):
    if v == 0:
        return "0 (none)"
    name = SONY_ERR.get(v)
    signed = v - 0x10000 if v & 0x8000 else v
    return name if name else f"{signed} ({v:#06x} — not a Sony -64..-81 code)"

def decode(words):
    w = words
    print(f"  w1 byte_cnt={w[1] >> 16:5d}  miss_cnt={w[1] & 0xFFFF:5d}")
    print(f"  w2 LIVE side={w[2] >> 31} track={(w[2] >> 24) & 0x7F:3d} "
          f"step_cnt={(w[2] >> 8) & 0xFFFF:5d} ism_error={w[2] & 7:03b}")
    print(f"  w3 LIVE fetch addr {w[3] & 0x3FFFFF:#08x} = {sec_geom(w[3] & 0x3FFFFF)}")
    print(f"  w4 onset_cnt={w[4] >> 24:3d} arm={(w[4] >> 16) & 0xFF:3d} "
          f"ovr={(w[4] >> 8) & 0xFF:3d} unr={w[4] & 0xFF:3d}")
    print(f"  w5 $142 FIRST err = {sony_err(w[5] >> 16)}")
    print(f"     $142 LAST  err = {sony_err(w[5] & 0xFFFF)}")
    print(f"  w6 $142 error completions={w[6] >> 16:5d}  ALL completions={w[6] & 0xFFFF:5d}")
    b1, b5 = w[7] >> 16, w[7] & 0xFFFF
    print(f"  w7 POISONED handshake samples={b1:5d}  (good CRC byte at the FIFO "
          f"head, newer byte reports CRC-bad)")
    print(f"     b5(error-pending) on handshake reads={b5:5d}")
    if len(w) > 8:
        pop2, strb = w[8] >> 16, w[8] & 0xFFFF
        print(f"  w8 pops with FIFO at 2 entries={pop2:5d}   lstrb falling edges={strb:5d}")
        if pop2:
            print("     (b1/b0 describe the byte AFTER the popped one in that state)")
    if len(w) > 9:
        m = w[9]
        mode, setup = m >> 24, (m >> 16) & 0xFF
        rej = m & 0x1FF
        print(f"  w9 MODE={mode:#04x} [motor={mode >> 7} ism={(mode >> 6) & 1} "
              f"hdsel={(mode >> 5) & 1} write={(mode >> 4) & 1} action={(mode >> 3) & 1} "
              f"drvsel={(mode >> 1) & 3:02b} clrfifo={mode & 1}]  SETUP={setup:#04x}")
        if rej & 0x100:
            print(f"     ** REJECTED STEPS: {rej & 0xFF} "
                  f"(well-formed STEP dropped because _enable was high)")
        else:
            print("     no rejected steps recorded")
    if len(w) > 10 and w[10]:
        print(f"  w10 AT FIRST $142 ERROR: side={w[10] >> 31} track={(w[10] >> 24) & 0x7F:3d} "
              f"addr {w[10] & 0x3FFFFF:#08x} = {sec_geom(w[10] & 0x3FFFFF)}")
    if len(w) > 11:
        st = w[11] >> 24
        ii, ie = (w[11] >> 17) & 1, (w[11] >> 16) & 1
        print(f"  w11 LIVE spinning={st >> 7} motor={(st >> 6) & 1} ism_sel={(st >> 5) & 1} "
              f"MOTORONreg={(st >> 4) & 1} side={(st >> 3) & 1} ism_active={(st >> 2) & 1} "
              f"action={(st >> 1) & 1} diskin={st & 1}")
        print(f"      insertDisk: internal={ii} external={ie}   "
              f"disk_data={(w[11] >> 8) & 0xFF:#04x} raw={w[11] & 0xFF:#04x}")
        if ii and not (st & 1):
            print("      ** image IS mounted to the internal slot but the drive says NO DISK")
        elif ie and not ii:
            print("      ** image landed in the EXTERNAL slot (unreachable in ISM mode)")
    nz, unr = w[6] >> 16, w[4] & 0xFF
    if b1:
        print(f"  ==> POISONING CONFIRMED: {b1} handshake sample(s) reported "
              "CRC-bad for a field whose CRC byte was correct — good sectors "
              "rejected. Restore true 2-deep FIFO semantics.")
    if b5:
        print(f"  ==> {b5} handshake read(s) saw error-pending (b5); if one "
              "lands on the ROM's CRC-byte sample it rejects that field too.")
    if nz:
        print(f"  ==> VERDICT: driver posted {nz} error completion(s); "
              f"first {sony_err(w[5] >> 16)}, last {sony_err(w[5] & 0xFFFF)}")
    elif unr:
        print(f"  ==> VERDICT: zero driver errors; {unr} unr event(s) = "
              "teardown-probe noise (expected, benign)")

for path in sys.argv[1:]:
    geom, words = find_and_decode(Image.open(path))
    if words is None:
        print(f"{path}: no HUD marker found")
        continue
    print(f"{path}: HUD at x={geom[0]} y={geom[1]} scale={geom[2]}")
    decode(words)
