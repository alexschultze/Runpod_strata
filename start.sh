#!/bin/bash
# Starts Strata 0.2 (its image holds the engine and the Terminal; nothing is compiled here). Branch strata-v2-dev.
#
#   1. Data (/data: model, pack, presets, tuning): on the local disk. COPY_DATA_LOCAL=yes (default) copies the store on the volume to it (rsync with progress
#      every 10 s), no: /data/Strata-data links to the volume. sync.sh pushes /data back to the store once the server is up.
#   2. Strata's own entrypoint (/opt/strata/entrypoint.sh) starts the server (MODE pod); queue and lb run it in the background beside our handler / proxy.
#
# Our variables, mapped to Strata's (see README_DETAILS.md):
#   STRATA_API_KEY (alias API_KEY)  required; ALLOW_NO_API_KEY=1 lets Strata make a key itself
#   MODEL=IQ2_XS  CONTEXT=32768  FAMILY  KV  VISION  GPU/GPUS  PORT  MODEL_PATH   the same names as in Strata's image (CONTEXT default is ours: Strata would take the largest that fits)
#   STRATA_PARALLEL=N   -> PARALLEL=N (requests answered together)
#   STRATA_CALIBRATE=no|yes|force   -> TUNE: no = skip, yes = TUNE=quick (done once per preset), force = TUNE=quick RETUNE=1
#   PRESET   Strata's preset name; default docker-<gpu>-<vram>g, so every kind of card gets its own preset and its own tuning
#   STRATA_SET   advanced engine settings, space separated key=value (replaces STRATA_ENGINE_ARGS)
#   COPY_DATA_LOCAL=yes|no   STRATA_STORE (default <volume>/strata-store/v2)   MODE=pod|lb|queue   LB_PORT=8000 (lb proxy)
# Ignored by Strata 0.2 (it plans RAM and the engine itself): LOW_RAM, REINSTALL, RESIDENT_BUDGET_GIB, HOST, CONFIG, STRATA_REF, STRATA_REPO.
set -e
. "$(dirname "$(readlink -f "$0")")/hwinfo.sh"; hw_detect; hw_banner   # first thing: which instance is this
HERE="$(dirname "$(readlink -f "$0")")"
if [ -z "${MODE:-}" ] && [ -n "${RUNPOD_ENDPOINT_ID:-}" ]; then MODE=queue; echo "start.sh: Serverless worker (RUNPOD_ENDPOINT_ID set), MODE=queue (set MODE=lb for a load-balancing endpoint)"; fi
MODE="${MODE:-pod}"
export MODEL="${MODEL:-IQ2_XS}" CONTEXT="${CONTEXT:-32768}"
case "${COPY_DATA_LOCAL:-yes}" in [Yy]*|1|[Tt]rue) COPY_DATA_LOCAL=yes ;; *) COPY_DATA_LOCAL=no ;; esac
export COPY_DATA_LOCAL
DATA="${DATA_DIR:-/data}"; export DATA_DIR="$DATA"
ENTRY="${STRATA_ENTRYPOINT:-/opt/strata/entrypoint.sh}"

# ---- where things are ----------------------------------------------------------------------------------------------------
# /workspace on a Pod, /runpod-volume on Serverless (only used when /workspace is not a mount)
if grep -qs ' /workspace ' /proc/mounts; then VOL=/workspace
elif [ -d /runpod-volume ]; then VOL=/runpod-volume
else VOL=""; fi
STRATA_STORE="${STRATA_STORE:-${VOL:+$VOL/strata-store/v2}}"
export STRATA_STORE
volume_report
engine_report
[ -n "$STRATA_STORE" ] && mkdir -p "$STRATA_STORE/data" "$STRATA_STORE/logs"
[ -n "$STRATA_STORE" ] || echo "start.sh: no volume found (/runpod-volume, /workspace): nothing is stored, model and tuning are lost with the container"
mkdir -p "$DATA"
[ -n "$STRATA_STORE" ] && [ -x "$HERE/volume-check.sh" ] && "$HERE/volume-check.sh" "$STRATA_STORE" || true

fail_alive() { echo "start.sh: $*" >&2; exec sleep infinity; }   # keeps the pod (and sshd) up so you can look around
API_KEY="${STRATA_API_KEY:-${API_KEY:-}}"; export API_KEY
if [ -z "$API_KEY" ] && [ "${ALLOW_NO_API_KEY:-0}" != 1 ]; then
    fail_alive "STRATA_API_KEY is not set: Strata is NOT started (it must not run without a key). Set it (Runpod Secrets) and run /opt/runpod/start.sh again."
fi
[ -n "$API_KEY" ] && [ "${#API_KEY}" -lt 16 ] && echo "start.sh: WARNING: the API key is short (${#API_KEY} characters), use 16 or more" >&2
for v in LOW_RAM REINSTALL RESIDENT_BUDGET_GIB HOST CONFIG STRATA_REF STRATA_REPO STRATA_ENGINE_ARGS POOL_WORKERS; do
    eval "x=\${$v:-}"
    [ -n "$x" ] && echo "start.sh: $v is from the Strata 0.1 image and is ignored (Strata 0.2 plans RAM and the engine itself; STRATA_SET=key=value for engine settings)" >&2
done
progress_run() {
    local label=$1 dest=$2 total=$3 pid rc=0 t0=$SECONDS next=$((SECONDS + 10)) prev=0 prevt=$SECONDS cur
    shift 3
    "$@" & pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        sleep 1
        [ "$SECONDS" -ge "$next" ] || continue
        next=$((SECONDS + 10))
        cur=$(du -sb "$dest" 2>/dev/null | cut -f1); cur=${cur:-0}
        awk -v l="$label" -v c="$cur" -v p="$prev" -v dt="$((SECONDS - prevt))" -v t="$total" -v e="$((SECONDS - t0))" 'BEGIN {
            sp = (dt > 0 && c >= p) ? (c - p) / dt : 0
            s = sprintf("start.sh: %s: %.1f", l, c / 2^30)
            if (t > 0) { s = s sprintf(" / %.1f GiB (%d%%)", t / 2^30, c * 100 / t) } else { s = s " GiB" }
            s = s sprintf(", %.0f MB/s, %ds elapsed", sp / 1e6, e)
            if (t > 0 && sp > 0 && t > c) s = s sprintf(", ETA %ds", (t - c) / sp)
            print s }'
        prev=$cur; prevt=$SECONDS
    done
    wait "$pid" || rc=$?
    return "$rc"
}

# ---- the data: local disk, with the volume as store -----------------------------------------------------------------------
if [ -n "$STRATA_STORE" ] && [ "$COPY_DATA_LOCAL" = yes ] && [ -d "$STRATA_STORE/data" ] && [ -n "$(ls -A "$STRATA_STORE/data" 2>/dev/null)" ] && [ ! -f "$DATA/.local-complete" ]; then
    SRC_BYTES=$(du -sb "$STRATA_STORE/data" 2>/dev/null | cut -f1); SRC_BYTES=${SRC_BYTES:-0}
    need=$(( SRC_BYTES / 1073741824 + 10 )); free=$(df -BG --output=avail "$DATA" | tail -1 | tr -dc 0-9)
    [ "$free" -ge "$need" ] || fail_alive "the container disk is too small: $need GiB needed under $DATA, $free GiB free. Raise the container disk (85 GB for the recommended model) or set COPY_DATA_LOCAL=no."
    echo "start.sh: copying the data from $STRATA_STORE/data to $DATA ($need GiB)"
    progress_run "copying the data" "$DATA" "$SRC_BYTES" rsync -a --partial --exclude=/state/api-key --exclude='*.log' "$STRATA_STORE/data/" "$DATA/"
    touch "$DATA/.local-complete"
elif [ -n "$STRATA_STORE" ] && [ "$COPY_DATA_LOCAL" = no ]; then   # the big files stay on the volume: /data/Strata-data is a link to it
    mkdir -p "$STRATA_STORE/data/Strata-data"
    if [ ! -L "$DATA/Strata-data" ]; then
        if [ -d "$DATA/Strata-data" ] && [ -z "$(ls -A "$DATA/Strata-data" 2>/dev/null)" ]; then rmdir "$DATA/Strata-data"; fi
        [ -e "$DATA/Strata-data" ] || ln -s "$STRATA_STORE/data/Strata-data" "$DATA/Strata-data"
    fi
fi

# ---- Strata's settings from ours ------------------------------------------------------------------------------------------
[ -n "${STRATA_PARALLEL:-}" ] && [ -z "${PARALLEL:-}" ] && export PARALLEL="$STRATA_PARALLEL"
if [ -z "${TUNE:-}" ]; then
    case "${STRATA_CALIBRATE:-no}" in
        yes)   export TUNE=quick ;;
        force) export TUNE=quick RETUNE=1 ;;
    esac
fi
if [ -z "${PRESET:-}" ]; then PRESET="docker-$(hw_slug "$GPU_NAME")-${GPU_VRAM_GIB}g"; fi   # one preset (and so one tuning) per kind of card
export PRESET
echo "start.sh: MODE=$MODE MODEL=$MODEL CONTEXT=$CONTEXT PRESET=$PRESET${TUNE:+ TUNE=$TUNE}${RETUNE:+ RETUNE=$RETUNE}${PARALLEL:+ PARALLEL=$PARALLEL}${STRATA_SET:+ STRATA_SET=\"$STRATA_SET\"} COPY_DATA_LOCAL=$COPY_DATA_LOCAL STORE=${STRATA_STORE:--} DATA=$DATA"

# ---- start ----------------------------------------------------------------------------------------------------------------
# once the server has loaded the model: push /data to the store (sync.sh waits for /health)
if [ -n "$STRATA_STORE" ]; then
    SP_PORT=8080; [ "$MODE" = pod ] && SP_PORT="${PORT:-8080}"   # the port Strata listens on (queue and lb: always 8080)
    ( PORT="$SP_PORT" ionice -c3 nice -n 19 "$HERE/sync.sh" >> "$STRATA_STORE/logs/sync.log" 2>&1 & )
fi
if [ "$MODE" = pod ]; then exec "$ENTRY" run; fi

export STRATA_PORT=8080
( PORT=8080 "$ENTRY" run ) &
SP=$!
trap 'kill -TERM $SP 2>/dev/null; wait $SP' TERM INT
PY=/opt/runpod/venv/bin/python
if [ "$MODE" = lb ]; then
    LBP="${LB_PORT:-8000}"
    PORT="$LBP" PORT_HEALTH="${PORT_HEALTH:-$LBP}" "$PY" "$HERE/proxy.py" &
else
    "$PY" -u "$HERE/handler.py" &
fi
wait $!
kill -TERM $SP 2>/dev/null; wait $SP
