#!/bin/bash
# Pulls the current scripts from the git repo over the ones baked into the image, so script changes need no image build.
# Opt-in: only runs when SCRIPTS_REF is set (branch, tag or commit). Called by entry.sh; usable by hand: SCRIPTS_REF=main /opt/runpod/update-scripts.sh
#   SCRIPTS_REF    branch/tag to use (unset = keep the scripts of the image). The repo is public: no credentials are used.
#   SCRIPTS_REPO   owner/repo or git URL (default alexschultze/Runpod_strata)
# Replaced: /opt/runpod/{start,sshd,sync,volume-check,hwinfo}.sh, /opt/runpod/{proxy,handler}.py, /app/scripts, /app/bench.
# Not replaced: entry.sh (the bootstrap), the Dockerfile's packages and the nvidia-smi shim (those need an image build).
# On any failure the image's own scripts stay in place.
[ -n "${SCRIPTS_REF:-}" ] || exit 0
RP="${RUNPOD_DIR:-/opt/runpod}"; APP="${APP_DIR:-/app}"
REPO="${SCRIPTS_REPO:-alexschultze/Runpod_strata}"
case "$REPO" in *://*|git@*|/*) ;; *) REPO="https://github.com/${REPO%.git}.git" ;; esac
echo "update-scripts: SCRIPTS_REF=$SCRIPTS_REF is set: fetching the scripts from $REPO (no retries, the start does not wait)"
W=$(mktemp -d) || exit 0; trap 'rm -rf "${W:?}"' EXIT
mkdir -p "$W/r"
case "$REPO" in
    https://github.com/*)   # GitHub: a tarball of the ref (git is not in the image)
        SLUG="${REPO#https://github.com/}"; SLUG="${SLUG%.git}"
        if ! { curl -fsSL --connect-timeout 5 --max-time 30 "https://codeload.github.com/$SLUG/tar.gz/$SCRIPTS_REF" -o "$W/r.tgz" 2>"$W/err" && tar -xzf "$W/r.tgz" -C "$W/r" --strip-components=1 2>>"$W/err"; }; then
            echo "update-scripts: FAILED, could not fetch $SLUG @ $SCRIPTS_REF ($(tail -1 "$W/err")): the scripts of the image are used"; exit 0
        fi ;;
    *)
        if ! { command -v git >/dev/null && git clone -q --depth 1 --branch "$SCRIPTS_REF" "$REPO" "$W/g" 2>"$W/err" && mv "$W/g/"* "$W/g/".[!.]* "$W/r/" 2>/dev/null; }; then
            echo "update-scripts: FAILED, could not fetch $REPO @ $SCRIPTS_REF ($(tail -1 "$W/err" 2>/dev/null)): the scripts of the image are used"; exit 0
        fi ;;
esac
R="$W/r"; N=0
for f in start.sh sshd.sh sync.sh volume-check.sh hwinfo.sh; do [ -f "$R/$f" ] && install -m 0755 "$R/$f" "$RP/$f" && N=$((N + 1)); done
for f in proxy.py handler.py; do [ -f "$R/serverless/$f" ] && install -m 0644 "$R/serverless/$f" "$RP/$f" && N=$((N + 1)); done
[ -d "$R/scripts" ] && mkdir -p "$APP/scripts" && cp -rf "$R/scripts/." "$APP/scripts/" && chmod +x "$APP"/scripts/*.sh 2>/dev/null
[ -d "$R/strata/bench" ] && mkdir -p "$APP/bench" && cp -rf "$R/strata/bench/." "$APP/bench/"
echo "update-scripts: OK, $REPO @ $SCRIPTS_REF : $N files in $RP, scripts and bench in $APP"
if [ -f "$R/entry.sh" ] && ! cmp -s "$R/entry.sh" "$RP/entry.sh"; then echo "update-scripts: note: entry.sh differs from the image's (not replaced; a new image is needed for it)"; fi
exit 0
