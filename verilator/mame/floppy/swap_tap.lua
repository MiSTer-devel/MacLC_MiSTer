-- swap_tap.lua — floppy_tap.lua plus scripted MEDIA CHANGES and snapshots.
-- Ground truth for the disk-swap mission (docs/resume_floppy_swap_2026-08-06.md
-- §7): what a real LC's drive+driver do when the medium is pulled out from
-- under a mounted volume and a different one appears — the exact thing a
-- MiSTer OSD re-mount does.
--
-- Same tap format as floppy_tap.lua (decode_v2.py-compatible). Media events
-- are written as '# MEDIA ...' comment lines so the decoder skips them but a
-- grep aligns them with the seq stream.
--
-- Env:
--   TAP_OUT    : output file             (default /tmp/swap_tap.txt)
--   MAX_FRAME  : exit after this frame   (default 9000)
--   LOG_FROM   : log bus accesses only from this frame on (default 0;
--                set huge to disable bus logging entirely)
--   UNLOAD_AT  : frame to unload flop1   (0 = never)
--   LOAD_AT    : frame to load LOAD_IMG  (0 = never)
--   LOAD_IMG   : image path for LOAD_AT
--   SNAP_EVERY : snapshot every N frames (0 = off) — needs -snapshot_directory

local TAP_OUT    = os.getenv("TAP_OUT")  or "/tmp/swap_tap.txt"
local function envnum(n, d) local v = os.getenv(n); return v and (tonumber(v) or d) or d end
local MAX_FRAME  = envnum("MAX_FRAME", 9000)
local LOG_FROM   = envnum("LOG_FROM", 0)
local UNLOAD_AT  = envnum("UNLOAD_AT", 0)
local LOAD_AT    = envnum("LOAD_AT", 0)
local LOAD_IMG   = os.getenv("LOAD_IMG")
local SNAP_EVERY = envnum("SNAP_EVERY", 0)

local VIA_LO,  VIA_HI  = 0xF00000, 0xF01FFF
local SWIM_LO, SWIM_HI = 0xF16000, 0xF17FFF

local f = io.open(TAP_OUT, "w")
local frame = 0
local seq = 0
local installed = false
local cpu, space
local taps = {}

local function pcnow()
	local pc = 0
	pcall(function() pc = cpu.state["CURPC"].value end)
	return pc
end

local function byte_of(data, mask)
	if (mask & 0xFF000000) ~= 0 then return (data >> 24) & 0xFF end
	if (mask & 0x00FF0000) ~= 0 then return (data >> 16) & 0xFF end
	if (mask & 0x0000FF00) ~= 0 then return (data >>  8) & 0xFF end
	return data & 0xFF
end

local function logacc(region, kind, off, data, mask)
	seq = seq + 1
	if frame < LOG_FROM then return end
	f:write(string.format("%08d F%05d %s %s off=%06X byte=%02X mask=%08X pc=%08X\n",
	                      seq, frame, region, kind, off & 0xFFFFFF, byte_of(data, mask), mask & 0xFFFFFFFF, pcnow()))
end

local function media_event(what)
	seq = seq + 1
	local line = string.format("# MEDIA %s seq=%08d F%05d", what, seq, frame)
	f:write(line .. "\n"); f:flush()
	print(line)
end

-- Locate the internal floppy (fdc:0) image device, lazily.
local flop
local function find_flop()
	if flop then return flop end
	for name, img in pairs(manager.machine.images) do
		local tag = img.device.tag
		if tag:find("fdc:0") then
			flop = img
			media_event("DEVICE " .. tag .. " as " .. name)
			return flop
		end
	end
	media_event("DEVICE-NOT-FOUND")
	return nil
end

local function setup()
	cpu = manager.machine.devices[":maincpu"]
	space = cpu.spaces["program"]
	f:write(string.format("# swap_tap VIA=%06X-%06X SWIM=%06X-%06X unload@%d load@%d img=%s\n",
	                      VIA_LO, VIA_HI, SWIM_LO, SWIM_HI, UNLOAD_AT, LOAD_AT, tostring(LOAD_IMG)))
	taps[#taps+1] = space:install_read_tap (VIA_LO,  VIA_HI,  "VIArd",  function(o,d,m) logacc("VIA",  "RD", o, d, m) end)
	taps[#taps+1] = space:install_write_tap(VIA_LO,  VIA_HI,  "VIAwr",  function(o,d,m) logacc("VIA",  "WR", o, d, m) end)
	taps[#taps+1] = space:install_read_tap (SWIM_LO, SWIM_HI, "SWIMrd", function(o,d,m) logacc("SWIM", "RD", o, d, m) end)
	taps[#taps+1] = space:install_write_tap(SWIM_LO, SWIM_HI, "SWIMwr", function(o,d,m) logacc("SWIM", "WR", o, d, m) end)
	f:flush()
end

emu.register_frame_done(function()
	frame = frame + 1
	if not installed then installed = true; setup() end

	if UNLOAD_AT ~= 0 and frame == UNLOAD_AT then
		local img = find_flop()
		if img then
			local ok, err = pcall(function() img:unload() end)
			media_event(ok and "UNLOAD-OK" or ("UNLOAD-ERR " .. tostring(err)))
		end
	end

	if LOAD_AT ~= 0 and frame == LOAD_AT and LOAD_IMG then
		local img = find_flop()
		if img then
			local ok, err = pcall(function() return img:load(LOAD_IMG) end)
			media_event(ok and ("LOAD-OK " .. LOAD_IMG) or ("LOAD-ERR " .. tostring(err)))
		end
	end

	if SNAP_EVERY ~= 0 and (frame % SNAP_EVERY) == 0 then
		pcall(function() manager.machine.video:snapshot() end)
	end

	if frame >= MAX_FRAME then f:flush(); manager.machine:exit() end
end)
