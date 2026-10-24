#!/usr/bin/env bash
# Test: default install
set -euo pipefail

YELLOW=$(printf '\033[1;33m')
NC=$(printf '\033[0m')
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/docker/scripts/common.sh
. "$SCRIPT_DIR/common.sh"

# shellcheck disable=SC2119 # default install: no env overrides
run_installer

echo -ne "${YELLOW}[test]${NC} nginx: "
systemctl is-enabled nginx
echo -ne "${YELLOW}[test]${NC} bun-app: "
systemctl is-enabled bun-app
systemctl is-active --quiet nginx
systemctl is-active --quiet bun-app

assert_dir_exists /srv/app
assert_file_exists /srv/app/server.ts
assert_file_exists /etc/systemd/system/bun-app.service
assert_file_exists /var/lib/app-info/application.info
assert_file_contains /etc/nginx/sites-available/default "root /var/www/app/dist"
assert_file_contains /etc/nginx/sites-available/default "^# Managed by ubuntu-bun-server-setup\."

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

# /api/ reaches the sandboxed Bun process with its prefix kept (B7)
curl --retry 5 --retry-all-errors --retry-delay 2 -fsS http://127.0.0.1/api/ | grep -q "Welcome to Bun"
curl -fsS http://127.0.0.1/api/x | grep -q '"path":"/api/x"'
main_pid=$(systemctl show -p MainPID --value bun-app)
assert_equals "bun process owner" bun-app "$(stat -c %U "/proc/$main_pid")"
assert_equals "bun-app restarts (crash loop?)" 0 "$(systemctl show -p NRestarts --value bun-app)"

# Environment comes from the root-only env file, not the unit
assert_equals "env file mode" 600 "$(stat -c %a /etc/bun-app.env)"
environ=$(tr '\0' '\n' <"/proc/$main_pid/environ")
grep -q '^INSTANCE_ID=.' <<<"$environ"
grep -qx 'PORT=3000' <<<"$environ"

# Security headers, no Nginx version (§4)
headers=$(curl -fsSI http://127.0.0.1/)
grep -qi '^X-Content-Type-Options: nosniff' <<<"$headers"
grep -qiE '^Server: nginx\s*$' <<<"$headers"

# /assets/ sends exactly one Cache-Control and keeps the security headers
mkdir -p /var/www/app/dist/assets
echo 'body{}' >/var/www/app/dist/assets/t.css
headers=$(curl -fsSI http://127.0.0.1/assets/t.css)
assert_equals "Cache-Control lines" 1 "$(grep -ci '^Cache-Control:' <<<"$headers")"
grep -qi '^X-Content-Type-Options: nosniff' <<<"$headers"

# Bun listens on loopback only; clients go through Nginx (S7)
listeners=$(ss -Hltn 'sport = :3000' | awk '{print $4}')
assert_equals "port 3000 listeners" "127.0.0.1:3000" "$listeners"
host_ip=$(hostname -I | awk '{print $1}')
if curl -fsS --max-time 3 "http://$host_ip:3000/" >/dev/null 2>&1; then
  echo "${RED}Assertion failed:${NC} Bun reachable on $host_ip:3000" >&2
  exit 1
fi

# No sshd in the image: the installer falls back to limiting 22 (S5)
ufw status | grep -qE '^22/tcp +LIMIT'

echo -ne "${YELLOW}[test]${NC} "
systemd-analyze security bun-app --no-pager | tail -1

# ensure certbot is accessible
command -v certbot >/dev/null

systemctl status bun-app --no-pager

# Every run is logged; a non-TTY run carries no colour escapes (S9)
assert_file_contains /var/log/bun-installer.log "Installation complete"
if grep -q $'\033\\[' /var/log/bun-installer.log; then
  echo "${RED}Assertion failed:${NC} installer log has colour escapes" >&2
  exit 1
fi

# Nginx sends "Connection: upgrade" only when the client asks for one (§4):
# swap bun-app for a probe that echoes the Connection header it receives
systemctl stop bun-app
bun -e 'Bun.serve({ hostname: "127.0.0.1", port: 3000, fetch: (req) => new Response(req.headers.get("connection") ?? "none") })' &
probe_pid=$!
plain=$(curl --retry 5 --retry-all-errors --retry-delay 1 -fsS http://127.0.0.1/api/x)
upgrade=$(curl -fsS -H 'Upgrade: websocket' -H 'Connection: Upgrade' http://127.0.0.1/api/x)
kill "$probe_pid"
wait "$probe_pid" || true # killed on purpose: non-zero status expected
systemctl start bun-app
assert_equals "Connection without upgrade" close "$plain"
assert_equals "Connection with upgrade" upgrade "$upgrade"
