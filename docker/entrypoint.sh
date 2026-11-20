#!/bin/bash
# Starts Caddy and the deploy API. If either exits, stop the other and exit, so Docker's restart policy
# brings the whole container back. tini (-g) forwards signals to both.
set -euo pipefail

# Render the main Caddyfile from GAMEHOST_* env, re-render site snippets, sweep /data/tmp.
gamehost prepare

caddy run --config "${GAMEHOST_DATA_DIR:-/data}/caddy/Caddyfile" --adapter caddyfile &
caddy_pid=$!
gamehost serve &
api_pid=$!

set +e
wait -n "$caddy_pid" "$api_pid"
status=$?
kill -TERM "$caddy_pid" "$api_pid" 2>/dev/null
wait
exit "$status"
