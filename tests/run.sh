#!/bin/bash
# Tests of start.sh, post-setup.sh and publish.sh with a fake Strata (no GPU, no model download).
# Needs root: the scripts use /opt/runpod and /opt/strata, like in the image. Run: sudo bash tests/run.sh
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
FAILS=0
ok()  { echo "  ok:   $1"; }
bad() { echo "  FAIL: $1"; FAILS=$((FAILS + 1)); }
has() { printf '%s' "$OUT" | grep -qE -- "$1"; }          # the last run's output matches
expect()   { if has "$2"; then ok "$1"; else bad "$1 (no match for: $2)"; printf '%s\n' "$OUT" | tail -15 | sed 's/^/        /'; fi; }
expect_no() { if has "$2"; then bad "$1 (unexpected: $2)"; else ok "$1"; fi; }
cleanup() { rm -f /opt/strata /opt/runpod/post-setup.sh /opt/runpod/publish.sh /opt/runpod/sshd.sh /opt/runpod/hwinfo.sh; rm -rf "${T:?}"; }
trap cleanup EXIT

mkdir -p /opt/runpod "$T/bin" "$T/upstream"
cp "$HERE"/post-setup.sh "$HERE"/publish.sh "$HERE"/sshd.sh "$HERE"/hwinfo.sh /opt/runpod/
chmod +x /opt/runpod/*.sh
printf '#!/bin/sh\ncase "$*" in *-L*) echo "GPU 0: Fake";; *query-gpu=name,memory.total*) echo "${FAKE_GPU:-Fake GPU 24G}, 24564 MiB, 8.6, 550.1";; *) echo 8.6;; esac\n' > "$T/bin/nvidia-smi"; chmod +x "$T/bin/nvidia-smi"

# a fake Strata repo with two release tags; its entrypoint has the same hook line as the real one
cd "$T/upstream" || exit 1
git init -q .
cat > docker-entrypoint.sh <<'EOS'
#!/bin/sh
set -e
cd /opt/strata || exit 1
tag="$(printf '%s' "$MODEL" | tr 'A-Z' 'a-z')"
cfg="$STRATA_DATA/config/strata-$tag.json"
mkdir -p "$STRATA_DATA/config"
if [ ! -f "$cfg" ] || [ "${REINSTALL:-0}" = 1 ]; then
  echo "FAKE SETUP reinstall=${REINSTALL:-0}"
  mkdir -p engine "$STRATA_DATA/models" "$STRATA_DATA/packs/$tag" "$STRATA_DATA/mtp"
  echo built > engine/BUILD.json; echo bin > engine/strata
  [ -f "$STRATA_DATA/models/model.gguf" ] || echo bigdata > "$STRATA_DATA/models/model.gguf"
  [ -f "$cfg" ] || { echo '{"args":["--max-context","32768"]}' > "strata-$tag.json"; cp -f "strata-$tag.json" "$cfg"; }
else
  ln -sfn "$cfg" "/opt/strata/strata-$tag.json"
fi
set -- --port "$PORT"
echo "FAKE SERVER LOW_RAM=${LOW_RAM-unset} API_KEY=${API_KEY-unset} args=$(jq -c .args "strata-$tag.json")"
EOS
echo "" > requirements.txt; printf '#!/bin/sh\n' > setup.sh; chmod +x docker-entrypoint.sh setup.sh
printf 'project(strata VERSION 0.1.1 LANGUAGES CXX)\n' > CMakeLists.txt
G="git -c user.email=t@t -c user.name=t"
git add -A && $G commit -qm v1 && git tag v0.1.1
printf 'project(strata VERSION 0.1.2 LANGUAGES CXX)\n' > CMakeLists.txt
$G commit -qam v2 && git tag v0.1.2
cd "$HERE" || exit 1

run() {   # env assignments for this run; the output goes to $OUT
    OUT=$(env -u LOW_RAM -u API_KEY -u STRATA_API_KEY -u PUBLIC_KEY -u SSH_PUBLIC_KEY -u REINSTALL -u COPY_DATA_LOCAL \
        PATH="$T/bin:$PATH" STRATA_STORE="$T/store" STRATA_LOCAL="$T/local" STRATA_REPO="file://$T/upstream" \
        MODEL=IQ2_XS PORT=8080 POOL_WORKERS=6 STRATA_API_KEY=k "$@" timeout 300 bash "$HERE/start.sh" 2>&1)
}
settle() { sleep 1; for _ in $(seq 1 600); do pgrep -f /opt/runpod/publish.sh >/dev/null || return 0; sleep 0.5; done; }   # the background publish (tar + zstd of the Strata folder) is slow on a busy CI runner: wait up to 5 min
fresh_pod() { rm -rf "${T:?}/local"; rm -f /opt/strata; }

echo "1. first start on an empty store: key, setup, archive, data pushed, banner"
run env; settle
expect    "banner names GPU, VRAM and RAM"        "GPU +1x Fake GPU 24G, 24 GiB VRAM"
expect    "key carries the latest tag"            "engine key sm86-[0-9a-f]{8}-v0\.1\.2"
expect    "the setup ran, pool workers written"   'FAKE SETUP reinstall=0'
[ -f "$T"/store/app-sm86-*-v0.1.2.tar.zst ] && ok "engine archive in the store" || bad "engine archive missing"
[ -f "$T/store/data/.complete" ] && ok "data pushed and marked complete" || bad "data not complete"

echo "2. new pod, same store: restore instead of setup"
fresh_pod; run env; settle
expect    "engine restored from the archive"      "restoring the engine from .*\.tar\.zst"
expect    "data copied from the store"            "copying the model data from"
expect_no "no setup this time"                    "FAKE SETUP"

echo "3. COPY_DATA_LOCAL=no: data stay on the volume"
fresh_pod; run env COPY_DATA_LOCAL=no; settle
[ -L "$T/local/Strata-data/models" ] && ok "models is a link into the store" || bad "models is not a link"

echo "4. other Strata version: new Strata, REINSTALL for the existing config"
run env STRATA_REF=v0.1.1; settle
expect    "REINSTALL=1 for the changed version"   "REINSTALL=1 for this start"

echo "5. config from the volume but no engine (no archive for this key): the setup must build it"
fresh_pod; run env; settle; rm -f "$T"/store/app-*.tar.zst "$T"/store/app-*.json; fresh_pod
run env; settle
expect    "REINSTALL=1 when the engine binary is missing" "no engine binary .* REINSTALL=1"

echo "6. without an API key Strata is not started"
OUT=$(env -u API_KEY -u STRATA_API_KEY PATH="$T/bin:$PATH" STRATA_STORE="$T/store" STRATA_LOCAL="$T/local" MODEL=IQ2_XS timeout 5 bash "$HERE/start.sh" 2>&1)
expect    "refused"                               "NOT started"

echo "7. calibration per hardware: never by default; yes calibrates once per hardware and applies the result"
cat > "$T/cal.sh" <<'EOS'
#!/bin/bash
echo ran >> "$CALLOG"
mkdir -p "$(dirname "$TUNED_FILE")"
printf '# fake\n--pcie-frac 0.55 --spec-min-p 0.30\n' > "$TUNED_FILE"
EOS
chmod +x "$T/cal.sh"
CAL="CALIBRATE_SCRIPT=$T/cal.sh CALLOG=$T/cal.log"
calls() { [ -f "$T/cal.log" ] && wc -l < "$T/cal.log" || echo 0; }
fresh_pod; run env $CAL; settle
[ "$(calls)" = 0 ] && ok "default: no calibration" || bad "default calibrated"
fresh_pod; run env $CAL STRATA_CALIBRATE=yes; settle
[ "$(calls)" = 1 ] && ok "yes, no result for this hardware: calibrates" || bad "yes did not calibrate once ($(calls))"
expect    "result applied to the config"          '"--pcie-frac","0.55","--spec-min-p","0.30"'
fresh_pod; run env $CAL STRATA_CALIBRATE=yes; settle
[ "$(calls)" = 1 ] && ok "yes, result exists: applied, not calibrated again" || bad "yes calibrated again"
fresh_pod; run env $CAL STRATA_CALIBRATE=yes FAKE_GPU="Other GPU 32G"; settle
[ "$(calls)" = 2 ] && ok "other GPU: calibrates for itself" || bad "other GPU did not calibrate ($(calls))"
cfgs=$(ls "$T"/local/Strata-data/config/strata-*.json)
for f in $cfgs; do jq '.args=["--pcie-frac","1.00","--pool-workers","9"]' "$f" > "$f.t" && cat "$f.t" > "$f"; rm -f "$f.t"; done
run env $CAL FAKE_GPU="Fake GPU 24G"; settle
expect_no "values calibrated on other hardware are replaced" '"--pool-workers","9"'
for f in $cfgs; do jq '.args=["--pcie-frac","1.00","--pool-workers","9"]' "$f" > "$f.t" && cat "$f.t" > "$f"; rm -f "$f.t"; done
run env $CAL FAKE_GPU="Unknown GPU"; settle
expect_no "no result for this hardware (STRATA_CALIBRATE=no): Strata's defaults, other hardware's values dropped" '"--pcie-frac"'

echo "8. STRATA_PARALLEL: N sets --batch N, 1 removes it"
fresh_pod; run env STRATA_PARALLEL=3; settle
expect    "3: --batch 3 in the args"              '"--batch","3"'
run env STRATA_PARALLEL=1; settle
expect_no "1: --batch gone"                       '"--batch"'

echo
[ "$FAILS" = 0 ] && echo "all tests passed" || echo "$FAILS test(s) failed"
exit "$FAILS"
