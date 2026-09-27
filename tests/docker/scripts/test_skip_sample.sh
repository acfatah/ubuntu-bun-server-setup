#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/docker/scripts/common.sh
. "$SCRIPT_DIR/common.sh"

run_installer SKIP_BUN_APP=1

assert_file_contains /etc/nginx/sites-available/default "root /var/www/html"

curl --retry 5 --retry-all-errors --retry-delay 2 -fsS http://127.0.0.1 | grep -q "Hello World"

# Bun is still installed system-wide, but no service user is created
assert_equals "bun binary type" "regular file" "$(stat -c %F /usr/local/bin/bun)"
if id -u bun-app >/dev/null 2>&1; then
  echo "bun-app user must not exist with SKIP_BUN_APP" >&2
  exit 1
fi
