# MAME Mac LC Build Guide for macOS (Apple Silicon/Intel)

This guide shows how to compile MAME's Mac LC driver on macOS with Homebrew SDL2 and enable detailed verbose logging for debugging.

## Prerequisites

```bash
# Install Homebrew if not already installed
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install SDL2
brew install sdl2

# Verify SDL2 installation
brew list sdl2
ls -la /opt/homebrew/include/SDL*.h  # Apple Silicon
ls -la /usr/local/include/SDL*.h      # Intel Mac
```

## Step 1: Get MAME Source

```bash
# Clone MAME repository
git clone https://github.com/mamedev/mame.git
cd mame
```

## Step 2: Apply SDL2 Framework Patch

The default MAME build tries to use SDL2.framework, but Homebrew provides SDL2 as a library. We need to patch the build script.

Edit `scripts/src/osd/sdl.lua` around line 254-264:

**Find this section:**
```lua
		if _OPTIONS["USE_LIBSDL"]~="1" then
			linkoptions {
				"-F" .. _OPTIONS["SDL_FRAMEWORK_PATH"],
			}
			links {
				"SDL2.framework",
			}
		else
			local str = backtick(sdlconfigcmd() .. " --libs --static | sed 's/-lSDLmain//'")
			addlibfromstring(str)
			addoptionsfromstring(str)
		end
```

**Replace with:**
```lua
		if _OPTIONS["USE_LIBSDL"]~="1" then
			-- Use Homebrew SDL2 library instead of framework
			local str = backtick(sdlconfigcmd() .. " --libs | sed 's/-lSDLmain//'")
			addlibfromstring(str)
			addoptionsfromstring(str)
		else
			local str = backtick(sdlconfigcmd() .. " --libs --static | sed 's/-lSDLmain//'")
			addlibfromstring(str)
			addoptionsfromstring(str)
		end
```

**Or use sed to apply the patch automatically:**
```bash
# Backup original
cp scripts/src/osd/sdl.lua scripts/src/osd/sdl.lua.backup

# This is a bit tricky with sed due to multi-line replacement
# Easier to manually edit or download the pre-patched file
```

## Step 3: Enable Verbose Logging (Optional)

For detailed debugging logs of Egret, VIA, and V8 subsystems:

```bash
# Enable Egret verbose logging
sed -i.bak 's/#define VERBOSE (0)/#define VERBOSE (0xff)/' src/mame/machine/egret.cpp

# Enable VIA verbose logging
sed -i.bak 's/#define VERBOSE (0)/#define VERBOSE (1)/' src/devices/machine/6522via.cpp

# Enable V8 video verbose logging
sed -i.bak 's/#define VERBOSE (0)/#define VERBOSE (1)/' src/mame/apple/v8.cpp

# Verify changes
grep "VERBOSE" src/mame/machine/egret.cpp | head -1
grep "VERBOSE" src/devices/machine/6522via.cpp | head -1
grep "VERBOSE" src/mame/apple/v8.cpp | head -1
```

## Step 4: Compile Mac LC Driver

**For Apple Silicon Macs:**
```bash
make SUBTARGET=maclc SOURCES=src/mame/apple/maclc.cpp \
  SDL_INSTALL_ROOT=/opt/homebrew \
  USE_LIBSDL=1 \
  CFLAGS="-I/opt/homebrew/include" \
  CXXFLAGS="-I/opt/homebrew/include" \
  -j8
```

**For Intel Macs:**
```bash
make SUBTARGET=maclc SOURCES=src/mame/apple/maclc.cpp \
  SDL_INSTALL_ROOT=/usr/local \
  USE_LIBSDL=1 \
  CFLAGS="-I/usr/local/include" \
  CXXFLAGS="-I/usr/local/include" \
  -j8
```

The compiled binary will be `./maclc` in the MAME root directory.

## Step 5: Prepare ROMs and Disk Images

```bash
# Create ROM directory structure
mkdir -p roms

# Place Mac LC ROM in roms/maclc.zip
# The ROM should be named appropriately inside the zip file

# Verify ROM structure
tree roms
# Should show:
# roms/
# └── maclc.zip

# Place hard disk image (if using)
# Example: mac608.chd (System 6.0.8)
```

## Step 6: Run Mac LC

**Basic run:**
```bash
./maclc maclc
```

**With hard disk:**
```bash
./maclc maclc -hard mac608.chd
```

**With verbose logging (if enabled in Step 3):**
```bash
# Capture full boot logs
./maclc maclc -hard mac608.chd -verbose 2>&1 | tee maclc_boot_full.log

# Let it boot completely, then quit with ESC -> Exit
```

**With debugger:**
```bash
./maclc maclc -hard mac608.chd -debug -verbose 2>&1 | tee maclc_debug.log
```

## Step 7: Analyzing Logs

After running with verbose logging enabled, you can filter the logs:

```bash
# Check log size
ls -lh maclc_boot_full.log

# Extract Egret logs
grep -i "egret\|EG->" maclc_boot_full.log > egret_only.log

# Extract VIA logs
grep -i "via" maclc_boot_full.log > via_only.log

# Extract video logs
grep -i "video\|v8\|rbv" maclc_boot_full.log > video_only.log

# Look for boot sequence
grep -i "680x0\|reset\|pram" maclc_boot_full.log | head -50
```

## Troubleshooting

### SDL2 framework not found
Make sure you're using the compilation command with `USE_LIBSDL=1` and the correct include paths.

### PRAM doesn't save / boots in monochrome
MAME saves PRAM to `nvram/maclc/egret_pram`. To reset:
```bash
rm nvram/maclc/egret_pram
./maclc maclc -hard mac608.chd
```
Then set color in Control Panels > Monitors and quit properly (ESC -> Exit).

### Recompiling after changes
If you modify source files or verbose flags, just run the make command again:
```bash
# For Apple Silicon
make SUBTARGET=maclc SOURCES=src/mame/apple/maclc.cpp \
  SDL_INSTALL_ROOT=/opt/homebrew \
  USE_LIBSDL=1 \
  CFLAGS="-I/opt/homebrew/include" \
  CXXFLAGS="-I/opt/homebrew/include" \
  -j8
```

### Clean build
If things get messed up:
```bash
make clean
# Then recompile
```

## Quick Reference Commands

**Compile (Apple Silicon):**
```bash
make SUBTARGET=maclc SOURCES=src/mame/apple/maclc.cpp SDL_INSTALL_ROOT=/opt/homebrew USE_LIBSDL=1 CFLAGS="-I/opt/homebrew/include" CXXFLAGS="-I/opt/homebrew/include" -j8
```

**Run with logging:**
```bash
./maclc maclc -hard mac608.chd -verbose 2>&1 | tee maclc_boot.log
```

**Filter logs:**
```bash
grep -i "egret" maclc_boot.log > egret.log
grep -i "via" maclc_boot.log > via.log
```
