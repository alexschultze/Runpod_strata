#!/bin/bash
# Quick read-speed check of the volume that holds the store (about 10 s). Warns, never blocks: engine archive and data are read from
# there (a slow volume makes the first copy to /tmp slow). Called by start.sh; usable by hand: /opt/runpod/volume-check.sh [dir]
# VOLUME_CHECK=no switches it off, VOLUME_MIN_MBPS (default 500) is the warning threshold, VOLUME_CHECK_MIB (default 512) the test size.
DIR="${1:-${STRATA_STORE:-}}"
case "${VOLUME_CHECK:-yes}" in [Nn]*|0|[Ff]alse) exit 0 ;; esac
[ -n "$DIR" ] && [ -d "$DIR" ] && [ -w "$DIR" ] || exit 0
command -v fio >/dev/null && command -v jq >/dev/null || { echo "volume-check: fio/jq missing, skipped"; exit 0; }
MIN="${VOLUME_MIN_MBPS:-500}"; MIB="${VOLUME_CHECK_MIB:-512}"
F="$DIR/.speedcheck.$$"; trap 'rm -f "$F"' EXIT
if fio --name=p --filename="$F" --size=4k --rw=write --direct=1 >/dev/null 2>&1; then IO="--direct=1"; MODE=direct; else IO="--direct=0 --invalidate=1"; MODE=buffered; fi
fio --name=w --filename="$F" --size="${MIB}M" --rw=write --bs=1M --iodepth=16 --ioengine=libaio $IO --end_fsync=1 >/dev/null 2>&1 || { echo "volume-check: write test failed on $DIR, skipped"; exit 0; }
BW=$(fio --name=r --filename="$F" --size="${MIB}M" --rw=read --bs=1M --iodepth=16 --numjobs=4 --offset_increment=0 --ioengine=libaio $IO --group_reporting --output-format=json 2>/dev/null | jq -r '.jobs[0].read.bw_bytes // 0 | . / 1048576 | floor')
[ -n "$BW" ] || exit 0
FS=$(findmnt -no FSTYPE -T "$DIR" 2>/dev/null | head -1)
echo "volume-check: $DIR ($FS) sequential read ${BW} MB/s ($MODE io, ${MIB} MiB, 4 readers)"
if [ "$BW" -lt "$MIN" ]; then
    echo "volume-check: WARNING read speed ${BW} MB/s is below ${MIN} MB/s: copying the engine/data from this volume will be slow."
    echo "volume-check:   a volume in the pod's own data center is usually faster than a global/shared one; COPY_DATA_LOCAL=no avoids the copy but then reads the model over this volume."
fi
exit 0
