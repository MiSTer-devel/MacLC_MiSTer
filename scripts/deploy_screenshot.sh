#!/usr/bin/env bash
# MacLC deploy: verify the Quartus build, then hand off to the reusable launcher
# tools/misterdeploy/launch_unstable_core.py, which pushes the rbf (scp, md5-verified),
# reboots the MiSTer for a clean menu, and selects the core via the OSD. The OSD
# keystroke sequence is generated from the live menu listing, so nothing about the
# menu layout is hard-coded. All machine config comes from scripts/local.env.
#
# Usage: bash scripts/deploy_screenshot.sh
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
if [ -r scripts/local.env ]; then . scripts/local.env; fi

: "${MISTER_HOST:?set MISTER_HOST in scripts/local.env}"
: "${MISTER_SSH_KEY:?set MISTER_SSH_KEY in scripts/local.env}"
: "${MISTER_HTTP_PORT:=8182}"
: "${RBF_NAME:=MacLC.rbf}"
# NVRAM/save seeding — overridable from local.env for porting to another core.
# `=` (not `:=`) so an explicit empty SEED_FILE in local.env disables seeding entirely;
# an unset one falls back to the current MacLC paths (no behaviour change).
: "${SEED_FILE=releases/MacLC.nvr}"
: "${SEED_REMOTE=/media/fat/games/MACLC/MacLC.nvr}"
: "${SEED_MOUNT_CFG=/media/fat/config/MacLC.s2}"
: "${SEED_MOUNT_REL=games/MACLC/MacLC.nvr}"

log() { echo "[$(date +%H:%M:%S)] $*"; }

log "=== Verify build artifact ==="
if [ ! -f "output_files/$RBF_NAME" ]; then
    log "ERROR: output_files/$RBF_NAME does not exist - build failed?"
    exit 1
fi
# Refuse to deploy a stale rbf left by a failed Quartus run: trust the first line of
# MacLC.fit.summary ("Fitter Status : Successful" vs "...: Failed").
FIT_STATUS=$(awk 'NR==1' output_files/MacLC.fit.summary 2>/dev/null)
case "$FIT_STATUS" in
    *Successful*) ;;
    *Failed*)
        log "ERROR: Quartus Fitter reported Failed in MacLC.fit.summary:"
        log "  $FIT_STATUS"
        exit 1 ;;
    *)
        log "WARN: no parseable Fitter Status in MacLC.fit.summary. Build state unknown — continuing." ;;
esac

log "=== Push rbf + seed PRAM + reboot + OSD-select via the reusable launcher ==="
# git-bash/MSYS rewrites bare "/media/fat/..." args into Windows paths; disable that
# so the absolute --seed-remote/--seed-mount-cfg paths reach the MiSTer unmangled.
export MSYS_NO_PATHCONV=1
# PRAM NVRAM lives in games/MACLC/MacLC.nvr, auto-mounted to SD slot 2 via
# config/MacLC.s2. Both are seeded create-only-if-missing, so a saved PRAM and
# its mount survive subsequent deploys (only the rbf is always overwritten).
LAUNCH_ARGS=(
    --host "$MISTER_HOST" --port "$MISTER_HTTP_PORT"
    --ssh-key "$MISTER_SSH_KEY"
    --core "$RBF_NAME"
    --push "output_files/$RBF_NAME"
)
if [ -n "$SEED_FILE" ]; then
    LAUNCH_ARGS+=(
        --seed-file "$SEED_FILE"
        --seed-remote "$SEED_REMOTE"
        --seed-mount-cfg "$SEED_MOUNT_CFG"
        --seed-mount-rel "$SEED_MOUNT_REL"
    )
else
    log "SEED_FILE empty — skipping NVRAM seed (push + launch only)"
fi
exec python tools/misterdeploy/launch_unstable_core.py "${LAUNCH_ARGS[@]}"
