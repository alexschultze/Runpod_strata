#!/bin/bash
# Runs the benchmark (bench/bench.py: TTFT and decode tokens/s) against the Strata server inside this pod.
# Waits for http://127.0.0.1:$PORT/health first (the port opens after the model has loaded).
# Uses STRATA_API_KEY (or API_KEY) from the environment. Model name for the request: $BENCH_MODEL (default "default").
# Extra arguments go to bench.py, e.g. --n 5 --max-tokens 512.
# Usage: /app/scripts/bench-local.sh [bench.py options]
PORT="${PORT:-8080}"
URL="http://127.0.0.1:$PORT"
for i in $(seq 1 120); do
    curl -fs "$URL/health" >/dev/null && break
    [ "$i" = 1 ] && echo "waiting for $URL/health (model loading) ..."
    sleep 5
done
curl -fs "$URL/health" >/dev/null || { echo "Strata did not answer on $URL/health after 10 minutes" >&2; exit 1; }
exec /opt/strata/.venv/bin/python /app/bench/bench.py --url "$URL" --key "${STRATA_API_KEY:-${API_KEY:-}}" --model "${BENCH_MODEL:-default}" "$@"
