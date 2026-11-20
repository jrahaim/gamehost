#!/usr/bin/env bash
# Builds gamehost, starts a native stack in a temp dir, runs the acceptance tests, stops the stack.
#   Tests/integration/run-local.sh [test-name-filter...]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
(cd "$root" && swift build -c release --product gamehost)
export GAMEHOST_BIN="$root/.build/release/gamehost"
state=$(mktemp -d "${TMPDIR:-/tmp}/gamehost-acceptance.XXXXXX")
trap '"$here/local-stack.sh" stop "$state"; echo "logs: $state"' EXIT
"$here/local-stack.sh" start "$state"

export GAMEHOST_BASE_DOMAIN=${GAMEHOST_BASE_DOMAIN:-games.test}
export GAMEHOST_ADMIN_TOKEN=${GAMEHOST_ADMIN_TOKEN:-local-test-admin-token-0123456789abcdef}
export GAMEHOST_TEST_URL="http://127.0.0.1:${GAMEHOST_EXTERNAL_PORT:-18081}"
export GAMEHOST_MAX_UPLOAD_MB=${GAMEHOST_MAX_UPLOAD_MB:-8}
export GAMEHOST_MAX_UNPACKED_MB=${GAMEHOST_MAX_UNPACKED_MB:-24}
export GAMEHOST_TEST_RESTART_CMD="'$here/local-stack.sh' restart '$state'"
export GAMEHOST_TEST_TMP_CHECK_CMD="ls -A '$state/data/tmp'"
export GAMEHOST_TEST_RELEASES_CMD="ls '$state/data/sites/{key}/releases'"
python3 "$here/acceptance.py" "$@"
