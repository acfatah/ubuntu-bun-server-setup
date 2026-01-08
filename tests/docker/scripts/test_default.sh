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

# ensure certbot is accessible
command -v certbot >/dev/null

systemctl status bun-app --no-pager
