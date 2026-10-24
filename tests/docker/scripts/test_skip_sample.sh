#!/usr/bin/env bash
# Test: SKIP_BUN_APP install + re-run
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

# Skip mode keeps Ubuntu's stock site: the installer template never lands
if grep -qF "# Managed by ubuntu-bun-server-setup." /etc/nginx/sites-available/default; then
  echo "${RED}Assertion failed:${NC} skip mode installed the Bun site" >&2
  exit 1
fi
for file in /etc/nginx/snippets/bun-proxy.conf /etc/nginx/conf.d/bun-connection-upgrade.conf; do
  if [[ -e $file ]]; then
    echo "${RED}Assertion failed:${NC} skip mode installed $file" >&2
    exit 1
  fi
done

# A re-run keeps the user's own index.html
echo "<h1>My own site</h1>" >/var/www/html/index.html
run_installer SKIP_BUN_APP=1
assert_file_contains /var/log/bun-installer.log "Kept existing /var/www/html/index.html"
curl --retry 5 --retry-all-errors --retry-delay 2 -fsS http://127.0.0.1 | grep -q "My own site"
