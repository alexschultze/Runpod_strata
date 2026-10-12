#!/bin/bash
# Speed of LOCAL storage. Paths tested (override with arguments):
#   /tmp/strata-bench   container disk (the pod's "Container Disk", where the image and /tmp live)
#   /dev/shm            RAM disk, only as an upper reference (skipped when too small)
# The pod volume under /workspace is tested by test-network-storage.sh together with the network volume,
# because which one it is depends on what you attached to the pod (the script prints the filesystem).
# Usage: scripts/test-local-storage.sh [size_gib=4] [runtime_s=15] [dir ...]
cd "$(dirname "$0")" || exit 1
SIZE="${1:-4}"; RUNTIME="${2:-15}"; shift 2 2>/dev/null
DIRS=("$@"); [ ${#DIRS[@]} -gt 0 ] || DIRS=(/tmp/strata-bench /dev/shm)
echo "Testing local paths: ${DIRS[*]}"; echo
for d in "${DIRS[@]}"; do ./storage-bench.sh "$d" "$SIZE" "$RUNTIME"; done
