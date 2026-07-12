V       = verilator
TOP     = --top-module scsi_bench_top
RTL     = ../../rtl
V_DEFINE = +define+SIMULATION=1 +incdir+../../rtl \
           --timescale-override 1ps/1ps \
           -Wno-TIMESCALEMOD -Wno-fatal \
           -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-IMPLICIT \
           -Wno-PINMISSING -Wno-UNUSEDSIGNAL -Wno-UNOPTFLAT \
           -Wno-CASEINCOMPLETE -Wno-UNSIGNED -Wno-CMPCONST \
           -Wno-LATCH -Wno-UNDRIVEN -Wno-MISINDENT -Wno-COMBDLY \
           -Wno-INITIALDLY -Wno-SYNCASYNCNET -Wno-BLKANDNBLK

V_SRC = scsi_bench_top.v $(RTL)/ncr5380.sv $(RTL)/scsi.v
C_SRC = scsi_bench.cpp
V_OPT = --x-assign fast --x-initial fast --noassert --trace-fst
EXE   = ./obj_dir/Vscsi_bench_top

all: $(EXE)

obj_dir/Vscsi_bench_top.cpp: $(V_SRC) Makefile
	$V -cc $(V_OPT) -exe --Mdir ./obj_dir $(V_DEFINE) $(TOP) $(V_SRC) $(C_SRC)

$(EXE): obj_dir/Vscsi_bench_top.cpp $(C_SRC)
	cd obj_dir && $(MAKE) -f Vscsi_bench_top.mk OBJCACHE=

run: $(EXE)
	$(EXE)

clean:
	rm -rf obj_dir

.PHONY: all run clean
