#!/usr/bin/env bash
# scripts/build_only.sh — build the core via Quartus from the CLI and print a clear
# status summary. BUILD ONLY: it never touches the MiSTer. To push+launch a finished
# build, run scripts/deploy_screenshot.sh (or tools/misterdeploy/launch_unstable_core.py).
#
# Reads scripts/local.env for QUARTUS_BIN (and RBF_NAME). Copy the template first:
#   cp scripts/local.env.sample scripts/local.env    # or: bash scripts/setup_env.sh
#
# Usage:
#   bash scripts/build_only.sh            # full compile -> .sof/.rbf, then status
#   bash scripts/build_only.sh --check    # fast Analysis & Synthesis only (no fit/rbf)
#   bash scripts/build_only.sh --no-wait  # don't wait for an in-progress Quartus
#   bash scripts/build_only.sh -h         # help
#
# Portable: the revision is auto-detected from the repo's single *.qsf (override with
# $QUARTUS_REVISION), so this script drops into another core repo with no edits.
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

# ------------------------------------------------------------------ args
WAIT=1 CHECK_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        -c|--check|--map-only) CHECK_ONLY=1 ;;
        --no-wait)             WAIT=0 ;;
        -h|--help)
            awk 'NR>=2 { if ($0 !~ /^#/) exit; sub(/^# ?/,""); print }' "${BASH_SOURCE[0]}"
            exit 0 ;;
        *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
    esac
    shift
done

# ------------------------------------------------------------------ env
if [ -r scripts/local.env ]; then
    . scripts/local.env
else
    echo "ERROR: scripts/local.env not found." >&2
    echo "       Create it from the template:  bash scripts/setup_env.sh" >&2
    echo "       (or:  cp scripts/local.env.sample scripts/local.env  then edit)" >&2
    exit 1
fi
if [ -z "${QUARTUS_BIN:-}" ]; then
    echo "ERROR: QUARTUS_BIN is not set in scripts/local.env." >&2
    echo "       Point it at your Quartus bin dir, e.g." >&2
    echo "         QUARTUS_BIN=/c/intelFPGA_lite/17.0/quartus/bin64" >&2
    exit 1
fi
export PATH="$QUARTUS_BIN:$PATH"
if ! command -v quartus_sh >/dev/null 2>&1; then
    echo "ERROR: quartus_sh not found on PATH after adding QUARTUS_BIN=$QUARTUS_BIN" >&2
    echo "       Check the path — it should contain quartus_sh(.exe)." >&2
    exit 1
fi

# Quartus revision to build. Auto-detected from the single *.qsf in the repo root so
# this script drops into ANY core repo with no edits; override with $QUARTUS_REVISION
# (needed only for multi-revision projects that have more than one .qsf).
if [ -n "${QUARTUS_REVISION:-}" ]; then
    REV="$QUARTUS_REVISION"
else
    shopt -s nullglob; qsf=( *.qsf ); shopt -u nullglob
    case "${#qsf[@]}" in
        1) REV="${qsf[0]%.qsf}" ;;
        0) echo "ERROR: no *.qsf in $(pwd) — is this a Quartus project root?" >&2
           echo "       (set QUARTUS_REVISION in scripts/local.env to name the revision)" >&2
           exit 1 ;;
        *) echo "ERROR: multiple *.qsf found (${qsf[*]}) — can't auto-pick a revision." >&2
           echo "       Set QUARTUS_REVISION in scripts/local.env to choose one." >&2
           exit 1 ;;
    esac
fi
RBF_NAME="${RBF_NAME:-$REV.rbf}"
log() { echo "[$(date +%H:%M:%S)] $*"; }

# ------------------------------------------------------------------ don't collide
# A second Quartus using the same project files would corrupt the compile. Wait for
# any in-progress one to finish (Windows: tasklist; Linux/mac: pgrep). --no-wait skips.
quartus_running() {
    if command -v tasklist >/dev/null 2>&1; then
        tasklist 2>/dev/null | grep -qiE "quartus_(map|fit|asm|sta|sh|pgm)\.exe"
    elif command -v pgrep >/dev/null 2>&1; then
        pgrep -f "quartus_(map|fit|asm|sta|sh|pgm)" >/dev/null 2>&1
    else
        return 1
    fi
}
if [ "$WAIT" = 1 ]; then
    if quartus_running; then log "Waiting for an in-progress Quartus to finish..."; fi
    while quartus_running; do sleep 30; done
fi

mkdir -p output_files
STAMP="$(date +%Y%m%d_%H%M%S)"
LOG="output_files/build_${STAMP}.log"

# ------------------------------------------------------------------ compile
touch output_files/.compile_in_progress
if [ "$CHECK_ONLY" = 1 ]; then
    log "Analysis & Synthesis only (quartus_map $REV) — fast syntax/multi-driver check" | tee -a "$LOG"
    SECONDS=0
    quartus_map "$REV" 2>&1 | tee -a "$LOG"
    RC=${PIPESTATUS[0]}
else
    log "Full compile (quartus_sh --flow compile $REV)" | tee -a "$LOG"
    SECONDS=0
    quartus_sh --flow compile "$REV" 2>&1 | tee -a "$LOG"
    RC=${PIPESTATUS[0]}
fi
DUR=$SECONDS
rm -f output_files/.compile_in_progress

# ------------------------------------------------------------------ status
# Print the "* Status :" line from a Quartus stage summary, if present.
stage_status() {
    local label="$1" file="output_files/$2"
    if [ -r "$file" ]; then
        local line; line=$(grep -m1 -E 'Status[[:space:]]*:' "$file" | sed 's/[[:space:]]\{2,\}/ /g')
        printf '  %-22s %s\n' "$label" "${line:-<no status line>}"
    else
        printf '  %-22s %s\n' "$label" "(no $file)"
    fi
}
# Worst-case (minimum) slack across the STA summary, if parseable.
worst_slack() {
    local file="output_files/$REV.sta.summary"
    [ -r "$file" ] || return 1
    awk '
        /[Ss]lack/ { v=""; for (i=1;i<=NF;i++) if ($i ~ /^-?[0-9]+\.[0-9]+$/) v=$i
                     if (v!="") { if (!seen || v+0 < min+0) { min=v; seen=1 } } }
        END { if (seen) print min }' "$file"
}

hr="------------------------------------------------------------"
echo ""              | tee -a "$LOG"
echo "$hr"           | tee -a "$LOG"
printf 'BUILD STATUS  (%s, %dm%02ds)\n' "$REV" $((DUR/60)) $((DUR%60)) | tee -a "$LOG"
echo "$hr"           | tee -a "$LOG"
{
    stage_status "Analysis & Synthesis" "$REV.map.summary"
    if [ "$CHECK_ONLY" != 1 ]; then
        stage_status "Fitter"            "$REV.fit.summary"
        # Timing: the .sta.summary is a TimeQuest slack table with no "Status:" line,
        # so report pass/fail from the worst-case (minimum) slack across all domains.
        SLK=$(worst_slack || true)
        if [ -n "${SLK:-}" ]; then
            if awk "BEGIN{exit !($SLK < 0)}"; then
                printf '  %-22s VIOLATED — worst slack %s ns  *** TIMING NOT MET ***\n' "Timing (STA)" "$SLK"
            else
                printf '  %-22s met — worst slack +%s ns\n' "Timing (STA)" "$SLK"
            fi
        elif [ -r "output_files/$REV.sta.summary" ]; then
            printf '  %-22s see output_files/%s.sta.summary\n' "Timing (STA)" "$REV"
        fi
        # Assembler writes the .sof/.rbf directly (this flow emits no .asm.summary),
        # so the artifact below IS the proof of a successful assembly.
        if [ -f "output_files/$RBF_NAME" ]; then
            SZ=$(stat -c %s "output_files/$RBF_NAME" 2>/dev/null || stat -f %z "output_files/$RBF_NAME" 2>/dev/null)
            MT=$(date -r "output_files/$RBF_NAME" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
            printf '  %-22s output_files/%s  (%s bytes, %s)\n' "Artifact" "$RBF_NAME" "${SZ:-?}" "${MT:-?}"
        else
            printf '  %-22s output_files/%s  *** MISSING ***\n' "Artifact" "$RBF_NAME"
        fi
    fi
    printf '  %-22s exit=%s\n' "Quartus flow" "$RC"
    printf '  %-22s %s\n' "Full log" "$LOG"
} | tee -a "$LOG"
echo "$hr" | tee -a "$LOG"

# Overall verdict + a nudge toward deploy (which this script deliberately does NOT do).
if [ "$RC" -ne 0 ]; then
    log "RESULT: FAILED (quartus exit=$RC) — see $LOG"
elif [ "$CHECK_ONLY" = 1 ]; then
    log "RESULT: check passed (Analysis & Synthesis only; no .rbf produced)"
elif [ -f "output_files/$RBF_NAME" ]; then
    log "RESULT: OK — output_files/$RBF_NAME ready. Deploy with: bash scripts/deploy_screenshot.sh"
else
    log "RESULT: flow returned 0 but output_files/$RBF_NAME is missing — check $LOG"
    RC=1
fi
exit "$RC"
