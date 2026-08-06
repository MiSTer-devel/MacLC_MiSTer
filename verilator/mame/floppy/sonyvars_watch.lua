-- sonyvars_watch.lua — ground truth for the -81 sectNFErr budget analysis.
-- Watches the Sony driver's retry-budget seeds in SonyVars ([$134]):
--   +42/+43 : ID-primitive-error retry pair (reset at a6d14a, dec at a6d37e)
--   +46/+47 : the -81 unwanted-sector budget (reset at a6d156, dec at a6d3a8)
--   +48/+49 : outer per-call retry pair (reset at a6d13a)
--   +20     : timed-wait remaining (a6d592 subtracts each sleep)
--   +62     : the GCR inter-attempt sleep amount (MFM uses constant 75)
-- and logs every CPU write into low-mem $140-$143 (the $142 result-code posts,
-- word-written ONLY on failure — a6cb64/a6cb68) with the posting PC.
-- See docs/sony_driver_mfm_read_reference.md.
--
-- Env: WATCH_OUT (default /tmp/sonyvars.txt), MAX_FRAME (default 4200)
-- Run: verilator/mame/floppy/run_floppy.sh dialect —
--   mame maclc ... -autoboot_script verilator/mame/floppy/sonyvars_watch.lua

local OUT = os.getenv("WATCH_OUT") or "/tmp/sonyvars.txt"
local MAX_FRAME = tonumber(os.getenv("MAX_FRAME") or "4200") or 4200

local f = io.open(OUT, "w")
local frame = 0
local installed = false
local cpu, space
local taps = {}
local last_summary = ""

local function pcnow()
	local pc = 0
	pcall(function() pc = cpu.state["CURPC"].value end)
	return pc
end

local function setup()
	cpu = manager.machine.devices[":maincpu"]
	space = cpu.spaces["program"]
	taps[#taps+1] = space:install_write_tap(0x140, 0x143, "e142", function(o, d, m)
		f:write(string.format("F%05d E142 off=%06X data=%08X mask=%08X pc=%08X\n",
			frame, o & 0xFFFFFF, d & 0xFFFFFFFF, m & 0xFFFFFFFF, pcnow()))
		f:flush()
	end)
	f:write("# sonyvars_watch: SV line logged on change; E142 = write into $140-$143\n")
	f:flush()
end

emu.register_frame_done(function()
	frame = frame + 1
	if not installed then installed = true; setup() end
	local ok, sv = pcall(function() return space:read_u32(0x134) end)
	if ok and sv ~= 0 and sv < 0x400000 then
		local s = string.format(
			"sv=%06X +17=%02X +18=%02X +20=%04X +42=%02X +43=%02X +45=%02X +46=%02X +47=%02X +48=%02X +49=%02X +62=%04X",
			sv, space:read_u8(sv + 17), space:read_u8(sv + 18),
			space:read_u16(sv + 20),
			space:read_u8(sv + 42), space:read_u8(sv + 43),
			space:read_u8(sv + 45),
			space:read_u8(sv + 46), space:read_u8(sv + 47),
			space:read_u8(sv + 48), space:read_u8(sv + 49),
			space:read_u16(sv + 62))
		if s ~= last_summary then
			last_summary = s
			f:write(string.format("F%05d SV %s\n", frame, s))
			f:flush()
		end
	end
	if frame >= MAX_FRAME then
		f:flush()
		manager.machine:exit()
	end
end)
