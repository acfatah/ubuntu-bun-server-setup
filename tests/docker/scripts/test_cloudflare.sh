#!/usr/bin/env bash
# Test: Cloudflare helper
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/docker/scripts/common.sh
. "$SCRIPT_DIR/common.sh"

UPDATER=/usr/local/sbin/cloudflare-update-ips
LISTS=(/etc/nginx/cloudflare/real-ip.conf /etc/nginx/cloudflare/edge-ips.conf)
SITE=/etc/nginx/sites-available/default
# Kept out of /tmp, like test_piped_install
STUB_DIR=/root/cloudflare-stub

# Writes a stub source: $1 is the IPv4 list, $2 the IPv6 list.
write_stub() {
  mkdir -p "$STUB_DIR"
  printf '%s' "$1" >"$STUB_DIR/ips-v4"
  printf '%s' "$2" >"$STUB_DIR/ips-v6"
}

# Runs the updater on the stub; expects it to fail and leave the
# generated lists and Nginx exactly as they were.
expect_rejected() {
  local label=$1 before after
  echo -e "${YELLOW}[test]${NC} rejected: $label"
  before=$(sha256sum "${LISTS[@]}")
  if CLOUDFLARE_IPS_SOURCE=$STUB_DIR "$UPDATER" 2>"$STUB_DIR/err"; then
    echo "${RED}Assertion failed:${NC} updater accepted $label" >&2
    exit 1
  fi
  cat "$STUB_DIR/err"
  after=$(sha256sum "${LISTS[@]}")
  assert_equals "lists after $label" "$before" "$after"
  nginx -t
  systemctl is-active --quiet nginx
}

# Retries a command for up to 10 s: a reload swaps workers asynchronously.
eventually() {
  local _
  for _ in {1..20}; do
    "$@" && return
    sleep 0.5
  done
  echo "${RED}Assertion failed:${NC} never true: $*" >&2
  exit 1
}

# Sends a request with CF-Connecting-IP and checks the access log shows it.
logged_as_client() {
  curl -fsS -H 'CF-Connecting-IP: 203.0.113.9' -o /dev/null 'http://127.0.0.1/?real-ip-probe'
  tail -n 1 /var/log/nginx/access.log | grep -q '^203\.0\.113\.9 .*real-ip-probe'
}

# True when a request from 127.0.0.1 gets the given status.
status_is() {
  [[ $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/) == "$1" ]]
}

V6_GOOD=$'2400:cb00::/32\n2606:4700::/32\n'
V4_GOOD=$'127.0.0.1/32\n173.245.48.0/20\n103.21.244.0/22\n103.22.200.0/22\n103.31.4.0/22\n141.101.64.0/18\n108.162.192.0/18\n'
V4_NO_LOCAL=$'173.245.48.0/20\n103.21.244.0/22\n103.22.200.0/22\n103.31.4.0/22\n141.101.64.0/18\n108.162.192.0/18\n'

# Only 1 skips; anything but empty/0/false/1 is rejected before any work
echo -e "${YELLOW}[test]${NC} SKIP_CLOUDFLARE=yes is rejected"
if out=$(bash "$INSTALLER" SKIP_CLOUDFLARE=yes 2>&1); then
  echo "${RED}Assertion failed:${NC} SKIP_CLOUDFLARE=yes was accepted" >&2
  exit 1
fi
grep -q "Invalid SKIP_CLOUDFLARE=yes" <<<"$out"

# Default install: updater, units, real Cloudflare lists, Nginx files
# shellcheck disable=SC2119 # default install: no env overrides
run_installer
for file in "$UPDATER" /etc/systemd/system/cloudflare-update-ips.service \
  /etc/systemd/system/cloudflare-update-ips.timer \
  /etc/nginx/conf.d/bun-cloudflare.conf /etc/nginx/snippets/cloudflare-only.conf \
  "${LISTS[@]}"; do
  assert_file_exists "$file"
done
[[ -x $UPDATER ]]
systemctl is-enabled --quiet cloudflare-update-ips.timer
systemctl is-active --quiet cloudflare-update-ips.timer
assert_file_contains /etc/nginx/cloudflare/real-ip.conf "^set_real_ip_from "
assert_file_contains /etc/nginx/cloudflare/real-ip.conf "^real_ip_header CF-Connecting-IP;$"
# shellcheck disable=SC2016 # literal Nginx variables, not shell ones
nginx -T 2>/dev/null | grep -q 'geo $realip_remote_addr $bun_cloudflare_edge'
assert_file_contains "$SITE" "^  #include snippets/cloudflare-only.conf;$"

# A bad fetch never touches the lists or Nginx
write_stub $'<html><body>502 Bad Gateway</body></html>\n' "$V6_GOOD"
expect_rejected "an HTML body"
write_stub "${V4_GOOD}not-an-ip;"$'\n' "$V6_GOOD"
expect_rejected "a junk line"
write_stub $'173.245.48.0/20\n' "$V6_GOOD"
expect_rejected "a too-short list"
write_stub "$V4_GOOD" ""
expect_rejected "an empty IPv6 list"
# Passes the format check, but Nginx refuses it: the old files come back
write_stub "${V4_GOOD}999.0.0.0/8"$'\n' "$V6_GOOD"
expect_rejected "a list nginx -t refuses"
grep -q "previous files restored" "$STUB_DIR/err"

# A good list applies and reloads; the same list again changes nothing
echo -e "${YELLOW}[test]${NC} good stub applies"
write_stub "$V4_GOOD" "$V6_GOOD"
CLOUDFLARE_IPS_SOURCE=$STUB_DIR "$UPDATER" | tee "$STUB_DIR/out"
grep -q "Nginx reloaded" "$STUB_DIR/out"
assert_file_contains /etc/nginx/cloudflare/real-ip.conf "^set_real_ip_from 127.0.0.1/32;$"
assert_file_contains /etc/nginx/cloudflare/edge-ips.conf "^2606:4700::/32 1;$"
CLOUDFLARE_IPS_SOURCE=$STUB_DIR "$UPDATER" | tee "$STUB_DIR/out"
grep -q "unchanged" "$STUB_DIR/out"
systemctl is-active --quiet nginx

# 127.0.0.1 now counts as an edge: the access log shows CF-Connecting-IP
echo -e "${YELLOW}[test]${NC} real client IP from CF-Connecting-IP"
eventually logged_as_client

# Blocking: on with the include; edge passes, anything else gets 403
echo -e "${YELLOW}[test]${NC} cloudflare-only include"
sed -i 's|^  #include snippets/cloudflare-only.conf;|  include snippets/cloudflare-only.conf;|' "$SITE"
nginx -t
systemctl reload nginx
eventually status_is 200
write_stub "$V4_NO_LOCAL" "$V6_GOOD"
CLOUDFLARE_IPS_SOURCE=$STUB_DIR "$UPDATER"
eventually status_is 403

# A host from an older version with the old allow/deny filter active: a
# re-run must not turn on real client IP, or "deny all" blocks visitors
echo -e "${YELLOW}[test]${NC} old cloudflare-ip-filter.conf stays in charge"
sed -i 's|^  include snippets/cloudflare-only.conf;|  include cloudflare-ip-filter.conf;|' "$SITE"
printf 'allow 127.0.0.1;\ndeny all;\n' >/etc/nginx/cloudflare-ip-filter.conf
rm /etc/nginx/conf.d/bun-cloudflare.conf
# shellcheck disable=SC2119 # default install: no env overrides
run_installer
if [[ -e /etc/nginx/conf.d/bun-cloudflare.conf ]]; then
  echo "${RED}Assertion failed:${NC} re-run enabled real IP under the old filter" >&2
  exit 1
fi
assert_file_contains /var/log/bun-installer.log "Nginx still includes cloudflare-ip-filter.conf"
eventually status_is 200
