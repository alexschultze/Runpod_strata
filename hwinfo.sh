#!/bin/bash
# Hardware facts of this instance, sourced by start.sh, post-setup.sh and scripts/calibrate.sh.
#   hw_detect   sets GPU_NAME GPU_COUNT GPU_VRAM_GIB GPU_CC DRIVER CPU_MODEL HOST_CORES CPU_QUOTA HOST_RAM_GIB POD_RAM_GIB
#   hw_banner   prints them (the first lines of every start, to recognise the instance at a glance)
#   strata_hwkey <config>   Strata's hardware key for a config; has_calibration <key>: settings.json has an entry for it

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
    echo "start.sh: disk    $(df -BG --output=avail "${STRATA_LOCAL:-/tmp}" 2>/dev/null | tail -1 | tr -dc 0-9) GiB free under ${STRATA_LOCAL:-/tmp}"
    echo "start.sh: ------------------------"
}

# Strata's own key of what a calibration is valid for (setup.py hardware_key: GPU, VRAM, CPU, RAM, model, context, images) for a config file
strata_hwkey() {
    local home="${STRATA_HOME:-/opt/strata}"
    ( cd "$home" && "$home/.venv/bin/python" -c 'import json,sys,setup; print(setup.hardware_key(json.load(open(sys.argv[1], encoding="utf-8-sig"))))' "$1" ) 2>/dev/null
}

# Strata's settings.json (calibrations per hardware key; on the volume through XDG_CONFIG_HOME) has an entry for this key
has_calibration() {
    jq -e --arg k "$1" '.calibration[$k]' "${XDG_CONFIG_HOME:-$HOME/.config}/strata/settings.json" >/dev/null 2>&1
}
