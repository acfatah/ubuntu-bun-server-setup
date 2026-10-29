#!/usr/bin/env bash
# Test: piped install with args
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/docker/scripts/common.sh
. "$SCRIPT_DIR/common.sh"

# Rejection logs stay out of /tmp: a file written there was once gone by
# the time its assert ran in the test container
err_dir=/root/piped-errors
mkdir -p "$err_dir"

# Unknown arguments are rejected before anything is installed
if bash "$INSTALLER" BOGUS=1 2>"$err_dir/bogus.err"; then
  echo "${RED}Assertion failed:${NC} installer accepted BOGUS=1" >&2
  exit 1
fi
assert_file_contains "$err_dir/bogus.err" "Unknown argument: BOGUS=1"

# A ref that could climb out of the repo path is rejected
if TEMPLATE_REF=../x bash "$INSTALLER" 2>"$err_dir/ref.err"; then
  echo "${RED}Assertion failed:${NC} installer accepted TEMPLATE_REF=../x" >&2
  exit 1
fi
assert_file_contains "$err_dir/ref.err" "Invalid TEMPLATE_REF=../x"

# Plain http is refused: templates must come over TLS or from disk
if TEMPLATE_BASE_URL=http://example.com/t bash "$INSTALLER" 2>"$err_dir/url.err"; then
  echo "${RED}Assertion failed:${NC} installer accepted TEMPLATE_BASE_URL=http://example.com/t" >&2
  exit 1
fi
assert_file_contains "$err_dir/url.err" "Invalid TEMPLATE_BASE_URL=http://example.com/t (use https:// or file://)"

# --version names the dev build and the ref; --help needs no root
version=$(TEMPLATE_REF=v0.4.0 bash "$INSTALLER" --version)
echo "$version"
grep -q "ubuntu-bun-server-setup dev" <<<"$version"
grep -q "templates: v0.4.0 from https://raw.githubusercontent.com/.*/v0.4.0/templates" <<<"$version"
grep -q "templates: not verified (dev channel)" <<<"$version"
sudo -u tester bash "$INSTALLER" --help | grep -q "TEMPLATE_BASE_URL"

# Pipe the installer like the README Quick Start, from a cwd without
# templates, passing a toggle as an argument. Templates come from this
# checkout through file://, so branch edits are tested before a merge.
# Kept out of /tmp: files written there during the run were gone by the
# time the asserts ran in the test container
test_dir=/root/piped-test
mkdir -p "$test_dir"
log="$test_dir/piped.log"
work_dir="$test_dir/cwd"
mkdir -p "$work_dir"
(cd "$work_dir" && TEMPLATE_BASE_URL=file:///workspace/templates bash -s -- SKIP_BUN_APP=1 <"$INSTALLER" 2>&1 | tee "$log")

if grep -q "unbound variable" "$log"; then
  echo "${RED}Assertion failed:${NC} piped install printed 'unbound variable'" >&2
  exit 1
fi
if grep -q "Using local template" "$log"; then
  echo "${RED}Assertion failed:${NC} piped install used local templates" >&2
  exit 1
fi
assert_file_contains "$log" "Downloading template"
assert_file_contains "$log" "templates: main from file:///workspace/templates"

# SKIP_BUN_APP=1 took effect; Cloudflare support still installed
for file in /usr/local/sbin/cloudflare-update-ips /etc/nginx/conf.d/bun-cloudflare.conf; do
  assert_file_exists "$file"
done
assert_file_contains /etc/nginx/sites-available/default "root /var/www/html"
curl --retry 5 --retry-all-errors --retry-delay 2 -fsS http://127.0.0.1 | grep -q "Hello World"
if id -u bun-app >/dev/null 2>&1; then
  echo "bun-app user must not exist with SKIP_BUN_APP" >&2
  exit 1
fi
assert_file_contains /var/lib/app-info/application.info 'installer_version="dev"'
assert_file_contains /var/lib/app-info/application.info 'template_ref="main"'
