#!/bin/bash
# Starts sshd with the key Runpod passes in $PUBLIC_KEY, and makes the pod's variables available in SSH logins.
# Does nothing when sshd already runs or no key is set. Used by start.sh and idle.sh.
pgrep -x sshd >/dev/null && exit 0
[ -n "$PUBLIC_KEY" ] || { echo "sshd.sh: PUBLIC_KEY is not set (add your key under Runpod Settings -> SSH Public Keys and restart the pod): sshd is NOT started" >&2; exit 0; }
mkdir -p ~/.ssh /run/sshd && chmod 700 ~/.ssh
echo "$PUBLIC_KEY" >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
ssh-keygen -A >/dev/null
# environment variables are not visible in SSH sessions by default: export them for logins (API_KEY included so scripts/bench-local.sh works; the file is root-only)
printenv | grep -E '^(RUNPOD_|STRATA_|API_KEY=|MODEL=|FAMILY=|CONTEXT=|LOW_RAM=|RESIDENT_BUDGET_GIB=|MODE=|CUDA|NVIDIA|LD_LIBRARY_PATH|PATH)' \
    | sed 's/^\([^=]*\)=\(.*\)$/export \1="\2"/' > /etc/rp_environment
chmod 600 /etc/rp_environment
grep -q rp_environment ~/.bashrc 2>/dev/null || echo 'source /etc/rp_environment' >> ~/.bashrc
/usr/sbin/sshd && echo "sshd started (key login only, no password)" || echo "sshd.sh: sshd failed to start (run /usr/sbin/sshd -t to see why)" >&2
