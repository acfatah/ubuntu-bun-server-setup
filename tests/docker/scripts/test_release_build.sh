#!/usr/bin/env bash
# Test: pinned release build verifies templates
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/docker/scripts/common.sh
. "$SCRIPT_DIR/common.sh"

# Kept out of /tmp: files written there during the run were gone by the
# time the asserts ran in the test container
test_dir=/root/release-test
dist=$test_dir/dist
work_dir=$test_dir/cwd
info=/var/lib/app-info/application.info
mkdir -p "$work_dir"

# The repo is mounted read-only; the build writes only to its out-dir
bash /workspace/build-installer.sh 9.9.9 "$dist"
(cd "$dist" && sha256sum -c SHA256SUMS)
if bash /workspace/build-installer.sh 9.9 "$test_dir/bad" 2>/dev/null; then
  echo "${RED}Assertion failed:${NC} build accepted version 9.9" >&2
  exit 1
fi

version=$(bash "$dist/install.sh" --version)
echo "$version"
grep -q "ubuntu-bun-server-setup 9.9.9" <<<"$version"
grep -q "templates: v9.9.9 from https://raw.githubusercontent.com/.*/v9.9.9/templates" <<<"$version"
grep -q "templates: verified against embedded SHA-256 sums" <<<"$version"

# Pinned piped install; the file:// mirror holds this checkout's
# templates, which match the embedded sums
log=$test_dir/pinned.log
(cd "$work_dir" && TEMPLATE_BASE_URL=file:///workspace/templates bash -s -- SKIP_BUN_APP=1 SKIP_CLOUDFLARE=1 <"$dist/install.sh" 2>&1 | tee "$log")
assert_file_contains "$log" "checked against the SHA-256 sums of v9.9.9"
assert_file_contains "$log" "Checksum OK: application.info"
assert_file_contains "$info" 'installer_version="9.9.9"'
assert_file_contains "$info" 'template_ref="v9.9.9"'
assert_file_contains /var/log/bun-installer.log "=== bun-installer 9.9.9 "

# A tampered template fails the re-run and leaves the old file in place
tampered=$test_dir/templates
cp -a /workspace/templates "$tampered"
echo 'tampered="yes"' >>"$tampered/application.info"
cp "$info" "$test_dir/application.info.before"
log=$test_dir/tampered.log
if (cd "$work_dir" && TEMPLATE_BASE_URL=file://$tampered bash -s -- SKIP_BUN_APP=1 SKIP_CLOUDFLARE=1 <"$dist/install.sh" >"$log" 2>&1); then
  cat "$log"
  echo "${RED}Assertion failed:${NC} pinned installer accepted a tampered template" >&2
  exit 1
fi
cat "$log"
assert_file_contains "$log" "Template application.info failed its checksum"
assert_file_contains "$log" "install failed at line [0-9]* (write_application_info)"
cmp "$test_dir/application.info.before" "$info"
assert_equals "files in /var/lib/app-info" "application.info" "$(ls -A /var/lib/app-info)"

# Another ref is expected to differ: one warning, no verification
log=$test_dir/override.log
(cd "$work_dir" && TEMPLATE_REF=main TEMPLATE_BASE_URL=file://$tampered bash -s -- SKIP_BUN_APP=1 SKIP_CLOUDFLARE=1 <"$dist/install.sh" 2>&1 | tee "$log")
assert_file_contains "$log" "TEMPLATE_REF=main differs from v9.9.9; templates are not verified"
assert_file_contains "$log" "templates: not verified (TEMPLATE_REF differs from INSTALLER_REF)"
if grep -q "Checksum OK" "$log"; then
  echo "${RED}Assertion failed:${NC} override run verified templates" >&2
  exit 1
fi
assert_file_contains "$info" 'tampered="yes"'
assert_file_contains "$info" 'template_ref="main"'
