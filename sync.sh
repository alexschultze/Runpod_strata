#!/bin/bash
# Pushes /data (model, pack, presets, tuning, run settings) to the store on the volume once the server has loaded its model, so the next
# worker or pod finds it. Incremental (rsync), at idle priority; the API key file and logs are not copied. Started by start.sh.
# Env: DATA_DIR (default /data), STRATA_STORE, PORT (the server's port, default 8080), SYNC_WAIT=no skips waiting for /health.
DATA="${DATA_DIR:-/data}"
[ -n "${STRATA_STORE:-}" ] && command -v rsync >/dev/null || { echo "$(date +%T) sync: no store or no rsync, nothing to do"; exit 0; }
if [ "${SYNC_WAIT:-yes}" != no ]; then
    for _ in $(seq 1 1440); do   # up to 2 hours: the first start downloads the model
        curl -fs "http://127.0.0.1:${PORT:-8080}/health" 2>/dev/null | grep -q '"loaded": *true' && break
        sleep 5
    done
fi
mkdir -p "$STRATA_STORE/data"
echo "$(date +%T) sync: $DATA -> $STRATA_STORE/data"
rsync -a --partial --exclude=/state/api-key --exclude='*.log' --exclude=/.local-complete "$DATA/" "$STRATA_STORE/data/" && touch "$STRATA_STORE/data/.complete" && echo "$(date +%T) sync: done" || { echo "$(date +%T) sync: failed" >&2; exit 1; }
