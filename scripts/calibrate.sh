#!/bin/bash
# Runs Strata's calibration (15-30 minutes, measures pcie-frac, spec-min-p, pool-workers and the expert tier).
# Strata keeps the result itself: in settings.json (one entry per hardware key; on the volume through XDG_CONFIG_HOME, so every pod and worker
# sees it) and in the model's config. Applied by Strata's setup for the same hardware (start.sh runs it again when the hardware changed).
# This script also keeps Strata's complete output in <store>/logs/calibrate-<date>.log and pushes the calibrated config to the volume.
# STRATA_CALIBRATE=yes|force runs this script by itself. Stop the running server first: the calibration needs the GPU and the CPU for itself.
# The calibration rewrites /opt/strata/strata-<tag>.json (replacing the link to the data folder's copy): this script copies it back.
# Usage: /app/scripts/calibrate.sh [setup.sh --calibrate options, e.g. --model IQ2_XS]
set -e
set -o pipefail
LOGDIR="${STRATA_STORE:+$STRATA_STORE/logs}"; LOGDIR="${LOGDIR:-$STRATA_DATA/logs}"
mkdir -p "$LOGDIR"
LOG="$LOGDIR/calibrate-$(date +%Y%m%d-%H%M%S).log"
cd /opt/strata
./setup.sh --calibrate --no-start "$@" 2>&1 | tee "$LOG"
for f in /opt/strata/strata-*.json; do
    case "$f" in *.shared-settings.json) continue ;; esac
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    cp -f "$f" "$STRATA_DATA/config/$(basename "$f")" && echo "calibrate.sh: $(basename "$f") saved to $STRATA_DATA/config"
done
if [ -n "${STRATA_STORE:-}" ]; then
    rsync -a "$STRATA_DATA/config/" "$STRATA_STORE/data/config/" && echo "calibrate.sh: config pushed to $STRATA_STORE/data/config"
fi
echo "calibrate.sh: Strata's output is in $LOG; the calibrations per hardware are in ${XDG_CONFIG_HOME:-~/.config}/strata/settings.json (jq '.calibration | keys')"
