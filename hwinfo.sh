#!/bin/bash
# Hardware facts of this instance, sourced by start.sh.
#   hw_detect   sets GPU_NAME GPU_COUNT GPU_VRAM_GIB GPU_CC DRIVER CPU_MODEL HOST_CORES CPU_QUOTA HOST_RAM_GIB POD_RAM_GIB
#   hw_banner   prints them (the first lines of every start, to recognise the instance at a glance)
#   volume_report   prints what the volume(s) and the store hold (mount, free space, top level, archives, data, calibrations)
#   engine_report   prints what Strata's engine (in the image) says about this machine

hw_slug() { printf '%s' "$1" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9]\+/-/g; s/^-//; s/-$//'; }

hw_mem_gib() {   # the pod's memory limit (cgroup) in GiB, else the host's
    local f v
    for f in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory/memory.limit_in_bytes; do
        v=$(cat "$f" 2>/dev/null) || continue
        case "$v" in ''|*[!0-9]*) continue ;; esac
        [ "$v" -lt 1099511627776 ] && { echo $((v / 1073741824)); return; }
    done
    awk '/MemTotal/ {print int($2 / 1048576)}' /proc/meminfo
}

hw_detect() {
    local q e=0
    case $- in *e*) e=1; set +e ;; esac   # a missing file or tool must not stop the caller (set -e)
    q=$(nvidia-smi --query-gpu=name,memory.total,compute_cap,driver_version --format=csv,noheader 2>/dev/null)
    GPU_COUNT=$(printf '%s\n' "$q" | grep -c .)
    GPU_NAME=$(printf '%s\n' "$q" | head -1 | cut -d, -f1 | sed 's/^ *//; s/ *$//')
    GPU_VRAM_GIB=$(printf '%s\n' "$q" | head -1 | cut -d, -f2 | tr -dc 0-9)
    GPU_VRAM_GIB=$(( (${GPU_VRAM_GIB:-0} + 512) / 1024 ))
    GPU_CC=$(printf '%s\n' "$q" | head -1 | cut -d, -f3 | tr -d ' ')
    DRIVER=$(printf '%s\n' "$q" | head -1 | cut -d, -f4 | tr -d ' ')
    GPU_NAME="${GPU_NAME:-no GPU}"
    CPU_MODEL=$(awk -F: '/model name/ {gsub(/^ +/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null)
    CPU_MODEL="${CPU_MODEL:-unknown CPU}"
    HOST_CORES=$(nproc --all 2>/dev/null || echo ?)
    CPU_QUOTA=$(awk '$1 != "max" && $2 > 0 {printf "%.1f", $1 / $2}' /sys/fs/cgroup/cpu.max 2>/dev/null)
    HOST_RAM_GIB=$(awk '/MemTotal/ {print int($2 / 1048576)}' /proc/meminfo)
    POD_RAM_GIB=$(hw_mem_gib)
    [ "$e" = 1 ] && set -e
    return 0
}

hw_banner() {
    echo "start.sh: ---- this instance ----"
    echo "start.sh: GPU     ${GPU_COUNT}x ${GPU_NAME}, ${GPU_VRAM_GIB} GiB VRAM, compute capability ${GPU_CC:-?}, driver ${DRIVER:-?}"
    echo "start.sh: CPU     ${CPU_MODEL}; host cores ${HOST_CORES}, pod quota ${CPU_QUOTA:-none} cores"
    echo "start.sh: RAM     pod limit ${POD_RAM_GIB} GiB, host ${HOST_RAM_GIB} GiB"
    [ -n "${RUNPOD_POD_ID:-}" ] && echo "start.sh: Runpod  id ${RUNPOD_POD_ID}${RUNPOD_ENDPOINT_ID:+, endpoint ${RUNPOD_ENDPOINT_ID}}${RUNPOD_DC_ID:+, data center ${RUNPOD_DC_ID}}"
    [ -n "${RUNPOD_POD_ID:-}" ] && echo "start.sh: URL     https://${RUNPOD_POD_ID}-${PORT:-8080}.proxy.runpod.net/  (HTTP port ${PORT:-8080} through Runpod's proxy; the API key is the only protection)"
    echo "start.sh: disk    $(df -BG --output=avail "${STRATA_LOCAL:-/tmp}" 2>/dev/null | tail -1 | tr -dc 0-9) GiB free under ${STRATA_LOCAL:-/tmp}"
    echo "start.sh: ------------------------"
}

# The engine that is part of Strata's image (Strata 0.2 ships it ready-made): what `strata components engine` says about it and this card.
# Nothing is compiled or archived on the pod any more.
engine_report() {
    local bin="${STRATA_BIN:-/opt/strata/terminal/bin/strata}" out e=0
    case $- in *e*) e=1; set +e ;; esac
    echo "start.sh: ---- engine (part of the image) ----"
    if [ -x "$bin" ]; then
        out=$(timeout 60 "$bin" components engine 2>&1)
        printf '%s\n' "$out" | head -14 | sed 's/^/start.sh:   /'
    else
        echo "start.sh:   $bin not found (is this image built on Strata's image?)"
    fi
    echo "start.sh: ------------------------------------"
    [ "$e" = 1 ] && set -e
    return 0
}

# What is on the volume: every candidate mount (/workspace on a Pod, /runpod-volume on Serverless) and the store in detail. Listings only
# (no du: that is slow on a network volume), each with a timeout so a hanging mount cannot stall the start.
volume_report() {
    local d store="${STRATA_STORE:-}" f e=0 n s
    case $- in *e*) e=1; set +e ;; esac
    echo "start.sh: ---- volume ----"
    for d in /workspace /runpod-volume; do
        if [ ! -d "$d" ]; then echo "start.sh: $d  not present"; continue; fi
        if grep -qs " $d " /proc/mounts; then s="mounted ($(findmnt -no FSTYPE -T "$d" 2>/dev/null | head -1))"; else s="a directory of the container disk, not a mount"; fi
        n=$(timeout 20 ls -A "$d" 2>/dev/null | wc -l)
        echo "start.sh: $d  $s, $(df -BG --output=avail,size "$d" 2>/dev/null | tail -1 | awk '{gsub("G","",$1); gsub("G","",$2); printf "%s GiB free of %s GiB", $1, $2}'), $n entries: $(timeout 20 ls -A "$d" 2>/dev/null | head -12 | tr '\n' ' ')"
    done
    if [ -z "$store" ]; then echo "start.sh: no store: nothing is kept between starts"
    elif [ ! -d "$store" ]; then echo "start.sh: store $store does not exist yet (the first start creates it)"
    else
        echo "start.sh: store $store:"
        if [ -d "$store/data" ]; then
            echo "start.sh:   data/: $(timeout 20 ls -A "$store/data" 2>/dev/null | tr '\n' ' ')$([ -f "$store/data/.complete" ] && echo '(complete)' || echo '(not marked complete)')"
            [ -d "$store/data/Strata-data" ] && echo "start.sh:   data/Strata-data: $(timeout 20 ls -A "$store/data/Strata-data" 2>/dev/null | tr '\n' ' ')"
            [ -d "$store/data/state" ] && echo "start.sh:   data/state (presets, tuning): $(timeout 20 ls -A "$store/data/state" 2>/dev/null | tr '\n' ' ')"
        else echo "start.sh:   no data/ yet (the first start downloads the model)"; fi
    fi
    echo "start.sh: ------------------"
    [ "$e" = 1 ] && set -e
    return 0
}
