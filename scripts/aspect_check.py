#!/usr/bin/env python3
"""Offline regression gate for the MacLC "Original" aspect ratio.

The Verilator sim does not instantiate video_freak (verilator/sim.v has no
VIDEO_ARX), so this is the only automated check on the aspect path. It

  1. parses the default (ar==0, "Original") ARX/ARY out of MacLC.sv's
     video_freak instance,
  2. runs them through a faithful software model of
     sys/video_freak.sv :: video_scale_int (sys_udiv/sys_umul are plain
     floor integer division/multiplication; V-Integer emits div_num —
     i.e. htarget itself, NOT the integer-multiple width — which is
     exactly how 256:171 overflowed a 1280 px panel with a 1437 px
     request), and
  3. fails (exit 1) if any output mode's requested size overflows the
     panel, or an integer-scale result is not exactly 4:3, or not an
     integer multiple of the source resolution.

History: the import-era default was 256:171 — the Mac PLUS 512x342
screen. The Mac LC is 4:3 in both monitor modes (640x480 VGA id 6,
512x384 12" RGB id 2). 256:171 drew ~12% too wide everywhere and blank-
screened 1280x1024 (V-Integer: 960*256/171 = 1437 > 1280). Run with
--show-broken to see those historical failures demonstrated.

Usage:  python3 scripts/aspect_check.py [--show-broken]
"""
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# Output modes to cover (the common MiSTer panel/forced modes).
MODES = [(1280, 720), (1920, 1080), (1280, 1024), (1024, 768),
         (2560, 1440), (800, 600)]

# The two LC video sources: VGA (monitor id 6, default) and 12" RGB (id 2).
SOURCES = [("VGA 640x480", 640, 480), ("12\" RGB 512x384", 512, 384)]

SCALE_NAMES = {1: "V-Integer", 2: "Narrower HV-Int", 3: "Wider HV-Int"}

M12 = 0xFFF  # video_scale_int does 12-bit unsigned arithmetic


def scale_int(W, H, SCALE, hsize, vsize, arx, ary):
    """Faithful model of sys/video_freak.sv :: video_scale_int.

    Returns ('ratio', arx, ary) when the block passes the aspect through,
    or ('size', width, height) when it emits a scaled size (VIDEO_ARX[12]
    set — see sys/emu_ports.vh). Integer division is floor, like sys_udiv.
    """
    if SCALE == 0 or (ary == 0 and arx != 0):
        return ('ratio', arx, ary)                      # top passthrough

    k = H // vsize                                      # cnt0
    if k == 0:
        return ('ratio', arx, ary)                      # cnt1: can't scale
    oheight = vsize * k                                 # cnt1/2

    htarget = None
    if ary == 0:                                        # cnt2 -> width path
        div_num = W
        kw = max(W // hsize, 1)                         # cnt8/9 (?:1 guard)
        hinteger = hsize * kw
        oheight = vsize * kw                            # cnt11 re-derives
    else:
        htarget = (oheight * arx) // ary                # cnt3/4
        div_num = htarget                               # kept for SCALE==1
        cand = hsize * max(htarget // hsize, 1)         # cnt5/6 (?:1 guard)
        if cand <= W:                                   # cnt7
            hinteger = cand
        else:                                           # overflow -> width path
            div_num = W
            kw = max(W // hsize, 1)
            hinteger = hsize * kw
            oheight = vsize * kw

    wideres = (hinteger + hsize) & M12                  # cnt12
    if htarget is None:
        wres = wideres                                  # (ary==0: stale htarget
        narrow = wideres > W                            #  path unused by us)
    else:
        narrow = (((htarget - hinteger) & M12) <= ((wideres - htarget) & M12)) \
                 or (wideres > W)
        wres = hinteger if hinteger == htarget else wideres

    if SCALE == 2:                                      # cnt13
        aw = hinteger
    elif SCALE == 3:
        aw = hinteger if wres > W else wres
    elif SCALE == 4:
        aw = hinteger if narrow else wres
    else:                                               # SCALE==1: div_num!
        aw = div_num
    return ('size', aw, oheight)


def parse_default_ar():
    """Pull the ar==0 ("Original") ARX/ARY defaults out of MacLC.sv."""
    src = (REPO / "MacLC.sv").read_text(encoding="utf-8", errors="replace")
    mx = re.search(r"\.ARX\(\(!ar\)\s*\?\s*12'd(\d+)", src)
    my = re.search(r"\.ARY\(\(!ar\)\s*\?\s*12'd(\d+)", src)
    if not mx or not my:
        sys.exit("aspect_check: could not find video_freak ARX/ARY defaults "
                 "in MacLC.sv — instance reformatted? Update the regexes.")
    return int(mx.group(1)), int(my.group(1))


def run(arx, ary, verbose=True):
    """Run all checks for one ARX:ARY pair. Returns a list of failures."""
    fails = []
    for sname, hsize, vsize in SOURCES:
        if verbose:
            print(f"\n  source {sname}  (aspect target {arx}:{ary})")
            print(f"  {'panel':>10} | {'V-Integer':>13} | {'Narrower':>13} "
                  f"| {'Wider':>13}")
        for W, H in MODES:
            cells = []
            for SCALE in (1, 2, 3):
                kind, w, h = scale_int(W, H, SCALE, hsize, vsize, arx, ary)
                where = (f"{sname} {W}x{H} {SCALE_NAMES[SCALE]}")
                if kind == 'ratio':
                    cells.append("(ratio)")
                    continue
                cells.append(f"{w}x{h}")
                if w > W:
                    fails.append(f"{where}: requested width {w} > panel {W}")
                if h > H:
                    fails.append(f"{where}: requested height {h} > panel {H}")
                # Integer-scale geometry: exactly 4:3 and a whole multiple
                # of the source. V-Integer's width is htarget, which for a
                # 4:3 source*target lands exactly on k*hsize — so the same
                # test applies to all three modes.
                if w * 3 != h * 4:
                    fails.append(f"{where}: {w}x{h} is not 4:3")
                if w % hsize or h % vsize:
                    fails.append(f"{where}: {w}x{h} not an integer multiple "
                                 f"of {hsize}x{vsize}")
            if verbose:
                print(f"  {W:>5}x{H:<4} | {cells[0]:>13} | {cells[1]:>13} "
                      f"| {cells[2]:>13}")
    return fails


def main():
    if "--show-broken" in sys.argv:
        print("Historical defaults 256:171 (Mac Plus 512x342) — expected "
              "failures, demonstration only:")
        for f in run(256, 171, verbose=True):
            print(f"    BROKEN: {f}")
        print()

    arx, ary = parse_default_ar()
    print(f"MacLC.sv \"Original\" aspect default: {arx}:{ary}")
    if (arx, ary) != (4, 3):
        print(f"FAIL: default aspect is {arx}:{ary}, expected 4:3 "
              "(both LC monitor modes are 4:3; 256:171 was the Mac Plus "
              "512x342 leftover)")
        return 1

    fails = run(arx, ary)
    if fails:
        print("\nFAILURES:")
        for f in fails:
            print(f"  {f}")
        return 1
    print("\nOK: no panel overflow; every integer-scale result is exactly "
          "4:3 and an integer multiple of its source.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
