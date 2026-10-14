#!/bin/bash
# Called by Strata's docker-entrypoint.sh (patched by start.sh) after the setup and before the server starts, on every start.
# 0. STRATA_CALIBRATE=yes|force runs the calibration (default no: never automatically)
# 0b. STRATA_PARALLEL=N (batch slots) and STRATA_ENGINE_ARGS (e.g. "--pcie-frac 1.00 --spec-min-p 0.70") is merged into the config args on every start
# 1. writes --pool-workers into the model's config unless it has one or has been calibrated (a calibration measured the workers itself)
# 2. in the background: archives the engine and pushes the data to the volume, once
# Environment from start.sh: STRATA_HOME STRATA_DATA STRATA_STORE KEY TAG COPY_DATA_LOCAL POOL_WORKERS
CFG="$STRATA_DATA/config/strata-$TAG.json"
has_cal() { [ -f "$CFG" ] && jq -e '.args | (index("--pcie-frac") or index("--spec-min-p"))' "$CFG" >/dev/null 2>&1; }
case "${STRATA_CALIBRATE:-no}" in
    yes|force)
        if [ "$STRATA_CALIBRATE" = force ] || ! has_cal; then
            echo "post-setup.sh: STRATA_CALIBRATE=$STRATA_CALIBRATE, running the calibration (15-30 min)"
            "${CALIBRATE_SCRIPT:-/app/scripts/calibrate.sh}" || echo "post-setup.sh: calibration failed, continuing without"
        else
            echo "post-setup.sh: config already calibrated, skipping (STRATA_CALIBRATE=force repeats it)"
        fi ;;
esac
# STRATA_PARALLEL=N: N requests decoded together (Strata's batch slots, --batch N). Unset: the config stays as it is (Strata's default: one at a time).
# 1 removes --batch/--slots again, N above 1 sets --batch N (the engine may run fewer when they do not fit: GET /v1/status concurrency.serving).
EA="${STRATA_ENGINE_ARGS:-}"; STRIP='[]'; PAR=""
case "${STRATA_PARALLEL:-}" in
    '') ;;
    *[!0-9]*) echo "post-setup.sh: STRATA_PARALLEL=$STRATA_PARALLEL is not a number, ignored" ;;
    0|1) STRIP='["--batch","--slots"]'; PAR=1 ;;
    *) STRIP='["--batch","--slots"]'; EA="$EA --batch $STRATA_PARALLEL"; PAR=$STRATA_PARALLEL ;;
esac
if { [ -n "$EA" ] || [ "$STRIP" != '[]' ]; } && [ -f "$CFG" ] && command -v jq >/dev/null; then
    for f in "$CFG" "$STRATA_HOME/strata-$TAG.json"; do
        [ -f "$f" ] || continue
        jq --arg a "$EA" --argjson strip "$STRIP" '
          ($a | split(" ") | map(select(length>0))) as $new
          | (($new | map(select(startswith("--")))) + $strip) as $flags
          | .args = ((.args | reduce .[] as $t ({out:[],skip:false};
                if ($t|startswith("--")) then (if ($flags|index($t)) then .skip=true else .skip=false | .out+=[$t] end)
                else (if .skip then . else .out+=[$t] end) end) | .out) + $new)' "$f" > "$f.tmp" && cat "$f.tmp" > "$f"; rm -f "$f.tmp"
    done
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
