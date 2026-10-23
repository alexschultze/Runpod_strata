#!/bin/bash
# Pushes /data (model, pack, presets, tuning, run settings) to the store on the volume once the server has loaded its model, so the next
# worker or pod finds it. SYNC_FINAL=1: the last sync at shutdown (start.sh), without waiting and without marking the store complete. Incremental (rsync), at idle priority; the API key file and logs are not copied. Started by start.sh.
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
# one rsync at a time (the final sync at shutdown must not collide with one still running); runtime files of a running Strata stay out
exec 9>"$STRATA_STORE/.sync.lock"; flock -w 300 9 || { echo "$(date +%T) sync: another sync holds the lock, giving up" >&2; exit 1; }
[ -L "$DATA/Strata-data" ] && SKIP=--exclude=/Strata-data || SKIP=--exclude=/nothing   # COPY_DATA_LOCAL=no: the big files are already on the volume
echo "$(date +%T) sync: $DATA -> $STRATA_STORE/data${SYNC_FINAL:+ (final, at shutdown)}"
rsync -a --partial $SKIP --exclude=/state/api-key --exclude='*.log' --exclude=/.local-complete --exclude=/state/strata/runtime/ --exclude=/state/strata/procs/ --exclude='*.lock' "$DATA/" "$STRATA_STORE/data/" \
    && { [ -n "${SYNC_FINAL:-}" ] || touch "$STRATA_STORE/data/.complete"; echo "$(date +%T) sync: done"; } || { echo "$(date +%T) sync: failed" >&2; exit 1; }
