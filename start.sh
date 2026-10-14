#!/bin/bash
# Starts Strata. Engine and data are installed and run under /tmp (local disk, fast); the network volume only stores them.
#
#   1. Engine: restored from the volume (strata-store/app-<key>.tar.zst) when an archive for this GPU, CPU and Strata commit exists,
#      else cloned from GitHub and built by Strata's setup.py, then archived to the volume (post-setup.sh).
#   2. Data (models, packs, mtp, config): COPY_DATA_LOCAL=yes (default) copies them from the volume to /tmp/Strata-data once per
#      pod, no: they stay on the volume and /tmp/Strata-data links to them. A first setup downloads into /tmp and pushes to the volume.
#   3. Strata starts from /tmp (MODE pod | lb | queue).
#
# Environment variables (defaults):
#   FAMILY=qwen  MODEL=IQ2_XS  CONTEXT=32768     Strata's setup choices (see README); LOW_RAM only when you set it, else Strata decides
#   STRATA_API_KEY required (alias API_KEY, Strata's own name): without it only sshd runs (ALLOW_NO_API_KEY=1 overrides, for tests that are not exposed)
#   COPY_DATA_LOCAL=yes|no    copy the model data to the local disk (default yes, needs a big container disk) or use it on the volume
#   STRATA_STORE   the volume's store, default <volume>/strata-store (volume: /workspace if mounted, else /runpod-volume)
#   STRATA_LOCAL   local base, default /tmp (Strata in <base>/Strata, data in <base>/Strata-data)
#   STRATA_REF / STRATA_REPO   Strata to use: latest (default: newest release tag), a tag like v0.1.43.1, a branch, or HEAD; the tag is part of the key
#   POOL_WORKERS   CPU expert workers written into a new config: default pod CPU quota minus 3 (min 4), 0 = leave Strata's choice
#   MODE=pod|lb|queue   Strata on :8080 | proxy with /ping on $PORT | runpod queue handler
#   RESIDENT_BUDGET_GIB  unsloth only: GiB of experts kept in RAM, default pod RAM (cgroup limit) minus 24
# Further Strata variables (KV, GPU, GPUS, PORT, VISION, REINSTALL, ...) pass through to Strata's docker-entrypoint.sh.
set -e
. "$(dirname "$(readlink -f "$0")")/hwinfo.sh"; hw_detect; hw_banner   # first thing: which instance is this
# a Serverless worker without an explicit MODE is queue-based (RunPod sets RUNPOD_ENDPOINT_ID there): without the handler the queue is never processed
if [ -z "${MODE:-}" ] && [ -n "${RUNPOD_ENDPOINT_ID:-}" ]; then MODE=queue; echo "start.sh: Serverless worker (RUNPOD_ENDPOINT_ID set), MODE=queue (set MODE=lb for a load-balancing endpoint)"; fi
MODE="${MODE:-pod}"
export MODEL="${MODEL:-IQ2_XS}" FAMILY="${FAMILY:-qwen}" CONTEXT="${CONTEXT:-32768}"   # LOW_RAM is not set here: Strata decides (auto)
case "${COPY_DATA_LOCAL:-yes}" in [Yy]*|1|[Tt]rue) COPY_DATA_LOCAL=yes ;; *) COPY_DATA_LOCAL=no ;; esac
export COPY_DATA_LOCAL

# ---- where things are ----------------------------------------------------------------------------------------------------
# Our volume is /workspace (Pod). /runpod-volume is where Runpod mounts its own model store and Serverless volumes: only used when
# /workspace is not a mount.
if grep -qs ' /workspace ' /proc/mounts; then VOL=/workspace
elif [ -d /runpod-volume ]; then VOL=/runpod-volume
else VOL=""; fi
STRATA_STORE="${STRATA_STORE:-${VOL:+$VOL/strata-store}}"
STRATA_LOCAL="${STRATA_LOCAL:-/tmp}"
STRATA_HOME="$STRATA_LOCAL/Strata"
export STRATA_STORE STRATA_HOME STRATA_DATA="${STRATA_DATA:-$STRATA_LOCAL/Strata-data}"
STRATA_REPO="${STRATA_REPO:-Niko1221/Strata}"
case "$STRATA_REPO" in */*) [[ "$STRATA_REPO" == *://* || "$STRATA_REPO" == git@* || "$STRATA_REPO" == /* ]] || STRATA_REPO="https://github.com/${STRATA_REPO%.git}.git" ;; esac   # owner/repo short form
if [ -n "$STRATA_STORE" ]; then
    mkdir -p "$STRATA_STORE/data" "$STRATA_STORE/logs"
    export XDG_CONFIG_HOME="$STRATA_STORE/xdg"; mkdir -p "$XDG_CONFIG_HOME"   # Strata's settings.json (incl. calibrations) persists
else
    echo "start.sh: no volume found (/runpod-volume, /workspace): nothing is stored, the setup is repeated after every pod restart"
fi
mkdir -p "$STRATA_LOCAL" "$STRATA_DATA"
[ -n "$STRATA_STORE" ] && [ -x /opt/runpod/volume-check.sh ] && /opt/runpod/volume-check.sh "$STRATA_STORE" || true   # warns when the volume reads slower than VOLUME_MIN_MBPS (500)

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

# Strata decides about the low-RAM mode from the host's RAM, not the pod's limit: say so when the limit is clearly too small for the experts
case "$MODEL" in Q2_0) ARENA=34 ;; IQ2_XS) ARENA=36 ;; IQ3_XXS) ARENA=43 ;; IQ3_S) ARENA=51 ;; IQ1_M) ARENA=24 ;; *) ARENA=0 ;; esac
if [ "$FAMILY" != unsloth ] && [ "$ARENA" -gt 0 ] && { [ -z "${LOW_RAM:-}" ] || [ "$LOW_RAM" = auto ] || [ "$LOW_RAM" = off ]; }; then
    POD_GIB=$(mem_gib)
    if [ "$POD_GIB" -lt $((ARENA + 12)) ]; then
        echo "start.sh: WARNING: the pod's RAM limit is ${POD_GIB} GiB, $MODEL keeps about $ARENA GiB of experts in RAM plus ~12 GiB for the rest. Strata reads the host's RAM and will not notice: set LOW_RAM=resident (or mmap), or pick a smaller MODEL." >&2
    fi
fi
case "$FAMILY" in qwen) prefix="" ;; *) prefix="${FAMILY}-" ;; esac
TAG="${prefix}$(printf '%s' "$MODEL" | tr 'A-Z' 'a-z')"; export TAG
echo "start.sh: MODE=$MODE FAMILY=$FAMILY MODEL=$MODEL CONTEXT=$CONTEXT LOW_RAM=${LOW_RAM:-(Strata decides)} COPY_DATA_LOCAL=$COPY_DATA_LOCAL STORE=${STRATA_STORE:--} DATA=$STRATA_DATA"

[ -x /opt/runpod/sshd.sh ] && /opt/runpod/sshd.sh

# AI_SETUP.md rule: never expose Strata without an API key (the Runpod proxy makes port 8080 reachable from the internet).
# The key is recorded in the model's config on the first start (REINSTALL=1 changes it later), so it is not generated here.
# Without a key only sshd runs, so you can still log in and debug.
API_KEY="${STRATA_API_KEY:-${API_KEY:-}}"; export API_KEY      # Strata's entrypoint and the queue handler read API_KEY
if [ -z "${API_KEY:-}" ] && [ "${ALLOW_NO_API_KEY:-0}" != 1 ]; then
    echo "start.sh: STRATA_API_KEY (or API_KEY) is not set. Strata is NOT started (set it, or ALLOW_NO_API_KEY=1 for a test without exposure)." >&2
    exec sleep infinity
fi
fail_alive() { echo "start.sh: $*" >&2; exec sleep infinity; }   # keeps the pod (and sshd) up so you can look around

# ---- 1. the engine: key, restore from the volume or clone ------------------------------------------------------------------
gpu_arch() { nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | tr -d '. ' | sort -u | paste -sd+ -; }
cpu_isa()  { grep -m1 '^flags' /proc/cpuinfo | tr ' ' '\n' | grep -E '^(avx|avx2|fma|f16c|bmi1|bmi2|avx512.*|avx_vnni|amx.*)$' | sort | tr '\n' ' ' | sha1sum | cut -c1-8; }
ARCH=$(gpu_arch); ARCH="${ARCH:-nogpu}"; ISA=$(cpu_isa)
# Which Strata: STRATA_REF = latest (default: the newest release tag v*), a tag (v0.1.43.1), a branch, or HEAD. The key carries the tag
# (stable, readable); for a branch or HEAD it carries branch-<commit>, because those move.
REF="${STRATA_REF:-latest}"
if [ "$REF" = latest ]; then
    REF=$(git ls-remote --tags --refs --sort=-v:refname "$STRATA_REPO" 'v*' 2>/dev/null | head -1 | sed 's#.*refs/tags/##')
    if [ -z "$REF" ]; then REF=HEAD; LATEST_FAILED=1; fi
fi
SHA=$(git ls-remote "$STRATA_REPO" "$REF" 2>/dev/null | awk 'NR==1 {print substr($1, 1, 12)}')
LABEL=""
if [ -n "$SHA" ]; then
    if git ls-remote --tags --refs "$STRATA_REPO" "refs/tags/$REF" 2>/dev/null | grep -q .; then LABEL="$REF"
    else LABEL="$(printf '%s' "$REF" | tr 'A-Z/' 'a-z-')-$SHA"; fi
elif [ -n "$STRATA_STORE" ]; then   # GitHub not reachable: take the newest archive for this GPU and CPU
    last=$(ls -t "$STRATA_STORE"/app-sm"$ARCH"-"$ISA"-*.tar.zst 2>/dev/null | head -1)
    [ -n "$last" ] && LABEL=$(basename "$last" .tar.zst | sed "s/^app-sm$ARCH-$ISA-//") && echo "start.sh: GitHub not reachable, using the newest archive ($LABEL)"
fi
[ -n "${LATEST_FAILED:-}" ] && echo "start.sh: no release tag found, using HEAD" >&2
CLONE_REF=""; [ "$REF" != HEAD ] && CLONE_REF="$REF"
export ARCH ISA SHA LABEL KEY="sm${ARCH}-${ISA}-${LABEL:-unknown}"
ARCHIVE="${STRATA_STORE:+$STRATA_STORE/app-$KEY.tar.zst}"   # zstd: the Strata folder is thousands of small files
echo "start.sh: engine key $KEY"

# Runs a command in the background and prints progress every 10 s: copied size (growth of <dest>), share of <total bytes> when known, speed, ETA.
# progress_run <label> <dest dir> <total bytes or 0> <command...>   (returns the command's exit code)
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

# ready = the Python environment and the engine are there AND they belong to this key (GPU architecture, CPU, Strata commit)
app_ready() { [ -f "$STRATA_HOME/.venv/.strata-bootstrap-done" ] && [ -f "$STRATA_HOME/engine/BUILD.json" ] && [ -f "$STRATA_HOME/engine/strata" ] && [ "$(cat "$STRATA_HOME/.strata-key" 2>/dev/null)" = "$KEY" ]; }
if ! app_ready; then
    if [ -n "$ARCHIVE" ] && [ -f "$ARCHIVE" ]; then
        echo "start.sh: restoring the engine from $ARCHIVE"
        rm -rf "${STRATA_HOME:?}"
        TOTAL=$(jq -r '.bytes // 0' "${ARCHIVE%.tar.zst}.json" 2>/dev/null); TOTAL=${TOTAL:-0}
        progress_run "restoring the engine" "$STRATA_HOME" "$TOTAL" tar -I zstd -xf "$ARCHIVE" -C "$STRATA_LOCAL"
    fi
fi
if ! app_ready; then   # no archive for this key: clone and prepare the Python environment; setup.py builds the engine below
    if [ -f "$STRATA_HOME/.strata-key" ] && [ "$(cat "$STRATA_HOME/.strata-key")" != "$KEY" ]; then
        echo "start.sh: the local Strata ($(cat "$STRATA_HOME/.strata-key")) is not the one for key $KEY: setting it up again"
        rm -rf "${STRATA_HOME:?}"
    fi
    if [ ! -d "$STRATA_HOME/.git" ]; then
        echo "start.sh: cloning $STRATA_REPO (${CLONE_REF:-HEAD}) into $STRATA_HOME"
        rm -rf "${STRATA_HOME:?}.tmp"
        git clone --depth 1 ${CLONE_REF:+--branch "$CLONE_REF"} "$STRATA_REPO" "$STRATA_HOME.tmp"
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
    echo "$KEY" > "$STRATA_HOME/.strata-key"
fi
if [ -f "$STRATA_HOME/engine/BUILD.json" ] && [ ! -f "$STRATA_HOME/engine/strata" ]; then   # stamp without binary (broken archive/copy): without this Strata's setup would call the engine done
    echo "start.sh: WARNING: engine/BUILD.json exists but engine/strata is missing: removing the stamp so the setup builds the engine again" >&2
    rm -f "$STRATA_HOME/engine/BUILD.json"
fi
chmod +x "$STRATA_HOME/setup.sh" "$STRATA_HOME/docker-entrypoint.sh"
export STRATA_VERSION=$(sed -n 's/^project(strata VERSION \([0-9.]*\).*/\1/p' "$STRATA_HOME/CMakeLists.txt" 2>/dev/null | head -1)
echo "start.sh: Strata ${STRATA_VERSION:-?} (${LABEL:-unknown}, commit ${SHA:-unknown})"
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
# GiB on the local disk when nothing is on the volume yet: models + mtp + pack + Strata. IQ2_XS measured (64 + 6.9 + 1.5 + 0.7 = 73 GiB,
# no experts.bin in that run), the others scaled from Strata's download sizes. EXTRA: experts.bin, which a setup in the low-RAM mode may add.
case "$MODEL" in
    Q2_0) NEED=72; EXTRA=32 ;;      IQ2_XS) NEED=73; EXTRA=33 ;;    IQ3_XXS) NEED=81; EXTRA=40 ;;  IQ3_S) NEED=88; EXTRA=47 ;;
    IQ1_M) NEED=64; EXTRA=22 ;;     UD-IQ4_XS) NEED=97; EXTRA=0 ;;  UD-Q4_K_XL) NEED=113; EXTRA=0 ;; *) NEED=100; EXTRA=40 ;;
esac
avail_gib() { df -BG --output=avail "$1" | tail -1 | tr -dc 0-9; }
if [ "$COPY_DATA_LOCAL" = yes ]; then
    if [ ! -f "$STRATA_DATA/.local-complete" ] && [ -n "$STRATA_STORE" ] && [ -f "$STRATA_STORE/data/.complete" ]; then
        SRC_BYTES=$(du -sb "$STRATA_STORE/data" --exclude=logs | cut -f1)
        have=$(( SRC_BYTES / 1073741824 + 10 ))
        [ "$(avail_gib "$STRATA_DATA")" -ge "$have" ] || fail_alive "the container disk is too small: $have GiB needed under $STRATA_DATA, $(avail_gib "$STRATA_DATA") GiB free. Raise the container disk or set COPY_DATA_LOCAL=no."
        echo "start.sh: copying the model data from $STRATA_STORE/data to $STRATA_DATA ($have GiB)"
        progress_run "copying the model data" "$STRATA_DATA" "$SRC_BYTES" rsync -a --partial --exclude=logs --exclude=.complete "$STRATA_STORE/data/" "$STRATA_DATA/"
        touch "$STRATA_DATA/.local-complete"
    elif [ ! -f "$STRATA_DATA/.local-complete" ]; then
        [ "$(avail_gib "$STRATA_DATA")" -ge "$((NEED + 5))" ] || echo "start.sh: WARNING: $(avail_gib "$STRATA_DATA") GiB free under $STRATA_DATA, $MODEL needs about $NEED GiB (+$EXTRA GiB if the setup writes experts.bin): raise the container disk or set COPY_DATA_LOCAL=no" >&2
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

# Data and config written by another Strata version: let Strata's setup adapt them (REINSTALL=1 re-runs the setup with --yes; files
# already on disk are found, not downloaded again). config/.built-with holds the Strata commit that wrote the config (the commit, not the tag: a tag and HEAD can be the same code) (post-setup.sh).
# No engine binary but a config (copied from the volume, written by another pod): Strata's entrypoint skips the setup when the config exists,
# so nothing would build the engine ("refers to missing files: .../engine/strata"). REINSTALL=1 runs the setup, which builds the engine.
if [ ! -f "$STRATA_HOME/engine/strata" ] && [ -f "$STRATA_DATA/config/strata-$TAG.json" ] && [ "${REINSTALL:-0}" != 1 ]; then
    export REINSTALL=1
    echo "start.sh: no engine binary in $STRATA_HOME/engine yet: REINSTALL=1 for this start so the setup builds it (3-4 minutes; the model files already present are kept)"
fi
# Calibration is per hardware and Strata keeps it itself (settings.json: one entry per hardware key, on the volume), applying the entry for this
# hardware when its setup writes a config. So when the config was set up on other hardware (config/.hw-key written by post-setup.sh differs from
# Strata's key now), or carries calibrated values of unknown hardware (no .hw-key), the setup runs again once: REINSTALL=1, the model files are kept.
CFGJ="$STRATA_DATA/config/strata-$TAG.json"
if [ -f "$CFGJ" ] && [ "${REINSTALL:-0}" != 1 ]; then
    HWK=$(strata_hwkey "$CFGJ"); MARK="$STRATA_DATA/config/.hw-key"; WHY=""
    if [ -n "$HWK" ]; then
        if [ -f "$MARK" ]; then
            [ "$(cat "$MARK")" = "$HWK" ] || WHY="the config was set up on other hardware ($(cat "$MARK"))"
        elif jq -e '.args | (index("--pcie-frac") or index("--spec-min-p"))' "$CFGJ" >/dev/null 2>&1; then
            WHY="the config carries calibrated values of unknown hardware"
        fi
    fi
    if [ -n "$WHY" ]; then
        export REINSTALL=1
        echo "start.sh: $WHY, this is $HWK: RECALIBRATE for this start (Strata's setup runs again with REINSTALL=1, keeps the model files and applies the calibration saved for this hardware, else its defaults)"
    fi
fi
BUILT_WITH="$STRATA_DATA/config/.built-with"
if [ -f "$BUILT_WITH" ] && [ -f "$STRATA_DATA/config/strata-$TAG.json" ] && [ -n "${SHA:-}" ] && [ "$(cat "$BUILT_WITH")" != "$SHA" ] && [ "${REINSTALL:-0}" != 1 ]; then
    export REINSTALL=1
    echo "start.sh: the config was written by Strata commit $(cat "$BUILT_WITH"), this is ${LABEL:-$SHA} (commit $SHA): REINSTALL=1 for this start (your own edits of the config's args are lost, calibration and pool workers are applied again)"
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
# Strata listens on 127.0.0.1 behind the load-balancer proxy (lb). In queue mode Runpod's proxy URL of the worker (https://<id>-8080.proxy.runpod.net,
# see /api_direct) must reach Strata's port, so it listens on all interfaces; the API key (required above) protects it. STRATA_HOST overrides.
if [ "$MODE" = lb ]; then SHOST="${STRATA_HOST:-127.0.0.1}"; else SHOST="${STRATA_HOST:-0.0.0.0}"; fi
( PORT=8080 HOST="$SHOST" /opt/strata/docker-entrypoint.sh ) &
SP=$!
trap 'kill -TERM $SP 2>/dev/null; wait $SP' TERM INT
if [ "$MODE" = lb ]; then
  /opt/strata/.venv/bin/python /opt/runpod/proxy.py &
else
  /opt/strata/.venv/bin/python -u /opt/runpod/handler.py &
fi
wait $!
kill -TERM $SP 2>/dev/null; wait $SP
