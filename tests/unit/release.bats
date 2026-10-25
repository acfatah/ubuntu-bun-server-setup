#!/usr/bin/env bats
# Unit tests for release.sh's version helpers and build-installer.sh's
# version check. tests/release/run.sh covers the release flow itself.

setup() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  # shellcheck source=release.sh
  source "$REPO_ROOT/release.sh"
  # release.sh sets -u for itself; bats expects it off
  set +u
}

@test "increment_version: patch, minor and major" {
  [ "$(increment_version 1.2.3 patch)" = 1.2.4 ]
  [ "$(increment_version 1.2.3 minor)" = 1.3.0 ]
  [ "$(increment_version 1.2.3 major)" = 2.0.0 ]
  [ "$(increment_version 0.9.9 patch)" = 0.9.10 ]
}

@test "increment_version: unknown type fails" {
  run increment_version 1.2.3 build
  [ "$status" -eq 1 ]
  [[ $output == *"Invalid increment type 'build'"* ]]
}

@test "version_gt: compares each field as a number" {
  version_gt 1.10.0 1.9.0
  version_gt 2.0.0 1.99.99
  version_gt 1.2.4 1.2.3
}

# A bare "! cmd" never fails a bats test (set -e ignores it); a function
# returning the negation does.
not_gt() {
  ! version_gt "$@"
}

@test "version_gt: equal or lower is not greater" {
  not_gt 1.2.3 1.2.3
  not_gt 1.9.0 1.10.0
  not_gt 1.2.3 1.3.0
}

@test "validate_version: accepts X.Y.Z" {
  local v
  for v in 0.0.0 1.2.3 10.20.30; do
    run validate_version "$v"
    [ "$status" -eq 0 ] || {
      echo "rejected $v"
      return 1
    }
  done
}

@test "validate_version: rejects other forms and leading zeros" {
  local v
  for v in 1.2 v1.2.3 1.2.3.4 1.2.3-rc.1 01.2.3 1.02.3 1.2.03 '' a.b.c; do
    run validate_version "$v"
    [ "$status" -eq 1 ] || {
      echo "accepted '$v'"
      return 1
    }
    [[ $output == *"Invalid version"* ]]
  done
}

@test "build-installer.sh: rejects leading zeros" {
  run "$REPO_ROOT/build-installer.sh" 08.09.09 "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 1 ]
  [[ $output == *"Invalid version '08.09.09'"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/out/install.sh" ]
}

@test "build-installer.sh: pins the version it is given" {
  run "$REPO_ROOT/build-installer.sh" 1.2.3 "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  run bash "$BATS_TEST_TMPDIR/out/install.sh" --version
  [ "$status" -eq 0 ]
  [[ $output == "ubuntu-bun-server-setup 1.2.3"* ]]
  [[ $output == *"templates: v1.2.3 from "* ]]
}
