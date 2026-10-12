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
