#!/bin/bash
# Pushes what the setup produced to the volume: the engine archive (once per key) and the model data (once). Runs in the background.
# Environment from start.sh: STRATA_HOME STRATA_DATA STRATA_STORE KEY TAG COPY_DATA_LOCAL
command -v rsync >/dev/null || { echo "publish: rsync is not installed"; exit 1; }
exec 8>"$STRATA_STORE/.publish.lock"
flock -n 8 || { echo "$(date +%T) publish: another publish is running"; exit 0; }
echo "$(date +%T) publish: key $KEY"
ARCHIVE="$STRATA_STORE/app-$KEY.tar"
if [ ! -f "$ARCHIVE" ] && [ -f "$STRATA_HOME/engine/BUILD.json" ]; then
    # without the build folders; the Python environment and the engine are what a restore needs
    tar -C "$(dirname "$STRATA_HOME")" --exclude="$(basename "$STRATA_HOME")/build" --exclude="$(basename "$STRATA_HOME")/build-vision" \
        -cf "$ARCHIVE.tmp" "$(basename "$STRATA_HOME")" && mv "$ARCHIVE.tmp" "$ARCHIVE" && echo "$(date +%T) publish: archive $(du -h "$ARCHIVE" | cut -f1)"
fi
rc=0
if [ "$COPY_DATA_LOCAL" = yes ]; then
    if [ ! -f "$STRATA_STORE/data/.complete" ]; then
        echo "$(date +%T) publish: pushing $STRATA_DATA to $STRATA_STORE/data"
        rsync -a --partial --exclude=logs --exclude=.local-complete "$STRATA_DATA/" "$STRATA_STORE/data/" && touch "$STRATA_STORE/data/.complete" || rc=1
    else   # data is there: only the config (a calibration or the pool workers may have changed it)
        rsync -a "$STRATA_DATA/config/" "$STRATA_STORE/data/config/" || rc=1
    fi
else
    mkdir -p "$STRATA_STORE/data/config"
    rsync -a "$STRATA_DATA/config/" "$STRATA_STORE/data/config/" && touch "$STRATA_STORE/data/.complete" || rc=1
fi
[ "$rc" = 0 ] && touch "$STRATA_DATA/.local-complete"
echo "$(date +%T) publish: done (rc=$rc)"
exit "$rc"
