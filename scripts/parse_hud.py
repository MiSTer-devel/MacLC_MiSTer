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
  row 5  latch @ last error onset {side, track[6:0], 2'b0, addr[21:0]}
  row 6  latch @ last error onset {byte_cnt[15:0], step_cnt[15:0]}
  row 7  {10'b0, dbg_flp_gcr_addr[21:0]}       floppy-side fetch address

Usage: parse_hud.py <frame.png> [more.png ...]
"""
import sys
import numpy as np
from PIL import Image

MARKER = 0xA5C3F00F

def find_and_decode(img):
    g = np.array(img.convert('L')) > 128
    H, W = g.shape
    for s in (1, 2, 3, 4):          # integer scale
        cw = 8 * s                   # cell width/height in screenshot px
        for y0 in range(0, min(40, H - 8 * cw)):
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
                # locked: decode all 8 rows at (x0, y0, s)
                words = []
                for r in range(8):
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

def decode(words):
    w = words
    print(f"  w1 byte_cnt={w[1] >> 16:5d}  miss_cnt={w[1] & 0xFFFF:5d}")
    print(f"  w2 LIVE side={w[2] >> 31} track={(w[2] >> 24) & 0x7F:3d} "
          f"step_cnt={(w[2] >> 8) & 0xFFFF:5d} ism_error={w[2] & 7:03b}")
    print(f"  w3 LIVE fetch addr {w[3] & 0x3FFFFF:#08x} = {sec_geom(w[3] & 0x3FFFFF)}")
    print(f"  w4 onset_cnt={w[4] >> 24:3d} arm={(w[4] >> 16) & 0xFF:3d} "
          f"ovr={(w[4] >> 8) & 0xFF:3d} unr={w[4] & 0xFF:3d}")
    print(f"  w5 LATCH side={w[5] >> 31} track={(w[5] >> 24) & 0x7F:3d} "
          f"addr {w[5] & 0x3FFFFF:#08x} = {sec_geom(w[5] & 0x3FFFFF)}")
    print(f"  w6 LATCH byte_cnt={w[6] >> 16:5d} step_cnt={w[6] & 0xFFFF:5d}")
    print(f"  w7 floppy-side addr {w[7] & 0x3FFFFF:#08x} = {sec_geom(w[7] & 0x3FFFFF)}")
    if (w[3] & 0x3FFFFF) != (w[7] & 0x3FFFFF):
        print(f"  !! w3/w7 fetch-address MISMATCH (SDRAM-slot vs floppy side)")

for path in sys.argv[1:]:
    geom, words = find_and_decode(Image.open(path))
    if words is None:
        print(f"{path}: no HUD marker found")
        continue
    print(f"{path}: HUD at x={geom[0]} y={geom[1]} scale={geom[2]}")
    decode(words)
