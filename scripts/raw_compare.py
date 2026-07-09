#!/usr/bin/env python3
"""Compare a floppy_ring v2 dump's RAW fetch stream against the disk image.

Usage: raw_compare.py <ring_dump.txt> <image.dsk>

Parses the per-strobe table (lines "S###: AAAA  s/ooo  RR EE"), then for each
strobe checks raw against image[addr-1 .. addr+1] (the fetch latch leads/lags
the emitted byte by up to one position while the prefetch pipeline advances).
Verdict: what fraction of the capture window's raw bytes ARE the image content
at the captured fetch address vs zeros vs something else entirely.

Also prints the image's nonzero 16-bit-word count (the dl_nonzero reference:
words with EITHER byte nonzero, counted over the whole 819200-byte image).
"""
import sys, re

dump_path, img_path = sys.argv[1], sys.argv[2]
img = open(img_path, 'rb').read()

strobes = []
for line in open(dump_path):
    m = re.match(r'S(\d+):\s+([0-9A-Fa-f]{4})\s+\d+/\d+\s+([0-9A-Fa-f]{2})\s+([0-9A-Fa-f]{2})', line)
    if m:
        strobes.append((int(m.group(1)), int(m.group(2), 16),
                        int(m.group(3), 16), int(m.group(4), 16)))

if not strobes:
    sys.exit("no S-table lines found — is this a v2 ring dump?")

match = zero_raw = other = in_range = 0
mismatches = []
for i, addr, raw, enc in strobes:
    if addr < len(img):
        in_range += 1
    neigh = [img[a] for a in (addr - 1, addr, addr + 1) if 0 <= a < len(img)]
    if raw in neigh:
        match += 1
        if raw == 0:
            zero_raw += 1  # matched, but content there is genuinely zero
    elif raw == 0:
        zero_raw += 1
    else:
        other += 1
        if len(mismatches) < 10:
            mismatches.append((i, addr, raw, neigh))

n = len(strobes)
print(f"strobes={n}  addr-in-image={in_range}")
print(f"raw matches image[addr±1]: {match}/{n}")
print(f"raw==0 (unmatched or matching true zero content): {zero_raw}/{n}")
print(f"raw nonzero but NOT image content: {other}/{n}")
for i, addr, raw, neigh in mismatches:
    print(f"  S{i:03d} addr={addr:#06x} raw={raw:#04x} image[addr-1..+1]={['%02X' % b for b in neigh]}")

nz_words = sum(1 for k in range(0, len(img) - 1, 2) if img[k] or img[k + 1])
print(f"\nimage nonzero-word count (dl_nonzero reference): {nz_words} of {len(img)//2}")
# dl_xor reference: dio_data = {even byte, odd byte} per accepted word
x = 0
for k in range(0, len(img) - 1, 2):
    x ^= (img[k] << 8) | img[k + 1]
print(f"image word-XOR (dl_xor reference): 0x{x:04X}")

if match > n * 0.9:
    print("VERDICT: raw stream IS the image content at the fetch address — the")
    print("  SDRAM content + fetch path are GOOD; look downstream (encoder handoff).")
elif zero_raw > n * 0.9:
    nz_img = sum(1 for _, a, _, _ in strobes if a < len(img) and img[a])
    print(f"VERDICT: raw stream is zeros while the image at those addresses has")
    print(f"  {nz_img}/{n} nonzero bytes — SDRAM does NOT hold the image there:")
    print("  download path (cross-check dl_words/dl_nonzero) or region clobber.")
