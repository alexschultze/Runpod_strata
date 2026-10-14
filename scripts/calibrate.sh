#!/bin/bash
# Runs Strata's calibration (15-30 minutes, measures pcie-frac, spec-min-p, pool-workers and the expert tier) and keeps the result
# for THIS hardware, next to each other in <store>/tuned/ (key = GPU, count, VRAM, CPU, model, context):
#   <key>.args   the calibrated flags (one line), a LOW_RAM=... line if there is one (kept, or the LOW_RAM of this run), and the summary lines of
#                Strata's calibration output as # comments
#   <key>.log    the complete output of Strata's calibration
# The next start on the same hardware applies the .args (post-setup.sh); other hardware has its own files.
# STRATA_CALIBRATE=yes|force runs this script by itself. Stop the running server first: the calibration needs the GPU and the CPU for itself.
# The calibration rewrites /opt/strata/strata-<tag>.json (replacing the link to the data folder's copy): this script copies the
# result back to the config folder and pushes it to the volume.
# Usage: /app/scripts/calibrate.sh [setup.sh --calibrate options, e.g. --model IQ2_XS]
set -e
set -o pipefail
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
LOG="${TUNED_FILE%.args}.log"
mkdir -p "$(dirname "$TUNED_FILE")"
OLD_LOW_RAM=$(sed -n 's/^LOW_RAM=//p' "$TUNED_FILE" 2>/dev/null | head -1 || true)

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
echo "calibrate.sh: the settings.json with the calibration is in ${XDG_CONFIG_HOME:-~/.config}/strata"

# the calibrated flags of the model's config, saved for this hardware
A=$(jq -r '.args as $a | [range(0;$a|length)] | map(select($a[.]|startswith("--pcie-frac") or startswith("--spec-min-p") or startswith("--pool-workers") or startswith("--adapt"))) | map([$a[.], (if ($a[.+1]//"--")|startswith("--") then empty else $a[.+1] end)]) | flatten | join(" ")' "$STRATA_DATA/config/strata-$TAG.json" 2>/dev/null || true)
LR="${LOW_RAM:-$OLD_LOW_RAM}"
{
    printf '# calibrated %s for %s (%s, %s GiB, %s)\n' "$(date -u +%FT%TZ)" "${TUNED_KEY:-?}" "${GPU_NAME:-?}" "${GPU_VRAM_GIB:-?}" "${CPU_MODEL:-?}"
    sed 's/\x1b\[[0-9;]*m//g' "$LOG" | { grep -iE 'tuned for this|tok/s|kept|default' || true; } | head -12 | sed 's/^/# /'
    [ -n "$LR" ] && printf 'LOW_RAM=%s\n' "$LR"
    printf '%s\n' "$A"
} > "$TUNED_FILE"
echo "calibrate.sh: result for this hardware saved to $TUNED_FILE: ${A:-(the defaults won)}${LR:+ LOW_RAM=$LR}; Strata's output in $LOG"
