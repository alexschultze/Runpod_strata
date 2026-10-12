#!/bin/bash
# Runs Strata's calibration (15-30 minutes, measures pcie-frac, spec-min-p, pool-workers and the expert tier) and keeps the result.
# Stop the running server first: the calibration needs the GPU and the CPU for itself.
# The calibration rewrites /opt/strata/strata-<tag>.json (replacing the link to the data folder's copy): this script copies the
# result back to the config folder and pushes it to the volume, so the next start (and the next pod) uses it.
# Usage: /app/scripts/calibrate.sh [setup.sh --calibrate options, e.g. --model IQ2_XS]
set -e
cd /opt/strata
./setup.sh --calibrate "$@"
for f in /opt/strata/strata-*.json; do
    case "$f" in *.shared-settings.json) continue ;; esac
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    cp -f "$f" "$STRATA_DATA/config/$(basename "$f")" && echo "calibrate.sh: $(basename "$f") saved to $STRATA_DATA/config"
done
if [ -n "${STRATA_STORE:-}" ]; then
    rsync -a "$STRATA_DATA/config/" "$STRATA_STORE/data/config/" && echo "calibrate.sh: config pushed to $STRATA_STORE/data/config"
fi
echo "calibrate.sh: the settings.json with the calibration is in ${XDG_CONFIG_HOME:-~/.config}/strata"
