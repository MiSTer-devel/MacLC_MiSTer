#!/usr/bin/env python3
"""Decode + structurally analyze a Mac 6-and-2 GCR byte stream.
Parses address fields (D5 AA 96) and data fields (D5 AA AD), decodes the
header, verifies the address checksum, and measures each data field's length
(D5 AA AD .. DE AA). Runs on my on-chip capture and on MAME's delivered stream.
"""
import sys, re

# 6-and-2 GCR disk-byte -> 6-bit value
GCR = [
 0x96,0x97,0x9A,0x9B,0x9D,0x9E,0x9F,0xA6,0xA7,0xAB,0xAC,0xAD,0xAE,0xAF,0xB2,0xB3,
 0xB4,0xB5,0xB6,0xB7,0xB9,0xBA,0xBB,0xBC,0xBD,0xBE,0xBF,0xCB,0xCD,0xCE,0xCF,0xD3,
 0xD6,0xD7,0xD9,0xDA,0xDB,0xDC,0xDD,0xDE,0xDF,0xE5,0xE6,0xE7,0xE9,0xEA,0xEB,0xEC,
 0xED,0xEE,0xEF,0xF2,0xF3,0xF4,0xF5,0xF6,0xF7,0xF9,0xFA,0xFB,0xFC,0xFD,0xFE,0xFF]
DEC = {b: i for i, b in enumerate(GCR)}

def load_flat(path):
    txt = open(path).read()
    # accept either a pure hex blob or the dump file's "FLAT" section
    m = re.split(r'FLAT.*?\n', txt, flags=re.S)
    body = m[1] if len(m) > 1 else txt
    hexs = re.findall(r'[0-9A-Fa-f]{2}', body)
    # if the dump had a scan section after, cut at first non-hex run already handled
    return [int(h, 16) for h in hexs]

def analyze(name, data):
    print(f"\n===== {name}: {len(data)} bytes =====")
    i = 0
    n = len(data)
    events = []
    while i < n - 2:
        if data[i] == 0xD5 and data[i+1] == 0xAA and data[i+2] == 0x96:
            # address field: D5 AA 96, then trk sec side fmt cksum, then DE AA
            f = data[i+3:i+8]
            if len(f) == 5 and all(b in DEC for b in f):
                trk, sec, side, fmt, cks = (DEC[b] for b in f)
                calc = trk ^ sec ^ side ^ fmt
                ok = "OK " if calc == cks else f"BAD(calc={calc:#04x})"
                events.append(('ADDR', i, f"trk={trk} sec={sec} side={side} fmt={fmt:#04x} cks={cks:#04x} {ok}"))
            else:
                events.append(('ADDR?', i, "malformed/ non-GCR header bytes"))
            i += 3
        elif data[i] == 0xD5 and data[i+1] == 0xAA and data[i+2] == 0xAD:
            # data field: D5 AA AD .. find DE AA
            j = i + 3
            while j < n - 1 and not (data[j] == 0xDE and data[j+1] == 0xAA):
                j += 1
            body = data[i+3:j]
            found = (j < n - 1)
            # content stats
            zeros = sum(1 for b in body if b == 0x96)
            valid = sum(1 for b in body if b in DEC)
            events.append(('DATA', i,
                f"len={len(body)} (D5AAAD..DEAA {'closed' if found else 'UNTERMINATED'}) "
                f"gcr96/zero={zeros} nonGCR={len(body)-valid} head={' '.join('%02X'%b for b in body[:6])}"))
            i = j + 2 if found else j
        else:
            i += 1
    for typ, off, msg in events:
        print(f"  @{off:04X} {typ:5s} {msg}")
    # summarize data-field lengths
    dl = [int(re.search(r'len=(\d+)', m).group(1)) for t,o,m in events if t=='DATA']
    if dl:
        print(f"  data-field lengths: {dl}  (Mac 524-byte sector -> ~699-703 GCR expected)")
    return events

for path, label in [(sys.argv[1], "CAPTURE (0dcf73e track0)"),
                    (sys.argv[2], "MAME 800k delivered")]:
    analyze(label, load_flat(path))
