#!/usr/bin/env python3
"""Differential check for the fetch cache: does a cached fetch ever return a
DIFFERENT instruction word than the uncached run saw at the same PC?

A naive diff of two cpu_trace.log files is useless here: enabling the cache
changes timing, so frame tags shift and interrupts land at different
instruction boundaries. Both runs are still executing the same program, so the
robust invariant is:

    for any PC in ROM space ($A00000-$AFFFFF), the instruction word at that PC
    is IMMUTABLE — ROM cannot change. If the cache-ON run ever reports a
    different opcode at a PC than the cache-OFF run did, the cache answered
    with stale/wrong data. That is the corruption mechanism, caught red-handed.

Optionally also checks the overlay mirror ($000000-$0FFFFF during early boot)
and reports RAM-PC opcode changes separately (those can be legitimate —
self-modifying code is exactly what QuickDraw does — so they are informational,
not failures).

Usage: icache_trace_diff.py trace_off.log trace_on.log
"""
import re
import sys
from collections import defaultdict

LINE = re.compile(r"^\[F(\d+)\]\s+([0-9A-Fa-f]{8}):\s+([0-9A-Fa-f]{4})\s")


def load(path, rom_only=True):
    """PC -> set of opcodes seen, plus first-sighting order for reporting."""
    seen = defaultdict(set)
    first = {}
    n = 0
    with open(path, errors="replace") as f:
        for line in f:
            m = LINE.match(line)
            if not m:
                continue
            n += 1
            pc = int(m.group(2), 16)
            op = m.group(3).upper()
            if rom_only and not (0xA00000 <= pc <= 0xAFFFFF):
                continue
            seen[pc].add(op)
            if pc not in first:
                first[pc] = (n, line.rstrip())
    return seen, first, n


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    rom_only = "--all" not in sys.argv
    off_path, on_path = args[0], args[1]
    print("scope:", "ROM space only" if rom_only else "ALL address space")
    print(f"loading OFF trace: {off_path}")
    off, off_first, off_n = load(off_path, rom_only)
    print(f"  {off_n:,} instructions, {len(off):,} distinct PCs")
    print(f"loading ON  trace: {on_path}")
    on, on_first, on_n = load(on_path, rom_only)
    print(f"  {on_n:,} instructions, {len(on):,} distinct PCs")

    # 1) any ROM PC that reported more than one opcode WITHIN a run is itself
    #    a red flag (ROM is immutable)
    for label, d in (("OFF", off), ("ON", on)):
        multi = {pc: ops for pc, ops in d.items() if len(ops) > 1}
        if multi:
            print(f"\n!! {label} run: {len(multi)} ROM PCs reported MULTIPLE opcodes")
            for pc, ops in list(multi.items())[:10]:
                print(f"   {pc:08X}: {sorted(ops)}")
        else:
            print(f"   {label} run: every ROM PC self-consistent")

    # 2) the real test — same PC, different opcode across runs
    common = set(off) & set(on)
    bad = []
    for pc in common:
        a = next(iter(off[pc])) if len(off[pc]) == 1 else None
        b = next(iter(on[pc])) if len(on[pc]) == 1 else None
        if a and b and a != b:
            bad.append((pc, a, b))
    bad.sort()

    print(f"\ncompared {len(common):,} ROM PCs present in both runs")
    if not bad:
        print("RESULT: PASS — no ROM PC ever returned a different opcode with the cache on.")
        print("        (The cache did not serve stale/wrong instructions in this workload.)")
        return 0

    print(f"RESULT: FAIL — {len(bad)} ROM PCs differ. The cache served wrong data:")
    for pc, a, b in bad[:20]:
        print(f"  PC {pc:08X}:  uncached={a}  cached={b}")
        if pc in on_first:
            print(f"      first cached sighting: {on_first[pc][1]}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
