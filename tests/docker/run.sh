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
IMAGE_NAME=${BUN_INSTALLER_TEST_IMAGE:-ubuntu-bun-installer/test-harness}

cleanup_containers=()
cleanup() {
  for name in "${cleanup_containers[@]}"; do
    docker rm -f "$name" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

build_image() {
  echo -e "${YELLOW}[tests]${NC} Building Docker image '$IMAGE_NAME'..."
  docker build -t "$IMAGE_NAME" -f "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR"
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
  local scripts=("test_root_guard.sh" "test_default.sh" "test_skip_sample.sh")
  if [[ $# -gt 0 ]]; then
    scripts=()
    for arg in "$@"; do
      if [[ $arg == *.sh ]]; then
        scripts+=("$arg")
      else
        scripts+=("${arg}.sh")
      fi
    done
  fi

  build_image
  for script in "${scripts[@]}"; do
    case $script in
      test_root_guard.sh)
        run_test "$script" "root guard"
        ;;
      test_default.sh)
        run_test "$script" "default install"
        ;;
      test_skip_sample.sh)
        run_test "$script" "SKIP_BUN_APP install + idempotency"
        ;;
      *)
        echo "Unknown test script: $script" >&2
        exit 1
        ;;
    esac
  done
}

main "$@"
