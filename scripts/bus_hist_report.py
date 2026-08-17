#!/usr/bin/env python3
"""Report on verilator/bus_hist.log — the Step-0 CPU bus-cycle histogram.

The log is written by the SIMULATION-only instrumentation in rtl/tg68k/tg68k.v
(branch cpu-enhancements): one WINDOW block per simulated second (32.5M clk_sys
ticks), containing
    WINDOW <n> ticks=<t> busy=<b> int_clkena=<c>
    T <busstate> <class> <ticksum>          exact ticks spent in these cycles
    H <busstate> <class> <len> <count>      cycle-length histogram (len clamped 63)

busstate: 0=fetch 1=read 2=write
class:    0=RAM 1=ROM 2=VRAM 3=VPA-periph 4=DTACK-I/O 5=other/32-bit

Cycle length = clkena-to-clkena period in clk_sys ticks (a no-wait SDRAM
access is 8).  int_clkena counts internal (busstate==01) kernel steps; each
spans 2 ticks in the current wrapper.  The per-cycle s0 gap tick lands in the
following cycle's length, so busy + 2*int_clkena + n_cycles ~= ticks.

Usage: bus_hist_report.py [bus_hist.log] [--from N] [--to N] [--windows]
"""
import sys
from collections import defaultdict

BS = ["fetch", "read", "write"]
CLS = ["RAM", "ROM", "VRAM", "VPA", "IO-DTACK", "other"]


def parse(path):
    wins = []
    cur = None
    with open(path) as f:
        for line in f:
            parts = line.split()
            if not parts:
                continue
            if parts[0] == "WINDOW":
                cur = {
                    "n": int(parts[1]),
                    "ticks": int(parts[2].split("=")[1]),
                    "busy": int(parts[3].split("=")[1]),
                    "int_clkena": int(parts[4].split("=")[1]),
                    "ticksum": defaultdict(int),
                    "hist": defaultdict(int),
                }
                wins.append(cur)
            elif parts[0] == "T" and cur is not None:
                cur["ticksum"][(int(parts[1]), int(parts[2]))] += int(parts[3])
            elif parts[0] == "H" and cur is not None:
                cur["hist"][(int(parts[1]), int(parts[2]), int(parts[3]))] += int(parts[4])
    return wins


def aggregate(wins):
    agg = {
        "ticks": 0, "busy": 0, "int_clkena": 0,
        "ticksum": defaultdict(int), "hist": defaultdict(int),
    }
    for w in wins:
        agg["ticks"] += w["ticks"]
        agg["busy"] += w["busy"]
        agg["int_clkena"] += w["int_clkena"]
        for k, v in w["ticksum"].items():
            agg["ticksum"][k] += v
        for k, v in w["hist"].items():
            agg["hist"][k] += v
    return agg


def report(a, label):
    ticks = a["ticks"]
    if not ticks:
        print(f"{label}: empty")
        return
    print(f"=== {label}: {ticks:,} ticks "
          f"({ticks / 32.5e6:.2f} s simulated) ===")
    int_ticks = 2 * a["int_clkena"]
    ncyc_total = sum(c for (_, _, _), c in
                     [(k, v) for k, v in a["hist"].items()]) if a["hist"] else 0
    ncyc_total = sum(a["hist"].values())
    print(f"  bus-cycle ticks {a['busy']:,} ({100*a['busy']/ticks:.1f}%)   "
          f"internal steps {a['int_clkena']:,} (~{100*int_ticks/ticks:.1f}% of ticks)   "
          f"cycles {ncyc_total:,}")

    # per (busstate, class): cycles, ticks, avg
    rows = []
    for (bs, cls), tsum in sorted(a["ticksum"].items()):
        n = sum(v for (b, c, _), v in a["hist"].items() if b == bs and c == cls)
        if n == 0:
            continue
        rows.append((bs, cls, n, tsum, tsum / n))
    print(f"  {'busstate':8} {'class':9} {'cycles':>10} {'ticks':>12} "
          f"{'%ticks':>7} {'avg len':>8}")
    for bs, cls, n, tsum, avg in sorted(rows, key=lambda r: -r[3]):
        print(f"  {BS[bs]:8} {CLS[cls]:9} {n:>10,} {tsum:>12,} "
              f"{100*tsum/ticks:>6.1f}% {avg:>8.2f}")

    # length distribution for the DTACK memory classes (RAM/ROM/VRAM)
    for cls in (0, 1, 2):
        dist = defaultdict(int)
        for (bs, c, ln), v in a["hist"].items():
            if c == cls:
                dist[ln] += v
        tot = sum(dist.values())
        if not tot:
            continue
        top = sorted(dist.items(), key=lambda kv: -kv[1])[:8]
        s = "  ".join(f"len{ln}:{100*v/tot:.1f}%" for ln, v in top)
        print(f"  {CLS[cls]} length mix ({tot:,} cycles): {s}")
    # VPA length mix (coarser)
    dist = defaultdict(int)
    for (bs, c, ln), v in a["hist"].items():
        if c == 3:
            dist[ln] += v
    tot = sum(dist.values())
    if tot:
        avg = sum(ln * v for ln, v in dist.items()) / tot
        print(f"  VPA length mix ({tot:,} cycles): avg~{avg:.1f} "
              f"(63 = clamp bucket: {100*dist.get(63,0)/tot:.1f}%)")
    print()


def main():
    args = sys.argv[1:]
    path = "bus_hist.log"
    w_from, w_to, per_window = None, None, False
    it = iter(range(len(args)))
    i = 0
    while i < len(args):
        if args[i] == "--from":
            w_from = int(args[i + 1]); i += 2
        elif args[i] == "--to":
            w_to = int(args[i + 1]); i += 2
        elif args[i] == "--windows":
            per_window = True; i += 1
        else:
            path = args[i]; i += 1
    wins = parse(path)
    if not wins:
        print(f"no windows in {path}")
        return 1
    sel = [w for w in wins
           if (w_from is None or w["n"] >= w_from)
           and (w_to is None or w["n"] <= w_to)]
    if per_window:
        for w in sel:
            report(aggregate([w]), f"window {w['n']}")
    report(aggregate(sel),
           f"windows {sel[0]['n']}..{sel[-1]['n']} ({len(sel)} of {len(wins)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
