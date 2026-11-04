#!/bin/bash
# Hardware facts of this instance, sourced by start.sh.
#   hw_detect   sets GPU_NAME GPU_COUNT GPU_VRAM_GIB GPU_CC DRIVER CPU_MODEL HOST_CORES CPU_QUOTA HOST_RAM_GIB POD_RAM_GIB
#   hw_banner   prints them (the first lines of every start, to recognise the instance at a glance)
#   hw_details  more facts, best effort: platform, CPU (caches, NUMA, instruction sets), memory (DIMMs with dmidecode), limits, GPU link, disks, DNS
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
    [ -n "${RUNPOD_IMAGE_VERSION:-}" ] && echo "start.sh: image   ${RUNPOD_IMAGE_VERSION} (commit ${RUNPOD_IMAGE_COMMIT:0:7}), Strata base ${RUNPOD_IMAGE_BASE:-?} ${RUNPOD_IMAGE_BASE_DIGEST:0:19}"
    [ -n "${RUNPOD_POD_ID:-}" ] && echo "start.sh: Runpod  id ${RUNPOD_POD_ID}${RUNPOD_ENDPOINT_ID:+, endpoint ${RUNPOD_ENDPOINT_ID}}${RUNPOD_DC_ID:+, data center ${RUNPOD_DC_ID}}"
    [ -n "${RUNPOD_POD_ID:-}" ] && echo "start.sh: URL     https://${RUNPOD_POD_ID}-${PORT:-8080}.proxy.runpod.net/  (HTTP port ${PORT:-8080} through Runpod's proxy; the API key is the only protection)"
    echo "start.sh: disk    $(df -BG --output=avail "${STRATA_LOCAL:-/tmp}" 2>/dev/null | tail -1 | tr -dc 0-9) GiB free under ${STRATA_LOCAL:-/tmp}"
    echo "start.sh: ------------------------"
}

# `dmidecode -t memory` on stdin -> "8 of 16 slots populated: 8 x 32 GB DDR4, 3200 MT/s configured (rated 3200), ~205 GB/s peak if every DIMM has its own channel"
hw_dimms() {
    awk -F': *' '
        /^Memory Device/ { n++; next }
        n && /^[ \t]+Size:/ { sz = $2; if (sz ~ /^[0-9]+ MB/) { sub(/ MB.*/, "", sz); sz = sz / 1024 " GB" } if (sz ~ /^[0-9]/) { pop++; cnt[sz]++ } cur = (sz ~ /^[0-9]/) ? 1 : 0; next }
        n && cur && /^[ \t]+Type:/ { type = $2; next }
        n && cur && /^[ \t]+Speed:/ { split($2, a, " "); rated = a[1]; next }
        n && cur && /^[ \t]+Configured (Memory|Clock) Speed:/ { split($2, a, " "); conf = a[1]; next }
        END {
            if (!n) exit 1
            list = ""
            for (k in cnt) list = list (list == "" ? "" : " + ") cnt[k] " x " k
            speed = conf ? conf : rated
            printf "%d of %d slots populated: %s %s", pop, n, list, type
            if (speed) printf ", %s MT/s configured (rated %s)", speed, (rated ? rated : "?")
            if (speed && pop) printf ", ~%d GB/s peak if every DIMM has its own channel", pop * speed * 8 / 1000
            printf "\n"
        }'
}

# More facts about this instance, best effort: a missing file or tool just leaves its line out. Everything is read-only and quick (DNS checks in parallel, 3 s at most).
hw_details() {
    local e=0 L v virt dmi f d src fs dev model rot tmp h res dns avail swap thp hp shm ml shmk out isa
    case $- in *e*) e=1; set +e ;; esac
    echo "start.sh: ---- details ----"
    # platform
    virt=$(systemd-detect-virt 2>/dev/null); { [ -z "$virt" ] || [ "$virt" = none ]; } && virt=$(lscpu 2>/dev/null | awk -F': *' '/Hypervisor vendor/ {print $2}')
    dmi=""; for f in sys_vendor product_name board_name bios_version; do v=$(cat "/sys/class/dmi/id/$f" 2>/dev/null); [ -n "$v" ] && dmi="$dmi$v / "; done
    echo "start.sh: host    kernel $(uname -r), image OS $(grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"')${virt:+, virtualization: $virt}${dmi:+, ${dmi% / }}"
    # cpu
    L=$(lscpu 2>/dev/null)
    lsf() { awk -F': *' -v k="$1" '$1 == k {print $2; exit}' <<<"$L"; }
    isa=$(awk '/^flags/ {for (i = 2; i <= NF; i++) if ($i ~ /^(sse4_2|avx|avx2|fma|avx512f|avx512bw|avx512_vnni|avx512_bf16|amx_tile|amx_bf16)$/) printf "%s ", $i; exit}' /proc/cpuinfo 2>/dev/null)
    echo "start.sh: cpu     $(lsf 'Socket(s)') socket(s) x $(lsf 'Core(s) per socket') cores x $(lsf 'Thread(s) per core') threads$(v=$(lsf 'CPU max MHz' | sed 's/\..*//'); [ -n "$v" ] && echo ", max $v MHz"), L1d $(lsf 'L1d cache'), L2 $(lsf 'L2 cache'), L3 $(lsf 'L3 cache'), NUMA nodes $(lsf 'NUMA node(s)'), load $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null), cpus allowed $(cat /sys/fs/cgroup/cpuset.cpus.effective 2>/dev/null || echo ?)"
    [ -n "$isa" ] && echo "start.sh: cpu     instruction sets: $isa"
    if [ "$(ls -d /sys/devices/system/node/node[0-9]* 2>/dev/null | wc -l)" -gt 1 ]; then
        for d in /sys/devices/system/node/node[0-9]*; do
            echo "start.sh: numa    $(basename "$d"): cpus $(cat "$d/cpulist" 2>/dev/null), $(awk '/MemTotal/ {print int($4 / 1048576)}' "$d/meminfo" 2>/dev/null) GiB"
        done
    fi
    # memory
    avail=$(awk '/MemAvailable/ {print int($2 / 1048576)}' /proc/meminfo); swap=$(awk '/SwapTotal/ {print int($2 / 1048576)}' /proc/meminfo)
    thp=$(sed 's/.*\[\(.*\)\].*/\1/' /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null); hp=$(awk '/HugePages_Total/ {print $2}' /proc/meminfo)
    echo "start.sh: memory  ${avail} GiB available of ${HOST_RAM_GIB:-?} GiB (pod limit ${POD_RAM_GIB:-?}), swap ${swap} GiB, transparent hugepages ${thp:-?}, hugepages ${hp:-0}"
    if command -v dmidecode >/dev/null 2>&1 && out=$(timeout 10 dmidecode -t memory 2>/dev/null) && v=$(hw_dimms <<<"$out") && [ -n "$v" ]; then
        echo "start.sh: memory  DIMMs: $v"
    else
        echo "start.sh: memory  DIMM layout not readable here (needs dmidecode and access to the DMI table)"
    fi
    # limits Strata cares about (docs: --ulimit memlock=-1:-1, --shm-size 2g)
    ml=$(ulimit -l); shm=$(df -BM --output=size /dev/shm 2>/dev/null | tail -1 | tr -dc 0-9)
    echo "start.sh: limits  memlock ${ml}$([ "$ml" != unlimited ] && echo " KiB (Strata recommends unlimited: page-locked memory)"), /dev/shm ${shm:-?} MiB$([ "${shm:-0}" -lt 2000 ] && echo " (Strata recommends 2 GB)"), open files $(ulimit -n), pids max $(cat /sys/fs/cgroup/pids.max 2>/dev/null || echo ?)"
    # gpu
    if command -v nvidia-smi >/dev/null 2>&1; then
        out=$(nvidia-smi --query-gpu=index,name,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max,power.limit,clocks.max.sm,mig.mode.current,ecc.mode.current --format=csv,noheader 2>/dev/null)
        printf '%s\n' "$out" | while IFS=, read -r idx name gn gx wn wx pw clk mig ecc; do
            [ -n "$idx" ] && echo "start.sh: gpu     $idx:${name}, PCIe gen${gn# } x${wn# } now (max gen${gx# } x${wx# }; an idle card lowers the link), power limit${pw}, max SM clock${clk}, MIG${mig}, ECC${ecc}"
        done
        v=$(nvidia-smi 2>/dev/null | grep -o 'CUDA Version: [0-9.]*' | head -1); [ -n "$v" ] && echo "start.sh: gpu     driver $v"
    fi
    # storage: file system, device and kind of the places that matter
    for d in / "${DATA_DIR:-/data}" "${STRATA_STORE:-}"; do
        [ -n "$d" ] && [ -d "$d" ] || continue
        src=$(findmnt -no SOURCE -T "$d" 2>/dev/null | head -1); fs=$(findmnt -no FSTYPE -T "$d" 2>/dev/null | head -1)
        dev=$(lsblk -no PKNAME "$src" 2>/dev/null | head -1); [ -z "$dev" ] && dev=$(basename "$src" 2>/dev/null | sed -E 's/p?[0-9]+$//')
        model=$(cat "/sys/block/$dev/device/model" 2>/dev/null | sed 's/ *$//'); rot=$(cat "/sys/block/$dev/queue/rotational" 2>/dev/null)
        echo "start.sh: disk    $d: ${fs:-?} on ${src:-?}${model:+ ($model)}$([ "$rot" = 0 ] && echo ", SSD/NVMe")$([ "$rot" = 1 ] && echo ", rotational"), $(df -BG --output=size,avail "$d" 2>/dev/null | tail -1 | awk '{gsub("G", "", $1); gsub("G", "", $2); printf "%s GiB, %s GiB free", $1, $2}')"
    done
    # network: the names the start needs (SCRIPTS_REF, the model download, the images), checked in parallel
    tmp=$(mktemp -d 2>/dev/null)
    if [ -n "$tmp" ]; then
        for h in github.com huggingface.co ghcr.io; do ( timeout 3 getent hosts "$h" >/dev/null 2>&1 && echo "$h ok" || echo "$h FAILED" ) > "$tmp/$h" & done
        wait
        res=$(cat "$tmp"/* | tr '\n' ' '); rm -rf "${tmp:?}"
        dns=$(awk '/^nameserver/ {printf "%s ", $2}' /etc/resolv.conf 2>/dev/null)
        echo "start.sh: network DNS servers ${dns:-none}; names: ${res}$(printf '%s' "$res" | grep -q FAILED && echo '(SCRIPTS_REF and the model download need them)')"
    fi
    echo "start.sh: -----------------"
    [ "$e" = 1 ] && set -e
    return 0
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
