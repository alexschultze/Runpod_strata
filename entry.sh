#!/bin/bash
# Entry point of the image: starts sshd, then either waits (default) or starts Strata.
#   AUTO_START=yes   start Strata automatically (always for MODE=lb or queue). Default: wait, you run /opt/runpod/start.sh yourself (in tmux).
/opt/runpod/sshd.sh
if [ "${AUTO_START:-no}" = yes ] || [ "${MODE:-pod}" != pod ]; then exec /opt/runpod/start.sh; fi
cat <<MSG
entry.sh: nothing is started (AUTO_START is not yes). To install/restore and start Strata run, inside tmux:
  STRATA_API_KEY=<secret> /opt/runpod/start.sh
  (variables: FAMILY, MODEL, CONTEXT, LOW_RAM, COPY_DATA_LOCAL, ...; see the README)
MSG
exec sleep infinity
