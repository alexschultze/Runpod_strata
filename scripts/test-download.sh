#!/bin/bash
# Download speed from the internet (for the ~70 GB model download). Reads the first N MiB of a public file
# from Hugging Face and discards it, so nothing is stored. URL tested (override with $1):
#   https://huggingface.co/bert-base-uncased/resolve/main/model.safetensors
# Usage: scripts/test-download.sh [url] [mib=512]
URL="${1:-https://huggingface.co/bert-base-uncased/resolve/main/model.safetensors}"
MIB="${2:-512}"
echo "URL: $URL  (first $MIB MiB)"
curl -sSL -r "0-$((MIB * 1048576 - 1))" -o /dev/null \
    -w 'downloaded %{size_download} bytes in %{time_total}s = %{speed_download} B/s (HTTP %{http_code})\n' "$URL" \
    | awk '{print; for(i=1;i<=NF;i++) if($i=="=") printf "-> %.0f MiB/s\n", $(i+1)/1048576}'
