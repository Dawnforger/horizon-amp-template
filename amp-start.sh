#!/usr/bin/env bash
# AMP start: first run writes server/server.toml from the AMP settings, then runs the server in the
# foreground with its console on stdin (AMP's console).  amp-start.sh <base-dir> <port>
set -euo pipefail
BASE=${1:?base dir}; PORT=${2:-25565}
cd "$BASE"; mkdir -p server
HS="$BASE/bin/horizon-server"
if [ ! -f server/server.toml ]; then
  [ "${HORIZON_EULA:-false}" = true ] || { echo "Accept the Minecraft EULA in AMP's Horizon settings first."; exit 1; }
  [ -n "${HORIZON_SEED:-}" ] || unset HORIZON_SEED
  [ -n "${HORIZON_OP:-}" ] || unset HORIZON_OP
  [ -n "${HORIZON_OP:-}" ] && export HORIZON_PLAYERS="${HORIZON_PLAYERS:-$HORIZON_OP}"
  HORIZON_PORT="$PORT" "$HS" --dir server init --yes
else
  # Keep the port in step with AMP's port setting (ignored if this Horizon build names the key differently).
  "$HS" --dir server config set "server.port=$PORT" >/dev/null 2>&1 || true
fi
exec "$HS" --dir server run
