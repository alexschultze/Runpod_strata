#!/bin/bash
# Speed of NETWORK / volume storage. Paths tested (override with arguments):
#   /workspace        pod volume, or the network volume when one is attached to a Pod (default mount)
#   /data             Strata default data dir (volume mount of the pod created by strata/runpod_ctl.py)
#   /runpod-volume    network volume as mounted for Serverless workers (skipped when absent)
# Each path is classified by its filesystem type; nfs/cifs/ceph/fuse/... = network, ext4/xfs/overlay = local.
# Usage: scripts/test-network-storage.sh [size_gib=4] [runtime_s=15] [dir ...]
cd "$(dirname "$0")" || exit 1
SIZE="${1:-4}"; RUNTIME="${2:-15}"; shift 2 2>/dev/null
DIRS=("$@"); [ ${#DIRS[@]} -gt 0 ] || DIRS=(/workspace /data /runpod-volume)
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
