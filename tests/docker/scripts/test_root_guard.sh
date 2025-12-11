#!/usr/bin/env bash
set -euo pipefail

RED=$(printf '\033[0;31m')
NC=$(printf '\033[0m')
INSTALLER="/workspace/install.sh"

# ensure installer fails when not root
if sudo -u tester bash -c "bash '$INSTALLER'"; then
  echo "${RED}Installer should have failed when not root${NC}" >&2
  exit 1
fi

# success: nothing else to verify
