#!/usr/bin/env bash
set -euo pipefail

YELLOW=$(printf '\033[1;33m')
RED=$(printf '\033[0;31m')
GREEN=$(printf '\033[1;32m')

NC=$(printf '\033[0m')

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is required to run these tests." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
UBUNTU_VERSION=${UBUNTU_VERSION:-22.04}
IMAGE_NAME=${BUN_INSTALLER_TEST_IMAGE:-ubuntu-bun-installer/test-harness:${UBUNTU_VERSION}}

cleanup_containers=()
cleanup() {
  for name in "${cleanup_containers[@]}"; do
    docker rm -f "$name" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

build_image() {
  echo -e "${YELLOW}[tests]${NC} Building Docker image '$IMAGE_NAME' (Ubuntu $UBUNTU_VERSION)..."
  docker build -t "$IMAGE_NAME" \
    --build-arg UBUNTU_VERSION="$UBUNTU_VERSION" \
    -f "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR"
}

# Label from the script's "# Test: <label>" header, else its file name.
test_label() {
  local script=$1
  local label
  label=$(sed -n '/^# Test: /{s///p;q}' "$SCRIPT_DIR/scripts/$script")
  echo "${label:-$script}"
}

start_container() {
  local name=$1
  docker run -d --rm \
    --name "$name" \
    --privileged \
    --cgroupns=host \
    --tmpfs /tmp \
    --tmpfs /run \
    --tmpfs /run/lock \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    -v "$REPO_ROOT":/workspace:ro \
    "$IMAGE_NAME" >/dev/null
}

run_test() {
  local script=$1
  local display=$2
  local name="bun-installer-${script//\//-}-$$"

  echo -e "${YELLOW}[tests]${NC} Starting '$display'..."
  start_container "$name"
  cleanup_containers+=("$name")

  set +e
  docker exec "$name" bash -lc "cd /workspace && tests/docker/scripts/$script"
  local status=$?
  set -e

  docker stop "$name" >/dev/null 2>&1 || true

  if [[ $status -ne 0 ]]; then
    echo -e "${YELLOW}[tests]${NC} '$display' ${RED}FAILED${NC}" >&2
    exit $status
  fi
  echo -e "${YELLOW}[tests]${NC} '$display' ${GREEN}passed${NC}"
}

main() {
  local scripts=()
  if [[ $# -gt 0 ]]; then
    local arg
    for arg in "$@"; do
      [[ $arg == *.sh ]] || arg="${arg}.sh"
      if [[ $arg != test_*.sh || ! -f "$SCRIPT_DIR/scripts/$arg" ]]; then
        echo "Unknown test script: $arg" >&2
        exit 1
      fi
      scripts+=("$arg")
    done
  else
    local path
    for path in "$SCRIPT_DIR"/scripts/test_*.sh; do
      scripts+=("${path##*/}")
    done
  fi

  build_image
  local script
  for script in "${scripts[@]}"; do
    run_test "$script" "$(test_label "$script")"
  done
}

main "$@"
