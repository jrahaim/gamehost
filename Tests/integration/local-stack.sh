#!/usr/bin/env bash
# Runs gamehost natively (Caddy + API, TLS_MODE=external) for the acceptance tests, without Docker.
#   local-stack.sh start|stop|restart STATE_DIR
# Needs: caddy (or CADDY_BIN), brotli, gzip, and a built `gamehost` binary (GAMEHOST_BIN).
set -euo pipefail
cmd=${1:?start|stop|restart}
state=${2:?state dir}
mkdir -p "$state"
state=$(cd "$state" && pwd)

export GAMEHOST_BASE_DOMAIN=${GAMEHOST_BASE_DOMAIN:-games.test}
export GAMEHOST_ADMIN_TOKEN=${GAMEHOST_ADMIN_TOKEN:-local-test-admin-token-0123456789abcdef}
export GAMEHOST_TLS_MODE=external
export GAMEHOST_DATA_DIR="$state/data"
export GAMEHOST_EXTERNAL_PORT=${GAMEHOST_EXTERNAL_PORT:-18081}
export GAMEHOST_PUBLIC_SCHEME=http
export GAMEHOST_INDEX_HOST=${GAMEHOST_INDEX_HOST:-arcade.games.test}
export GAMEHOST_PUBLIC_PORT=$GAMEHOST_EXTERNAL_PORT
export GAMEHOST_API_LISTEN_PORT=${GAMEHOST_API_LISTEN_PORT:-18080}
export GAMEHOST_CADDY_ADMIN=${GAMEHOST_CADDY_ADMIN:-localhost:12019}
export GAMEHOST_CADDY_BIN=${CADDY_BIN:-caddy}
export GAMEHOST_MAX_UPLOAD_MB=${GAMEHOST_MAX_UPLOAD_MB:-8}
export GAMEHOST_MAX_UNPACKED_MB=${GAMEHOST_MAX_UNPACKED_MB:-24}
bin=${GAMEHOST_BIN:?set GAMEHOST_BIN to the built gamehost binary}

stop() {
  for p in api caddy; do
    local pidfile="${state:?}/${p:?}.pid"
    if [[ -f "$pidfile" ]]; then
      kill "$(cat "$pidfile")" 2>/dev/null || true
      for _ in $(seq 50); do kill -0 "$(cat "$pidfile")" 2>/dev/null || break; sleep 0.1; done
      rm -f "$pidfile"
    fi
  done
}

start() {
  "$bin" prepare >>"$state/api.log" 2>&1
  "$GAMEHOST_CADDY_BIN" run --config "$GAMEHOST_DATA_DIR/caddy/Caddyfile" --adapter caddyfile >>"$state/caddy.log" 2>&1 &
  echo $! >"$state/caddy.pid"
  "$bin" serve >>"$state/api.log" 2>&1 &
  echo $! >"$state/api.pid"
  for _ in $(seq 100); do
    if curl -fsS -H "Host: deploy.$GAMEHOST_BASE_DOMAIN" "http://127.0.0.1:$GAMEHOST_EXTERNAL_PORT/healthz" >/dev/null 2>&1; then return 0; fi
    sleep 0.2
  done
  echo "stack did not become healthy; see $state/*.log" >&2
  exit 1
}

case $cmd in
  start) start ;;
  stop) stop ;;
  restart) stop; start ;;
  *) echo "unknown command $cmd" >&2; exit 64 ;;
esac
