#!/bin/bash
# Storage benchmark for one directory (fio). Used by test-local-storage.sh and test-network-storage.sh.
# Usage: scripts/storage-bench.sh <dir> [size_gib=4] [runtime_s=15]
# Tests are chosen for Strata: big sequential reads (model download/copy, pack loading) and
# random reads of 4 KiB / 128 KiB (LOW_RAM mode maps experts from experts.bin on disk).
set -u
DIR="${1:?usage: $0 <dir> [size_gib] [runtime_s]}"
SIZE_GIB="${2:-4}"
RUNTIME="${3:-15}"
command -v fio >/dev/null && command -v jq >/dev/null || { echo "fio and jq are required" >&2; exit 1; }

mkdir -p "$DIR" 2>/dev/null && [ -w "$DIR" ] || { echo "SKIP $DIR: missing or not writable"; exit 2; }
WORK="$DIR/.strata-bench.$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

FREE_GIB=$(df -P -BG "$DIR" | awk 'NR==2 {gsub("G","",$4); print $4}')
[ "$FREE_GIB" -ge $((SIZE_GIB * 2)) ] || { echo "SKIP $DIR: only ${FREE_GIB} GiB free, need $((SIZE_GIB * 2))"; exit 2; }

echo "=== $DIR"
echo "mount:   $(findmnt -no FSTYPE,SOURCE -T "$DIR" | head -1 | tr -s ' ')"
echo "free:    ${FREE_GIB} GiB   test file: ${SIZE_GIB} GiB   runtime per test: ${RUNTIME}s"

# O_DIRECT bypasses the page cache; some network/FUSE filesystems refuse it
if fio --name=probe --filename="$WORK/probe" --size=4k --rw=write --direct=1 >/dev/null 2>&1; then
    IO="--direct=1"; echo "io mode: direct (page cache bypassed)"
else
    IO="--direct=0 --invalidate=1"; echo "io mode: buffered (no O_DIRECT here; reads may be served from cache and look too fast)"
fi
rm -f "$WORK/probe"
case "$(findmnt -no FSTYPE -T "$DIR" | head -1)" in
    fuse*) echo "note:    FUSE volume: a file written moments ago can be served from the mount's own cache (geesefs does so although O_DIRECT is accepted):"
           echo "         read results far above the write speed (and ~1 us random-read latency) are cache hits, not the network. Trust the write speed, or read a big file written long ago (dd if=<file> of=/dev/null bs=1M count=1024 iflag=direct)." ;;
esac

FILE="$WORK/test.bin"
# run <name> <rw> <bs> <iodepth> <numjobs> <direction: read|write> [extra fio args]
run() {
    local name=$1 rw=$2 bs=$3 qd=$4 jobs=$5 dir=$6; shift 6
    local out sz="${SIZE_GIB}G" off=""
    # several readers get disjoint parts of the file: the same blocks read by all of them would be served from cache after the first
    if [ "$jobs" -gt 1 ] && [ "$dir" = read ]; then sz="$((SIZE_GIB * 1024 / jobs))M"; off="--offset_increment=$sz"; fi
    out=$(fio --name="$name" --filename="$FILE" --size="$sz" $off --rw="$rw" --bs="$bs" \
          --iodepth="$qd" --numjobs="$jobs" --ioengine=libaio $IO --runtime="$RUNTIME" --time_based \
          --group_reporting --output-format=json "$@" 2>/dev/null) || { printf '%-34s failed\n' "$name"; return; }
    echo "$out" | jq -r --arg n "$name" --arg d "$dir" '
        .jobs[0][$d] as $j
        | [$n, ($j.bw_bytes/1048576|floor|tostring+" MiB/s"), ($j.iops|floor|tostring+" IOPS"),
           (($j.clat_ns.mean/1000)|floor|tostring+" us avg"),
           (($j.clat_ns.percentile["99.000000"] // 0)/1000|floor|tostring+" us p99")]
        | @tsv' | awk -F'\t' '{printf "%-34s %12s %12s %12s %12s\n", $1,$2,$3,$4,$5}'
}

printf '%-34s %12s %12s %12s %12s\n' test bandwidth iops latency "latency p99"
# 1) create the file with a sequential write (also the write speed)
run "seq write 1M qd16"        write     1M   16 1 write --end_fsync=1 --time_based=0
# 2) read it back
run "seq read 1M qd16 x1"      read      1M   16 1 read
run "seq read 1M qd16 x4"      read      1M   16 4 read
run "rand read 4k qd1 (latency)" randread 4k   1 1 read
run "rand read 4k qd32 x4"     randread  4k   32 4 read
run "rand read 128k qd16 x4"   randread  128k 16 4 read

# 3) metadata: create + read 300 small files (network filesystems are slow here)
S=$(date +%s.%N)
for i in $(seq 1 300); do head -c 4096 /dev/zero > "$WORK/f$i"; done; sync
for i in $(seq 1 300); do cat "$WORK/f$i" > /dev/null; done
E=$(date +%s.%N)
printf '%-34s %12s\n' "300 small files create+read" "$(awk -v s="$S" -v e="$E" 'BEGIN{printf "%.2f s", e-s}')"
echo
