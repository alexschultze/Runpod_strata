#!/bin/bash
# Smoke test of the built image, run INSIDE it by the workflow (docker run --entrypoint bash -v tests/smoke-image.sh:/smoke.sh image /smoke.sh):
# are the entry points of Strata's image that start.sh builds on still there, and are our own files in place? A failing check stops the push.
# For tests of this script itself: SMOKE_ROOT=<fake root> prefixes every path, SMOKE_NO_EXEC=1 skips the checks that run programs.
R="${SMOKE_ROOT:-}"
FAILS=0
ok()  { echo "  ok:   $1"; }
bad() { echo "  FAIL: $1"; echo "::error::smoke test: $1" 2>/dev/null; FAILS=$((FAILS + 1)); }
exe() { [ -x "$R$2" ] && ok "$1 ($2)" || bad "$1 is missing or not executable: $2"; }

echo "Strata's entry points (start.sh and the Dockerfile rely on them)"
exe "Strata's entrypoint"     /opt/strata/entrypoint.sh
exe "Strata's command line"   /opt/strata/terminal/bin/strata
exe "tini (PID 1 of the image)" /usr/bin/tini

echo "the variables start.sh hands to Strata's entrypoint are still read by it"
for v in MODEL FAMILY CONTEXT PARALLEL TUNE RETUNE PRESET API_KEY STRATA_SET PORT; do
    grep -qw "$v" "$R/opt/strata/entrypoint.sh" 2>/dev/null && ok "entrypoint reads $v" || bad "Strata's entrypoint no longer mentions $v: start.sh passes it"
done

echo "our files"
for f in entry start sync sshd hwinfo volume-check update-scripts; do
    exe "$f.sh" "/opt/runpod/$f.sh"
    bash -n "$R/opt/runpod/$f.sh" 2>/dev/null && ok "$f.sh has no syntax error" || bad "$f.sh has a syntax error"
done
[ -f "$R/app/scripts/bench-hw.py" ] && ok "bench-hw.py" || bad "/app/scripts/bench-hw.py is missing"

if [ -z "${SMOKE_NO_EXEC:-}" ]; then
    echo "programs"
    for t in fio jq rsync tmux curl python3 sshd; do command -v "$t" >/dev/null 2>&1 || [ -x "/usr/sbin/$t" ] && ok "$t" || bad "$t is not installed"; done
    /opt/runpod/venv/bin/python -c "import runpod, requests" 2>/dev/null && ok "venv: runpod and requests import" || bad "venv: runpod or requests do not import"
    /opt/strata/terminal/bin/strata launch --help >/dev/null 2>&1 && ok "strata launch --help runs" || bad "strata launch --help fails"
    python3 /app/scripts/bench-hw.py --only ram --seconds 1 2>&1 | grep -q "bench: ram" && ok "bench-hw.py runs" || bad "bench-hw.py does not run"
    echo "for the log: $(/opt/strata/terminal/bin/strata components engine 2>&1 | head -3 | tr '\n' '|')"
fi

echo
[ "$FAILS" = 0 ] && echo "smoke test passed" || { echo "$FAILS check(s) failed"; exit 1; }
