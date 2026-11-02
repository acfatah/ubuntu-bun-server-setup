#!/usr/bin/env bash
# Deploys a Bun app to a host set up by ubuntu-bun-server-setup, over SSH.
# See docs/app.md "Deploying". Run it from your machine, not the host.
#
#   deploy.sh [--release | --rollback] <ssh-target> [<src-dir>]
#
# In place (default): rsync <src-dir> (default .) into /srv/app, keeping
#   data and node_modules out of the sync, run bun install on the host,
#   restart bun-app and check its health.
# --release: sync into a new /srv/app-releases/<UTC time> instead, switch
#   the /srv/app symlink to it atomically, restart, keep the last KEEP.
# --rollback: point /srv/app back at the release before the current one.
#
# The SSH user needs passwordless sudo (or is root), and the host needs
# rsync. Environment:
#   KEEP=5            releases kept by --release (the current one always)
#   INSTALLER_PATH=   install.sh on the host; when set, the health check
#                     runs its --check instead of a curl of /healthz
set -euo pipefail

APP_DIR=/srv/app
RELEASES_DIR=/srv/app-releases
KEEP=${KEEP:-5}
INSTALLER_PATH=${INSTALLER_PATH:-}

usage() {
  echo "Usage: $0 [--release | --rollback] <ssh-target> [<src-dir>]" >&2
  exit 2
}

# Runs on the host as root, fed to `sudo bash -s` over SSH. $1 is the
# action, the rest its arguments. The case is the last command, so bash
# has read the whole script before any child could read its stdin.
# shellcheck disable=SC2016 # expanded on the host, not here
REMOTE='
set -euo pipefail
APP_DIR=$1 RELEASES_DIR=$2 KEEP=$3 INSTALLER_PATH=$4 action=$5
shift 5

# bun install as root into the app dir; the service only reads it
install_deps() {
  [[ -f $1/package.json ]] || return 0
  if [[ -f $1/bun.lock || -f $1/bun.lockb ]]; then
    (cd "$1" && /usr/local/bin/bun install --frozen-lockfile --production)
  else
    (cd "$1" && /usr/local/bin/bun install --production)
  fi
}

restart_and_check() {
  systemctl restart bun-app
  if [[ -n $INSTALLER_PATH && -f $INSTALLER_PATH ]]; then
    bash "$INSTALLER_PATH" --check
  else
    # Quiet while bun-app starts (Nginx answers 502 until it listens)
    if ! curl -fs --max-time 5 --retry 10 --retry-connrefused --retry-delay 1 \
      http://127.0.0.1/healthz >/dev/null; then
      echo "Health check failed: /healthz; see journalctl -u bun-app" >&2
      exit 1
    fi
    echo "Health check: /healthz OK"
  fi
}

# Releases oldest first (names sort by time; 0-initial before them all)
releases() {
  find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d | sort
}

# Points /srv/app at $1: a new link renamed over the old one, atomic
switch_to() {
  ln -sfn "$1" "$APP_DIR.new"
  mv -T "$APP_DIR.new" "$APP_DIR"
  echo "Switched $APP_DIR -> $1"
}

case $action in
  check-in-place)
    if [[ -L $APP_DIR ]]; then
      echo "$APP_DIR is a release symlink; deploy with --release" >&2
      exit 1
    fi
    ;;
  finish-in-place)
    install_deps "$APP_DIR"
    restart_and_check
    ;;
  prepare-release)
    if [[ -e $APP_DIR && ! -L $APP_DIR ]]; then
      cat >&2 <<EOF
$APP_DIR is a plain directory. Move it into a first release once, on the
host (bun-app keeps running from the moved dir until the next restart):

  sudo mkdir -p $RELEASES_DIR
  sudo mv $APP_DIR $RELEASES_DIR/0-initial
  sudo ln -s $RELEASES_DIR/0-initial $APP_DIR

Then run deploy.sh --release again.
EOF
      exit 1
    fi
    rel=$RELEASES_DIR/$(date -u +%Y%m%dT%H%M%SZ)
    if [[ -e $rel ]]; then
      echo "$rel exists; wait a second and retry" >&2
      exit 1
    fi
    mkdir -p "$rel"
    echo "$rel"
    ;;
  finish-release)
    rel=$1
    ln -sfn /var/lib/bun-app "$rel/data"
    install_deps "$rel"
    switch_to "$rel"
    restart_and_check
    current=$(readlink -f "$APP_DIR")
    mapfile -t all < <(releases)
    for ((i = 0; i < ${#all[@]} - KEEP; i++)); do
      [[ ${all[i]} == "$current" ]] && continue
      rm -rf -- "${all[i]}"
      echo "Removed old release ${all[i]}"
    done
    ;;
  rollback)
    if [[ ! -L $APP_DIR ]]; then
      echo "$APP_DIR is not a release symlink; nothing to roll back" >&2
      exit 1
    fi
    current=$(readlink -f "$APP_DIR")
    previous=
    while IFS= read -r r; do
      [[ $r == "$current" ]] && break
      previous=$r
    done < <(releases)
    if [[ -z $previous ]]; then
      echo "No release before $current to roll back to" >&2
      exit 1
    fi
    switch_to "$previous"
    restart_and_check
    ;;
esac
'

# Runs one REMOTE action on the host as root
remote() {
  local args
  printf -v args ' %q' "$APP_DIR" "$RELEASES_DIR" "$KEEP" "$INSTALLER_PATH" "$@"
  # shellcheck disable=SC2029 # args are quoted with %q for the remote shell
  ssh "$target" "sudo bash -s --$args" <<<"$REMOTE"
}

# Copies src into dest on the host as root: root-owned, not writable by
# the service, data and node_modules left alone (--delete skips excluded)
sync_to() {
  rsync -a --delete --rsync-path='sudo rsync' \
    --chown=root:root --chmod=go-w,a+rX \
    --exclude /data --exclude /node_modules --exclude /.git \
    "$src/" "$target:$1/"
}

mode=in-place
case ${1:-} in
  --release) mode=release && shift ;;
  --rollback) mode=rollback && shift ;;
  -h | --help) usage ;;
esac
[[ $# -ge 1 && $# -le 2 ]] || usage
target=$1
src=${2:-.}

case $mode in
  in-place)
    [[ -f $src/package.json ]] || {
      echo "No package.json in $src" >&2
      exit 1
    }
    remote check-in-place
    sync_to "$APP_DIR"
    remote finish-in-place
    ;;
  release)
    [[ -f $src/package.json ]] || {
      echo "No package.json in $src" >&2
      exit 1
    }
    rel=$(remote prepare-release)
    sync_to "$rel"
    remote finish-release "$rel"
    ;;
  rollback)
    remote rollback
    ;;
esac
echo "Deployed to $target ($mode)"
