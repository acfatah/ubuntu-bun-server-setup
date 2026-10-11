#!/usr/bin/env bash
set -euo pipefail

YELLOW=$(printf '\033[1;33m')
NC=$(printf '\033[0m')
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/docker/scripts/common.sh
. "$SCRIPT_DIR/common.sh"

run_installer

echo -ne "${YELLOW}[test]${NC} nginx: "; systemctl is-enabled nginx
echo -ne "${YELLOW}[test]${NC} bun-app: "; systemctl is-enabled bun-app
systemctl is-active --quiet nginx
systemctl is-active --quiet bun-app

assert_dir_exists /srv/app
assert_file_exists /srv/app/server.ts
assert_file_exists /etc/systemd/system/bun-app.service
assert_file_exists /var/lib/app-info/application.info
assert_file_contains /etc/nginx/sites-available/default "root /var/www/app/dist"

curl --retry 5 --retry-all-errors --retry-delay 2 -fsS http://127.0.0.1 | grep -q "Hello Bun"

# bun-app runs unprivileged and sandboxed (S2)
assert_equals "unit User" bun-app "$(systemctl show -p User --value bun-app)"
assert_equals "bun binary type" "regular file" "$(stat -c %F /usr/local/bin/bun)"
assert_equals "data link" /var/lib/bun-app "$(readlink /srv/app/data)"
assert_equals "state dir owner" bun-app "$(stat -c %U /var/lib/bun-app)"

# state dir writable, code read-only for the service user
as_app() { runuser -u bun-app -- "$@"; }
as_app touch /var/lib/bun-app/.probe
rm -f /var/lib/bun-app/.probe
if as_app touch /srv/app/.probe 2>/dev/null; then
  echo "bun-app must not write to /srv/app" >&2
  exit 1
fi

# /api/ reaches the sandboxed Bun process (prefix stripped -> "/")
curl --retry 5 --retry-all-errors --retry-delay 2 -fsS http://127.0.0.1/api/ | grep -q "Welcome to Bun"
main_pid=$(systemctl show -p MainPID --value bun-app)
assert_equals "bun process owner" bun-app "$(stat -c %U "/proc/$main_pid")"
assert_equals "bun-app restarts (crash loop?)" 0 "$(systemctl show -p NRestarts --value bun-app)"

echo -ne "${YELLOW}[test]${NC} "
systemd-analyze security bun-app --no-pager | tail -1

# ensure certbot is accessible
command -v certbot >/dev/null

systemctl status bun-app --no-pager
