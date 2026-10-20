#!/bin/bash
# N concurrent streams against the Strata server in this pod (bench/bench_parallel.py): tok/s per stream and in total, TTFT.
# Compare STRATA_PARALLEL (batch slots) and engine arguments: restart with one setting, run this, note the table.
# Reads STRATA_API_KEY (or API_KEY). Extra arguments go to bench_parallel.py.
# Usage: /app/scripts/bench-parallel.sh [--streams 1,2,3] [--rounds 2] [--max-tokens 256]
PORT="${PORT:-8080}"
URL="http://127.0.0.1:$PORT"
for i in $(seq 1 120); do curl -fs "$URL/health" >/dev/null && break; [ "$i" = 1 ] && echo "waiting for $URL/health ..."; sleep 5; done
curl -fs "$URL/health" >/dev/null || { echo "Strata did not answer on $URL/health after 10 minutes" >&2; exit 1; }
echo "preset: ${PRESET:-?}   (settings of this server: docker exec / strata launch --list-presets)"
exec /opt/runpod/venv/bin/python /app/bench/bench_parallel.py --url "$URL" --key "${STRATA_API_KEY:-${API_KEY:-}}" --model "${BENCH_MODEL:-default}" "$@"
