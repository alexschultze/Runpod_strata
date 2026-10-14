#!/bin/bash
# Called by Strata's docker-entrypoint.sh (patched by start.sh) after the setup and before the server starts, on every start.
# 0. calibration, per hardware (GPU, CPU, model, context): a result is kept as <store>/tuned/<key>.args and applied on every start of the same hardware.
#      STRATA_CALIBRATE=no (default)  never calibrates; a saved result for this hardware is applied
#      STRATA_CALIBRATE=yes           applies the saved result, calibrates (15-30 min) first when there is none for this hardware
#      STRATA_CALIBRATE=force         always calibrates
#    STRATA_PARALLEL=N (batch slots) and STRATA_ENGINE_ARGS (e.g. "--pcie-frac 1.00") are manual overrides, merged on top on every start
# 1. writes --pool-workers into the model's config unless it has one or has been calibrated (a calibration measured the workers itself)
# 2. in the background: archives the engine and pushes the data to the volume, once
# Environment from start.sh: STRATA_HOME STRATA_DATA STRATA_STORE KEY TAG CONTEXT COPY_DATA_LOCAL POOL_WORKERS
CFG="$STRATA_DATA/config/strata-$TAG.json"
. "${RUNPOD_DIR:-/opt/runpod}/hwinfo.sh"; hw_detect; hw_key
export TUNED_KEY
TUNED_DIR="${STRATA_STORE:+$STRATA_STORE/tuned}"; TUNED_DIR="${TUNED_DIR:-$STRATA_DATA/tuned}"
export TUNED_FILE="$TUNED_DIR/$TUNED_KEY.args"
CALIB='["--pcie-frac","--spec-min-p","--pool-workers","--adapt-every","--adapt-swaps","--adapt-decay"]'   # what a calibration sets

# merge_args "<args>" '<json list of flags to remove first>': into both copies of the config (the data folder's and Strata's own)
merge_args() {
    local f
    command -v jq >/dev/null && [ -f "$CFG" ] || return 0
    for f in "$CFG" "$STRATA_HOME/strata-$TAG.json"; do
        [ -f "$f" ] || continue
        jq --arg a "$1" --argjson strip "$2" '
          ($a | split(" ") | map(select(length>0))) as $new
          | (($new | map(select(startswith("--")))) + $strip) as $flags
          | .args = ((.args | reduce .[] as $t ({out:[],skip:false};
                if ($t|startswith("--")) then (if ($flags|index($t)) then .skip=true else .skip=false | .out+=[$t] end)
                else (if .skip then . else .out+=[$t] end) end) | .out) + $new)' "$f" > "$f.tmp" && cat "$f.tmp" > "$f"; rm -f "$f.tmp"
    done
}

echo "post-setup.sh: hardware key $TUNED_KEY"
case "${STRATA_CALIBRATE:-no}" in
    force) NEED_CAL=1 ;;
    yes)   [ -f "$TUNED_FILE" ] && NEED_CAL=0 || NEED_CAL=1 ;;
    *)     NEED_CAL=0 ;;
esac
if [ "$NEED_CAL" = 1 ]; then
    echo "post-setup.sh: STRATA_CALIBRATE=$STRATA_CALIBRATE, calibrating for this hardware (15-30 min)"
    "${CALIBRATE_SCRIPT:-/app/scripts/calibrate.sh}" || echo "post-setup.sh: calibration failed, continuing without"
fi
if [ -f "$TUNED_FILE" ]; then
    TA=$(grep -v '^#' "$TUNED_FILE" | tr '\n' ' ')
    merge_args "$TA" "$CALIB"   # the saved result replaces every calibrated flag (a config calibrated elsewhere keeps none of them)
    echo "post-setup.sh: calibration for this hardware applied from $TUNED_FILE: ${TA:-(the defaults won)}"
elif [ "${STRATA_CALIBRATE:-no}" != no ]; then
    echo "post-setup.sh: no calibration for this hardware (calibration failed?), the config is used as it is"
fi

# STRATA_PARALLEL=N: N requests decoded together (Strata's batch slots, --batch N). Unset: the config stays as it is (Strata's default: one at a time).
# 1 removes --batch/--slots again, N above 1 sets --batch N (the engine may run fewer when they do not fit: GET /v1/status concurrency.serving).
EA="${STRATA_ENGINE_ARGS:-}"; STRIP='[]'; PAR=""
case "${STRATA_PARALLEL:-}" in
    '') ;;
    *[!0-9]*) echo "post-setup.sh: STRATA_PARALLEL=$STRATA_PARALLEL is not a number, ignored" ;;
    0|1) STRIP='["--batch","--slots"]'; PAR=1 ;;
    *) STRIP='["--batch","--slots"]'; EA="$EA --batch $STRATA_PARALLEL"; PAR=$STRATA_PARALLEL ;;
esac
if [ -n "$EA" ] || [ "$STRIP" != '[]' ]; then
    merge_args "$EA" "$STRIP"
    [ -n "$EA" ] && echo "post-setup.sh: engine arguments merged into the config: $EA"
    [ "$PAR" = 1 ] && echo "post-setup.sh: STRATA_PARALLEL=1: one request at a time"
fi

if [ "${POOL_WORKERS:-0}" -gt 0 ] && [ -f "$CFG" ] && command -v jq >/dev/null; then
    if jq -e '.args | (index("--pool-workers") or index("--pcie-frac") or index("--spec-min-p"))' "$CFG" >/dev/null; then
        :   # already set, or calibrated (a calibration measured the worker counts together with its other values)
    else
        for f in "$CFG" "$STRATA_HOME/strata-$TAG.json"; do
            [ -f "$f" ] || continue
            jq --arg n "$POOL_WORKERS" '.args += ["--pool-workers", $n]' "$f" > "$f.tmp" && cat "$f.tmp" > "$f"; rm -f "$f.tmp"
        done
        echo "post-setup.sh: --pool-workers $POOL_WORKERS written into the config"
    fi
fi
[ -n "${SHA:-}" ] && [ -f "$CFG" ] && echo "$SHA" > "$STRATA_DATA/config/.built-with"   # the Strata commit this config now belongs to
if [ -n "$STRATA_STORE" ]; then
    mkdir -p "$STRATA_STORE/logs"
    ( ionice -c3 nice -n 19 /opt/runpod/publish.sh >> "$STRATA_STORE/logs/publish.log" 2>&1 & )
fi
exit 0
