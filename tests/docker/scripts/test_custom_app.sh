#!/usr/bin/env bash
# Test: custom app replace, release dirs, deploy.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/docker/scripts/common.sh
. "$SCRIPT_DIR/common.sh"

EXAMPLE=/workspace/docs/examples/hono
DEPLOY=/workspace/docs/examples/deploy.sh
WORK=/root/custom-app
mkdir -p "$WORK"

# Prints the body of a request through Nginx; retries while bun-app starts
get() {
  curl --retry 10 --retry-all-errors --retry-delay 1 -fsS "http://127.0.0.1$1"
}

# Prints the visit counter from /api/x, which also bumps it
visits() {
  get /api/x | jq -r .visits
}

# Copies the example to $1 with its message changed to $2
example_copy() {
  rm -rf "$1"
  cp -r "$EXAMPLE" "$1"
  rm -rf "$1/node_modules"
  sed -i "s/^const MESSAGE = .*/const MESSAGE = \"$2\";/" "$1/src/index.ts"
}

assert_message() {
  assert_equals "message on /api/x" "$1" "$(get /api/x | jq -r .message)"
}

run_installer SKIP_UPGRADE=1 SKIP_CERTBOT=1
get / | grep -q "Hello Bun"

# Replace the sample with the Hono example, as docs/app.md says
echo -e "${YELLOW}[test]${NC} replace the sample with the Hono example"
find /srv/app -mindepth 1 -maxdepth 1 ! -name data -exec rm -rf {} +
cp -r "$EXAMPLE/." /srv/app/
rm -rf /srv/app/node_modules
(cd /srv/app && /usr/local/bin/bun install --frozen-lockfile --production)
systemctl restart bun-app
assert_equals "/healthz" ok "$(get /healthz)"
api=$(get /api/x)
assert_equals "message" "Hello from Hono" "$(jq -r .message <<<"$api")"
assert_equals "path" /api/x "$(jq -r .path <<<"$api")"
first=$(jq -r .visits <<<"$api")
assert_equals "visits after one more request" "$((first + 1))" "$(visits)"
assert_file_exists /var/lib/bun-app/app.sqlite

# A re-run keeps the replaced app: no sample server.ts, same package.json
echo -e "${YELLOW}[test]${NC} installer re-run keeps the replaced app"
cp /srv/app/package.json "$WORK/package.json.orig"
run_installer SKIP_UPGRADE=1 SKIP_CERTBOT=1
cmp /srv/app/package.json "$WORK/package.json.orig"
[[ ! -e /srv/app/server.ts ]]
assert_message "Hello from Hono"
bash "$INSTALLER" --check

# Static frontend beside the API
echo -e "${YELLOW}[test]${NC} static dist beside /api/"
mkdir -p /var/www/app/dist/assets
echo '<!doctype html><title>Custom SPA</title>' >/var/www/app/dist/index.html
echo 'console.log("app")' >/var/www/app/dist/assets/app.js
chmod 644 /var/www/app/dist/index.html /var/www/app/dist/assets/app.js
get / | grep -q "Custom SPA"
cache_lines=$(curl -fsSI http://127.0.0.1/assets/app.js | grep -ci '^cache-control:')
assert_equals "Cache-Control headers on /assets/" 1 "$cache_lines"
assert_message "Hello from Hono"
spa=$(curl -sS http://127.0.0.1/some/route)
assert_equals "SPA path falls back to Bun" "Hello from Hono: no route for /some/route" "$spa"

# deploy.sh over SSH to localhost, as a sudo user
echo -e "${YELLOW}[test]${NC} deploy.sh over local SSH"
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
target=tester@localhost

before=$(visits)
example_copy "$WORK/v2" "Hello from v2"
"$DEPLOY" "$target" "$WORK/v2"
assert_message "Hello from v2"
assert_equals "visits after deploy (data kept)" "$((before + 2))" "$(visits)"
[[ -L /srv/app/data ]]
assert_equals "code owner" root "$(stat -c %U /srv/app/src/index.ts)"

# --release onto a plain dir refuses with the migration hint
echo -e "${YELLOW}[test]${NC} deploy.sh --release and --rollback"
example_copy "$WORK/v3" "Hello from v3"
if out=$("$DEPLOY" --release "$target" "$WORK/v3" 2>&1); then
  echo "${RED}Assertion failed:${NC} --release onto a plain dir was accepted" >&2
  exit 1
fi
grep -q "0-initial" <<<"$out"
[[ ! -L /srv/app ]]

# The hint's migration, verbatim
mkdir -p /srv/app-releases
mv /srv/app /srv/app-releases/0-initial
ln -s /srv/app-releases/0-initial /srv/app

before=$(visits)
"$DEPLOY" --release "$target" "$WORK/v3"
[[ -L /srv/app ]]
assert_equals "data resolves to the state dir" /var/lib/bun-app "$(readlink -f /srv/app/data)"
assert_message "Hello from v3"
assert_equals "visits after a release (data kept)" "$((before + 2))" "$(visits)"
v3_dir=$(readlink -f /srv/app)

# A second release, keeping 2: 0-initial is pruned
sleep 1
example_copy "$WORK/v4" "Hello from v4"
KEEP=2 "$DEPLOY" --release "$target" "$WORK/v4"
assert_message "Hello from v4"
[[ ! -e /srv/app-releases/0-initial ]]
assert_equals "releases kept" 2 "$(find /srv/app-releases -mindepth 1 -maxdepth 1 | wc -l)"

# An installer re-run keeps the link and writes no sample
run_installer SKIP_UPGRADE=1 SKIP_CERTBOT=1
[[ -L /srv/app ]]
[[ ! -e /srv/app/server.ts ]]
assert_message "Hello from v4"

"$DEPLOY" --rollback "$target"
assert_equals "release after rollback" "$v3_dir" "$(readlink -f /srv/app)"
assert_message "Hello from v3"
bash "$INSTALLER" --check

echo "custom app test passed"
