#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Releases a new version: bumps VERSION, commits "release: vX.Y.Z", creates an
# annotated tag vX.Y.Z and pushes main and the tag to origin in one atomic
# push. The tag triggers .github/workflows/release.yml.
#
# Refuses unless HEAD is on main, equal to origin/main after a fetch, the
# tree is clean, the tag is new, the version goes up and build-installer.sh
# can build the pinned installer. See RELEASE.md.
# ==============================================================================

RELEASE_BRANCH=main
REMOTE=origin
VERSION_FILE=VERSION

if [[ -t 1 ]]; then
  GREEN=$(printf '\033[0;32m')
  YELLOW=$(printf '\033[1;33m')
  RED=$(printf '\033[0;31m')
  NC=$(printf '\033[0m')
else
  GREEN='' YELLOW='' RED='' NC=''
fi

USAGE="Usage:
  release.sh [options]              Prompt for the release type (patch default)
  release.sh [options] patch        Bump patch version (1.0.0 -> 1.0.1)
  release.sh [options] minor        Bump minor version (1.0.0 -> 1.1.0)
  release.sh [options] major        Bump major version (1.0.0 -> 2.0.0)
  release.sh [options] X.Y.Z        Set a specific version

Options:
  -y, --yes          Skip the confirmation (required without a terminal)
  -d, --dry-run      Run every check and print the plan; change nothing
  -h, --help         Show this help message
  --patch, --minor, --major
                     Same as the bare words"

DRY_RUN=false
YES=false
INCREMENT_TYPE=""
NEW_VERSION=""
BUILD_DIR=""
PROBLEMS=()

die() {
  echo -e "${RED}$*${NC}" >&2
  exit 1
}

# Sets DRY_RUN, YES and either INCREMENT_TYPE or NEW_VERSION.
parse_args() {
  local arg
  for arg in "$@"; do
    case $arg in
      -h | --help)
        echo "$USAGE"
        exit 0
        ;;
      -d | --dry-run) DRY_RUN=true ;;
      -y | --yes) YES=true ;;
      --major | --minor | --patch) set_release "${arg#--}" ;;
      major | minor | patch) set_release "$arg" ;;
      -*) die "Unknown option: $arg\n$USAGE" ;;
      *) set_release "$arg" ;;
    esac
  done
}

# Records one release type or version; a second one is an error.
set_release() {
  [[ -z $INCREMENT_TYPE && -z $NEW_VERSION ]] \
    || die "Give one release type or version, not several.\n$USAGE"
  case $1 in
    major | minor | patch) INCREMENT_TYPE=$1 ;;
    *) NEW_VERSION=$1 ;;
  esac
}

# Moves to the top of the work tree, so VERSION and build-installer.sh are
# found from any cwd. Uses git rev-parse: in a linked worktree .git is a file.
require_repo() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not in a git repository"
  cd "$(git rev-parse --show-toplevel)"
  [[ -f $VERSION_FILE ]] || die "$VERSION_FILE file not found"
}

# Fails unless $1 is X.Y.Z.
validate_version() {
  [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "Invalid version '$1'. Use semantic versioning (e.g. 1.0.0)."
}

# Prints $1 bumped by $2 (major, minor or patch).
increment_version() {
  local major minor patch
  IFS=. read -r major minor patch <<<"$1"
  case $2 in
    major) echo "$((10#$major + 1)).0.0" ;;
    minor) echo "$((10#$major)).$((10#$minor + 1)).0" ;;
    patch) echo "$((10#$major)).$((10#$minor)).$((10#$patch + 1))" ;;
    *) die "Invalid increment type '$2'. Use major, minor or patch." ;;
  esac
}

# True when SemVer $1 is greater than $2 (numeric per field).
version_gt() {
  local a b i
  IFS=. read -ra a <<<"$1"
  IFS=. read -ra b <<<"$2"
  for i in 0 1 2; do
    ((10#${a[i]} > 10#${b[i]})) && return 0
    ((10#${a[i]} < 10#${b[i]})) && return 1
  done
  return 1
}

# Asks for the release type on a terminal; patch is the default.
prompt_release_type() {
  local choice
  if [[ ! -t 0 ]]; then
    echo "No terminal; release type defaults to patch." >&2
    echo patch
    return
  fi
  while true; do
    printf 'Select release type:\n  1) patch (default)\n  2) minor\n  3) major\n' >&2
    read -rp "Choice [1-3]: " choice
    case ${choice,,} in
      "" | 1 | patch) echo patch && return ;;
      2 | minor) echo minor && return ;;
      3 | major) echo major && return ;;
      *) echo "Invalid choice: $choice" >&2 ;;
    esac
  done
}

problem() {
  PROBLEMS+=("$*")
}

# Runs every release check and collects failures in PROBLEMS; never exits.
preflight() {
  local target=$1 current=$2 tag=$3
  local branch head remote_head rc err

  branch=$(git symbolic-ref --quiet --short HEAD || true)
  [[ $branch == "$RELEASE_BRANCH" ]] \
    || problem "Not on $RELEASE_BRANCH (on ${branch:-a detached HEAD})"

  git update-index -q --refresh || true # only refreshes stat info
  if ! git diff-index --quiet HEAD -- || ! git diff --cached --quiet; then
    problem "Uncommitted changes to tracked files"
  fi

  if err=$(git fetch --quiet "$REMOTE" "$RELEASE_BRANCH" --tags 2>&1); then
    head=$(git rev-parse HEAD)
    remote_head=$(git rev-parse -q --verify "refs/remotes/$REMOTE/$RELEASE_BRANCH" || true)
    if [[ -z $remote_head ]]; then
      problem "No $REMOTE/$RELEASE_BRANCH after the fetch"
    elif [[ $head != "$remote_head" ]]; then
      if git merge-base --is-ancestor HEAD "$remote_head"; then
        problem "HEAD is behind $REMOTE/$RELEASE_BRANCH; pull first"
      elif git merge-base --is-ancestor "$remote_head" HEAD; then
        problem "HEAD is ahead of $REMOTE/$RELEASE_BRANCH; merge those commits through a PR first"
      else
        problem "HEAD and $REMOTE/$RELEASE_BRANCH have diverged"
      fi
    fi

    rc=0
    git ls-remote --exit-code --tags "$REMOTE" "refs/tags/$tag" >/dev/null 2>&1 || rc=$?
    case $rc in
      0) problem "Tag $tag already exists on $REMOTE" ;;
      2) ;;
      *) problem "Could not list tags on $REMOTE (git ls-remote exit $rc)" ;;
    esac
  else
    problem "git fetch $REMOTE $RELEASE_BRANCH failed: ${err:-no output}"
  fi

  if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    problem "Tag $tag already exists locally"
  fi

  version_gt "$target" "$current" \
    || problem "Target version $target is not greater than $current"

  if ! err=$(./build-installer.sh "$target" "$BUILD_DIR" 2>&1 >/dev/null); then
    problem "build-installer.sh $target failed: ${err:-no output}"
  fi
}

# Prints the release summary, then asks for [y/N] unless --yes was given.
confirm() {
  local current=$1 target=$2 tag=$3 answer
  echo "Release $current -> $target"
  echo "  branch:  $RELEASE_BRANCH"
  echo "  commit:  release: $tag"
  echo "  tag:     $tag (annotated)"
  echo "  push:    $REMOTE ($(git remote get-url "$REMOTE")), atomic"
  [[ $YES == true ]] && return 0
  [[ -t 0 ]] || die "No terminal to confirm on; use --yes to release non-interactively."
  read -rp "Proceed? [y/N] " answer
  [[ ${answer,,} == y || ${answer,,} == yes ]] || die "Aborted; nothing changed."
}

# Writes VERSION, commits, tags and pushes main and the tag atomically. On a
# rejected push, prints the commands that undo the local commit and tag.
release() {
  local target=$1 tag=$2
  echo "$target" >"$VERSION_FILE"
  git add "$VERSION_FILE"
  git commit --quiet -m "release: $tag"
  git tag -a "$tag" -m "Release $tag"
  echo -e "${GREEN}Committed and tagged $tag${NC}"

  if ! git push --atomic "$REMOTE" "$RELEASE_BRANCH" "refs/tags/$tag"; then
    echo -e "${RED}Push rejected; $REMOTE has neither the commit nor the tag.${NC}" >&2
    echo "To undo the local release commit and tag, run:" >&2
    echo "  git tag -d $tag && git reset --soft HEAD~1 && git restore --staged $VERSION_FILE && git checkout $VERSION_FILE" >&2
    exit 1
  fi
  echo -e "${GREEN}Pushed $RELEASE_BRANCH and $tag to $REMOTE${NC}"
}

main() {
  local current target tag problem_line

  parse_args "$@"
  require_repo

  current=$(<"$VERSION_FILE")
  validate_version "$current"
  if [[ -n $NEW_VERSION ]]; then
    validate_version "$NEW_VERSION"
    target=$NEW_VERSION
  else
    [[ -n $INCREMENT_TYPE ]] || INCREMENT_TYPE=$(prompt_release_type)
    target=$(increment_version "$current" "$INCREMENT_TYPE")
  fi
  tag="v$target"
  echo "Current version: $current"
  echo "Target version:  $target"

  BUILD_DIR=$(mktemp -d)
  trap 'rm -rf "$BUILD_DIR"' EXIT
  preflight "$target" "$current" "$tag"

  if ((${#PROBLEMS[@]})); then
    echo -e "${RED}Cannot release $tag:${NC}" >&2
    for problem_line in "${PROBLEMS[@]}"; do
      echo -e "  ${RED}-${NC} $problem_line" >&2
    done
  fi

  if [[ $DRY_RUN == true ]]; then
    if ((${#PROBLEMS[@]} == 0)); then
      echo -e "${GREEN}All checks passed.${NC} Pinned installer:"
      bash "$BUILD_DIR/install.sh" --version | sed 's/^/  /'
    fi
    echo -e "${YELLOW}[DRY RUN]${NC} A real run would:"
    echo "  1. Write $target to $VERSION_FILE (now $current)"
    echo "  2. Commit: release: $tag"
    echo "  3. Create annotated tag $tag"
    echo "  4. git push --atomic $REMOTE $RELEASE_BRANCH refs/tags/$tag"
    ((${#PROBLEMS[@]} == 0)) || exit 1
    exit 0
  fi

  ((${#PROBLEMS[@]} == 0)) || exit 1
  confirm "$current" "$target" "$tag"
  release "$target" "$tag"
  echo -e "${GREEN}Released $tag.${NC} The release workflow builds and publishes it."
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
