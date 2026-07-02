#!/usr/bin/env bash
# scripts/setup_env.sh — generate scripts/local.env from the committed template.
#
# scripts/local.env is gitignored (it holds your host/IP, ssh key path, Quartus dir).
# This copies scripts/local.env.sample -> scripts/local.env so you only have to edit
# a few lines. It never overwrites an existing local.env unless you pass --force.
#
# Usage:
#   bash scripts/setup_env.sh            # create local.env if missing, then tell you what to edit
#   bash scripts/setup_env.sh --force    # overwrite an existing local.env (a .bak is kept)
#   bash scripts/setup_env.sh -h         # help
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

FORCE=0
case "${1:-}" in
    --force|-f) FORCE=1 ;;
    -h|--help)  awk 'NR>=2 { if ($0 !~ /^#/) exit; sub(/^# ?/,""); print }' "${BASH_SOURCE[0]}"; exit 0 ;;
    "")         ;;
    *)          echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
esac

SRC=scripts/local.env.sample
DST=scripts/local.env

if [ ! -r "$SRC" ]; then
    echo "ERROR: template $SRC not found — are you in the repo root?" >&2
    exit 1
fi
if [ -e "$DST" ] && [ "$FORCE" != 1 ]; then
    echo "$DST already exists — leaving it untouched."
    echo "  (edit it directly, or re-run with --force to regenerate from the template.)"
    exit 0
fi
if [ -e "$DST" ] && [ "$FORCE" = 1 ]; then
    cp "$DST" "$DST.bak"
    echo "Backed up existing $DST -> $DST.bak"
fi

cp "$SRC" "$DST"
echo "Created $DST from $SRC."
echo ""
echo "Next: open $DST and set the MACHINE values for your setup —"
echo "  QUARTUS_BIN      your Quartus bin dir (e.g. /c/intelFPGA_lite/17.0/quartus/bin64)"
echo "  MISTER_HOST      your MiSTer's hostname/IP"
echo "  MISTER_SSH_KEY   path to the ssh key for root@MiSTer"
echo ""
echo "Then:  bash scripts/build_only.sh        # build"
echo "       bash scripts/deploy_screenshot.sh # push + launch on the MiSTer"
