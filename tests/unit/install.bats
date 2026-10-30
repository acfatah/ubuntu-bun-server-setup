#!/usr/bin/env bats
# Unit tests for install.sh functions; sourcing it runs no install step.

setup() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  unset SKIP_BUN_APP SKIP_CLOUDFLARE FULL_UPGRADE SKIP_UPGRADE SKIP_CERTBOT SKIP_UFW TEMPLATE_REF TEMPLATE_BASE_URL BUN_VERSION BUN_DOWNLOAD_BASE_URL
  # shellcheck source=install.sh
  source "$REPO_ROOT/install.sh"
  # install.sh sets -u for itself; bats expects it off
  set +u
  FILE=$BATS_TEST_TMPDIR/file
}

# Writes $1 to FILE, replaces $2 with $3, and compares FILE with $4.
check_replace() {
  printf '%s' "$1" >"$FILE"
  replace_placeholder "$FILE" "$2" "$3"
  local expected=$BATS_TEST_TMPDIR/expected
  printf '%s' "$4" >"$expected"
  diff "$expected" "$FILE"
}

@test "sourcing install.sh runs nothing" {
  run bash -c 'source "$1" && echo sourced' _ "$REPO_ROOT/install.sh"
  [ "$status" -eq 0 ]
  [ "$output" = sourced ]
}

@test "executed and piped runs still reach parse_args" {
  run bash "$REPO_ROOT/install.sh" --version
  [ "$status" -eq 0 ]
  [[ $output == "ubuntu-bun-server-setup dev"* ]]
  run bash -s -- --version <"$REPO_ROOT/install.sh"
  [ "$status" -eq 0 ]
  [[ $output == "ubuntu-bun-server-setup dev"* ]]
}

@test "replace_placeholder: backslash sequences stay literal" {
  check_replace $'a __X__ b\n' __X__ 'x\1y\\z\n' $'a x\\1y\\\\z\\n b\n'
}

@test "replace_placeholder: & | and / stay literal" {
  check_replace $'__X__\n' __X__ 'a&b|c/d' $'a&b|c/d\n'
}

@test "replace_placeholder: a newline in the value" {
  check_replace $'a __X__ b\n' __X__ $'one\ntwo' $'a one\ntwo b\n'
}

@test "replace_placeholder: empty value" {
  check_replace $'a__X__b\n' __X__ '' $'ab\n'
}

@test "replace_placeholder: every occurrence, on one line and across lines" {
  check_replace $'__X__ __X____X__\nno\n__X__\n' __X__ v $'v vv\nno\nv\n'
}

@test "replace_placeholder: special characters in the placeholder" {
  check_replace $'a [.*]\\1 b\n' '[.*]\1' ok $'a ok b\n'
}

@test "replace_placeholder: absent or empty placeholder leaves the file alone" {
  check_replace $'line __Y__\n' __X__ v $'line __Y__\n'
  check_replace $'line __Y__\n' '' v $'line __Y__\n'
}

@test "replace_placeholder: keeps mode and inode" {
  printf 'a __X__\n' >"$FILE"
  chmod 640 "$FILE"
  local inode
  inode=$(stat -c %i "$FILE")
  replace_placeholder "$FILE" __X__ b
  [ "$(stat -c %a "$FILE")" = 640 ]
  [ "$(stat -c %i "$FILE")" = "$inode" ]
  [ "$(cat "$FILE")" = "a b" ]
}

@test "replace_placeholder: a missing file fails" {
  run replace_placeholder "$BATS_TEST_TMPDIR/missing" __X__ v
  [ "$status" -ne 0 ]
}

@test "parse_args: toggles accept empty, 0, false and 1 as argument" {
  local name value
  for name in SKIP_BUN_APP SKIP_CLOUDFLARE FULL_UPGRADE SKIP_UPGRADE SKIP_CERTBOT SKIP_UFW; do
    for value in '' 0 false 1; do
      run parse_args "$name=$value"
      [ "$status" -eq 0 ] || {
        echo "$name=$value: $output"
        return 1
      }
    done
  done
}

@test "parse_args: toggles accept empty, 0, false and 1 from the environment" {
  local name value
  for name in SKIP_BUN_APP SKIP_CLOUDFLARE FULL_UPGRADE SKIP_UPGRADE SKIP_CERTBOT SKIP_UFW; do
    for value in '' 0 false 1; do
      printf -v "$name" '%s' "$value"
      run parse_args
      [ "$status" -eq 0 ] || {
        echo "$name=$value: $output"
        return 1
      }
      unset "$name"
    done
  done
}

@test "parse_args: a toggle set to yes is rejected, as argument and from env" {
  local name
  for name in SKIP_BUN_APP SKIP_CLOUDFLARE FULL_UPGRADE SKIP_UPGRADE SKIP_CERTBOT SKIP_UFW; do
    run parse_args "$name=yes"
    [ "$status" -eq 1 ]
    [[ $output == *"Invalid $name=yes"* ]]
    printf -v "$name" yes
    run parse_args
    [ "$status" -eq 1 ]
    [[ $output == *"Invalid $name=yes"* ]]
    unset "$name"
  done
}

# Checks a run's status $1 and output $2 refuse SKIP_UPGRADE=1 with
# FULL_UPGRADE=1.
conflict_refused() {
  [ "$1" -eq 1 ]
  [[ $2 == *"Invalid combination: SKIP_UPGRADE=1 and FULL_UPGRADE=1"* ]]
  [[ $2 == *Usage:* ]]
}

@test "parse_args: SKIP_UPGRADE=1 with FULL_UPGRADE=1 is rejected" {
  run parse_args SKIP_UPGRADE=1 FULL_UPGRADE=1
  conflict_refused "$status" "$output"
  SKIP_UPGRADE=1 FULL_UPGRADE=1 run parse_args
  conflict_refused "$status" "$output"
  SKIP_UPGRADE=1 run parse_args FULL_UPGRADE=1
  conflict_refused "$status" "$output"
  FULL_UPGRADE=1 run parse_args SKIP_UPGRADE=1
  conflict_refused "$status" "$output"
}

@test "parse_args: SKIP_UPGRADE=1 with FULL_UPGRADE=0 is accepted" {
  run parse_args SKIP_UPGRADE=1 FULL_UPGRADE=0
  [ "$status" -eq 0 ]
}

@test "parse_args: unknown argument" {
  run parse_args FOO=1
  [ "$status" -eq 1 ]
  [[ $output == *"Unknown argument: FOO=1"* ]]
  [[ $output == *Usage:* ]]
}

@test "parse_args: --version and --help exit 0" {
  local arg
  for arg in --version -V; do
    run parse_args "$arg"
    [ "$status" -eq 0 ]
    [[ $output == "ubuntu-bun-server-setup dev"* ]]
  done
  for arg in --help -h; do
    run parse_args "$arg"
    [ "$status" -eq 0 ]
    [[ $output == Usage:* ]]
  done
}

@test "parse_args: TEMPLATE_REF outside the safe set is rejected" {
  local ref
  for ref in ../x a..b 'a b' 'a;b' ''; do
    TEMPLATE_REF=$ref
    run parse_args
    [ "$status" -eq 1 ] || {
      echo "accepted TEMPLATE_REF='$ref'"
      return 1
    }
    [[ $output == *"Invalid TEMPLATE_REF="* ]]
  done
}

@test "parse_args: TEMPLATE_REF tags and branches are accepted" {
  local ref
  for ref in v1.2.3 feature/x main; do
    TEMPLATE_REF=$ref
    run parse_args
    [ "$status" -eq 0 ] || {
      echo "rejected TEMPLATE_REF='$ref': $output"
      return 1
    }
  done
}

@test "parse_args: TEMPLATE_BASE_URL other than https:// or file:// is rejected" {
  local url
  for url in http://example.com/t ftp://example.com/t HTTPS://example.com/t example.com/t file: https://; do
    TEMPLATE_BASE_URL=$url
    run parse_args
    [ "$status" -eq 1 ] || {
      echo "accepted TEMPLATE_BASE_URL='$url'"
      return 1
    }
    [[ $output == *"Invalid TEMPLATE_BASE_URL=$url (use https:// or file://)"* ]]
  done
}

@test "parse_args: TEMPLATE_BASE_URL https:// and file:// are accepted" {
  local url
  for url in https://x/t file:///w/t; do
    TEMPLATE_BASE_URL=$url
    run parse_args
    [ "$status" -eq 0 ] || {
      echo "rejected TEMPLATE_BASE_URL='$url': $output"
      return 1
    }
  done
}

# Stubs curl: logs its arguments one per line, then exits with $1.
stub_curl() {
  CURL_STATUS=$1
  CURL_LOG=$BATS_TEST_TMPDIR/curl.args
  curl() {
    printf '%s\n' "$@" >"$CURL_LOG"
    return "$CURL_STATUS"
  }
}

@test "fetch_url: https or file only, TLS 1.2+, retries and a time cap" {
  stub_curl 0
  fetch_url https://x/t/a "$FILE"
  local args
  args=$(tr '\n' ' ' <"$CURL_LOG")
  [[ $args == *"--proto =https,file "* ]]
  [[ $args == *"--proto-redir =https "* ]]
  [[ $args == *"--tlsv1.2 "* ]]
  [[ $args == *"--retry 3 "* ]]
  [[ $args == *"--max-time 60 "* ]]
  [[ $args == *"https://x/t/a -o $FILE "* ]]
}

@test "fetch_url: fails when curl fails" {
  stub_curl 22
  run fetch_url https://x/t/a "$FILE"
  [ "$status" -eq 22 ]
}

@test "fetch_url: a third argument overrides the time cap" {
  stub_curl 0
  fetch_url https://x/t/a "$FILE" 600
  local args
  args=$(tr '\n' ' ' <"$CURL_LOG")
  [[ $args == *"--max-time 600 "* ]]
}

@test "parse_args: BUN_VERSION defaults to the pin" {
  [ "$BUN_VERSION" = "$BUN_PINNED_VERSION" ]
  [[ $BUN_PINNED_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "parse_args: BUN_VERSION X.Y.Z and latest are accepted, as argument and from env" {
  local value
  for value in 1.4.3 latest 10.0.12; do
    run parse_args "BUN_VERSION=$value"
    [ "$status" -eq 0 ] || {
      echo "argument BUN_VERSION=$value: $output"
      return 1
    }
    BUN_VERSION=$value
    run parse_args
    [ "$status" -eq 0 ] || {
      echo "env BUN_VERSION=$value: $output"
      return 1
    }
  done
}

@test "parse_args: an invalid BUN_VERSION is rejected, as argument and from env" {
  local value
  for value in yes 1.4 v1.4.4 1.4.4-canary '1.4.4 ' '' 'latest '; do
    run parse_args "BUN_VERSION=$value"
    [ "$status" -eq 1 ] || {
      echo "accepted argument BUN_VERSION='$value'"
      return 1
    }
    [[ $output == *"Invalid BUN_VERSION=$value (use X.Y.Z or latest)"* ]]
    [[ $output == *Usage:* ]]
  done
  for value in yes 1.4 v1.4.4 1.4.4-canary '1.4.4 '; do
    BUN_VERSION=$value
    run parse_args --version
    [ "$status" -eq 1 ] || {
      echo "accepted env BUN_VERSION='$value'"
      return 1
    }
    [[ $output == *"Invalid BUN_VERSION=$value (use X.Y.Z or latest)"* ]]
  done
}

@test "an invalid BUN_VERSION exits before the root check" {
  run bash "$REPO_ROOT/install.sh" BUN_VERSION=yes
  [ "$status" -eq 1 ]
  [[ $output == *"Invalid BUN_VERSION=yes"* ]]
  [[ $output != *"must be run as root"* ]]
}

@test "parse_args: BUN_DOWNLOAD_BASE_URL other than https:// or file:// is rejected" {
  local url
  for url in http://example.com/b ftp://example.com/b example.com/b https://; do
    BUN_DOWNLOAD_BASE_URL=$url
    run parse_args
    [ "$status" -eq 1 ] || {
      echo "accepted BUN_DOWNLOAD_BASE_URL='$url'"
      return 1
    }
    [[ $output == *"Invalid BUN_DOWNLOAD_BASE_URL=$url (use https:// or file://)"* ]]
  done
}

@test "parse_args: BUN_DOWNLOAD_BASE_URL https:// and file:// are accepted" {
  local url
  for url in https://mirror/bun file:///root/bun-mirror; do
    BUN_DOWNLOAD_BASE_URL=$url
    run parse_args
    [ "$status" -eq 0 ] || {
      echo "rejected BUN_DOWNLOAD_BASE_URL='$url': $output"
      return 1
    }
  done
}

@test "BUN_PINNED_SHA256: one sha256 per supported asset" {
  local asset
  [ "$(wc -l <<<"$BUN_PINNED_SHA256")" -eq 3 ]
  for asset in bun-linux-x64.zip bun-linux-x64-baseline.zip bun-linux-aarch64.zip; do
    grep -Eq "^[0-9a-f]{64}  $asset\$" <<<"$BUN_PINNED_SHA256" || {
      echo "no sum for $asset"
      return 1
    }
  done
}

# Stubs uname to print machine $1, and points CPUINFO at a file whose
# flags line is $2.
fake_cpu() {
  UNAME_M=$1
  uname() { echo "$UNAME_M"; }
  CPUINFO=$BATS_TEST_TMPDIR/cpuinfo
  printf 'processor\t: 0\nflags\t\t: %s\n' "$2" >"$CPUINFO"
}

@test "bun_asset: x64 with AVX2, x64 without, aarch64" {
  fake_cpu x86_64 'fpu sse4_2 avx avx2 bmi2'
  [ "$(bun_asset)" = bun-linux-x64.zip ]
  fake_cpu x86_64 'fpu sse4_2 avx'
  [ "$(bun_asset)" = bun-linux-x64-baseline.zip ]
  fake_cpu aarch64 'fp asimd'
  [ "$(bun_asset)" = bun-linux-aarch64.zip ]
}

@test "bun_asset: an unreadable cpuinfo picks the x64 baseline build" {
  fake_cpu x86_64 avx2
  CPUINFO=$BATS_TEST_TMPDIR/missing
  [ "$(bun_asset)" = bun-linux-x64-baseline.zip ]
}

@test "bun_asset: another architecture is refused" {
  fake_cpu riscv64 ''
  run bun_asset
  [ "$status" -eq 1 ]
  [[ $output == *"Unsupported architecture for Bun: riscv64"* ]]
}

# Stubs curl: logs its arguments, copies file $1 to the -o path, or prints
# $2 for -w; exits with $3 (default 0).
stub_curl_serving() {
  CURL_BODY=$1 CURL_OUT=${2:-} CURL_STATUS=${3:-0}
  CURL_LOG=$BATS_TEST_TMPDIR/curl.args
  curl() {
    printf '%s\n' "$@" >>"$CURL_LOG"
    local out=""
    while [[ $# -gt 0 ]]; do
      [[ $1 == -o ]] && out=$2
      shift
    done
    [[ $CURL_STATUS -eq 0 ]] || return "$CURL_STATUS"
    if [[ $out != /dev/null && -n $CURL_BODY ]]; then
      cat "$CURL_BODY" >"$out"
    fi
    printf '%s' "$CURL_OUT"
  }
}

@test "bun_expected_sha: the pin uses the embedded sum, no download" {
  stub_curl_serving ''
  local expected
  expected=$(awk '$2 == "bun-linux-aarch64.zip" {print $1}' <<<"$BUN_PINNED_SHA256")
  [ "$(bun_expected_sha "$BUN_PINNED_VERSION" bun-linux-aarch64.zip "$BATS_TEST_TMPDIR")" = "$expected" ]
  [ ! -e "$CURL_LOG" ]
}

@test "bun_expected_sha: another version reads its release's SHASUMS256.txt" {
  local sums=$BATS_TEST_TMPDIR/sums sha
  sha=$(printf '%064d' 7)
  printf '%s  bun-linux-x64-profile.zip\n%s  bun-linux-x64.zip\n' "$(printf '%064d' 1)" "$sha" >"$sums"
  stub_curl_serving "$sums"
  mkdir "$BATS_TEST_TMPDIR/work"
  [ "$(bun_expected_sha 1.4.3 bun-linux-x64.zip "$BATS_TEST_TMPDIR/work")" = "$sha" ]
  grep -qx "https://github.com/oven-sh/bun/releases/download/bun-v1.4.3/SHASUMS256.txt" "$CURL_LOG"
}

@test "bun_expected_sha: a missing entry or a failed download fails" {
  local sums=$BATS_TEST_TMPDIR/sums
  printf '%s  bun-linux-x64-baseline.zip\n' "$(printf '%064d' 1)" >"$sums"
  stub_curl_serving "$sums"
  run bun_expected_sha 1.4.3 bun-linux-x64.zip "$BATS_TEST_TMPDIR"
  [ "$status" -eq 1 ]
  [[ $output == *"No checksum for bun-linux-x64.zip in Bun 1.4.3"* ]]
  stub_curl_serving "$sums" '' 22
  run bun_expected_sha 1.4.3 bun-linux-x64-baseline.zip "$BATS_TEST_TMPDIR"
  [ "$status" -eq 1 ]
  [[ $output == *"Could not download SHASUMS256.txt for Bun 1.4.3"* ]]
}

@test "resolve_bun_version: X.Y.Z is used as is, with no lookup" {
  stub_curl_serving ''
  BUN_VERSION=1.4.3
  [ "$(resolve_bun_version)" = 1.4.3 ]
  [ ! -e "$CURL_LOG" ]
}

@test "resolve_bun_version: latest follows the release redirect" {
  stub_curl_serving '' https://github.com/oven-sh/bun/releases/tag/bun-v1.5.0
  BUN_VERSION=latest
  [ "$(resolve_bun_version)" = 1.5.0 ]
  local args
  args=$(tr '\n' ' ' <"$CURL_LOG")
  [[ $args == *"--proto =https "* ]]
  [[ $args == *"--tlsv1.2 "* ]]
}

@test "resolve_bun_version: latest with an odd tag or a failed lookup fails" {
  BUN_VERSION=latest
  stub_curl_serving '' https://github.com/oven-sh/bun/releases/tag/bun-v1.5.0-canary
  run resolve_bun_version
  [ "$status" -eq 1 ]
  [[ $output == *"unexpected tag"* ]]
  stub_curl_serving '' '' 6
  run resolve_bun_version
  [ "$status" -eq 1 ]
  [[ $output == *"Could not look up the latest Bun release"* ]]
}

@test "print_version: dev channel says templates are not verified" {
  run print_version
  [ "$status" -eq 0 ]
  [[ $output == *"templates: not verified (dev channel)"* ]]
}

@test "print_version: a release build on its own ref says verified" {
  INSTALLER_REF=v9.9.9 TEMPLATE_REF=v9.9.9 TEMPLATE_SHA256='abc  motd.sh'
  run print_version
  [ "$status" -eq 0 ]
  [[ $output == *"templates: verified against embedded SHA-256 sums"* ]]
}

@test "print_version: a release build on another ref says not verified" {
  INSTALLER_REF=v9.9.9 TEMPLATE_REF=main TEMPLATE_SHA256='abc  motd.sh'
  run print_version
  [ "$status" -eq 0 ]
  [[ $output == *"templates: not verified (TEMPLATE_REF differs from INSTALLER_REF)"* ]]
}

@test "print_version: the pinned Bun is verified against embedded sums" {
  run print_version
  [ "$status" -eq 0 ]
  [[ $output == *"bun: $BUN_PINNED_VERSION (pinned $BUN_PINNED_VERSION, verified against embedded SHA-256)"* ]]
}

@test "print_version: another Bun is verified against its SHASUMS256.txt" {
  local value
  for value in 1.4.3 latest; do
    BUN_VERSION=$value
    run print_version
    [ "$status" -eq 0 ]
    [[ $output == *"bun: $value (pinned $BUN_PINNED_VERSION, verified against the release's SHASUMS256.txt)"* ]]
  done
}

@test "parse_args: SKIP_BUN_APP=1 serves the stock web root" {
  [ "$NGINX_ROOT" = /var/www/app/dist ]
  parse_args
  [ "$NGINX_ROOT" = /var/www/app/dist ]
  parse_args SKIP_BUN_APP=1
  [ "$NGINX_ROOT" = /var/www/html ]
}

# Writes a fake os-release with the given lines and points OS_RELEASE at it.
fake_os_release() {
  OS_RELEASE=$BATS_TEST_TMPDIR/os-release
  printf '%s\n' "$@" >"$OS_RELEASE"
}

@test "require_ubuntu: 20.04 is refused" {
  fake_os_release 'ID=ubuntu' 'VERSION_ID="20.04"'
  run require_ubuntu
  [ "$status" -eq 1 ]
  [[ $output == *"22.04 or later"* ]]
  [[ $output == *"Detected: 20.04."* ]]
}

@test "require_ubuntu: 22.04 and later pass" {
  local v
  for v in 22.04 24.04 26.04; do
    fake_os_release 'ID=ubuntu' "VERSION_ID=\"$v\""
    run require_ubuntu
    [ "$status" -eq 0 ] || {
      echo "refused $v: $output"
      return 1
    }
  done
}

@test "require_ubuntu: another distribution is refused" {
  fake_os_release 'ID=debian' 'VERSION_ID="12"'
  run require_ubuntu
  [ "$status" -eq 1 ]
  [[ $output == *"targets Ubuntu"* ]]
}

@test "require_ubuntu: a missing or malformed VERSION_ID is refused" {
  fake_os_release 'ID=ubuntu'
  run require_ubuntu
  [ "$status" -eq 1 ]
  [[ $output == *"Cannot read"* ]]
  fake_os_release 'ID=ubuntu' 'VERSION_ID="22"'
  run require_ubuntu
  [ "$status" -eq 1 ]
  [[ $output == *"Cannot read"* ]]
}

@test "require_ubuntu: a missing os-release is refused" {
  OS_RELEASE=$BATS_TEST_TMPDIR/absent
  run require_ubuntu
  [ "$status" -eq 1 ]
  [[ $output == *"not found"* ]]
}

# Stubs apt-get and sleep for apt_update: apt-get fails its first $1 calls,
# and both log their arguments, one call per line.
stub_apt() {
  APT_FAILS=$1
  APT_LOG=$BATS_TEST_TMPDIR/apt-get
  SLEEP_LOG=$BATS_TEST_TMPDIR/sleep
  : >"$APT_LOG"
  : >"$SLEEP_LOG"
  apt-get() {
    echo "$*" >>"$APT_LOG"
    [ "$(wc -l <"$APT_LOG")" -gt "$APT_FAILS" ]
  }
  sleep() { echo "$*" >>"$SLEEP_LOG"; }
  APT_UPDATE_DELAY=7
}

@test "apt_update: succeeds on the first try without retrying" {
  stub_apt 0
  run apt_update
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$APT_LOG")" -eq 1 ]
  [[ $(cat "$APT_LOG") == *Acquire::Retries=3*update ]]
  [ ! -s "$SLEEP_LOG" ]
  [[ $output != *retrying* ]]
}

@test "apt_update: recovers on the third try" {
  stub_apt 2
  run apt_update
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$APT_LOG")" -eq 3 ]
  [[ $output == *"attempt 1/3"* ]]
  [[ $output == *"attempt 2/3"* ]]
  [ "$(cat "$SLEEP_LOG")" = $'7\n7' ]
}

@test "apt_update: fails after the last try, with no sleep after it" {
  stub_apt 99
  run apt_update
  [ "$status" -eq 1 ]
  [ "$(wc -l <"$APT_LOG")" -eq 3 ]
  [ "$(wc -l <"$SLEEP_LOG")" -eq 2 ]
  [[ $output == *"failed after 3 attempts"* ]]
}

@test "upgrade_packages: plain upgrade by default" {
  stub_apt 0
  run upgrade_packages
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$APT_LOG")" -eq 1 ]
  [[ $(cat "$APT_LOG") == *" upgrade" ]]
  [[ $output == *"Upgrading packages (apt-get upgrade)"* ]]
}

@test "upgrade_packages: FULL_UPGRADE=1 runs full-upgrade" {
  stub_apt 0
  FULL_UPGRADE=1
  run upgrade_packages
  [ "$status" -eq 0 ]
  [[ $(cat "$APT_LOG") == *" full-upgrade" ]]
}

@test "upgrade_packages: SKIP_UPGRADE=1 calls no apt-get" {
  stub_apt 0
  SKIP_UPGRADE=1
  run upgrade_packages
  [ "$status" -eq 0 ]
  [ ! -s "$APT_LOG" ]
  [[ $output == *"Skipping package upgrade (SKIP_UPGRADE=1)."* ]]
  [[ $output != *Upgrading* ]]
}

# Stubs the three commands require_snapd reads: systemctl is-enabled
# prints SERVICE_STATE and SOCKET_STATE, dpkg-query prints DPKG_STATUS
# (failing when empty, as for a package dpkg never saw) and apt-cache
# policy shows CANDIDATE. Each logs its name to SNAPD_LOG.
stub_snapd() {
  SERVICE_STATE=$1 SOCKET_STATE=$2 DPKG_STATUS=$3 CANDIDATE=$4
  SNAPD_LOG=$BATS_TEST_TMPDIR/snapd
  : >"$SNAPD_LOG"
  systemctl() {
    echo systemctl >>"$SNAPD_LOG"
    printf '%s\n%s\n' "$SERVICE_STATE" "$SOCKET_STATE"
    [ "$SERVICE_STATE" = enabled ]
  }
  dpkg-query() {
    echo dpkg-query >>"$SNAPD_LOG"
    [ -n "$DPKG_STATUS" ] || return 1
    printf '%s' "$DPKG_STATUS"
  }
  apt-cache() {
    echo apt-cache >>"$SNAPD_LOG"
    printf 'snapd:\n  Installed: (none)\n  Candidate: %s\n' "$CANDIDATE"
  }
}

@test "require_snapd: SKIP_CERTBOT=1 checks nothing" {
  stub_snapd masked masked '' '(none)'
  SKIP_CERTBOT=1
  run require_snapd
  [ "$status" -eq 0 ]
  [ ! -s "$SNAPD_LOG" ]
}

@test "require_snapd: installed and enabled passes" {
  stub_snapd enabled enabled 'install ok installed' 2.66
  run require_snapd
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "require_snapd: a masked service or socket is refused" {
  local states
  for states in 'masked enabled' 'enabled masked' 'masked masked'; do
    # shellcheck disable=SC2086 # two words on purpose
    stub_snapd $states 'install ok installed' 2.66
    run require_snapd
    [ "$status" -eq 1 ] || {
      echo "accepted $states: $output"
      return 1
    }
    [[ $output == *"snapd is masked"* ]]
    [[ $output == *"systemctl unmask snapd.service snapd.socket"* ]]
    [[ $output == *"SKIP_CERTBOT=1"* ]]
  done
}

@test "require_snapd: not installed with an apt candidate passes" {
  local status_line
  for status_line in '' 'deinstall ok config-files'; do
    stub_snapd disabled disabled "$status_line" 2.66
    run require_snapd
    [ "$status" -eq 0 ] || {
      echo "refused '$status_line': $output"
      return 1
    }
  done
}

@test "require_snapd: not installed with no apt candidate is refused" {
  local candidate
  for candidate in '(none)' ''; do
    stub_snapd disabled disabled '' "$candidate"
    run require_snapd
    [ "$status" -eq 1 ] || {
      echo "accepted candidate '$candidate': $output"
      return 1
    }
    [[ $output == *"snapd is not installed and apt cannot install it"* ]]
    [[ $output == *"SKIP_CERTBOT=1"* ]]
  done
}

@test "take_lock: succeeds while the lock is free" {
  LOCK_FILE=$BATS_TEST_TMPDIR/lock
  run take_lock
  [ "$status" -eq 0 ]
  [ -e "$LOCK_FILE" ]
}

@test "take_lock: refuses while another process holds the lock" {
  LOCK_FILE=$BATS_TEST_TMPDIR/lock
  exec 8>"$LOCK_FILE"
  flock -n 8
  run take_lock
  exec 8>&-
  [ "$status" -eq 1 ]
  [[ $output == *"Another installer run is in progress (lock: $LOCK_FILE)"* ]]
}

# Points APP_INFO_FILE at the test dir; with an argument, writes it as an
# earlier run would, with ufw="$1" ("legacy" writes no ufw= line).
earlier_info() {
  APP_INFO_FILE=$BATS_TEST_TMPDIR/application.info
  [ $# -gt 0 ] || return 0
  printf 'application_name="Bun.sh"\n' >"$APP_INFO_FILE"
  [ "$1" = legacy ] || printf 'ufw="%s"\n' "$1" >>"$APP_INFO_FILE"
}

# Stubs ufw (reporting status $1: active or inactive) and ssh_ports; ufw
# logs its arguments to UFW_LOG, one call per line.
stub_ufw() {
  UFW_STATUS=$1
  UFW_LOG=$BATS_TEST_TMPDIR/ufw
  : >"$UFW_LOG"
  ufw() {
    echo "$*" >>"$UFW_LOG"
    case $1 in
      status) echo "Status: $UFW_STATUS" ;;
      app) echo "  Nginx Full" ;;
    esac
  }
  ssh_ports() { echo 22; }
}

# True when the stubbed ufw was asked to enable, set a policy or add a rule.
ufw_changed() {
  grep -qE '^(--force enable|default|limit|allow)' "$UFW_LOG"
}

# A bare "! ufw_changed" would never fail a test (see not_gt in release.bats)
ufw_unchanged() {
  ! ufw_changed
}

# Runs configure_ufw and checks UFW_STATE is $1 and ufw_changed is $2.
check_ufw() {
  configure_ufw
  [ "$UFW_STATE" = "$1" ] || {
    echo "UFW_STATE=$UFW_STATE, expected $1"
    return 1
  }
  if [ "$2" = changed ]; then
    ufw_changed
  else
    ufw_unchanged
  fi
}

@test "previous_ufw_state: no file, each recorded value, legacy file" {
  earlier_info
  [ -z "$(previous_ufw_state)" ]
  local state
  for state in enabled skipped left-disabled legacy; do
    earlier_info "$state"
    [ "$(previous_ufw_state)" = "$state" ]
  done
}

@test "configure_ufw: SKIP_UFW=1 touches nothing" {
  earlier_info enabled
  stub_ufw inactive
  SKIP_UFW=1
  check_ufw skipped unchanged
  [ ! -s "$UFW_LOG" ]
}

@test "configure_ufw: an active UFW gets its rules" {
  earlier_info left-disabled
  stub_ufw active
  check_ufw enabled changed
  grep -qx 'limit 22/tcp' "$UFW_LOG"
  grep -qx 'allow Nginx Full' "$UFW_LOG"
  ! grep -q '^default' "$UFW_LOG" || return 1
}

# Checks an inactive UFW gets the default policy, rules and enable.
check_ufw_enabled() {
  stub_ufw inactive
  check_ufw enabled changed
  grep -qx 'default deny incoming' "$UFW_LOG"
  grep -qx 'limit 22/tcp' "$UFW_LOG"
  grep -qx -- '--force enable' "$UFW_LOG"
}

@test "configure_ufw: inactive on a first install is enabled" {
  earlier_info
  check_ufw_enabled
}

@test "configure_ufw: inactive after an earlier SKIP_UFW=1 run is enabled" {
  earlier_info skipped
  check_ufw_enabled
}

@test "configure_ufw: inactive after an earlier enable is left disabled" {
  local earlier
  for earlier in enabled left-disabled legacy; do
    earlier_info "$earlier"
    stub_ufw inactive
    check_ufw left-disabled unchanged
    [[ $(configure_ufw) == *"left disabled"* ]]
  done
}

# Stubs the health checks' commands: $1..$4 are 1 (healthy) or 0 for
# nginx, bun-app, the /healthz probe and certbot. NGINX_SITE gets the
# /healthz location; every call is logged to HEALTH_LOG.
stub_health() {
  NGINX_UP=$1 APP_UP=$2 PROBE_OK=$3 CERTBOT_OK=$4
  HEALTH_LOG=$BATS_TEST_TMPDIR/health
  : >"$HEALTH_LOG"
  NGINX_SITE=$BATS_TEST_TMPDIR/site
  printf 'server {\n  location = /healthz {\n  }\n}\n' >"$NGINX_SITE"
  systemctl() {
    echo "systemctl $*" >>"$HEALTH_LOG"
    case $* in
      *nginx) [ "$NGINX_UP" = 1 ] ;;
      *bun-app) [ "$APP_UP" = 1 ] ;;
      *) return 1 ;;
    esac
  }
  curl() {
    echo "curl $*" >>"$HEALTH_LOG"
    [ "$PROBE_OK" = 1 ] || return 22
    echo ok
  }
  certbot() {
    echo certbot >>"$HEALTH_LOG"
    [ "$CERTBOT_OK" = 1 ]
  }
  snap() { return 1; }
  # Root unless AS_ROOT=0, whoever runs the tests
  is_root() { [ "${AS_ROOT:-1}" = 1 ]; }
}

# Stubs with $1..$4 (see stub_health), checks everything, and expects
# exactly one problem containing $5.
one_problem() {
  stub_health "$1" "$2" "$3" "$4"
  health_problems 1 1
  [ "${#PROBLEMS[@]}" -eq 1 ] || {
    echo "problems: ${PROBLEMS[*]}"
    return 1
  }
  [[ ${PROBLEMS[0]} == *"$5"* ]]
}

@test "health_problems: a healthy host has no problems" {
  stub_health 1 1 1 1
  health_problems 1 1
  [ "${#PROBLEMS[@]}" -eq 0 ]
  [ "${#CHECKS[@]}" -eq 4 ]
}

@test "health_problems: each failure is one problem" {
  one_problem 0 1 1 1 "Nginx is not active"
  one_problem 1 0 1 1 "Service 'bun-app' is not active"
  one_problem 1 1 0 1 "Health probe failed; see: curl -i http://127.0.0.1/healthz"
  one_problem 1 1 1 0 "Certbot does not run"
}

@test "health_problems: as non-root, Certbot is the link, not certbot --version" {
  stub_health 1 1 1 0
  AS_ROOT=0
  CERTBOT_BIN=$BATS_TEST_TMPDIR/certbot
  printf '#!/bin/sh\n' >"$BATS_TEST_TMPDIR/real-certbot"
  chmod 755 "$BATS_TEST_TMPDIR/real-certbot"
  ln -s "$BATS_TEST_TMPDIR/real-certbot" "$CERTBOT_BIN"
  health_problems 1 1
  [ "${#PROBLEMS[@]}" -eq 0 ]
  run grep -c '^certbot' "$HEALTH_LOG"
  [ "$output" = 0 ]
  rm "$BATS_TEST_TMPDIR/real-certbot"
  health_problems 1 1
  [[ ${PROBLEMS[*]} == *"Certbot does not run"* ]]
}

@test "health_problems: the probe retries through Nginx on 127.0.0.1" {
  stub_health 1 1 1 1
  health_problems 1 1
  grep -q -- '--retry 5 --retry-connrefused --retry-delay 1 http://127.0.0.1/healthz$' "$HEALTH_LOG"
}

@test "health_problems: app and certbot off skip their checks" {
  stub_health 1 0 0 0
  health_problems 0 0
  [ "${#PROBLEMS[@]}" -eq 0 ]
  [ "${CHECKS[*]}" = "Nginx is active" ]
  [ "$(cat "$HEALTH_LOG")" = "systemctl is-active --quiet nginx" ]
}

@test "health_problems: a site without the /healthz location is not probed" {
  stub_health 1 1 0 1
  printf 'server {\n}\n' >"$NGINX_SITE"
  health_problems 1 1
  [ "${#PROBLEMS[@]}" -eq 0 ]
  [ "${#CHECKS[@]}" -eq 3 ]
  run grep -c '^curl' "$HEALTH_LOG"
  [ "$output" = 0 ]
}

@test "run_check: no installation found" {
  stub_health 1 1 1 1
  earlier_info
  run run_check
  [ "$status" -eq 1 ]
  [[ $output == *"No installation found ($APP_INFO_FILE is missing)"* ]]
  [ ! -s "$HEALTH_LOG" ]
}

@test "run_check: no unit and no certbot check only Nginx" {
  stub_health 1 0 0 0
  earlier_info enabled
  BUN_APP_UNIT=$BATS_TEST_TMPDIR/bun-app.service
  CERTBOT_BIN=$BATS_TEST_TMPDIR/certbot
  run run_check
  [ "$status" -eq 0 ]
  [[ $output == *"Health check: OK"*"Nginx is active"* ]]
  [[ $output != *bun-app* && $output != *Certbot* ]]
}

@test "run_check: the unit and a dangling certbot link are checked" {
  stub_health 1 1 1 0
  earlier_info enabled
  BUN_APP_UNIT=$BATS_TEST_TMPDIR/bun-app.service
  touch "$BUN_APP_UNIT"
  CERTBOT_BIN=$BATS_TEST_TMPDIR/certbot
  ln -s "$BATS_TEST_TMPDIR/missing" "$CERTBOT_BIN"
  run run_check
  [ "$status" -eq 1 ]
  [[ $output == *"problems found"*"Certbot does not run"* ]]
  grep -q 'is-active --quiet bun-app' "$HEALTH_LOG"
  grep -q '^curl' "$HEALTH_LOG"
}

@test "parse_args: --check exits 0 or 1 and takes no lock" {
  LOCK_FILE=$BATS_TEST_TMPDIR/lock
  BUN_APP_UNIT=$BATS_TEST_TMPDIR/bun-app.service
  CERTBOT_BIN=$BATS_TEST_TMPDIR/certbot
  earlier_info enabled
  stub_health 1 1 1 1
  run parse_args --check
  [ "$status" -eq 0 ]
  stub_health 0 1 1 1
  run parse_args -c
  [ "$status" -eq 1 ]
  [ ! -e "$LOCK_FILE" ]
}

@test "--check runs before the root check" {
  run bash "$REPO_ROOT/install.sh" --check
  [[ $output == *"Health check: "* ]]
  [[ $output != *"must be run as root"* ]]
}
