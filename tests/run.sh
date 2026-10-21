#!/bin/bash
# Tests of start.sh and sync.sh against a fake Strata entrypoint and engine tool (no GPU, no image, no download). No root needed: DATA_DIR,
# STRATA_STORE, STRATA_ENTRYPOINT and STRATA_BIN point into a temporary folder. Run: bash tests/run.sh
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
FAILS=0
ok()  { echo "  ok:   $1"; }
bad() { echo "  FAIL: $1"; FAILS=$((FAILS + 1)); }
has() { printf '%s' "$OUT" | grep -qE -- "$1"; }          # the last run's output matches
expect()   { if has "$2"; then ok "$1"; else bad "$1 (no match for: $2)"; printf '%s\n' "$OUT" | tail -15 | sed 's/^/        /'; fi; }
expect_no() { if has "$2"; then bad "$1 (unexpected: $2)"; else ok "$1"; fi; }
cleanup() { rm -rf "${T:?}"; }
trap cleanup EXIT

mkdir -p "$T/bin" "$T/store/data/Strata-data/models" "$T/store/data/state"
printf '#!/bin/sh\ncase "$*" in *-L*) echo "GPU 0: Fake";; *query-gpu=name,memory.total*) echo "${FAKE_GPU:-Fake GPU 24G}, 24564 MiB, 8.6, 550.1";; *) echo 8.6;; esac\n' > "$T/bin/nvidia-smi"
# Strata's entrypoint in the image: here it only prints what it was given
cat > "$T/entry-fake.sh" <<'EOS'
#!/bin/sh
echo "FAKE STRATA args=$* API_KEY=${API_KEY-unset} MODEL=$MODEL CONTEXT=$CONTEXT PRESET=${PRESET-} TUNE=${TUNE-unset} RETUNE=${RETUNE-unset} PARALLEL=${PARALLEL-unset} STRATA_SET=${STRATA_SET-unset} LOW_RAM=${LOW_RAM-unset}"
EOS
printf '#!/bin/sh\n[ "$1 $2" = "components engine" ] && echo "engine: cuda, usable: yes, archs: sm_86" || echo other\n' > "$T/bin/strata"
chmod +x "$T/bin/nvidia-smi" "$T/entry-fake.sh" "$T/bin/strata"
echo "weights" > "$T/store/data/Strata-data/models/m.gguf"; echo "secret-key" > "$T/store/data/state/api-key"; echo '{}' > "$T/store/data/state/presets.json"

run() {   # env assignments for this run; the output goes to $OUT. A new DATA_DIR per run unless one is given.
    D=$(mktemp -d "$T/dataXXXX")
    OUT=$(env -u LOW_RAM -u API_KEY -u STRATA_API_KEY -u TUNE -u RETUNE -u PARALLEL -u STRATA_PARALLEL -u STRATA_CALIBRATE -u STRATA_SET -u PRESET -u COPY_DATA_LOCAL -u MODE \
        PATH="$T/bin:$PATH" STRATA_ENTRYPOINT="$T/entry-fake.sh" STRATA_BIN="$T/bin/strata" DATA_DIR="$D" STRATA_STORE="$T/store" SYNC_WAIT=no \
        API_KEY=k1234567890123456 "$@" timeout 120 bash "$HERE/start.sh" 2>&1)
}
settle() { sleep 1; for _ in $(seq 1 60); do pgrep -f "$HERE/sync.sh" >/dev/null || return 0; sleep 0.5; done; }

echo "1. a default start: info blocks, Strata's own settings from ours"
run env; settle
expect    "the info block names GPU and VRAM"     "GPU +1x Fake GPU 24G, 24 GiB VRAM"
expect    "the volume report lists the store"     "---- volume ----"
expect    "the engine of the image is reported"   "engine \(part of the image\)"
expect    "the engine tool's answer is shown"     "usable: yes"
expect    "model and context defaults"            "MODEL=IQ2_XS CONTEXT=32768"
expect    "the key reaches Strata"                "API_KEY=k1234567890123456"
expect    "one preset per kind of card"           "PRESET=docker-fake-gpu-24g-24g"
expect    "no tuning by default"                  "TUNE=unset RETUNE=unset"
OUT=$(env -u API_KEY -u STRATA_API_KEY PATH="$T/bin:$PATH" STRATA_ENTRYPOINT="$T/entry-fake.sh" STRATA_BIN="$T/bin/strata" DATA_DIR="$T/nokey" STRATA_STORE="$T/store" timeout 5 bash "$HERE/start.sh" 2>&1)
expect    "without an API key Strata is not started" "NOT started"

echo "2. our variables mapped to Strata's"
run env TUNE=quick PARALLEL=2 STRATA_SET="prefill=65536"; settle
expect    "calibrate yes: tune quick"             "TUNE=quick RETUNE=unset"
expect    "parallel"                              "PARALLEL=2"
expect    "advanced settings pass through"        "STRATA_SET=prefill=65536"
run env TUNE=quick RETUNE=1; settle
expect    "tune again"                            "TUNE=quick RETUNE=1"
run env STRATA_CALIBRATE=yes STRATA_PARALLEL=2; settle
expect    "the former names are reported"         "STRATA_CALIBRATE no longer exists: use TUNE"
run env PRESET=mine LOW_RAM=on; settle
expect    "an own preset name wins"               "PRESET=mine"
expect    "LOW_RAM is said to be ignored"         "LOW_RAM is from the Strata 0.1 image and is ignored"

echo "3. data: the store is copied to the local disk once, the key file stays behind"
run env; settle
LD=$(printf '%s' "$OUT" | sed -n 's/.*DATA=\(.*\)$/\1/p' | head -1)
[ -f "$LD/Strata-data/models/m.gguf" ] && ok "the model files are local" || bad "model not copied to $LD"
[ -f "$LD/state/presets.json" ] && ok "presets and tuning are local" || bad "state not copied"
[ ! -e "$LD/state/api-key" ] && ok "the API key file is not copied" || bad "api-key was copied"
expect    "copy progress logging is on"           "copying the data from"
OUT=$(env PATH="$T/bin:$PATH" STRATA_ENTRYPOINT="$T/entry-fake.sh" STRATA_BIN="$T/bin/strata" DATA_DIR="$LD" STRATA_STORE="$T/store" SYNC_WAIT=no API_KEY=k1234567890123456 timeout 120 bash "$HERE/start.sh" 2>&1)
expect_no "a second start does not copy again"    "copying the data from"

mkdir -p "$T/store/data/home/run"; chmod 755 "$T/store/data/home/run"
run env; settle
LD=$(printf '%s' "$OUT" | sed -n 's/.*DATA=\(.*\)$/\1/p' | head -1)
[ "$(stat -c %a "$LD/home/run")" = 700 ] && ok "directories copied from the volume are owner-only again" || bad "mode of home/run is $(stat -c %a "$LD/home/run")"
rm -r "$T/store/data/home"

echo "4. COPY_DATA_LOCAL=no: the big files stay on the volume"
run env COPY_DATA_LOCAL=no; settle
LD=$(printf '%s' "$OUT" | sed -n 's/.*DATA=\(.*\)$/\1/p' | head -1)
[ -L "$LD/Strata-data" ] && ok "Strata-data is a link to the store" || bad "Strata-data is not a link"
[ -f "$LD/state/presets.json" ] && ok "presets and tuning are still copied locally" || bad "state not copied with COPY_DATA_LOCAL=no"
SD=$(mktemp -d "$T/sdXXXX"); ln -s "$T/store/data/Strata-data" "$SD/Strata-data"; mkdir -p "$SD/state"; echo t > "$SD/state/tuned.json"
DATA_DIR="$SD" STRATA_STORE="$T/store" SYNC_WAIT=no bash "$HERE/sync.sh" > "$T/sync2.out" 2>&1 && [ -f "$T/store/data/state/tuned.json" ] && [ -d "$T/store/data/Strata-data/models" ] && ok "sync with a linked Strata-data succeeds, the store keeps its files" || { bad "sync with link failed"; cat "$T/sync2.out"; }

echo "5. sync.sh: the local data goes back to the store"
mkdir -p "$T/syncdata/Strata-data/models" "$T/syncdata/state"
echo new > "$T/syncdata/Strata-data/models/new.gguf"; echo k > "$T/syncdata/state/api-key"; echo log > "$T/syncdata/state/x.log"
DATA_DIR="$T/syncdata" STRATA_STORE="$T/store" SYNC_WAIT=no bash "$HERE/sync.sh" > "$T/sync.out" 2>&1
[ -f "$T/store/data/Strata-data/models/new.gguf" ] && ok "a new model file reaches the store" || bad "new file missing in the store"
[ "$(cat "$T/store/data/state/api-key")" = "secret-key" ] && ok "the store's key file is untouched" || bad "api-key overwritten"
[ ! -e "$T/store/data/state/x.log" ] && [ -f "$T/store/data/.complete" ] && ok "logs stay out, the store is marked complete" || bad "log copied or no .complete"

echo
[ "$FAILS" = 0 ] && echo "all tests passed" || echo "$FAILS test(s) failed"
exit "$FAILS"
