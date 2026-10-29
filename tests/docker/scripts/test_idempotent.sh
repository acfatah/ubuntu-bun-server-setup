#!/usr/bin/env bash
# Test: re-run keeps edits
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/docker/scripts/common.sh
. "$SCRIPT_DIR/common.sh"

edited_files=(
  /etc/systemd/system/bun-app.service
  /etc/bun-app.env
  /etc/nginx/sites-available/default
  /etc/nginx/snippets/bun-proxy.conf
  /etc/nginx/conf.d/bun-connection-upgrade.conf
  /usr/local/sbin/cloudflare-update-ips
  /etc/systemd/system/cloudflare-update-ips.service
  /etc/systemd/system/cloudflare-update-ips.timer
  /etc/nginx/conf.d/bun-cloudflare.conf
  /etc/nginx/snippets/cloudflare-only.conf
  /etc/update-motd.d/00-custom
)

# Only 1 skips; anything but empty/0/false/1 is rejected before any work
echo -e "${YELLOW}[test]${NC} SKIP_BUN_APP=yes is rejected"
if out=$(bash "$INSTALLER" SKIP_BUN_APP=yes 2>&1); then
  echo "${RED}Assertion failed:${NC} SKIP_BUN_APP=yes was accepted" >&2
  exit 1
fi
grep -q "Invalid SKIP_BUN_APP=yes" <<<"$out"

# First run: SKIP_BUN_APP=0 installs the app
run_installer SKIP_BUN_APP=0
systemctl is-active --quiet bun-app
curl --retry 5 --retry-all-errors --retry-delay 2 -fsS http://127.0.0.1 | grep -q "Hello Bun"

instance_id=$(sed -n 's/^INSTANCE_ID=//p' /etc/environment)
[[ -n $instance_id ]]

# Simulate a host from an older version (duplicate line) and user edits
echo "INSTANCE_ID=stale-duplicate" >>/etc/environment
for file in "${edited_files[@]}"; do
  echo "# user edit" >>"$file"
done

# A run while another holds the lock fails and changes nothing: the
# stale INSTANCE_ID line stays and the log gets no header
echo -e "${YELLOW}[test]${NC} a run is refused while the lock is held"
lock=/run/lock/bun-installer.lock
log_lines=$(wc -l </var/log/bun-installer.log)
env_before=$(sha256sum </etc/environment)
exec 8>"$lock"
flock -n 8
if out=$(bash "$INSTALLER" 2>&1); then
  echo "${RED}Assertion failed:${NC} a run succeeded while the lock was held" >&2
  exit 1
fi
exec 8>&-
grep -q "Another installer run is in progress" <<<"$out"
assert_equals "log lines after a refused run" "$log_lines" "$(wc -l </var/log/bun-installer.log)"
assert_equals "/etc/environment after a refused run" "$env_before" "$(sha256sum </etc/environment)"

# Second run (lock released) must keep all of it
# shellcheck disable=SC2119 # default install: no env overrides
run_installer

assert_equals "INSTANCE_ID lines" 1 "$(grep -c '^INSTANCE_ID=' /etc/environment)"
assert_file_contains /etc/environment "^INSTANCE_ID=${instance_id}\$"
assert_file_contains /etc/bun-app.env "^INSTANCE_ID=${instance_id}\$"
main_pid=$(systemctl show -p MainPID --value bun-app)
tr '\0' '\n' <"/proc/$main_pid/environ" | grep -qx "INSTANCE_ID=${instance_id}"
for file in "${edited_files[@]}"; do
  assert_file_contains "$file" "^# user edit\$"
done
assert_file_contains /var/log/bun-installer.log "Kept existing /etc/systemd/system/bun-app.service"

nginx -t
systemctl is-active --quiet nginx
systemctl is-active --quiet bun-app
curl --retry 5 --retry-all-errors --retry-delay 2 -fsS http://127.0.0.1 | grep -q "Hello Bun"

# Ubuntu's MOTD scripts are diverted and stay away after a base-files
# reinstall (which is what an upgrade does to them)
for name in 00-header 10-help-text; do
  dpkg-divert --list "/etc/update-motd.d/$name" | grep -q motd-disabled
done
DEBIAN_FRONTEND=noninteractive apt-get -qqy install --reinstall base-files >/dev/null
for name in 00-header 10-help-text; do
  if [[ -e /etc/update-motd.d/$name ]]; then
    echo "${RED}Assertion failed:${NC} /etc/update-motd.d/$name came back" >&2
    exit 1
  fi
done
assert_file_exists /etc/update-motd.d/00-custom
