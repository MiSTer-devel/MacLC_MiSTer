"""
Shared helpers for the Phase 0 floppy GCR harness: geometry (soff/spt) and
the sony_to_disk_byte forward table, extracted mechanically from the RTL
source itself so a misreading of the table cannot silently diverge from
what the core actually does.

PROVENANCE: ported 2026-09-14 from MacPlus_MiSTer sim/gcr_common.py
(branch floppy-write, commit d263851). The port is legitimate because
rtl/floppy_track_encoder.v is BYTE-IDENTICAL between the two cores --
verified by diff, not assumed, as docs/floppy_write_plan.md Phase 0
requires. If that ever stops being true, this whole harness is suspect:
re-run the diff before trusting it.

Companions: gcr_gen_image.py (synthetic disk), gcr_encoder_model.py
(cycle-accurate encoder port), gcr_decode_track.py (reference decoder +
the Phase 0 gate), gcr_test_negative.py (rejection cases).
"""
import re
import pathlib

RTL_ENCODER = pathlib.Path(__file__).resolve().parent.parent / "rtl" / "floppy_track_encoder.v"

# Geometry of a Sony 400K/800K GCR disk: the outer zones spin the same speed
# but hold fewer sectors, so sectors-per-track steps down every 16 tracks.
ZONE_SPT = [12, 11, 10, 9, 8]


def spt_of(track: int) -> int:
    """Sectors per track, one side. rtl/floppy_track_encoder.v `spt`."""
    return ZONE_SPT[min(track // 16, 4)]


def soff_of(track: int) -> int:
    """
    Cumulative single-side sector count for every track BEFORE `track`.
    Mirrors the RTL's `soff`, which is computed from track-1's zone (see
    the trackm1[6:4] ladder) rather than track's -- the boundary tracks 16,
    32, 48 and 64 are exactly where an off-by-one zone lookup would hide.
    """
    if track == 0:
        return 0
    g2 = min((track - 1) // 16, 4)
    if g2 == 0:
        return track * 12
    if g2 == 1:
        return track * 11 + 16
    if g2 == 2:
        return track * 10 + 48
    if g2 == 3:
        return track * 9 + 96
    return track * 8 + 160


def rol1_8(x: int) -> int:
    """8-bit rotate left by one -- the RTL's { c1[6:0], c1[7] }."""
    x &= 0xFF
    return ((x << 1) | (x >> 7)) & 0xFF


def extract_sony_table(path: pathlib.Path = RTL_ENCODER) -> dict:
    """
    Parse the `(si==6'hXX)?8'hYY:` entries out of the sony_to_disk_byte
    table in the RTL source. Returns {si (0-63): disk_byte (0-255)}.
    """
    text = path.read_text()
    m = re.search(r"wire \[7:0\] sony_to_disk_byte =(.*?);", text, re.DOTALL)
    if not m:
        raise RuntimeError(f"could not locate sony_to_disk_byte table in {path}")
    body = m.group(1)
    pairs = re.findall(r"si==6'h([0-9a-fA-F]+)\)\?8'h([0-9a-fA-F]+)", body)
    table = {int(si, 16): int(byte_, 16) for si, byte_ in pairs}
    # the final entry has no `si==` guard (it is the default/else case: si==0x3f)
    default_m = re.search(r":\s*8'h([0-9a-fA-F]+)\s*$", body.strip())
    if default_m:
        table[0x3F] = int(default_m.group(1), 16)
    if len(table) != 64:
        raise RuntimeError(f"expected 64 table entries, got {len(table)}: {sorted(table)}")
    return table


SONY_TABLE = extract_sony_table()
REVERSE_SONY_TABLE = {v: k for k, v in SONY_TABLE.items()}
assert len(REVERSE_SONY_TABLE) == 64, "forward table is not a bijection"

# Every encoded byte has bit 7 set and no more than one pair of adjacent
# zero bits -- the GCR run-length rule that lets the IWM find byte sync.
# Cheap invariant, and it catches a table mis-parse that still yields 64.
assert all(v & 0x80 for v in SONY_TABLE.values()), "encoded byte with clear MSB"

TOTAL_SECTORS_PER_SIDE = soff_of(80)   # 800
IMAGE_SIZE_800K = TOTAL_SECTORS_PER_SIDE * 512 * 2   # 819200


if __name__ == "__main__":
    print(f"{len(SONY_TABLE)} forward table entries extracted from {RTL_ENCODER.name}")
    print("si=0x00 ->", hex(SONY_TABLE[0]))
    print("si=0x3f ->", hex(SONY_TABLE[0x3F]))
    print(f"sectors/side = {TOTAL_SECTORS_PER_SIDE}, 800K image = {IMAGE_SIZE_800K} bytes")
    for t in (0, 15, 16, 40, 64, 79):
        print(f"  track {t:2d}: spt={spt_of(t)} soff={soff_of(t)}")
