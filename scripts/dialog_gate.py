#!/usr/bin/env python3
"""Classify a MacLC screenshot: is a Finder ERROR DIALOG actually on screen?

Why this exists (2026-08-05): scratch/copy_babysit.sh detected "a dialog is
up" from the deactivated Copy window's lavender progress track. That test
false-fired on 12 of 17 captures in one whole-disk copy run — the frames were
the plain desktop — and inflated the error count 3x (17 reported vs 5 real),
which is exactly the kind of bad reference that has burned this project
before. A white-panel + black-text test does NOT separate them either: the
Finder window behind the alert is also white with black labels.

What DOES separate them is the alert's exclamation triangle, which renders at
a fixed position. Measured over all 17 run-1 captures:
    real dialog : 242 dark px      desktop frame : 88 dark px
so the threshold sits at a comfortable 150.

Usage:  dialog_gate.py <frame.png> [more.png ...]
Exit code 0 if the LAST frame given shows a dialog, 1 if not (so it can gate
a shell loop). Prints one line per frame.
"""
import sys
import numpy as np
from PIL import Image

# Alert-triangle box in core-resolution pixels, and the separation threshold.
TRI_BOX = (slice(100, 140), slice(152, 196))
TRI_MIN = 150


def has_dialog(path):
    a = np.array(Image.open(path).convert('L')).astype(int)
    tri = int((a[TRI_BOX] < 100).sum())
    return tri >= TRI_MIN, tri


def main(paths):
    last = False
    for p in paths:
        try:
            last, tri = has_dialog(p)
        except Exception as e:                      # unreadable/short frame
            print(f"{p}: ERROR {e}")
            last = False
            continue
        print(f"{p}: {'DIALOG' if last else 'no dialog'} (triangle={tri})")
    return 0 if last else 1


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1:]))
