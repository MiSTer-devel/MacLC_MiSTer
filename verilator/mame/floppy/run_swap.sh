#!/usr/bin/env bash
# run_swap.sh — MAME `maclc` headless with swap_tap.lua: scripted media
# changes + snapshots. Ground truth for the disk-swap mission.
#
# Usage:
#   bash run_swap.sh <boot-disk|-> [seconds] [tap_out] [snap_dir]
#     boot-disk '-' = start with NO floppy (the ?-screen case).
#   Everything else via env (see swap_tap.lua): MAX_FRAME LOG_FROM UNLOAD_AT
#   LOAD_AT LOAD_IMG SNAP_EVERY, plus MAME ROMPATH RAMSIZE.
set -uo pipefail

MAME="${MAME:-/usr/games/mame}"
ROMPATH="${ROMPATH:-$HOME/maclc_roms}"
RAMSIZE="${RAMSIZE:-2M}"
RUNDIR="${RUNDIR:-$HOME/maclc_run}"
HERE="$(cd "$(dirname "$0")" && pwd)"

DISK="${1:?need a disk image path or - for none}"
SECONDS_TO_RUN="${2:-300}"
TAP_OUT="${3:-/tmp/swap_tap.txt}"
SNAP_DIR="${4:-$RUNDIR/snaps}"

mkdir -p "$RUNDIR" "$SNAP_DIR"
cd "$RUNDIR"

COMMON=( maclc -rompath "$ROMPATH" -ramsize "$RAMSIZE"
         -nothrottle -video none -sound none
         -seconds_to_run "$SECONDS_TO_RUN"
         -snapshot_directory "$SNAP_DIR" -snapname "f%i" )
if [ "$DISK" != "-" ]; then
	[ -f "$DISK" ] || { echo "disk not found: $DISK" >&2; exit 2; }
	COMMON+=( -flop1 "$DISK" )
fi

export TAP_OUT
echo "=== SWAP run: boot=$DISK ${SECONDS_TO_RUN}s tap=$TAP_OUT snaps=$SNAP_DIR ==="
echo "    UNLOAD_AT=${UNLOAD_AT:-0} LOAD_AT=${LOAD_AT:-0} LOAD_IMG=${LOAD_IMG:-} LOG_FROM=${LOG_FROM:-0} SNAP_EVERY=${SNAP_EVERY:-0} MAX_FRAME=${MAX_FRAME:-9000}"
"$MAME" "${COMMON[@]}" -autoboot_script "$HERE/swap_tap.lua" 2>&1 | tail -40
echo "=== tap lines: $(wc -l < "$TAP_OUT" 2>/dev/null || echo 0) ==="
