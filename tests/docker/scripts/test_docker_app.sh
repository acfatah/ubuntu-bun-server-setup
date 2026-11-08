#!/usr/bin/env bash
# Test: Docker app behind Nginx (cookbook)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/docker/scripts/common.sh
. "$SCRIPT_DIR/common.sh"

# Follows docs/cookbook/docker.md step by step; keep the two in step.
EXAMPLE=/workspace/docs/examples/hono
WORK=/root/docker-app
mkdir -p "$WORK"

# Prints the body of a request through Nginx; retries while the app starts
get() {
  curl --retry 10 --retry-all-errors --retry-delay 1 -fsS "http://127.0.0.1$1"
}

# Prints the visit counter from /api/x, which also bumps it
visits() {
  get /api/x | jq -r .visits
}

assert_message() {
  assert_equals "message on /api/x" "$1" "$(get /api/x | jq -r .message)"
}

# The page's docker run line, for image tag $1
run_app() {
  docker run -d --name my-app --restart unless-stopped \
    -p 127.0.0.1:3000:3000 \
    --env-file /etc/my-app.env -v my-app-data:/data \
    --read-only --tmpfs /tmp --cap-drop ALL \
    --security-opt no-new-privileges \
    "$1" >/dev/null
}

# Step 1: install in skip mode
run_installer SKIP_BUN_APP=1 SKIP_UPGRADE=1 SKIP_CERTBOT=1

# Step 2: Docker. The page points at Docker's own packages; the test uses
# Ubuntu's docker.io, which needs no extra apt source. Overlay mounts
# cannot sit on this container's overlay root, so both image stores
# (/var/lib/docker, and containerd's snapshotter) go on a tmpfs.
echo -e "${YELLOW}[test]${NC} install Docker inside the test container"
for dir in /var/lib/docker /var/lib/containerd; do
  mkdir -p "$dir"
  mount -t tmpfs tmpfs "$dir"
done
apt_update_retry
apt-get install -qqy --no-install-recommends docker.io >/dev/null
systemctl start docker
docker version --format '{{.Server.Version}}'

# The image's Bun must be the installer's pin (RELEASE.md bumps both)
pin=$(sed -n 's/^BUN_PINNED_VERSION=//p' "$INSTALLER")
from=$(sed -n 's|^FROM oven/bun:||p' "$EXAMPLE/Dockerfile")
assert_equals "Dockerfile FROM tag vs BUN_PINNED_VERSION" "$pin" "$from"

# Step 3: the managed site, snippet and map, as the page copies them
echo -e "${YELLOW}[test]${NC} copy the proxy site from the templates"
base=file:///workspace/templates
curl -fsSL -o /etc/nginx/sites-available/default "$base/nginx-default.conf"
curl -fsSL -o /etc/nginx/snippets/bun-proxy.conf "$base/nginx-bun-proxy.conf"
curl -fsSL -o /etc/nginx/conf.d/bun-connection-upgrade.conf "$base/nginx-connection-upgrade.conf"
sed -i 's|__NGINX_ROOT__|/var/www/app/dist|' /etc/nginx/sites-available/default
mkdir -p /var/www/app/dist
nginx -t && systemctl reload nginx

# Steps 4 and 5: build the example and run it on loopback
echo -e "${YELLOW}[test]${NC} build and run the example image"
docker build -q -t my-app:1 "$EXAMPLE"
install -m 600 /dev/null /etc/my-app.env
run_app my-app:1

assert_equals "/healthz" ok "$(get /healthz)"
api=$(get /api/x)
assert_equals "message" "Hello from Hono" "$(jq -r .message <<<"$api")"
assert_equals "path" /api/x "$(jq -r .path <<<"$api")"
first=$(jq -r .visits <<<"$api")
assert_equals "visits after one more request" "$((first + 1))" "$(visits)"
curl -fsSI http://127.0.0.1/api/x | grep -qi '^x-content-type-options: nosniff'

# Published on loopback only
echo -e "${YELLOW}[test]${NC} port 3000 is on 127.0.0.1 only"
listen=$(ss -Hltn)
grep -q '127\.0\.0\.1:3000 ' <<<"$listen"
if grep -Eq '(0\.0\.0\.0|\[::\]|\*):3000 ' <<<"$listen"; then
  echo "${RED}Assertion failed:${NC} port 3000 listens beyond loopback" >&2
  echo "$listen" >&2
  exit 1
fi
ip=$(hostname -I | cut -d' ' -f1)
if curl -fsS --max-time 5 "http://$ip:3000/healthz"; then
  echo "${RED}Assertion failed:${NC} $ip:3000 answered" >&2
  exit 1
fi

# The flags that stand in for the unit's sandbox
echo -e "${YELLOW}[test]${NC} container sandbox flags"
assert_equals "ReadonlyRootfs" true "$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}}' my-app)"
assert_equals "user" bun "$(docker inspect -f '{{.Config.User}}' my-app)"
docker inspect -f '{{json .HostConfig.CapDrop}}' my-app | grep -q '"ALL"'

# A skip-mode re-run keeps the copied site, and --check skips the app
echo -e "${YELLOW}[test]${NC} installer re-run keeps the site"
cp /etc/nginx/sites-available/default "$WORK/site.orig"
run_installer SKIP_BUN_APP=1 SKIP_UPGRADE=1 SKIP_CERTBOT=1
cmp /etc/nginx/sites-available/default "$WORK/site.orig"
assert_message "Hello from Hono"
check=$(bash "$INSTALLER" --check)
echo "$check"
if grep -Eqi 'bun-app|healthz' <<<"$check"; then
  echo "${RED}Assertion failed:${NC} --check names bun-app or healthz" >&2
  exit 1
fi

# Deploy a new tag in place of the old one; the volume keeps the state
echo -e "${YELLOW}[test]${NC} deploy my-app:2, then roll back to my-app:1"
before=$(visits)
rm -rf "$WORK/v2"
cp -r "$EXAMPLE" "$WORK/v2"
sed -i 's/^const MESSAGE = .*/const MESSAGE = "Hello from v2";/' "$WORK/v2/src/index.ts"
docker build -q -t my-app:2 "$WORK/v2"
docker rm -f my-app >/dev/null
run_app my-app:2
assert_message "Hello from v2"
assert_equals "visits kept across the deploy" "$((before + 2))" "$(visits)"

docker rm -f my-app >/dev/null
run_app my-app:1
assert_message "Hello from Hono"

echo "Docker app test passed"
