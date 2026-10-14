#!/bin/bash
# Speed of NETWORK / volume storage. Paths tested (override with arguments):
#   /workspace        pod volume, or the network volume when one is attached to a Pod (default mount)
#   /data             Strata default data dir (volume mount of the pod created by strata/runpod_ctl.py)
#   /runpod-volume    network volume as mounted for Serverless workers (skipped when absent)
# Each path is classified by its filesystem type; nfs/cifs/ceph/fuse/... = network, ext4/xfs/overlay = local.
# Usage: scripts/test-network-storage.sh [dir ...] [size_gib=4] [runtime_s=15]   (numbers and directories may come in any order:
#        the first number is the size, the second the runtime, everything else is a directory)
cd "$(dirname "$0")" || exit 1
SIZE=4; RUNTIME=15; DIRS=(); NUMS=0
for a in "$@"; do
    if [[ "$a" =~ ^[0-9]+$ ]]; then
        NUMS=$((NUMS + 1)); [ "$NUMS" -eq 1 ] && SIZE=$a; [ "$NUMS" -eq 2 ] && RUNTIME=$a
    else DIRS+=("$a"); fi
done
[ ${#DIRS[@]} -gt 0 ] || DIRS=(/workspace /data /runpod-volume)
echo "Testing volume paths: ${DIRS[*]}"; echo
for d in "${DIRS[@]}"; do
    [ -d "$d" ] || { echo "SKIP $d: does not exist"; echo; continue; }
    fs=$(findmnt -no FSTYPE -T "$d" | head -1)
    case "$fs" in
        nfs*|cifs|smb*|ceph|glusterfs|fuse*|lustre|9p|virtiofs) echo "$d is network/shared storage ($fs)" ;;
        *) echo "$d is local storage ($fs), not a network volume" ;;
    esac
    ./storage-bench.sh "$d" "$SIZE" "$RUNTIME"
done
