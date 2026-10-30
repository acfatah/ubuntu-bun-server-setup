#!/usr/bin/env bash
# Test: Bun pin
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/docker/scripts/common.sh
. "$SCRIPT_DIR/common.sh"

INSTALL_LOG=/var/log/bun-installer.log
BUN_BIN=/usr/local/bin/bun
RELEASES=https://github.com/oven-sh/bun/releases/download
# Re-runs skip what this test does not need, to save time
FAST=(SKIP_UPGRADE=1 SKIP_CERTBOT=1)
PINNED=$(sed -n 's/^BUN_PINNED_VERSION=//p' "$INSTALLER")
# The zip this host gets: the installer's own choice
ASSET=$(bash -c 'source "$1" && bun_asset' _ "$INSTALLER")
# Under /root: files under /tmp went missing during installs (CLAUDE.md)
MIRROR=/root/bun-mirror

fail() {
  echo "${RED}Assertion failed:${NC} $*" >&2
  exit 1
}

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

# Fails if /usr/local/bin holds a leftover .bun.* temp file.
assert_no_bun_temp() {
  if compgen -G '/usr/local/bin/.bun.*' >/dev/null; then
    fail "temp file left in /usr/local/bin: $(echo /usr/local/bin/.bun.*)"
  fi
}

echo -e "${YELLOW}[test]${NC} BUN_VERSION=yes is rejected before anything is written"
if out=$(bash "$INSTALLER" BUN_VERSION=yes 2>&1); then
  fail "BUN_VERSION=yes was accepted"
fi
grep -q "Invalid BUN_VERSION=yes (use X.Y.Z or latest)" <<<"$out"
[[ ! -e $INSTALL_LOG ]] || fail "a refused run wrote $INSTALL_LOG"
[[ ! -e $BUN_BIN ]] || fail "$BUN_BIN exists before any install"

echo -e "${YELLOW}[test]${NC} a tampered zip fails before /usr/local/bin is touched"
# The fresh image has no CA bundle yet; the installer would add it later
apt_update_retry
apt-get install -qqy ca-certificates >/dev/null
mkdir -p "$MIRROR/bun-v$PINNED"
curl -fsSL --retry 3 -o "$MIRROR/bun-v$PINNED/$ASSET" "$RELEASES/bun-v$PINNED/$ASSET"
printf 'x' >>"$MIRROR/bun-v$PINNED/$ASSET"
if out=$(run_installer BUN_DOWNLOAD_BASE_URL="file://$MIRROR" "${FAST[@]}" 2>&1); then
  fail "an install from a tampered zip succeeded"
fi
grep -q "Bun $ASSET failed its checksum" <<<"$out" || fail "no checksum message: $out"
grep -q "install failed at line" <<<"$out" || fail "no trap message"
[[ ! -e $BUN_BIN ]] || fail "$BUN_BIN written from a tampered zip"
assert_no_bun_temp

echo -e "${YELLOW}[test]${NC} default run installs the pinned Bun"
before=$(log_lines)
run_installer "${FAST[@]}" >/dev/null
assert_equals "bun version" "$PINNED" "$("$BUN_BIN" --version)"
log_since "$before" | grep -q "Checksum OK: $ASSET (embedded)" || fail "no embedded checksum line"
assert_file_contains /var/lib/app-info/application.info "^application_version=\"$PINNED\"\$"

echo -e "${YELLOW}[test]${NC} a bad SHASUMS256.txt fails and keeps the installed Bun"
cp "$BUN_BIN" /root/bun.saved
mkdir -p "$MIRROR/bun-v1.4.3"
echo "not the zip" >"$MIRROR/bun-v1.4.3/$ASSET"
printf '%064d  %s\n' 0 "$ASSET" >"$MIRROR/bun-v1.4.3/SHASUMS256.txt"
if out=$(run_installer BUN_VERSION=1.4.3 BUN_DOWNLOAD_BASE_URL="file://$MIRROR" "${FAST[@]}" 2>&1); then
  fail "an install against a bad SHASUMS256.txt succeeded"
fi
grep -q "Bun $ASSET failed its checksum" <<<"$out" || fail "no checksum message: $out"
cmp "$BUN_BIN" /root/bun.saved || fail "$BUN_BIN changed after a failed check"
assert_no_bun_temp

echo -e "${YELLOW}[test]${NC} BUN_VERSION=1.4.3 replaces the pinned Bun"
before=$(log_lines)
run_installer BUN_VERSION=1.4.3 "${FAST[@]}" >/dev/null
log_since "$before" | grep -q "Replacing Bun $PINNED with 1.4.3" || fail "no replace line"
log_since "$before" | grep -q "Checksum OK: $ASSET (SHASUMS256.txt)" || fail "no SHASUMS256.txt checksum line"
assert_equals "bun version" 1.4.3 "$("$BUN_BIN" --version)"
assert_equals "bun-app user runs bun" 1.4.3 "$(runuser -u bun-app -- "$BUN_BIN" --version)"
assert_file_contains /var/lib/app-info/application.info '^application_version="1.4.3"$'

echo -e "${YELLOW}[test]${NC} a default re-run brings Bun back to the pin"
before=$(log_lines)
run_installer "${FAST[@]}" >/dev/null
log_since "$before" | grep -q "Replacing Bun 1.4.3 with $PINNED" || fail "no replace line"
assert_equals "bun version" "$PINNED" "$("$BUN_BIN" --version)"
assert_equals "bunx link" bun "$(readlink /usr/local/bin/bunx)"

echo -e "${YELLOW}[test]${NC} the same version is left alone"
stamp=$(stat -c '%i %Y' "$BUN_BIN")
before=$(log_lines)
run_installer "${FAST[@]}" >/dev/null
log_since "$before" | grep -q "Bun $PINNED already installed" || fail "no already-installed line"
if log_since "$before" | grep -q "Downloading Bun"; then
  fail "a matching Bun was downloaded again"
fi
assert_equals "bun inode and mtime" "$stamp" "$(stat -c '%i %Y' "$BUN_BIN")"

echo -e "${YELLOW}[test]${NC} BUN_VERSION=latest installs the newest release"
before=$(log_lines)
run_installer BUN_VERSION=latest "${FAST[@]}" >/dev/null
latest=$("$BUN_BIN" --version)
[[ $latest =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "latest Bun reports '$latest'"
if ! log_since "$before" | grep -Eq "Bun $latest already installed|Replacing Bun $PINNED with $latest"; then
  fail "log does not name the resolved version $latest"
fi
systemctl is-active --quiet bun-app || fail "bun-app is not active"
