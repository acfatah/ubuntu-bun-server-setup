#!/usr/bin/env bash
# Test: broken template fails loudly
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/docker/scripts/common.sh
. "$SCRIPT_DIR/common.sh"

# The repo is mounted read-only; break a template in a copy. Kept out of
# /tmp: files written there during the run were gone by assert time.
repo=/root/broken-repo
log=/root/fail.log
cp -a /workspace "$repo"
echo "this_is_not_a_directive;" >>"$repo/templates/nginx-default.conf"

echo -e "${YELLOW}[test]${NC} Running installer with a broken nginx template"
if bash "$repo/install.sh" >"$log" 2>&1; then
  cat "$log"
  echo "${RED}Assertion failed:${NC} installer succeeded with a broken template" >&2
  exit 1
fi
cat "$log"

assert_file_contains "$log" "unknown directive"
assert_file_contains "$log" "install failed at line [0-9]* (configure_nginx)"
if grep -q "Installation complete" "$log"; then
  echo "${RED}Assertion failed:${NC} summary claimed success" >&2
  exit 1
fi
if grep -q $'\033\\[' "$log"; then
  echo "${RED}Assertion failed:${NC} non-TTY output has colour escapes" >&2
  exit 1
fi

# The failure is in the installer log too
assert_file_contains /var/log/bun-installer.log "install failed at line"

# A masked snapd is refused before any package work (0009). The first
# run got past install_certbot, so snapd is installed here.
masked_log=/root/masked-snapd.log
systemctl mask snapd.service snapd.socket

echo -e "${YELLOW}[test]${NC} Running installer with snapd masked"
if bash /workspace/install.sh >"$masked_log" 2>&1; then
  cat "$masked_log"
  echo "${RED}Assertion failed:${NC} installer ran with snapd masked" >&2
  exit 1
fi
cat "$masked_log"

assert_file_contains "$masked_log" "snapd is masked, but Certbot is installed as a snap"
assert_file_contains "$masked_log" "re-run with SKIP_CERTBOT=1"
# exit, not a failing command: no trap line
if grep -q "Upgrading packages\|install failed at line" "$masked_log"; then
  echo "${RED}Assertion failed:${NC} package work or the trap ran before the refusal" >&2
  exit 1
fi
# Unmasked, so the 20.04 check below stands on its own
systemctl unmask snapd.service snapd.socket

# Last: fake Ubuntu 20.04. /etc/os-release links to /usr/lib/os-release,
# so write a real file and replace the link, never write through it.
old_log=/root/old-ubuntu.log
sed 's/^VERSION_ID=.*/VERSION_ID="20.04"/' /etc/os-release >/root/os-release.old
mv -f /root/os-release.old /etc/os-release

echo -e "${YELLOW}[test]${NC} Running installer on a faked Ubuntu 20.04"
if bash /workspace/install.sh >"$old_log" 2>&1; then
  cat "$old_log"
  echo "${RED}Assertion failed:${NC} installer ran on Ubuntu 20.04" >&2
  exit 1
fi
cat "$old_log"

assert_file_contains "$old_log" "requires Ubuntu 22.04 or later. Detected: 20.04."
if grep -q "Upgrading packages" "$old_log"; then
  echo "${RED}Assertion failed:${NC} package work started before the refusal" >&2
  exit 1
fi
