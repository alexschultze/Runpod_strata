#!/bin/bash
# Called by Strata's docker-entrypoint.sh (patched by start.sh) after the setup and before the server starts, on every start.
# 1. writes --pool-workers into the model's config unless it has one or has been calibrated (a calibration measured the workers itself)
# 2. in the background: archives the engine and pushes the data to the volume, once
# Environment from start.sh: STRATA_HOME STRATA_DATA STRATA_STORE KEY TAG COPY_DATA_LOCAL POOL_WORKERS
CFG="$STRATA_DATA/config/strata-$TAG.json"
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
