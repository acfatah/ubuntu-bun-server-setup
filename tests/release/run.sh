#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Tests release.sh against a throwaway clone with a bare origin. Needs only
# git and bash; touches nothing outside a mktemp directory.
#
# Usage: tests/release/run.sh
# ==============================================================================

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Keep the user's git config (hooks, signing, aliases) out of the tests
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com

PASSED=0
FAILED=0
WORK=""
OUT=""
RC=0
T_FAILED=0

cleanup() {
  [[ -z $WORK ]] || rm -rf "$WORK"
}
trap cleanup EXIT

# Creates $WORK/origin.git and a clone $WORK/repo at VERSION 1.2.3 on main.
setup() {
  cleanup
  WORK=$(mktemp -d)
  git init --quiet --bare --initial-branch=main "$WORK/origin.git"
  git init --quiet --initial-branch=main "$WORK/repo"
  cp "$ROOT_DIR/release.sh" "$ROOT_DIR/build-installer.sh" "$ROOT_DIR/install.sh" "$WORK/repo/"
  cp -r "$ROOT_DIR/templates" "$WORK/repo/"
  echo 1.2.3 >"$WORK/repo/VERSION"
  git -C "$WORK/repo" add -A
  git -C "$WORK/repo" commit --quiet -m init
  git -C "$WORK/repo" remote add origin "$WORK/origin.git"
  git -C "$WORK/repo" push --quiet -u origin main
}

# Runs $dir/release.sh with the remaining args, stdin closed; sets OUT, RC.
# The cwd is $CWD when set (to run it from elsewhere), else $dir.
release() {
  local dir=$1
  shift
  RC=0
  OUT=$(cd "${CWD:-$dir}" && "$dir/release.sh" "$@" </dev/null 2>&1) || RC=$?
}

# Pushes one more commit to origin/main from a second clone.
advance_origin() {
  git clone --quiet "$WORK/origin.git" "$WORK/other"
  echo change >"$WORK/other/other.txt"
  git -C "$WORK/other" add other.txt
  git -C "$WORK/other" commit --quiet -m other
  git -C "$WORK/other" push --quiet origin main
}

# Marks the running test failed; tests run in an if, where set -e is off.
fail() {
  local line
  T_FAILED=1
  echo "    $*"
  echo "    --- output (exit $RC) ---"
  while IFS= read -r line; do echo "    $line"; done <<<"$OUT"
  return 1
}

expect_rc() {
  [[ $RC -eq $1 ]] || fail "expected exit $1, got $RC"
}

expect_out() {
  grep -qF -- "$1" <<<"$OUT" || fail "output lacks: $1"
}

# Nothing released: VERSION 1.2.3, one commit, no tags, here or on origin.
expect_unreleased() {
  [[ $(cat "$WORK/repo/VERSION") == 1.2.3 ]] || fail "VERSION changed"
  [[ $(git -C "$WORK/repo" rev-list --count HEAD) -le 2 ]] || fail "extra commits"
  [[ -z $(git -C "$WORK/repo" tag) ]] || fail "local tag created"
  [[ -z $(git -C "$WORK/origin.git" tag) ]] || fail "tag pushed"
  [[ $(git -C "$WORK/origin.git" log -1 --format=%s main) != release:* ]] || fail "release commit pushed"
}

test_requires_yes_without_tty() {
  release "$WORK/repo" minor
  expect_rc 1 && expect_out "use --yes" && expect_unreleased
}

test_happy_path() {
  release "$WORK/repo" minor --yes
  expect_rc 0 || return 1
  [[ $(cat "$WORK/repo/VERSION") == 1.3.0 ]] || fail "VERSION is not 1.3.0"
  [[ $(git -C "$WORK/repo" log -1 --format=%s) == "release: v1.3.0" ]] || fail "commit message"
  [[ $(git -C "$WORK/repo" cat-file -t v1.3.0) == tag ]] || fail "tag is not annotated"
  [[ $(git -C "$WORK/origin.git" cat-file -t v1.3.0) == tag ]] || fail "tag not on origin"
  [[ $(git -C "$WORK/origin.git" rev-parse main) == $(git -C "$WORK/repo" rev-parse HEAD) ]] \
    || fail "origin/main is not the release commit"
}

test_linked_worktree_dry_run() {
  # main can be checked out in one worktree only; newer git refuses -B
  git -C "$WORK/repo" checkout --quiet --detach
  git -C "$WORK/repo" worktree add --quiet "$WORK/wt" main
  [[ $(git -C "$WORK/wt" symbolic-ref --short HEAD) == main ]] || fail "setup: worktree is not on main"
  CWD="$WORK/wt/templates" release "$WORK/wt" --dry-run patch
  expect_rc 0 && expect_out "All checks passed" && expect_out "ubuntu-bun-server-setup 1.2.4"
}

test_off_main() {
  git -C "$WORK/repo" checkout --quiet -b topic
  release "$WORK/repo" patch --yes
  expect_rc 1 && expect_out "Not on main (on topic)" && expect_unreleased
}

test_dirty_tree() {
  echo dirty >>"$WORK/repo/install.sh"
  release "$WORK/repo" patch --yes
  expect_rc 1 && expect_out "Uncommitted changes" && expect_unreleased
}

test_staged_change() {
  echo new >"$WORK/repo/new.txt"
  git -C "$WORK/repo" add new.txt
  release "$WORK/repo" patch --yes
  expect_rc 1 && expect_out "Uncommitted changes" && expect_unreleased
}

test_untracked_allowed() {
  echo scratch >"$WORK/repo/scratch.txt"
  release "$WORK/repo" --dry-run patch
  expect_rc 0 && expect_out "All checks passed"
}

test_behind_origin() {
  advance_origin
  release "$WORK/repo" patch --yes
  expect_rc 1 && expect_out "behind origin/main" && expect_unreleased
}

test_ahead_of_origin() {
  echo local >"$WORK/repo/local.txt"
  git -C "$WORK/repo" add local.txt
  git -C "$WORK/repo" commit --quiet -m local
  release "$WORK/repo" patch --yes
  expect_rc 1 && expect_out "ahead of origin/main" || return 1
  [[ -z $(git -C "$WORK/repo" tag) ]] || fail "local tag created"
}

test_local_tag_exists() {
  git -C "$WORK/repo" tag v1.2.4
  release "$WORK/repo" patch --yes
  expect_rc 1 && expect_out "Tag v1.2.4 already exists locally"
}

test_remote_tag_exists() {
  git -C "$WORK/repo" tag v1.2.4
  git -C "$WORK/repo" push --quiet origin v1.2.4
  git -C "$WORK/repo" tag -d v1.2.4 >/dev/null
  # Fetch prunes nothing, so it brings the tag back; ls-remote also sees it
  release "$WORK/repo" patch --yes
  expect_rc 1 && expect_out "Tag v1.2.4 already exists on origin"
}

test_same_version() {
  release "$WORK/repo" 1.2.3 --yes
  expect_rc 1 && expect_out "not greater than 1.2.3" && expect_unreleased
}

test_lower_version() {
  release "$WORK/repo" 1.0.0 --yes
  expect_rc 1 && expect_out "not greater than 1.2.3" && expect_unreleased
}

test_broken_slot_line() {
  sed -i 's/^INSTALLER_REF=main$/INSTALLER_REF=other/' "$WORK/repo/install.sh"
  git -C "$WORK/repo" commit --quiet -am "break slot"
  git -C "$WORK/repo" push --quiet origin main
  release "$WORK/repo" patch --yes
  expect_rc 1 && expect_out "build-installer.sh 1.2.4 failed"
}

test_dry_run_with_problems() {
  advance_origin
  echo dirty >>"$WORK/repo/install.sh"
  release "$WORK/repo" --dry-run minor
  expect_rc 1 && expect_out "behind origin/main" && expect_out "Uncommitted changes" \
    && expect_out "[DRY RUN]" && expect_unreleased || return 1
  [[ $(git -C "$WORK/origin.git" rev-list --count main) -eq 2 ]] || fail "origin changed"
}

test_rejected_push() {
  printf '#!/bin/sh\necho "rejected by test hook" >&2\nexit 1\n' >"$WORK/origin.git/hooks/pre-receive"
  chmod +x "$WORK/origin.git/hooks/pre-receive"
  release "$WORK/repo" patch --yes
  expect_rc 1 && expect_out "Push rejected" && expect_out "git tag -d v1.2.4 && git reset --soft HEAD~1" || return 1
  [[ -z $(git -C "$WORK/origin.git" tag) ]] || fail "tag reached origin"
  [[ $(git -C "$WORK/origin.git" log -1 --format=%s main) == init ]] || fail "commit reached origin"
  # The printed unwind restores the pre-release state
  (cd "$WORK/repo" && git tag -d v1.2.4 >/dev/null && git reset --quiet --soft HEAD~1 \
    && git restore --staged VERSION && git checkout --quiet VERSION)
  [[ -z $(git -C "$WORK/repo" status --short) ]] || fail "unwind left changes"
  expect_unreleased
}

test_unknown_flag() {
  release "$WORK/repo" --bogus
  expect_rc 1 && expect_out "Unknown option: --bogus"
}

test_help() {
  release "$WORK/repo" --help
  expect_rc 0 && expect_out "--yes"
}

main() {
  local t
  for t in $(declare -F | awk '$3 ~ /^test_/ { print $3 }'); do
    setup
    if (
      T_FAILED=0
      "$t" || T_FAILED=1
      exit "$T_FAILED"
    ); then
      echo "PASS $t"
      PASSED=$((PASSED + 1))
    else
      echo "FAIL $t"
      FAILED=$((FAILED + 1))
    fi
  done
  echo "$PASSED passed, $FAILED failed"
  ((FAILED == 0))
}

main "$@"
