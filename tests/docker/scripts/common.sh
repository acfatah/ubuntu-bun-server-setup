#!/usr/bin/env bash
set -euo pipefail

YELLOW=$(printf '\033[1;33m')
RED=$(printf '\033[0;31m')
NC=$(printf '\033[0m')
INSTALLER="/workspace/install.sh"
LOG_DIR="/tmp/bun-installer"
mkdir -p "$LOG_DIR"

require_root() {
  if [[ $(id -u) -ne 0 ]]; then
    echo "Tests must run as root inside container" >&2
    exit 1
  fi
}

run_installer() {
  local env_args=()
  if [[ $# -gt 0 ]]; then
    env_args=("$@")
  fi
  echo -e "${YELLOW}[test]${NC} Running installer with env: ${env_args[*]:-default}"
  mkdir -p "$LOG_DIR"
  env "${env_args[@]}" bash "$INSTALLER" | tee "$LOG_DIR/install_$(date +%s).log"
}

assert_dir_exists() {
  local dir=$1
  if [[ ! -d "$dir" ]]; then
    echo "${RED}Assertion failed:${NC} $dir does not exist" >&2
    exit 1
  fi
}

assert_file_exists() {
  local file=$1
  if [[ ! -f "$file" ]]; then
    echo "${RED}Assertion failed:${NC} $file does not exist" >&2
    exit 1
  fi
}

assert_file_contains() {
  local file=$1
  local pattern=$2
  if ! grep -q "$pattern" "$file"; then
    echo "${RED}Assertion failed:${NC} $file does not contain '$pattern'" >&2
    exit 1
  fi
}

require_root
