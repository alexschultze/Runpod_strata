#!/bin/bash
# Pulls the current scripts from the git repo over the ones baked into the image, so script changes need no image build.
# Opt-in: only runs when SCRIPTS_REF is set (branch, tag or commit). Called by entry.sh; usable by hand: SCRIPTS_REF=main /opt/runpod/update-scripts.sh
#   SCRIPTS_REF    branch/tag to use (unset = keep the scripts of the image). The repo is public: no credentials are used.
#   SCRIPTS_REPO   owner/repo or git URL (default alexschultze/Runpod_strata)
# Replaced: /opt/runpod/{start,sshd,post-setup,publish,volume-check}.sh, /opt/runpod/{proxy,handler}.py, /app/scripts, /app/bench.
# Not replaced: entry.sh (the bootstrap), the Dockerfile's packages and the nvidia-smi shim (those need an image build).
# On any failure the image's own scripts stay in place.
[ -n "${SCRIPTS_REF:-}" ] || exit 0
RP="${RUNPOD_DIR:-/opt/runpod}"; APP="${APP_DIR:-/app}"
REPO="${SCRIPTS_REPO:-alexschultze/Runpod_strata}"
case "$REPO" in *://*|git@*|/*) ;; *) REPO="https://github.com/${REPO%.git}.git" ;; esac
W=$(mktemp -d) || exit 0; trap 'rm -rf "${W:?}"' EXIT
if ! git clone -q --depth 1 --branch "$SCRIPTS_REF" "$REPO" "$W/r" 2>"$W/err"; then
    # a commit SHA cannot be cloned with --branch: fetch it
    if ! { git init -q "$W/r" && git -C "$W/r" fetch -q --depth 1 "$REPO" "$SCRIPTS_REF" 2>>"$W/err" && git -C "$W/r" checkout -q FETCH_HEAD; }; then
        echo "update-scripts: could not fetch $REPO @ $SCRIPTS_REF ($(tail -1 "$W/err")), keeping the scripts of the image"; exit 0
    fi
fi
R="$W/r"; N=0
for f in start.sh sshd.sh post-setup.sh publish.sh volume-check.sh; do [ -f "$R/$f" ] && install -m 0755 "$R/$f" "$RP/$f" && N=$((N + 1)); done
for f in proxy.py handler.py; do [ -f "$R/serverless/$f" ] && install -m 0644 "$R/serverless/$f" "$RP/$f" && N=$((N + 1)); done
[ -d "$R/scripts" ] && mkdir -p "$APP/scripts" && cp -rf "$R/scripts/." "$APP/scripts/" && chmod +x "$APP"/scripts/*.sh 2>/dev/null
[ -d "$R/strata/bench" ] && mkdir -p "$APP/bench" && cp -rf "$R/strata/bench/." "$APP/bench/"
echo "update-scripts: $REPO @ $SCRIPTS_REF ($(git -C "$R" rev-parse --short HEAD)): $N files in $RP, scripts and bench in $APP"
if [ -f "$R/entry.sh" ] && ! cmp -s "$R/entry.sh" "$RP/entry.sh"; then echo "update-scripts: note: entry.sh differs from the image's (not replaced; a new image is needed for it)"; fi
exit 0
