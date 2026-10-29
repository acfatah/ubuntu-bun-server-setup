#!/usr/bin/env bash
# Test: host safety defaults
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/docker/scripts/common.sh
. "$SCRIPT_DIR/common.sh"

INSTALL_LOG=/var/log/bun-installer.log

# Prints the installer log written since line $1 (the previous length).
log_since() {
  tail -n "+$(($1 + 1))" "$INSTALL_LOG"
}

log_lines() {
  if [[ -f $INSTALL_LOG ]]; then
    wc -l <"$INSTALL_LOG"
  else
    echo 0
  fi
}

# Same validation as SKIP_BUN_APP: a typo must not silently fall back
echo -e "${YELLOW}[test]${NC} FULL_UPGRADE=yes is rejected"
if out=$(bash "$INSTALLER" FULL_UPGRADE=yes 2>&1); then
  echo "${RED}Assertion failed:${NC} FULL_UPGRADE=yes was accepted" >&2
  exit 1
fi
grep -q "Invalid FULL_UPGRADE=yes" <<<"$out"

echo -e "${YELLOW}[test]${NC} SKIP_UFW=yes is rejected"
if out=$(bash "$INSTALLER" SKIP_UFW=yes 2>&1); then
  echo "${RED}Assertion failed:${NC} SKIP_UFW=yes was accepted" >&2
  exit 1
fi
grep -q "Invalid SKIP_UFW=yes" <<<"$out"

# Either guess would be wrong for someone, so the pair is refused (0003)
echo -e "${YELLOW}[test]${NC} SKIP_UPGRADE=1 with FULL_UPGRADE=1 is rejected"
before=$(log_lines)
if out=$(bash "$INSTALLER" SKIP_UPGRADE=1 FULL_UPGRADE=1 2>&1); then
  echo "${RED}Assertion failed:${NC} SKIP_UPGRADE=1 FULL_UPGRADE=1 was accepted" >&2
  exit 1
fi
grep -q "Invalid combination: SKIP_UPGRADE=1 and FULL_UPGRADE=1" <<<"$out"
assert_equals "log lines after the refused run" "$before" "$(log_lines)"

# sshd on a custom port: the installer must limit it, not 22 (S5)
echo -e "${YELLOW}[test]${NC} Installing openssh-server on port 2222"
export DEBIAN_FRONTEND=noninteractive
apt_update_retry
apt-get -qqy install openssh-server >/dev/null
echo "Port 2222" >/etc/ssh/sshd_config.d/99-test.conf

# First run: plain upgrade, sshd port limited
before=$(log_lines)
run_installer SKIP_BUN_APP=1
first_log=$(log_since "$before")
grep -q "Upgrading packages (apt-get upgrade)" <<<"$first_log"

status=$(ufw status)
echo "$status"
grep -qE '^2222/tcp +LIMIT' <<<"$status"
if grep -qE '^22/tcp ' <<<"$status"; then
  echo "${RED}Assertion failed:${NC} port 22 limited although sshd uses 2222" >&2
  exit 1
fi

# Operator changes made after the first run must survive a re-run (I4)
ufw allow 8080/tcp
ufw default allow incoming
touch /var/run/reboot-required

# Second run: full-upgrade opt-in, nothing reset
before=$(log_lines)
run_installer SKIP_BUN_APP=1 FULL_UPGRADE=1
second_log=$(log_since "$before")
grep -q "Upgrading packages (apt-get full-upgrade)" <<<"$second_log"
grep -q "Reboot required to finish package upgrades" <<<"$second_log"
rm -f /var/run/reboot-required

status=$(ufw status verbose)
echo "$status"
grep -qE '^8080/tcp +ALLOW' <<<"$status"
grep -q "allow (incoming)" <<<"$status"
assert_equals "2222/tcp v4 rules" 1 "$(grep -cE '^2222/tcp +LIMIT' <<<"$status")"
assert_file_contains /var/lib/app-info/application.info '^ufw="enabled"$'

# The operator turns UFW off: a re-run must leave it off (0023). It also
# skips the upgrade: apt-get update runs, no upgrade (0003)
ufw disable
before=$(log_lines)
run_installer SKIP_BUN_APP=1 SKIP_UPGRADE=1
third_log=$(log_since "$before")
grep -q "Updating package lists (apt-get update)" <<<"$third_log"
grep -q "Skipping package upgrade (SKIP_UPGRADE=1)." <<<"$third_log"
if grep -q "Upgrading packages" <<<"$third_log"; then
  echo "${RED}Assertion failed:${NC} SKIP_UPGRADE=1 run upgraded packages" >&2
  exit 1
fi
assert_equals "UFW after a re-run" "Status: inactive" "$(ufw status)"
grep -q "UFW is inactive but an earlier run enabled it; left disabled" <<<"$third_log"
assert_file_contains /var/lib/app-info/application.info '^ufw="left-disabled"$'
