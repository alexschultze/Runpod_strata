#!/bin/bash
# Runs Strata's calibration (15-30 minutes, measures pcie-frac, spec-min-p, pool-workers and the expert tier) and keeps the result
# for THIS hardware: <store>/tuned/<key>.args (key = GPU, count, VRAM, CPU, model, context). The next start on the same hardware applies it
# (post-setup.sh); other hardware has its own file. STRATA_CALIBRATE=yes runs this script by itself when no result exists for the hardware.
# Stop the running server first: the calibration needs the GPU and the CPU for itself.
# The calibration rewrites /opt/strata/strata-<tag>.json (replacing the link to the data folder's copy): this script copies the
# result back to the config folder and pushes it to the volume.
# Usage: /app/scripts/calibrate.sh [setup.sh --calibrate options, e.g. --model IQ2_XS]
set -e
cd /opt/strata
./setup.sh --calibrate --no-start "$@"
for f in /opt/strata/strata-*.json; do
    case "$f" in *.shared-settings.json) continue ;; esac
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    cp -f "$f" "$STRATA_DATA/config/$(basename "$f")" && echo "calibrate.sh: $(basename "$f") saved to $STRATA_DATA/config"
done
if [ -n "${STRATA_STORE:-}" ]; then
    rsync -a "$STRATA_DATA/config/" "$STRATA_STORE/data/config/" && echo "calibrate.sh: config pushed to $STRATA_STORE/data/config"
fi
echo "calibrate.sh: the settings.json with the calibration is in ${XDG_CONFIG_HOME:-~/.config}/strata"

# the calibrated flags of the model's config, saved for this hardware
. "${RUNPOD_DIR:-/opt/runpod}/hwinfo.sh"
if [ -z "${TAG:-}" ]; then
    for f in "$STRATA_DATA"/config/strata-*.json; do [ -f "$f" ] && { b=$(basename "$f" .json); TAG="${b#strata-}"; break; }; done
fi
hw_detect
if [ -z "${TUNED_FILE:-}" ]; then
    hw_key
    D="${STRATA_STORE:+$STRATA_STORE/tuned}"; D="${D:-$STRATA_DATA/tuned}"
    TUNED_FILE="$D/$TUNED_KEY.args"
fi
A=$(jq -r '.args as $a | [range(0;$a|length)] | map(select($a[.]|startswith("--pcie-frac") or startswith("--spec-min-p") or startswith("--pool-workers") or startswith("--adapt"))) | map([$a[.], (if ($a[.+1]//"--")|startswith("--") then empty else $a[.+1] end)]) | flatten | join(" ")' "$STRATA_DATA/config/strata-$TAG.json" 2>/dev/null || true)
mkdir -p "$(dirname "$TUNED_FILE")"
printf '# calibrated %s for %s (%s, %s GiB, %s)\n%s\n' "$(date -u +%FT%TZ)" "${TUNED_KEY:-?}" "${GPU_NAME:-?}" "${GPU_VRAM_GIB:-?}" "${CPU_MODEL:-?}" "$A" > "$TUNED_FILE"
echo "calibrate.sh: result for this hardware saved to $TUNED_FILE: ${A:-(the defaults won)}"
