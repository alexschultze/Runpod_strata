#!/bin/bash
# Entry point of the image: starts sshd, then either waits (default) or starts Strata.
#   SCRIPTS_REF=<branch|tag>   use the scripts of that git ref instead of the ones in the image (see update-scripts.sh)
#   AUTO_START=yes   start Strata automatically (always for MODE=lb or queue). Default: wait, you run /opt/runpod/start.sh yourself (in tmux).
/opt/runpod/sshd.sh
[ -z "${MODE:-}" ] && [ -n "${RUNPOD_ENDPOINT_ID:-}" ] && export MODE=queue   # Serverless worker: start (and queue handler) automatically
/opt/runpod/update-scripts.sh   # only with SCRIPTS_REF set: current scripts from the git repo instead of the image's
if [ "${AUTO_START:-no}" = yes ] || [ "${MODE:-pod}" != pod ]; then exec /opt/runpod/start.sh; fi
cat <<MSG
entry.sh: nothing is started (AUTO_START is not yes). To copy the data from the volume and start Strata run, inside tmux:
  STRATA_API_KEY=<secret> /opt/runpod/start.sh
  (variables: MODEL, CONTEXT, PARALLEL or STRATA_PARALLEL, STRATA_CALIBRATE, COPY_DATA_LOCAL, ...; see the README)
MSG
exec sleep infinity
