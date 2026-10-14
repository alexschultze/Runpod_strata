#!/bin/bash
# Quick read-speed check of the volume that holds the store (about 10 s). Warns, never blocks: engine archive and data are read from
# there (a slow volume makes the first copy to /tmp slow). Called by start.sh; usable by hand: /opt/runpod/volume-check.sh [dir]
# VOLUME_CHECK=no switches it off, VOLUME_MIN_MBPS (default 500) is the warning threshold, VOLUME_CHECK_MIB (default 512) the test size.
DIR="${1:-${STRATA_STORE:-}}"
case "${VOLUME_CHECK:-yes}" in [Nn]*|0|[Ff]alse) exit 0 ;; esac
[ -n "$DIR" ] && [ -d "$DIR" ] && [ -w "$DIR" ] || exit 0
command -v fio >/dev/null && command -v jq >/dev/null || { echo "volume-check: fio/jq missing, skipped"; exit 0; }
MIN="${VOLUME_MIN_MBPS:-500}"; MIB="${VOLUME_CHECK_MIB:-512}"; Q=$((MIB / 4))
F=""; trap '[ -n "$F" ] && rm -f "$F"' EXIT
# Best: read a big file that already lies in the store (engine archive, packs, ...): nothing was just written, so no cache holds it.
# A file written moments ago may be served from memory (geesefs keeps it in its own cache although O_DIRECT is accepted) and shows far too high a speed.
BIG=$(find "$DIR" -maxdepth 4 -type f -size +"${MIB}"M ! -name '.speedcheck.*' 2>/dev/null | head -1)
if [ -n "$BIG" ]; then
    SRC="existing file $(basename "$BIG")"; T="$BIG"; WRITTEN=no
else
    F="$DIR/.speedcheck.$$"; T="$F"; WRITTEN=yes; SRC="test file written just now"
    fio --name=w --filename="$F" --size="${MIB}M" --rw=write --bs=1M --iodepth=16 --ioengine=libaio --direct=1 --end_fsync=1 >/dev/null 2>&1 || \
    fio --name=w --filename="$F" --size="${MIB}M" --rw=write --bs=1M --iodepth=16 --ioengine=libaio --end_fsync=1 >/dev/null 2>&1 || { echo "volume-check: write test failed on $DIR, skipped"; exit 0; }
fi
if fio --name=p --filename="${F:-$DIR/.speedcheck.p.$$}" --size=4k --rw=write --direct=1 >/dev/null 2>&1; then IO="--direct=1"; MODE=direct; else IO="--direct=0 --invalidate=1"; MODE=buffered; fi
rm -f "$DIR/.speedcheck.p.$$"
# 4 readers on disjoint quarters of the file (the same blocks read four times would be served from cache)
BW=$(fio --name=r --filename="$T" --readonly --size="${Q}M" --offset_increment="${Q}M" --rw=read --bs=1M --iodepth=16 --numjobs=4 --ioengine=libaio $IO --group_reporting --output-format=json 2>/dev/null | jq -r '.jobs[0].read.bw_bytes // 0 | . / 1048576 | floor')
[ -n "$BW" ] || exit 0
FS=$(findmnt -no FSTYPE -T "$DIR" 2>/dev/null | head -1)
echo "volume-check: $DIR ($FS) sequential read ${BW} MB/s ($SRC, $MODE io, ${MIB} MiB, 4 readers)"
if [ "$BW" -lt "$MIN" ]; then
    echo "volume-check: WARNING read speed ${BW} MB/s is below ${MIN} MB/s: copying the engine/data from this volume will be slow."
    echo "volume-check:   a volume in the pod's own data center is usually faster than a global/shared one; COPY_DATA_LOCAL=no avoids the copy but then reads the model over this volume."
elif [ "$WRITTEN" = yes ] && case "$FS" in fuse*) true ;; *) false ;; esac; then
    echo "volume-check: note: on a FUSE volume a just-written file may be served from the mount's cache, so this value can be too high; it is only trustworthy once the store holds a big file (after the first publish)"
fi
exit 0
