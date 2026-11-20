#!/usr/bin/env bash
# Builds the image, runs it in TLS_MODE=external, and runs the acceptance tests against the container.
#   Tests/integration/run-docker.sh [test-name-filter...]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
name=gamehost-acceptance-$$
port=${GAMEHOST_TEST_PORT:-18081}
export GAMEHOST_BASE_DOMAIN=games.test
export GAMEHOST_ADMIN_TOKEN=docker-test-admin-token-0123456789abcdef
export GAMEHOST_MAX_UPLOAD_MB=8
export GAMEHOST_MAX_UNPACKED_MB=24

docker build -t gamehost:test "$root"
trap 'docker logs "$name" > "${TMPDIR:-/tmp}/$name.log" 2>&1 || true; docker rm -f "$name" >/dev/null 2>&1 || true; docker volume rm "$name" >/dev/null 2>&1 || true' EXIT
docker run -d --name "$name" -p "127.0.0.1:$port:8081" -v "$name:/data" \
  -e GAMEHOST_BASE_DOMAIN -e GAMEHOST_ADMIN_TOKEN -e GAMEHOST_MAX_UPLOAD_MB -e GAMEHOST_MAX_UNPACKED_MB \
  -e GAMEHOST_TLS_MODE=external gamehost:test >/dev/null
for _ in $(seq 100); do
  curl -fsS -H "Host: deploy.games.test" "http://127.0.0.1:$port/healthz" >/dev/null 2>&1 && break
  sleep 0.3
done

export GAMEHOST_TEST_URL="http://127.0.0.1:$port"
export GAMEHOST_TEST_RESTART_CMD="docker restart $name >/dev/null"
export GAMEHOST_TEST_TMP_CHECK_CMD="docker exec $name ls -A /data/tmp"
export GAMEHOST_TEST_RELEASES_CMD="docker exec $name ls /data/sites/{key}/releases"
python3 "$here/acceptance.py" "$@"
