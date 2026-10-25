#!/usr/bin/env bats
# Unit tests for templates/motd.sh, with bun, nginx and hostname stubbed.

setup() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  # shellcheck source=install.sh
  source "$REPO_ROOT/install.sh"
  set +u
  STUBS=$BATS_TEST_TMPDIR/stubs
  MOTD=$BATS_TEST_TMPDIR/00-custom
  mkdir -p "$STUBS"
  cp "$REPO_ROOT/templates/motd.sh" "$MOTD"
  replace_placeholder "$MOTD" __NGINX_ROOT__ /var/www/app/dist
  stub bun 'echo 1.2.3'
  stub nginx 'echo "nginx version: nginx/1.24.0 (Ubuntu)" >&2'
  stub hostname 'echo "203.0.113.7 10.0.0.2 "'
}

# Writes an executable $STUBS/$1 that runs the shell code $2.
stub() {
  printf '#!/bin/sh\n%s\n' "$2" >"$STUBS/$1"
  chmod +x "$STUBS/$1"
}

run_motd() {
  PATH="$STUBS:$PATH" DISTRIB_DESCRIPTION="Ubuntu 24.04 LTS" run sh "$MOTD"
}

@test "motd: versions, web root and address" {
  run_motd
  [ "$status" -eq 0 ]
  [[ ${lines[0]} == "Welcome to Ubuntu 24.04 LTS, with Bun v1.2.3 and Nginx v1.24.0 (Ubuntu)." ]]
  [[ $output == *"Nginx root: /var/www/app/dist"* ]]
  [[ $output == *"Public access: http://203.0.113.7"$'\n'* ]]
  [[ $output != *__* ]]
}

@test "motd: failing bun and nginx print version unknown" {
  stub bun 'exit 127'
  stub nginx 'echo "nginx: command not found" >&2; exit 127'
  run_motd
  [ "$status" -eq 0 ]
  [[ ${lines[0]} == *"with Bun (version unknown) and Nginx (version unknown)."* ]]
  [[ $output != *v-unknown* ]]
}

@test "motd: no address prints a placeholder" {
  stub hostname 'echo ""'
  run_motd
  [ "$status" -eq 0 ]
  [[ $output == *"Public access: http://<server-ip>"* ]]
}

@test "motd: the UFW line names no SSH port" {
  run_motd
  [ "$status" -eq 0 ]
  [[ ${lines[1]} == "UFW is enabled: SSH rate-limited, HTTP (80) and HTTPS (443) allowed." ]]
  [[ ${lines[1]} != *22* ]]
}
