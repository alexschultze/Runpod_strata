#!/bin/bash
# What the pod provides before Strata is installed: driver/CUDA, GPU, RAM (incl. container limit), paths.
# Paths shown: / (container disk), /workspace (pod or network volume), /runpod-volume (serverless network volume), /dev/shm
echo "--- GPU / driver (Strata needs driver >= 580, CUDA >= 13.0) ---"
nvidia-smi --query-gpu=name,driver_version,memory.total,compute_cap,mig.mode.current --format=csv 2>&1
nvidia-smi -L 2>&1   # on a MIG slice this lists the MIG device; Strata reads memory.total from nvidia-smi
nvidia-smi 2>/dev/null | grep -i "CUDA Version"
echo; echo "--- RAM (Strata loads 32-62 GB; LOW_RAM=on for less) ---"
free -g | head -2
for f in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory/memory.limit_in_bytes; do
    [ -r "$f" ] && echo "cgroup memory limit: $(cat "$f")  ($f)"
done
echo "CPU cores: $(nproc)   AVX2: $(grep -m1 -qw avx2 /proc/cpuinfo && echo yes || echo NO)"
echo; echo "--- Paths ---"
for p in / /workspace /runpod-volume /dev/shm; do
    [ -d "$p" ] && printf '%-16s %s\n' "$p" "$(df -h "$p" | awk 'NR==2 {print $2" total, "$4" free"}')  $(findmnt -no FSTYPE,SOURCE -T "$p" | head -1 | tr -s ' ')"
done
