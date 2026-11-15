#!/usr/bin/env bash
# regen_tg68k.sh - regenerate rtl/tg68k/TG68KdotC_Kernel.v from the VHDL source
# via ghdl, using the EXACT generics the core is built with (mirrors
# docs/how-to-convert-cpu.txt and the #(2,2,2,2,2,2,2,1) wrapper instantiation).
#
# Run this after editing any rtl/tg68k/*.vhd, then rebuild verilator/Quartus.
# The FPGA (Quartus) and Verilator both compile the generated .v, NOT the .vhd,
# so VHDL edits have no effect until this regenerates the .v.
#
# Requires: ghdl on PATH. Repo-relative paths only.
set -eu

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO/rtl/tg68k" || { echo "cannot cd to rtl/tg68k"; exit 1; }

command -v ghdl >/dev/null 2>&1 || { echo "ERROR: ghdl not found on PATH"; exit 127; }

echo ">>> ghdl analyze (Pack, ALU, Kernel) ..."
ghdl -a -fsynopsys -fexplicit TG68K_Pack.vhd
ghdl -a -fsynopsys -fexplicit TG68K_ALU.vhd
ghdl -a -fsynopsys -fexplicit TG68KdotC_Kernel.vhd

echo ">>> ghdl synth -> TG68KdotC_Kernel.v ..."
tmp="TG68KdotC_Kernel.v.new"
ghdl synth -fsynopsys -fexplicit --latches \
    -gSR_Read=2 \
    -gVBR_Stackframe=2 \
    -gextAddr_Mode=2 \
    -gMUL_Mode=2 \
    -gDIV_Mode=2 \
    -gBitField=2 \
    -gBarrelShifter=2 \
    -gMUL_Hardware=1 \
    --out=verilog TG68KdotC_Kernel > "$tmp"

lines="$(wc -l < "$tmp" | tr -d ' ')"
if [ "$lines" -lt 1000 ]; then
    echo "ERROR: regenerated Verilog is only $lines lines - looks wrong. Aborting."
    rm -f "$tmp"
    exit 1
fi
mv -f "$tmp" TG68KdotC_Kernel.v
echo ">>> wrote rtl/tg68k/TG68KdotC_Kernel.v ($lines lines)"

# ghdl work artifacts
rm -f work-obj*.cf *.o 2>/dev/null || true
echo ">>> done. Rebuild the simulator (verilator/ make) and/or recompile Quartus."
