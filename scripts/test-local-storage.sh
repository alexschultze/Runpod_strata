#!/bin/bash
# Speed of LOCAL storage. Paths tested (override with arguments):
#   /tmp/strata-bench   container disk (the pod's "Container Disk", where the image and /tmp live)
#   /dev/shm            RAM disk, only as an upper reference (skipped when too small)
# The pod volume under /workspace is tested by test-network-storage.sh together with the network volume,
# because which one it is depends on what you attached to the pod (the script prints the filesystem).
# Usage: scripts/test-local-storage.sh [dir ...] [size_gib=4] [runtime_s=15]   (numbers and directories in any order: first number = size, second = runtime)
cd "$(dirname "$0")" || exit 1
SIZE=4; RUNTIME=15; DIRS=(); NUMS=0
for a in "$@"; do
    if [[ "$a" =~ ^[0-9]+$ ]]; then
        NUMS=$((NUMS + 1)); [ "$NUMS" -eq 1 ] && SIZE=$a; [ "$NUMS" -eq 2 ] && RUNTIME=$a
    else DIRS+=("$a"); fi
done
[ ${#DIRS[@]} -gt 0 ] || DIRS=(/tmp/strata-bench /dev/shm)
echo "Testing local paths: ${DIRS[*]}"; echo
for d in "${DIRS[@]}"; do ./storage-bench.sh "$d" "$SIZE" "$RUNTIME"; done
