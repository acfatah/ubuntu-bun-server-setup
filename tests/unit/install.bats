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
