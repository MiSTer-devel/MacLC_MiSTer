#!/usr/bin/env python
"""Finder colour-icon corruption gate (Class B SCSI read-path marginality).

Usage:
  python scripts/icon_gate.py <screenshot.png> [more.png ...]
Exit 0 = every frame PASSES; 1 = any FAIL; frames must be fresh captures
(use scripts/grab_fresh.sh — a stale frame invalidates the verdict).

CLAUDE.md law: gate EVERY new fit in the FINDER on colour icons, then soak
>=2 further Finder boots (the historic error-11 hits boot 2). MacAtrium is
NOT a gate. Boot lands in MacAtrium (auto-start); reach the Finder via
Application menu > Hide MacAtrium, and PARK THE CURSOR TOP-LEFT (12x
mouseMove:-60,-60) before capturing — it contaminates the volume-icon cell.

Requires the standard bench guest (MacAtrium_Sys window at its default boot
spot, 640x480). Cells + validated readings (good = releases/MacLC_20260802-era
Finder, bad = probes-off fit ccb82d32, both captured 2026-08-03):
  SystemPicker folder (178,88,232,132): colours 4 vs 99   -> pass ncol<=12
  TestGame folder (148,155,205,198):  colour_px 324 vs 0  -> pass ncol<=12 and cpx>100
  Volume icon (580,35,630,65):        darkblue 0 vs 408   -> pass <50
  Tools control (36,95,72,130):       corrupt fits strip even folder tints
colour_px counts pixels with ANY channel spread (>0): the clean folder tint is
pale (218,218,255 — spread 37), so a saturation threshold like >40 false-fails.
"""
import sys
import numpy as np
from PIL import Image

def score(path):
    im = np.array(Image.open(path).convert("RGB")).astype(int)
    if im.shape[:2] != (480, 640):
        print(f"== {path}: UNEXPECTED SIZE {im.shape[1]}x{im.shape[0]} — cells invalid")
        return "ERROR"
    print(f"== {path}")
    checks = []

    def cell(x0, y0, x1, y1):
        return im[y0:y1, x0:x1]

    def ncol(a):
        return len(np.unique(a.reshape(-1, 3), axis=0))

    def cpx(a):
        return int(((a.max(axis=2) - a.min(axis=2)) > 0).sum())

    sp = cell(178, 88, 232, 132)
    checks.append(("SystemPicker", f"colours={ncol(sp)}", ncol(sp) <= 12))
    tg = cell(148, 155, 205, 198)
    checks.append(("TestGame", f"colours={ncol(tg)} colour_px={cpx(tg)}",
                   ncol(tg) <= 12 and cpx(tg) > 100))
    vi = cell(580, 35, 630, 65)
    db = int(((vi[..., 2] > vi[..., 0] + 25) & (vi[..., 2] < 200)).sum())
    checks.append(("VolumeIcon", f"darkblue_px={db}", db < 50))
    tl = cell(36, 95, 72, 130)
    checks.append(("Tools(ctrl)", f"colours={ncol(tl)} colour_px={cpx(tl)}",
                   ncol(tl) <= 12 and cpx(tl) > 100))

    ok_all = True
    for name, stat, ok in checks:
        print(f"  {name:14s} {stat:32s} {'ok' if ok else '<-- FAIL'}")
        ok_all &= ok
    print(f"  VERDICT: {'PASS' if ok_all else 'FAIL'}")
    return "PASS" if ok_all else "FAIL"

if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    results = [score(p) for p in sys.argv[1:]]
    sys.exit(0 if all(r == "PASS" for r in results) else 1)
