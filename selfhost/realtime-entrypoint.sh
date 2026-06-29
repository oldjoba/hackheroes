#!/bin/sh
# Background the tenant self-registration, then run Realtime's real startup.
# The original entrypoint was: tini -s -g -- /app/run.sh   (cmd: /app/bin/server)
set -e

# Kick off registration in the background; it waits for the API to be up.
/usr/local/bin/register-tenant.sh &

# Hand off to the official startup (tini reaps, run.sh boots the server).
exec /usr/bin/tini -s -g -- /app/run.sh "$@"
