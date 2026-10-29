#!/usr/bin/env bats
# Unit tests for install.sh functions; sourcing it runs no install step.

setup() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  unset SKIP_BUN_APP SKIP_CLOUDFLARE FULL_UPGRADE SKIP_UFW TEMPLATE_REF TEMPLATE_BASE_URL
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
  for name in SKIP_BUN_APP SKIP_CLOUDFLARE FULL_UPGRADE SKIP_UFW; do
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
  for name in SKIP_BUN_APP SKIP_CLOUDFLARE FULL_UPGRADE SKIP_UFW; do
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
  for name in SKIP_BUN_APP SKIP_CLOUDFLARE FULL_UPGRADE SKIP_UFW; do
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
