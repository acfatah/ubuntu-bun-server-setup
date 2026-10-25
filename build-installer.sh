#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Builds the release installer: install.sh pinned to tag v<version>, with the
# SHA-256 of every template embedded, plus SHA256SUMS covering it.
#
# Usage: ./build-installer.sh <X.Y.Z> [out-dir]   (out-dir default: dist/)
# Reads templates next to this script; writes only to out-dir.
# ==============================================================================

# Byte-order sort, so the embedded list is the same on every host
export LC_ALL=C

GREEN=$(printf '\033[0;32m')
RED=$(printf '\033[0;31m')
NC=$(printf '\033[0m')
USAGE="Usage: build-installer.sh <X.Y.Z> [out-dir]"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() {
  echo -e "${RED}$*${NC}" >&2
  exit 1
}

# Prints "<sha>  <name>" for every template, sorted by name.
template_sums() {
  (cd "$ROOT_DIR/templates" && sha256sum -- *)
}

# Rewrites the three release lines of install.sh (stdin to stdout); fails
# unless each one matched exactly once. Sums come in through ENVIRON: awk
# -v would reject the newlines in them.
pin_installer() {
  local version=$1
  TEMPLATE_SUMS=$(template_sums) awk -v version="$version" -v q="'" '
    $0 == "INSTALLER_VERSION=dev" { print "INSTALLER_VERSION=" version; v++; next }
    $0 == "INSTALLER_REF=main" { print "INSTALLER_REF=v" version; r++; next }
    $0 == "TEMPLATE_SHA256=" q q { print "TEMPLATE_SHA256=" q ENVIRON["TEMPLATE_SUMS"] q; s++; next }
    { print }
    END { exit !(v == 1 && r == 1 && s == 1) }
  '
}

main() {
  local version=${1:-} out_dir=${2:-$ROOT_DIR/dist}
  local installer

  [[ $# -le 2 ]] || die "$USAGE"
  [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid version '${version}'. $USAGE"

  mkdir -p "$out_dir"
  installer="$out_dir/install.sh"
  if ! pin_installer "$version" <"$ROOT_DIR/install.sh" >"$installer"; then
    rm -f "$installer"
    die "install.sh must contain each release line exactly once (INSTALLER_VERSION=dev, INSTALLER_REF=main, TEMPLATE_SHA256='')."
  fi
  chmod 755 "$installer"
  bash -n "$installer"
  (cd "$out_dir" && sha256sum install.sh >SHA256SUMS)

  echo -e "${GREEN}Built $installer (v${version}, $(template_sums | wc -l) templates) and $out_dir/SHA256SUMS${NC}"
}

main "$@"
