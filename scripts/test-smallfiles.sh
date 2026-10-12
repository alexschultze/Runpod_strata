#!/bin/bash
# Small-file / metadata speed of a directory, next to a local reference (git checkout, pip install, venv creation live on this).
# Needs only bash and coreutils. Paths tested (override with arguments): /workspace and the local reference /tmp.
# Usage: scripts/test-smallfiles.sh [dir=/workspace] [files=1000] [reference_dir=/tmp]
#   GIT=1 scripts/test-smallfiles.sh ...   additionally times a shallow `git clone` of Strata and `git status` in both
DIR="${1:-/workspace}"; N="${2:-1000}"; REF="${3:-/tmp}"
bench() {   # prints "name seconds" lines for one directory
    local d="$1/.smallfiles.$$" i t0 x
    mkdir -p "$d" 2>/dev/null && [ -w "$d" ] || { echo "SKIP $1 not writable" >&2; return 1; }
    ph() { local t1=$EPOCHREALTIME; echo "$1 $(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f", b-a}')"; }
    t0=$EPOCHREALTIME; mkdir "$d"/dir{1..1000} 2>/dev/null;               ph "mkdir 1000 dirs (1 call)"
    t0=$EPOCHREALTIME; for ((i=1;i<=N;i++)); do printf '%4096s' x > "$d/f$i"; done; ph "create $N files x 4 KiB"
    t0=$EPOCHREALTIME; sync -f "$d" 2>/dev/null || sync;                   ph "flush (sync)"
    t0=$EPOCHREALTIME; stat -c %s "$d"/f* > /dev/null;                     ph "stat $N files (1 call)"
    t0=$EPOCHREALTIME; for ((i=1;i<=N;i++)); do read -r -N 4096 x < "$d/f$i"; done; ph "read $N files"
    t0=$EPOCHREALTIME; for ((i=1;i<=N;i++)); do mv "$d/f$i" "$d/g$i"; done; ph "rename $N files (mv per file)"
    t0=$EPOCHREALTIME; rm -rf "$d";                                        ph "delete all (1 call)"
    if [ "${GIT:-0}" = 1 ] && command -v git >/dev/null; then
        mkdir -p "$1/.gitbench.$$"
        t0=$EPOCHREALTIME; git clone -q --depth 1 https://github.com/Niko1221/Strata.git "$1/.gitbench.$$/s" 2>/dev/null; ph "git clone --depth 1 Strata"
        t0=$EPOCHREALTIME; git -C "$1/.gitbench.$$/s" status -s > /dev/null 2>&1; ph "git status (stat of the tree)"
        rm -rf "$1/.gitbench.$$"
    fi
}
echo "dir:       $DIR   ($(findmnt -no FSTYPE,SOURCE -T "$DIR" 2>/dev/null | head -1 | cut -c1-70))"
echo "reference: $REF   ($(findmnt -no FSTYPE,SOURCE -T "$REF" 2>/dev/null | head -1 | cut -c1-70))"
echo "files: $N (create/read/rename are per-file shell operations; compare the two columns, not the absolute numbers)"
A=$(bench "$DIR") || exit 1
B=$(bench "$REF")
printf '\n%-34s %12s %12s %8s\n' test "$DIR [s]" "$REF [s]" slower
paste -d'|' <(echo "$A") <(echo "$B") | awk -F'|' '{
    split($1, a, " "); split($2, b, " "); n = split($1, ta, " "); sa = ta[n]; m = split($2, tb, " "); sb = tb[m];
    name = $1; sub(" [0-9.]+$", "", name);
    printf "%-34s %12.2f %12.2f %7.1fx\n", name, sa, sb, (sb > 0.0005 ? sa / sb : 0) }'
