#!/usr/bin/env bats
# Unit tests for install.sh functions; sourcing it runs no install step.

setup() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  unset SKIP_BUN_APP SKIP_CLOUDFLARE FULL_UPGRADE TEMPLATE_REF TEMPLATE_BASE_URL
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
  for name in SKIP_BUN_APP SKIP_CLOUDFLARE FULL_UPGRADE; do
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
  for name in SKIP_BUN_APP SKIP_CLOUDFLARE FULL_UPGRADE; do
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
  for name in SKIP_BUN_APP SKIP_CLOUDFLARE FULL_UPGRADE; do
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
