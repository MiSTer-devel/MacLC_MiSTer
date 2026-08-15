V = verilator
COSIM = n

TOP = --top-module emu
RTL = ../rtl
V_INC = +incdir+$(RTL)

V_DEFINE = +define+debug=1 +define+SIMULATION=1 +define+USE_ASC_AUDIO=1  -CFLAGS "-I../sim/imgui -I../sim/vinc -I../sim/ -g "  --timescale-override 1ps/1ps -Wno-TIMESCALEMOD \
	-I$(RTL) \
	-I$(RTL)/tg68k \
	-I$(RTL)/uart \
	-I$(RTL)/egret \
        --timing
# Suppress common warnings that don't affect simulation correctness
V_DEFINE += -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-IMPLICIT -Wno-PINMISSING -Wno-UNUSEDSIGNAL -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE -Wno-UNSIGNED -Wno-CMPCONST -Wno-LATCH -Wno-UNDRIVEN -Wno-MISINDENT -Wno-COMBDLY -Wno-INITIALDLY -Wno-SYNCASYNCNET -Wno-BLKLOOPINIT -Wno-MULTIDRIVEN -Wno-GENUNNAMED
#V_DEFINE += --threads 8  # this slows it way down
V_DEFINE += --trace-fst
# Uncomment to enable verbose per-instruction/per-cycle debug traces (HC05, TG68, VIA, PVIA, etc.)
# V_DEFINE += +define+VERBOSE_TRACE=1
# Uncomment for a FOCUSED HC05 stuck-loop trace (no flood) - prints the Egret PC +
# BYTEACK/TIP/TREQ every ~32k fetches. Use to pinpoint the byte-4 SR/BYTEACK hang.
# V_DEFINE += +define+EGRET_SRDEBUG=1
V_DEFINE +=

UNAME_S := $(shell uname -s)

ifeq ($(UNAME_S), Darwin) #APPLE
	ECHO_MESSAGE = "Mac OS X"
	LIBS += -framework OpenGL -framework Cocoa -framework IOKit -framework CoreVideo `sdl2-config --libs`
	LIBS += -L/usr/local/lib -L/opt/local/lib

	CXXFLAGS += `sdl2-config --cflags` -Iimgui
	CXXFLAGS += `sdl2-config --cflags | sed 's|include/SDL2|include/|'`
	CXXFLAGS += -I/usr/local/include -I/opt/local/include
	CFLAGS = $(CXXFLAGS) -Iimgui
endif

ifeq ($(UNAME_S), Linux) #LINUX
	ECHO_MESSAGE = "Linux"
	LIBS += -lGL -ldl `sdl2-config --libs`

	CXXFLAGS += `sdl2-config --cflags` -Iimgui
	CFLAGS = $(CXXFLAGS)
endif

ifeq ($(findstring MINGW,$(UNAME_S)),MINGW)
	ECHO_MESSAGE = "MinGW"
	LIBS += -lgdi32 -lopengl32 -limm32 `pkg-config --static --libs sdl2`

	CXXFLAGS += `pkg-config --cflags sdl2`
	CFLAGS = $(CXXFLAGS)
endif

CFLAGS += $(CC_OPT) $(CC_DEFINE) -Iimgui
LDFLAGS = $(LIBS)
EXE = ./obj_dir/Vemu
#V_OPT = -O3 --x-assign fast --x-initial fast --noassert
V_OPT =  --x-assign fast --x-initial fast --noassert
#CC_OPT = -O
CC_OPT =

# MacLC RTL source files
V_SRC = \
	sim.v \
	sim_ram.v \
	sim_ddr3.v \
	$(RTL)/pds/pds_enet.sv \
	$(RTL)/tg68k/TG68K_ALU.v \
	$(RTL)/tg68k/TG68K_Pack.sv \
	$(RTL)/tg68k/TG68KdotC_Kernel.v \
	$(RTL)/tg68k/tg68k.v \
	$(RTL)/addrController_top.v \
	$(RTL)/addrDecoder.v \
	$(RTL)/dataController_top.sv \
	$(RTL)/maclc_v8_video.sv \
	$(RTL)/vram_bram.sv \
	$(RTL)/ariel_ramdac.sv \
	$(RTL)/pseudovia.sv \
	$(RTL)/via6522.sv \
	$(RTL)/adb.sv \
	$(RTL)/adb_device.sv \
	$(RTL)/asc.sv \
	$(RTL)/v8_clocks.sv \
	$(RTL)/ps2_kbd.sv \
	$(RTL)/ps2_mouse.v \
	$(RTL)/swim.v \
	$(RTL)/floppy.v \
	$(RTL)/floppy_track_encoder.v \
	$(RTL)/mfm_track_encoder.v \
	$(RTL)/scsi.v \
	$(RTL)/cd_audio.sv \
	$(RTL)/ncr5380.sv \
	$(RTL)/scc.v \
	$(RTL)/pll/pll_0002.v \
	$(RTL)/egret/egret_wrapper.sv \
	$(RTL)/egret/m68hc05_core.sv \
	$(RTL)/egret/m68hc05_alu.sv \
	$(RTL)/uart/txuart.v \
	$(RTL)/uart/rxuart.v


C_SRC = \
	sim_main.cpp  \
	sim/sim_bus.cpp sim/sim_blkdevice.cpp sim/sim_clock.cpp sim/sim_console.cpp sim/sim_video.cpp sim/sim_console.cpp sim/sim_input.cpp  sim/sim_audio.cpp sim/sim_serial.cpp \
	sim/m68kdasm.c sim/m68k_dasm_stubs.cpp \
	sim/imgui/imgui_impl_sdl.cpp sim/imgui/imgui_impl_opengl2.cpp sim/imgui/imgui_draw.cpp sim/imgui/imgui_widgets.cpp sim/imgui/imgui_tables.cpp sim/imgui/imgui.cpp sim/imgui/ImGuiFileDialog.cpp sim/imgui/implot.cpp sim/imgui/implot_items.cpp

VOUT = obj_dir/Vemu.cpp

all: $(EXE)

$(VOUT): $(V_SRC)  Makefile
	$V -cc $(V_OPT) -LDFLAGS "$(LDFLAGS) " -exe --trace --Mdir ./obj_dir $(V_DEFINE) $(V_INC) $(TOP) -CFLAGS $(CFLAGS) $(V_SRC) $(C_SRC)

$(EXE): $(VOUT) $(C_SRC)
#	(cd obj_dir; make OPT="-fauto-inc-dec -fdce -fdefer-pop -fdse -ftree-ccp -ftree-ch -ftree-fre -ftree-dce -ftree-dse" -f Vemu.mk)
	(cd obj_dir; make -f Vemu.mk)

fast:
	(cd obj_dir; rm -f *.o ; make OPT="-fcompare-elim -fcprop-registers -fguess-branch-probability -fauto-inc-dec -fif-conversion2 -fif-conversion -fipa-pure-const -fdce -fipa-profile -fipa-reference -fmerge-constants -fsplit-wide-types -fdefer-pop -fdse -ftree-ccp -ftree-ch -ftree-fre -ftree-dce -ftree-dse -ftree-builtin-call-dce -ftree-copyrename -ftree-dominator-opts -ftree-forwprop -ftree-phiprop -ftree-sra -ftree-pta -ftree-ter -funit-at-a-time -ftree-bit-ccp -falign-functions  -falign-jumps -falign-loops  -falign-labels -fcaller-saves -fcrossjumping -fcse-follow-jumps -fcse-skip-blocks -fdelete-null-pointer-checks -fdevirtualize -fexpensive-optimizations -fgcse  -fgcse-lm -finline-small-functions -findirect-inlining -fipa-sra -foptimize-sibling-calls -fpartial-inlining -fpeephole2 -fregmove -freorder-blocks  -freorder-functions -frerun-cse-after-loop -fsched-interblock  -fsched-spec -fschedule-insns -fschedule-insns2 -fstrict-aliasing -fstrict-overflow -ftree-switch-conversion -ftree-pre -ftree-vrp" -f Vemu.mk)

clean:
	rm -f obj_dir/*
