#!/bin/bash
# Starts Strata. Engine and data are installed and run under /tmp (local disk, fast); the network volume only stores them.
#
#   1. Engine: restored from the volume (strata-store/app-<key>.tar) when an archive for this GPU, CPU and Strata commit exists,
#      else cloned from GitHub and built by Strata's setup.py, then archived to the volume (post-setup.sh).
#   2. Data (models, packs, mtp, config): COPY_DATA_LOCAL=yes (default) copies them from the volume to /tmp/Strata-data once per
#      pod, no: they stay on the volume and /tmp/Strata-data links to them. A first setup downloads into /tmp and pushes to the volume.
#   3. Strata starts from /tmp (MODE pod | lb | queue).
#
# Environment variables (defaults):
#   FAMILY=qwen  MODEL=IQ2_XS  CONTEXT=32768  LOW_RAM=on     Strata's setup choices (see README)
#   API_KEY        required: without it only sshd runs (ALLOW_NO_API_KEY=1 overrides, for tests that are not exposed)
#   COPY_DATA_LOCAL=yes|no    copy the model data to the local disk (default yes, needs a big container disk) or use it on the volume
#   STRATA_STORE   the volume's store, default <volume>/strata-store (volume: /runpod-volume, else /workspace if mounted)
#   STRATA_LOCAL   local base, default /tmp (Strata in <base>/Strata, data in <base>/Strata-data)
#   STRATA_REF / STRATA_REPO   branch/tag and URL of the Strata repo (default: HEAD of Niko1221/Strata); the commit is part of the key
#   POOL_WORKERS   CPU expert workers written into a new config: default pod CPU quota minus 3 (min 4), 0 = leave Strata's choice
#   MODE=pod|lb|queue   Strata on :8080 | proxy with /ping on $PORT | runpod queue handler
#   RESIDENT_BUDGET_GIB  unsloth only: GiB of experts kept in RAM, default pod RAM (cgroup limit) minus 24
# Further Strata variables (KV, GPU, GPUS, PORT, VISION, REINSTALL, ...) pass through to Strata's docker-entrypoint.sh.
set -e
MODE="${MODE:-pod}"
export MODEL="${MODEL:-IQ2_XS}" FAMILY="${FAMILY:-qwen}" CONTEXT="${CONTEXT:-32768}" LOW_RAM="${LOW_RAM:-on}"
case "${COPY_DATA_LOCAL:-yes}" in [Yy]*|1|[Tt]rue) COPY_DATA_LOCAL=yes ;; *) COPY_DATA_LOCAL=no ;; esac
export COPY_DATA_LOCAL

# ---- where things are ----------------------------------------------------------------------------------------------------
if [ -d /runpod-volume ]; then VOL=/runpod-volume
elif grep -qs ' /workspace ' /proc/mounts; then VOL=/workspace
else VOL=""; fi
STRATA_STORE="${STRATA_STORE:-${VOL:+$VOL/strata-store}}"
STRATA_LOCAL="${STRATA_LOCAL:-/tmp}"
STRATA_HOME="$STRATA_LOCAL/Strata"
export STRATA_STORE STRATA_HOME STRATA_DATA="${STRATA_DATA:-$STRATA_LOCAL/Strata-data}"
STRATA_REPO="${STRATA_REPO:-https://github.com/Niko1221/Strata.git}"
if [ -n "$STRATA_STORE" ]; then
    mkdir -p "$STRATA_STORE/data" "$STRATA_STORE/logs"
    export XDG_CONFIG_HOME="$STRATA_STORE/xdg"; mkdir -p "$XDG_CONFIG_HOME"   # Strata's settings.json (incl. calibrations) persists
else
    echo "start.sh: no volume found (/runpod-volume, /workspace): nothing is stored, the setup is repeated after every pod restart"
fi
mkdir -p "$STRATA_LOCAL" "$STRATA_DATA"

# ---- Strata's setup reads the host's RAM from /proc/meminfo and cannot see the pod's limit: derive values from the cgroup ----
mem_gib() {
    local f v
    for f in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory/memory.limit_in_bytes; do
        v=$(cat "$f" 2>/dev/null) || continue
        case "$v" in ''|*[!0-9]*) continue ;; esac
        [ "$v" -lt 1099511627776 ] && { echo $((v / 1073741824)); return; }
    done
    awk '/MemTotal/ {print int($2 / 1048576)}' /proc/meminfo
}
if [ "$FAMILY" = unsloth ] && [ -z "${RESIDENT_BUDGET_GIB:-}" ]; then
    RAM_GIB=$(mem_gib)
    RESIDENT_BUDGET_GIB=$((RAM_GIB - 24)); [ "$RESIDENT_BUDGET_GIB" -lt 8 ] && RESIDENT_BUDGET_GIB=8
    echo "start.sh: pod RAM ${RAM_GIB} GiB -> RESIDENT_BUDGET_GIB=$RESIDENT_BUDGET_GIB (set the variable to override)"
fi
export RESIDENT_BUDGET_GIB="${RESIDENT_BUDGET_GIB:-}"
if [ -z "${POOL_WORKERS:-}" ]; then
    read -r quota period < /sys/fs/cgroup/cpu.max 2>/dev/null || { quota=max; period=100000; }
    if [ "$quota" != max ] && [ "${period:-0}" -gt 0 ]; then
        POOL_WORKERS=$((quota / period - 3)); [ "$POOL_WORKERS" -lt 4 ] && POOL_WORKERS=4
        echo "start.sh: pod CPU quota $((quota / period)) vCPUs -> POOL_WORKERS=$POOL_WORKERS (written into a new config; set POOL_WORKERS=0 to leave it to Strata)"
    else POOL_WORKERS=0; fi
fi
export POOL_WORKERS

case "$FAMILY" in qwen) prefix="" ;; *) prefix="${FAMILY}-" ;; esac
TAG="${prefix}$(printf '%s' "$MODEL" | tr 'A-Z' 'a-z')"; export TAG
echo "start.sh: MODE=$MODE FAMILY=$FAMILY MODEL=$MODEL CONTEXT=$CONTEXT LOW_RAM=$LOW_RAM COPY_DATA_LOCAL=$COPY_DATA_LOCAL STORE=${STRATA_STORE:--} DATA=$STRATA_DATA"

[ -x /opt/runpod/sshd.sh ] && /opt/runpod/sshd.sh

# AI_SETUP.md rule: never expose Strata without an API key (the Runpod proxy makes port 8080 reachable from the internet).
# The key is recorded in the model's config on the first start (REINSTALL=1 changes it later), so it is not generated here.
# Without a key only sshd runs, so you can still log in and debug.
if [ -z "${API_KEY:-}" ] && [ "${ALLOW_NO_API_KEY:-0}" != 1 ]; then
    echo "start.sh: API_KEY is not set. Strata is NOT started (set API_KEY, or ALLOW_NO_API_KEY=1 for a test without exposure)." >&2
    exec sleep infinity
fi
fail_alive() { echo "start.sh: $*" >&2; exec sleep infinity; }   # keeps the pod (and sshd) up so you can look around

# ---- 1. the engine: key, restore from the volume or clone ------------------------------------------------------------------
gpu_arch() { nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | tr -d '. ' | sort -u | paste -sd+ -; }
cpu_isa()  { grep -m1 '^flags' /proc/cpuinfo | tr ' ' '\n' | grep -E '^(avx|avx2|fma|f16c|bmi1|bmi2|avx512.*|avx_vnni|amx.*)$' | sort | tr '\n' ' ' | sha1sum | cut -c1-8; }
ARCH=$(gpu_arch); ARCH="${ARCH:-nogpu}"; ISA=$(cpu_isa)
SHA=$(git ls-remote "$STRATA_REPO" "${STRATA_REF:-HEAD}" 2>/dev/null | awk 'NR==1 {print substr($1, 1, 12)}')
if [ -z "$SHA" ] && [ -n "$STRATA_STORE" ]; then   # GitHub not reachable: take the newest archive for this GPU and CPU
    last=$(ls -t "$STRATA_STORE"/app-sm"$ARCH"-"$ISA"-*.tar 2>/dev/null | head -1)
    [ -n "$last" ] && SHA=$(basename "$last" .tar | sed "s/^app-sm$ARCH-$ISA-//")
fi
export KEY="sm${ARCH}-${ISA}-${SHA:-unknown}"
ARCHIVE="${STRATA_STORE:+$STRATA_STORE/app-$KEY.tar}"
echo "start.sh: engine key $KEY"

app_ready() { [ -f "$STRATA_HOME/.venv/.strata-bootstrap-done" ] && [ -f "$STRATA_HOME/engine/BUILD.json" ]; }
if ! app_ready; then
    if [ -n "$ARCHIVE" ] && [ -f "$ARCHIVE" ]; then
        echo "start.sh: restoring the engine from $ARCHIVE"
        rm -rf "${STRATA_HOME:?}"
        tar -xf "$ARCHIVE" -C "$STRATA_LOCAL"
    fi
fi
if ! app_ready; then   # no archive for this key: clone and prepare the Python environment; setup.py builds the engine below
    if [ ! -d "$STRATA_HOME/.git" ]; then
        echo "start.sh: cloning $STRATA_REPO ${STRATA_REF:+(ref $STRATA_REF) }into $STRATA_HOME"
        rm -rf "${STRATA_HOME:?}.tmp"
        git clone --depth 1 ${STRATA_REF:+--branch "$STRATA_REF"} "$STRATA_REPO" "$STRATA_HOME.tmp"
        rm -rf "${STRATA_HOME:?}"; mv "$STRATA_HOME.tmp" "$STRATA_HOME"
    fi
    if [ ! -f "$STRATA_HOME/.venv/.strata-bootstrap-done" ]; then
        echo "start.sh: creating the Python environment in $STRATA_HOME/.venv"
        rm -rf "${STRATA_HOME:?}/.venv"
        python3 -m venv "$STRATA_HOME/.venv"
        "$STRATA_HOME/.venv/bin/pip" install --no-cache-dir --upgrade pip
        "$STRATA_HOME/.venv/bin/pip" install --no-cache-dir -r "$STRATA_HOME/requirements.txt"
        "$STRATA_HOME/.venv/bin/pip" install --no-cache-dir runpod requests
        touch "$STRATA_HOME/.venv/.strata-bootstrap-done"
    fi
fi
chmod +x "$STRATA_HOME/setup.sh" "$STRATA_HOME/docker-entrypoint.sh"
ln -sfn "$STRATA_HOME" /opt/strata          # Strata's entrypoint works in /opt/strata

# Strata's entrypoint sets up (engine build, download) and then starts the server in one go. Hook between the two: post-setup.sh
# (pool workers into the config, archive the engine and push the data to the volume). Skipped with a warning if the entrypoint changed.
EP="$STRATA_HOME/docker-entrypoint.sh"
if ! grep -q STRATA_POST_SETUP "$EP"; then
    if grep -q '^set -- --port "\$PORT"$' "$EP"; then
        sed -i 's|^set -- --port "\$PORT"$|[ -n "${STRATA_POST_SETUP:-}" ] \&\& "$STRATA_POST_SETUP" \|\| true\nset -- --port "$PORT"|' "$EP"
    else
        echo "start.sh: WARNING: Strata's docker-entrypoint.sh has changed, the post-setup hook (archive, push, pool workers) is not installed" >&2
    fi
fi
export STRATA_POST_SETUP=/opt/runpod/post-setup.sh

# ---- 2. the data ---------------------------------------------------------------------------------------------------------
# estimated GiB on the local disk (download + pack + MTP) when nothing is on the volume yet
case "$MODEL" in Q2_0) NEED=100 ;; IQ2_XS) NEED=115 ;; IQ3_XXS) NEED=135 ;; IQ3_S) NEED=150 ;; IQ1_M) NEED=90 ;; UD-IQ4_XS) NEED=115 ;; UD-Q4_K_XL) NEED=130 ;; *) NEED=150 ;; esac
avail_gib() { df -BG --output=avail "$1" | tail -1 | tr -dc 0-9; }
if [ "$COPY_DATA_LOCAL" = yes ]; then
    if [ ! -f "$STRATA_DATA/.local-complete" ] && [ -n "$STRATA_STORE" ] && [ -f "$STRATA_STORE/data/.complete" ]; then
        have=$(( $(du -sk "$STRATA_STORE/data" | cut -f1) / 1048576 + 10 ))
        [ "$(avail_gib "$STRATA_DATA")" -ge "$have" ] || fail_alive "the container disk is too small: $have GiB needed under $STRATA_DATA, $(avail_gib "$STRATA_DATA") GiB free. Raise the container disk or set COPY_DATA_LOCAL=no."
        echo "start.sh: copying the model data from $STRATA_STORE/data to $STRATA_DATA ($have GiB)"
        rsync -a --partial --exclude=logs --exclude=.complete "$STRATA_STORE/data/" "$STRATA_DATA/"
        touch "$STRATA_DATA/.local-complete"
    elif [ ! -f "$STRATA_DATA/.local-complete" ]; then
        [ "$(avail_gib "$STRATA_DATA")" -ge "$NEED" ] || echo "start.sh: WARNING: $(avail_gib "$STRATA_DATA") GiB free under $STRATA_DATA, about $NEED GiB are needed for $MODEL (raise the container disk or set COPY_DATA_LOCAL=no)" >&2
    fi
elif [ -n "$STRATA_STORE" ]; then   # data stays on the volume: the big folders are links, the config is a local copy (pushed back by post-setup.sh)
    for d in models packs mtp; do
        mkdir -p "$STRATA_STORE/data/$d"
        [ -L "$STRATA_DATA/${d:?}" ] || { rm -rf "${STRATA_DATA:?}/${d:?}"; ln -s "$STRATA_STORE/data/$d" "$STRATA_DATA/$d"; }
    done
    if [ ! -d "$STRATA_DATA/config" ] && [ -d "$STRATA_STORE/data/config" ]; then cp -a "$STRATA_STORE/data/config" "$STRATA_DATA/config"; fi
else
    fail_alive "COPY_DATA_LOCAL=no needs a volume, none was found"
fi

# Strata writes its engine log to /opt/strata/strata-<tag>.log: link it to the volume so it survives a restart
if [ -n "$STRATA_STORE" ]; then ln -sfn "$STRATA_STORE/logs/strata-$TAG.log" "/opt/strata/strata-$TAG.log"; fi

# setup.py asks questions when it is started without --yes, and a container has no keyboard: a closed stdin makes it stop with
# "input ended before a setup answer was received". Two questions can still come up at the start (the setup run itself uses --yes):
# 1) "Which one?" when /opt/strata holds more than one strata-*.json, e.g. after switching MODEL. Only the configs in the data
#    folder count (the entrypoint links the requested one), so stale copies of other models are removed here.
for f in /opt/strata/strata-*.json; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    case "$f" in *.shared-settings.json|"/opt/strata/strata-$TAG.json") ;; *) rm -f "$f" ;; esac
done
# 2) "share the model across both GPUs?" on a pod with two or more GPUs: pin the first one unless GPU or GPUS is given
if [ -z "${GPU:-}${GPUS:-}" ] && [ "$(nvidia-smi -L 2>/dev/null | grep -c '^GPU ')" -gt 1 ]; then
    export GPU=0
    echo "start.sh: several GPUs and neither GPU nor GPUS set: GPU=0 (set GPUS=0,1 or GPUS=all to share the model)"
fi

# ---- 3. start ------------------------------------------------------------------------------------------------------------
if [ "$MODE" = pod ]; then exec /opt/strata/docker-entrypoint.sh; fi

export STRATA_PORT=8080
( PORT=8080 HOST=127.0.0.1 /opt/strata/docker-entrypoint.sh ) &
SP=$!
trap 'kill -TERM $SP 2>/dev/null; wait $SP' TERM INT
if [ "$MODE" = lb ]; then
  /opt/strata/.venv/bin/python /opt/runpod/proxy.py &
else
  /opt/strata/.venv/bin/python -u /opt/runpod/handler.py &
fi
wait $!
kill -TERM $SP 2>/dev/null; wait $SP
