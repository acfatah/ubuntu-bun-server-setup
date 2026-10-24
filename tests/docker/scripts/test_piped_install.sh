#!/usr/bin/env bash
# Test: piped install with args
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/docker/scripts/common.sh
. "$SCRIPT_DIR/common.sh"

# Unknown arguments are rejected before anything is installed
if bash "$INSTALLER" BOGUS=1 2>"$LOG_DIR/bogus.err"; then
  echo "${RED}Assertion failed:${NC} installer accepted BOGUS=1" >&2
  exit 1
fi
assert_file_contains "$LOG_DIR/bogus.err" "Unknown argument: BOGUS=1"

# Pipe the installer like the README Quick Start, from a cwd without
# templates, passing the toggles as arguments. SKIP_CLOUDFLARE=1: the
# Cloudflare templates may not be on main yet
# Kept out of /tmp: files written there during the run were gone by the
# time the asserts ran in the test container
test_dir=/root/piped-test
mkdir -p "$test_dir"
log="$test_dir/piped.log"
work_dir="$test_dir/cwd"
mkdir -p "$work_dir"
(cd "$work_dir" && bash -s -- SKIP_BUN_APP=1 SKIP_CLOUDFLARE=1 <"$INSTALLER" 2>&1 | tee "$log")

if grep -q "unbound variable" "$log"; then
  echo "${RED}Assertion failed:${NC} piped install printed 'unbound variable'" >&2
  exit 1
fi
if grep -q "Using local template" "$log"; then
  echo "${RED}Assertion failed:${NC} piped install used local templates" >&2
  exit 1
fi
assert_file_contains "$log" "Downloading template"

# SKIP_BUN_APP=1 and SKIP_CLOUDFLARE=1 took effect
for file in /usr/local/sbin/cloudflare-update-ips /etc/nginx/conf.d/bun-cloudflare.conf; do
  if [[ -e $file ]]; then
    echo "${RED}Assertion failed:${NC} SKIP_CLOUDFLARE=1 installed $file" >&2
    exit 1
  fi
done
assert_file_contains /etc/nginx/sites-available/default "root /var/www/html"
curl --retry 5 --retry-all-errors --retry-delay 2 -fsS http://127.0.0.1 | grep -q "Hello World"
if id -u bun-app >/dev/null 2>&1; then
  echo "bun-app user must not exist with SKIP_BUN_APP" >&2
  exit 1
fi
