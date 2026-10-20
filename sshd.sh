#!/bin/bash
# Starts sshd with the key Runpod passes in $PUBLIC_KEY, and makes the pod's variables available in SSH logins.
# The key comes from $PUBLIC_KEY (set by Runpod) or, if that is empty, from $SSH_PUBLIC_KEY (set it yourself in the template; a public key is no secret).
# Does nothing when sshd already runs or no key is set. Used by entry.sh and start.sh.
pgrep -x sshd >/dev/null && exit 0
KEY_LINE="${PUBLIC_KEY:-${SSH_PUBLIC_KEY:-}}"
[ -n "$KEY_LINE" ] || { echo "sshd.sh: neither PUBLIC_KEY (Runpod) nor SSH_PUBLIC_KEY (template variable) is set: sshd is NOT started. Add your key under Runpod Settings -> SSH Public Keys and restart the pod, or set SSH_PUBLIC_KEY" >&2; exit 0; }
# sshd reads authorized_keys from the home in /etc/passwd, not from $HOME (which can differ for the container's main process)
SSH_HOME=$(getent passwd root | cut -d: -f6); SSH_HOME="${SSH_HOME:-/root}"
mkdir -p "$SSH_HOME/.ssh" /run/sshd && chmod 700 "$SSH_HOME/.ssh"
grep -qxF "$KEY_LINE" "$SSH_HOME/.ssh/authorized_keys" 2>/dev/null || echo "$KEY_LINE" >> "$SSH_HOME/.ssh/authorized_keys"
chmod 600 "$SSH_HOME/.ssh/authorized_keys"
ssh-keygen -A >/dev/null
# environment variables are not visible in SSH sessions by default: export them for logins (API_KEY included so scripts/bench-local.sh works; the file is root-only)
printenv | grep -E '^(RUNPOD_|STRATA_|API_KEY=|MODEL=|FAMILY=|CONTEXT=|PARALLEL=|TUNE=|RETUNE=|PRESET=|KV=|VISION=|GPUS?=|PORT=|LB_PORT=|COPY_DATA_LOCAL=|MODE=|CUDA|NVIDIA|LD_LIBRARY_PATH|PATH)' \
    | sed 's/^\([^=]*\)=\(.*\)$/export \1="\2"/' > /etc/rp_environment
chmod 600 /etc/rp_environment
grep -q rp_environment "$SSH_HOME/.bashrc" 2>/dev/null || echo 'source /etc/rp_environment' >> "$SSH_HOME/.bashrc"
/usr/sbin/sshd && echo "sshd started (key login only, no password)" || echo "sshd.sh: sshd failed to start (run /usr/sbin/sshd -t to see why)" >&2
