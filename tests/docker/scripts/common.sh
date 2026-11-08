#!/usr/bin/env bash
set -euo pipefail

YELLOW=$(printf '\033[1;33m')
RED=$(printf '\033[0;31m')
NC=$(printf '\033[0m')
INSTALLER="/workspace/install.sh"
# Not /tmp: boot-time systemd-tmpfiles-setup empties it, and a file
# written before it ran was gone when the test read it back.
LOG_DIR="/root/bun-installer-test"
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

# apt-get update with the installer's retry (3 tries, 10 s apart), for
# test steps that install packages themselves; a flaky mirror is not a
# test failure.
apt_update_retry() {
  local try
  for try in 1 2 3; do
    apt-get -qqy -o Acquire::Retries=3 update && return 0
    ((try < 3)) || break
    echo -e "${YELLOW}[test]${NC} apt-get update failed (attempt ${try}/3); retrying in 10s..." >&2
    sleep 10
  done
  return 1
}

# Lets root deploy over SSH to tester@localhost, as docs/examples/deploy.sh
# does to a real host: installs openssh-server and rsync, gives the image's
# tester user passwordless sudo and root's ed25519 key, and records the
# host key in root's known_hosts (retried while sshd starts).
setup_local_ssh() {
  apt_update_retry
  apt-get install -qqy --no-install-recommends openssh-server openssh-client rsync >/dev/null
  mkdir -p /run/sshd
  systemctl start ssh
  echo 'tester ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/tester
  chmod 440 /etc/sudoers.d/tester
  mkdir -p /root/.ssh /home/tester/.ssh
  [[ -f /root/.ssh/id_ed25519 ]] || ssh-keygen -q -t ed25519 -N '' -f /root/.ssh/id_ed25519
  cp /root/.ssh/id_ed25519.pub /home/tester/.ssh/authorized_keys
  chown -R tester:tester /home/tester/.ssh
  chmod 700 /home/tester/.ssh
  for _ in $(seq 10); do
    ssh-keyscan -t ed25519 localhost >/root/.ssh/known_hosts 2>/dev/null && [[ -s /root/.ssh/known_hosts ]] && break
    sleep 1
  done
  [[ -s /root/.ssh/known_hosts ]]
}

# Holds an fcntl write lock on $1 for $2 seconds, as another apt or dpkg
# would; run it with &. Exits non-zero at once when the lock is taken.
# apt uses fcntl locks, so flock(1) would not block it. struct flock is
# packed as "s s x4 q q i x4" (l_type, l_whence, pad, l_start, l_len,
# l_pid, pad): the 64-bit Linux layout, on x86_64 and aarch64.
hold_apt_lock() {
  perl -MFcntl -e '
    open(my $fh, ">>", $ARGV[0]) or die "open $ARGV[0]: $!\n";
    my $lock = pack("s s x4 q q i x4", F_WRLCK, 0, 0, 0, 0);
    fcntl($fh, F_SETLK, $lock) or die "lock $ARGV[0]: $!\n";
    print "held $ARGV[0]\n";
    sleep $ARGV[1];
  ' "$1" "$2"
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

assert_equals() {
  local label=$1
  local expected=$2
  local actual=$3
  if [[ "$actual" != "$expected" ]]; then
    echo "${RED}Assertion failed:${NC} $label: expected '$expected', got '$actual'" >&2
    exit 1
  fi
}

require_root
