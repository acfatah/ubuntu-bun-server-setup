#!/usr/bin/env bash
# Test: Astro static and SSR (cookbook)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/docker/scripts/common.sh
. "$SCRIPT_DIR/common.sh"

# Follows docs/cookbook/astro.md: the static example copied into the web
# root, then the SSR example deployed with deploy.sh behind the
# dist/client link. Needs the npm registry for bun install.
STATIC_EXAMPLE=/workspace/docs/examples/astro-static
SSR_EXAMPLE=/workspace/docs/examples/astro
DEPLOY=/workspace/docs/examples/deploy.sh
WORK=/root/astro-app
LINK_TARGET=/srv/app/dist/client
export ASTRO_TELEMETRY_DISABLED=1
mkdir -p "$WORK"

# Prints the body of a request through Nginx; retries while bun-app starts
get() {
  curl --retry 10 --retry-all-errors --retry-delay 1 -fsS "http://127.0.0.1$1"
}

# Copies example $1 to $2 without local build output (the repo mount may
# hold a developer's node_modules, dist or .astro), then builds it as the
# page does on your machine: bun install, bun run build.
build_copy() {
  rm -rf "$2"
  cp -r "$1" "$2"
  rm -rf "$2/node_modules" "$2/dist" "$2/.astro"
  (cd "$2" && /usr/local/bin/bun install --frozen-lockfile && /usr/local/bin/bun run build)
}

# Checks the page at / shows $1, and its stylesheet under /assets/ has
# exactly one Cache-Control header
assert_page() {
  local page css cache_lines
  page=$(get /)
  if [[ $page != *"$1"* ]]; then
    echo "${RED}Assertion failed:${NC} / does not show '$1': $page" >&2
    exit 1
  fi
  css=$(grep -o '/assets/[^"]*\.css' <<<"$page" | head -n1)
  [[ -n $css ]]
  cache_lines=$(curl -fsSI "http://127.0.0.1$css" | grep -ci '^cache-control:')
  assert_equals "Cache-Control headers on $css" 1 "$cache_lines"
}

# Prints the visits counter of /api/x for the session in cookie jar $1
visits() {
  curl -fsS -b "$1" -c "$1" http://127.0.0.1/api/x | jq -r .visits
}

run_installer SKIP_UPGRADE=1 SKIP_CERTBOT=1
setup_local_ssh
host=tester@localhost

# Static site: built, then copied with the page's rsync and modes
echo -e "${YELLOW}[test]${NC} static Astro site in /var/www/app/dist"
build_copy "$STATIC_EXAMPLE" "$WORK/static"
(
  cd "$WORK/static"
  rsync -a --delete --rsync-path='sudo rsync' dist/ "$host":/var/www/app/dist/
  ssh "$host" 'sudo chown -R root:root /var/www/app/dist &&
  sudo find /var/www/app/dist -type d -exec chmod 755 {} + &&
  sudo find /var/www/app/dist -type f -exec chmod 644 {} +'
)
assert_page "Hello from static Astro"
assert_equals "static file owner" root "$(stat -c %U /var/www/app/dist/index.html)"

# The page's link, made before any SSR deploy, is dangling: a re-run
# refuses before changing anything, with no trap line
echo -e "${YELLOW}[test]${NC} a dangling web-root link stops a re-run"
rm -rf /var/www/app/dist && ln -s /srv/app/dist/client /var/www/app/dist
log=/root/astro-dangling.log
if SKIP_UPGRADE=1 SKIP_CERTBOT=1 bash "$INSTALLER" >"$log" 2>&1; then
  cat "$log"
  echo "${RED}Assertion failed:${NC} installer ran with a dangling web-root link" >&2
  exit 1
fi
cat "$log"
assert_file_contains "$log" "/var/www/app/dist is a symlink to a missing path (/srv/app/dist/client)."
assert_file_contains "$log" "remove the link: sudo rm /var/www/app/dist"
if grep -q "install failed at line\|Updating package lists" "$log"; then
  echo "${RED}Assertion failed:${NC} the trap or apt ran before the refusal" >&2
  exit 1
fi
assert_equals "link after the refusal" "$LINK_TARGET" "$(readlink /var/www/app/dist)"

# SSR: HOST in the env file, build, deploy.sh
echo -e "${YELLOW}[test]${NC} SSR example deployed with deploy.sh"
echo 'HOST=127.0.0.1' >>/etc/bun-app.env
build_copy "$SSR_EXAMPLE" "$WORK/ssr"
"$DEPLOY" "$host" "$WORK/ssr"

assert_equals "/healthz" ok "$(get /healthz)"
assert_equals "/healthz Cache-Control" "no-store" \
  "$(curl -fsSI http://127.0.0.1/healthz | awk -F': ' 'tolower($1) == "cache-control" {print $2}' | tr -d '\r')"
api=$(get /api/x)
assert_equals "path" /api/x "$(jq -r .path <<<"$api")"
assert_equals "message" "Hello from Astro" "$(jq -r .message <<<"$api")"
assert_page "Hello from Astro"
assert_file_contains /var/www/app/dist/index.html "Hello from Astro"
assert_equals "code owner" root "$(stat -c %U /srv/app/dist/server/entry.mjs)"

# The prerendered page comes from the link, not from Bun
systemctl stop bun-app
assert_page "Hello from Astro"
systemctl start bun-app
get /healthz >/dev/null # listening again before ss looks

listeners=$(ss -Hltn 'sport = :3000' | awk '{print $4}')
assert_equals "port 3000 listeners" "127.0.0.1:3000" "$listeners"

# Sessions live in the state dir and survive a restart
jar=$WORK/cookies
rm -f "$jar"
get /healthz >/dev/null
assert_equals "visits, first request" 1 "$(visits "$jar")"
assert_equals "visits, second request" 2 "$(visits "$jar")"
systemctl restart bun-app
get /healthz >/dev/null
assert_equals "visits after a restart" 3 "$(visits "$jar")"
assert_dir_exists /var/lib/bun-app/sessions
[[ -n $(find /var/lib/bun-app/sessions -type f) ]]
if journalctl -u bun-app --no-pager | grep -q ENOENT; then
  journalctl -u bun-app --no-pager | tail -n 30
  echo "${RED}Assertion failed:${NC} bun-app logged ENOENT" >&2
  exit 1
fi

# A re-run keeps the app and the link
echo -e "${YELLOW}[test]${NC} installer re-run keeps the Astro app and the link"
cp /srv/app/package.json "$WORK/package.json.orig"
run_installer SKIP_UPGRADE=1 SKIP_CERTBOT=1
cmp /srv/app/package.json "$WORK/package.json.orig"
[[ ! -e /srv/app/server.ts ]]
assert_equals "link after a re-run" "$LINK_TARGET" "$(readlink /var/www/app/dist)"
assert_page "Hello from Astro"
bash "$INSTALLER" --check

# Release dirs: client files switch and roll back with the code
echo -e "${YELLOW}[test]${NC} --release and --rollback switch the client files"
mkdir -p /srv/app-releases
mv /srv/app /srv/app-releases/0-initial
ln -s /srv/app-releases/0-initial /srv/app

rm -rf "$WORK/ssr-v2"
cp -r "$SSR_EXAMPLE" "$WORK/ssr-v2"
sed -i "s/^const MESSAGE = .*/const MESSAGE = 'Hello from Astro v2';/" "$WORK/ssr-v2/src/pages/index.astro"
build_copy "$WORK/ssr-v2" "$WORK/ssr-v2-build"
"$DEPLOY" --release "$host" "$WORK/ssr-v2-build"
assert_page "Hello from Astro v2"
assert_equals "/healthz after a release" ok "$(get /healthz)"

"$DEPLOY" --rollback "$host"
assert_equals "release after rollback" /srv/app-releases/0-initial "$(readlink -f /srv/app)"
page=$(get /)
if [[ $page == *"Hello from Astro v2"* ]]; then
  echo "${RED}Assertion failed:${NC} / still shows v2 after --rollback" >&2
  exit 1
fi
assert_page "Hello from Astro"
bash "$INSTALLER" --check

echo "astro app test passed"
