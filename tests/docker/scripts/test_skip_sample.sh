#!/usr/bin/env bash
# Test: SKIP_BUN_APP install + re-run
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/docker/scripts/common.sh
. "$SCRIPT_DIR/common.sh"

INFO=/var/lib/app-info/application.info

run_installer SKIP_BUN_APP=1 SKIP_UFW=1 SKIP_CERTBOT=1

assert_file_contains /etc/nginx/sites-available/default "root /var/www/html"

# SKIP_UFW=1: UFW stays inactive with no rules added, and the run says so
assert_equals "UFW after SKIP_UFW=1" "Status: inactive" "$(ufw status)"
if ufw show added | grep -qE 'limit|Nginx Full|allow'; then
  echo "${RED}Assertion failed:${NC} SKIP_UFW=1 added UFW rules" >&2
  ufw show added >&2
  exit 1
fi
assert_file_contains "$INFO" '^ufw="skipped"$'
assert_file_contains /var/log/bun-installer.log "SKIP_UFW=1: UFW left untouched"

# SKIP_CERTBOT=1: neither snapd nor Certbot installed, summary still passes
if dpkg -s snapd >/dev/null 2>&1 || command -v certbot >/dev/null; then
  echo "${RED}Assertion failed:${NC} SKIP_CERTBOT=1 installed snapd or certbot" >&2
  exit 1
fi
assert_file_contains /var/log/bun-installer.log "SKIP_CERTBOT=1: snapd and Certbot not installed"
assert_file_contains /var/log/bun-installer.log "Certbot skipped (SKIP_CERTBOT=1)"

curl --retry 5 --retry-all-errors --retry-delay 2 -fsS http://127.0.0.1 | grep -q "Hello World"

# --check infers skip mode: Nginx only, no bun-app, probe or Certbot
check_out=$(bash "$INSTALLER" --check)
echo "$check_out"
grep -q "Health check: OK" <<<"$check_out"
if grep -qE "bun-app|healthz|Certbot" <<<"$check_out"; then
  echo "${RED}Assertion failed:${NC} --check checked what skip mode lacks" >&2
  exit 1
fi

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

# Cloudflare: real-IP config for every site, stock site left alone
assert_file_exists /etc/nginx/conf.d/bun-cloudflare.conf
assert_file_exists /etc/nginx/cloudflare/real-ip.conf
if grep -q "cloudflare" /etc/nginx/sites-available/default; then
  echo "${RED}Assertion failed:${NC} skip mode edited the stock site" >&2
  exit 1
fi
assert_file_contains /var/log/bun-installer.log "Cloudflare: only the real client IP applies"

# A re-run keeps the user's own index.html; without SKIP_UFW it enables
# UFW, since the earlier run recorded it as skipped; without SKIP_CERTBOT
# it installs snapd and Certbot
echo "<h1>My own site</h1>" >/var/www/html/index.html
run_installer SKIP_BUN_APP=1
certbot --version
grep -q "Certbot runs" <<<"$(bash "$INSTALLER" --check)"
ufw status | grep -q "^Status: active"
assert_file_contains "$INFO" '^ufw="enabled"$'
assert_file_contains /var/log/bun-installer.log "Kept existing /var/www/html/index.html"
curl --retry 5 --retry-all-errors --retry-delay 2 -fsS http://127.0.0.1 | grep -q "My own site"
