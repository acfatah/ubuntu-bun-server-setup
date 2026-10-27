#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# Ubuntu Bun installer
# - Installs Nginx, UFW, Certbot (snap), Bun
# - Sets up a simple Bun app under /srv/app
# - Creates sandboxed systemd service bun-app (runs as user bun-app)
# - Installs a Cloudflare IP updater with a daily timer (real client IP)
# - Configures UFW and writes application info + MOTD
# - Exits non-zero on the first failing step; logs every run to
#   /var/log/bun-installer.log
#
# Toggles (env var or KEY=VALUE argument; set to 1 to enable):
#   SKIP_BUN_APP=1    -> skip creating /srv/app Bun app
#   SKIP_CLOUDFLARE=1 -> skip the Cloudflare IP updater and Nginx files
#   FULL_UPGRADE=1    -> apt-get full-upgrade instead of upgrade
#
# Template source (env var only):
#   TEMPLATE_REF=<ref>      -> git ref to fetch templates from
#   TEMPLATE_BASE_URL=<url> -> templates directory URL (mirror, file://)
#
# Usage:
#   sudo bash install.sh [SKIP_BUN_APP=1] [SKIP_CLOUDFLARE=1] [FULL_UPGRADE=1]
#   curl -fsSL <url>/install.sh | sudo bash -s -- [SKIP_BUN_APP=1] [SKIP_CLOUDFLARE=1] [FULL_UPGRADE=1]
#   bash install.sh --version | --help
# ==============================================================================

# Release builds: build-installer.sh rewrites these three lines, pinning
# templates to the release tag and embedding their SHA-256 sums. The repo
# copy is the dev channel (templates from main, unverified).
INSTALLER_VERSION=dev
INSTALLER_REF=main
TEMPLATE_SHA256=''

APP_DIR=/srv/app
NGINX_ROOT=/var/www/app/dist
LOG_FILE=/var/log/bun-installer.log
USAGE="Usage: install.sh [--version | --help] [SKIP_BUN_APP=1] [SKIP_CLOUDFLARE=1] [FULL_UPGRADE=1]"
BASE_PACKAGES=(curl unzip lsb-release ca-certificates nginx ufw snapd)
# apt-get update attempts and the pause between them, in seconds
APT_UPDATE_TRIES=3
APT_UPDATE_DELAY=10
# Colours only on a terminal; logs and CI output stay free of escapes
if [[ -t 1 ]]; then
  GREEN=$(printf '\033[0;32m')
  YELLOW=$(printf '\033[1;33m')
  RED=$(printf '\033[0;31m')
  NC=$(printf '\033[0m')
else
  GREEN='' YELLOW='' RED='' NC=''
fi
TEMPLATE_REF=${TEMPLATE_REF:-$INSTALLER_REF}
TEMPLATE_BASE_URL=${TEMPLATE_BASE_URL:-https://raw.githubusercontent.com/acfatah/ubuntu-bun-server-setup/$TEMPLATE_REF/templates}
# Local templates are used only when run from a file (clone or test), never
# when piped, so a stray ./templates in cwd is never deployed.
TEMPLATE_LOCAL_DIR=""
if [[ -f "${BASH_SOURCE[0]:-}" ]]; then
  TEMPLATE_LOCAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/templates"
fi

download_template() {
  local template_name="$1"
  local dest_path="$2"
  mkdir -p "$(dirname "$dest_path")"
  local local_template="$TEMPLATE_LOCAL_DIR/$template_name"

  if [[ -n $TEMPLATE_LOCAL_DIR && -f "$local_template" ]]; then
    echo -e "${YELLOW}Using local template for $template_name...${NC}"
    cp "$local_template" "$dest_path"
    return
  fi

  echo -e "${YELLOW}Downloading template $template_name...${NC}"
  # Verified before the move, so a bad download never replaces a file.
  # mktemp creates 0600; nginx and bun-app must read the result.
  local tmp
  tmp=$(mktemp "$(dirname "$dest_path")/.${dest_path##*/}.XXXXXX")
  if ! curl -fsSL "${TEMPLATE_BASE_URL}/${template_name}" -o "$tmp" \
    || ! verify_template "$template_name" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  chmod 644 "$tmp"
  mv "$tmp" "$dest_path"
}

# True when downloads are checked: a release build fetching its own ref.
verify_templates() {
  [[ -n $TEMPLATE_SHA256 && $TEMPLATE_REF == "$INSTALLER_REF" ]]
}

# Checks a downloaded template against the SHA-256 embedded in a release
# build; a missing entry fails too. No-op unless verify_templates.
verify_template() {
  local name=$1 file=$2 expected actual
  verify_templates || return 0

  expected=$(awk -v name="$name" '$2 == name {print $1; exit}' <<<"$TEMPLATE_SHA256")
  if [[ -z $expected ]]; then
    echo -e "${RED}No checksum for template $name in installer ${INSTALLER_VERSION}.${NC}" >&2
    return 1
  fi
  actual=$(sha256sum "$file")
  actual=${actual%% *}
  if [[ $actual != "$expected" ]]; then
    echo -e "${RED}Template $name failed its checksum (expected $expected, got $actual).${NC}" >&2
    return 1
  fi
  echo "Checksum OK: $name"
}

# Prints the installer version and where templates come from.
print_version() {
  echo "ubuntu-bun-server-setup ${INSTALLER_VERSION}"
  echo "templates: ${TEMPLATE_REF} from ${TEMPLATE_BASE_URL}"
  if [[ -n $TEMPLATE_LOCAL_DIR && -d $TEMPLATE_LOCAL_DIR ]]; then
    echo "local templates (used first): ${TEMPLATE_LOCAL_DIR}"
  fi
}

# Prints usage, toggles and the template source overrides.
print_help() {
  cat <<EOF
$USAGE

Provisions Ubuntu 22.04+ with Bun, Nginx, UFW, Certbot and a sample Bun
app. Run as root.

Options:
  -V, --version      print the version and template source, then exit
  -h, --help         print this help, then exit

Toggles (KEY=VALUE argument or env var; only 1 enables):
  SKIP_BUN_APP=1     skip the sample app, its user and its unit
  SKIP_CLOUDFLARE=1  skip the Cloudflare IP updater and Nginx files
  FULL_UPGRADE=1     apt-get full-upgrade instead of upgrade

Template source (env var only):
  TEMPLATE_REF=<ref>       git ref to fetch templates from (default: ${INSTALLER_REF})
  TEMPLATE_BASE_URL=<url>  templates directory URL, e.g. a mirror or file://
EOF
}

# Replaces every $2 in file $1 with $3, literally: awk reads both through
# ENVIRON, so \, &, | and newlines are plain text. The file is rewritten
# in place, keeping its inode, mode and owner.
replace_placeholder() {
  local target_file="$1" tmp
  tmp=$(mktemp)
  if ! PLACEHOLDER="$2" VALUE="$3" awk '
    BEGIN { p = ENVIRON["PLACEHOLDER"]; v = ENVIRON["VALUE"]; n = length(p) }
    n == 0 { print; next }
    {
      line = $0
      out = ""
      while ((i = index(line, p)) > 0) {
        out = out substr(line, 1, i - 1) v
        line = substr(line, i + n)
      }
      print out line
    }' "$target_file" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  cat "$tmp" >"$target_file"
  rm -f "$tmp"
}

# Returns 0 (after a notice) if the path exists, so a re-run never
# clobbers a file the user may have edited.
keep_existing() {
  [[ -e $1 ]] || return 1
  echo -e "${YELLOW}Kept existing $1 (installer template not applied).${NC}"
}

# Writes each template:destination pair unless the destination exists.
deploy_templates() {
  local pair
  for pair in "$@"; do
    if ! keep_existing "${pair#*:}"; then
      download_template "${pair%%:*}" "${pair#*:}"
    fi
  done
}

# Uniquely identifies this installation instance; reused across re-runs
INSTANCE_ID=""
if [[ -f /etc/environment ]]; then
  # First match only; sed alone, so pipefail can't trip on SIGPIPE
  INSTANCE_ID=$(sed -n '/^INSTANCE_ID=/{s///p;q}' /etc/environment)
fi
INSTANCE_ID=${INSTANCE_ID:-$(cat /proc/sys/kernel/random/uuid)}

# True when the sample app, its user and its unit are skipped.
skip_app() {
  [[ ${SKIP_BUN_APP:-} == 1 ]]
}

# True when the Cloudflare updater, its timer and Nginx files are skipped.
skip_cloudflare() {
  [[ ${SKIP_CLOUDFLARE:-} == 1 ]]
}

# True when packages are upgraded with full-upgrade instead of upgrade.
full_upgrade() {
  [[ ${FULL_UPGRADE:-} == 1 ]]
}

# Applies KEY=VALUE arguments as toggles; only known keys are accepted.
parse_args() {
  local arg name
  # Ends up in a URL; no "..", so it cannot climb out of the repo path
  if [[ ! $TEMPLATE_REF =~ ^[A-Za-z0-9._/-]+$ || $TEMPLATE_REF == *..* ]]; then
    echo -e "${RED}Invalid TEMPLATE_REF=${TEMPLATE_REF}${NC}" >&2
    exit 1
  fi

  for arg in "$@"; do
    case $arg in
      -V | --version)
        print_version
        exit 0
        ;;
      -h | --help)
        print_help
        exit 0
        ;;
      SKIP_BUN_APP=*)
        SKIP_BUN_APP="${arg#*=}"
        ;;
      SKIP_CLOUDFLARE=*)
        SKIP_CLOUDFLARE="${arg#*=}"
        ;;
      FULL_UPGRADE=*)
        FULL_UPGRADE="${arg#*=}"
        ;;
      *)
        echo -e "${RED}Unknown argument: $arg${NC}" >&2
        echo "$USAGE" >&2
        exit 1
        ;;
    esac
  done

  # Env var or argument; a typo like "yes" must not silently fall back
  for name in SKIP_BUN_APP SKIP_CLOUDFLARE FULL_UPGRADE; do
    case ${!name:-} in
      '' | 0 | false | 1) ;;
      *)
        echo -e "${RED}Invalid ${name}=${!name} (use 1 to enable)${NC}" >&2
        echo "$USAGE" >&2
        exit 1
        ;;
    esac
  done

  if skip_app; then
    NGINX_ROOT=/var/www/html
  fi
}

# Ensures the script is executed as root (UID 0).
require_root() {
  if [[ $(id -u) -ne 0 ]]; then
    echo -e "${RED}This installer must be run as root (use sudo).${NC}" >&2
    exit 1
  fi
}

# Verifies the host is Ubuntu by reading /etc/os-release.
require_ubuntu() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    if [[ ${ID:-} != "ubuntu" ]]; then
      echo -e "${RED}This script targets Ubuntu. Detected: ${ID:-unknown}.${NC}" >&2
      exit 1
    fi
  else
    echo -e "${RED}/etc/os-release not found; cannot verify Ubuntu.${NC}" >&2
    exit 1
  fi
}

# Refreshes APT metadata, retrying the whole update: Acquire::Retries
# covers failed downloads, not an InRelease that downloads but then
# fails verification (a mirror caught mid-sync).
apt_update() {
  local try
  for ((try = 1; try <= APT_UPDATE_TRIES; try++)); do
    apt-get -qqy -o Acquire::Retries=3 update && return 0
    ((try < APT_UPDATE_TRIES)) || break
    echo -e "${YELLOW}apt-get update failed (attempt ${try}/${APT_UPDATE_TRIES}); retrying in ${APT_UPDATE_DELAY}s...${NC}" >&2
    sleep "$APT_UPDATE_DELAY"
  done
  echo -e "${RED}apt-get update failed after ${APT_UPDATE_TRIES} attempts.${NC}" >&2
  return 1
}

# Updates APT metadata and upgrades packages non-interactively. Plain
# upgrade by default (never removes packages); full-upgrade with
# FULL_UPGRADE=1. --force-confdef/--force-confold keep existing configs.
apt_update_upgrade() {
  local mode=upgrade
  full_upgrade && mode=full-upgrade

  export DEBIAN_FRONTEND=noninteractive
  apt_update
  echo -e "${GREEN}Upgrading packages (apt-get ${mode})...${NC}"
  apt-get -qqy -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold' "$mode"
}

# Installs base packages needed by the stack.
install_base_packages() {
  echo -e "${GREEN}Installing base packages: ${BASE_PACKAGES[*]}...${NC}"
  apt-get -qqy install "${BASE_PACKAGES[@]}"
}

# Prints the ports sshd listens on, one per line, from `sshd -T`. Falls
# back to 22 with a notice when sshd is absent or its config unreadable.
ssh_ports() {
  local ports=""

  if command -v sshd >/dev/null 2>&1; then
    # sshd -T needs this dir; socket-activated hosts may not have it yet
    mkdir -p /run/sshd
    # A failing sshd -T is handled below: empty output means fallback
    ports=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}') || true
  fi

  if [[ -z $ports ]]; then
    echo -e "${YELLOW}Could not read sshd ports (sshd -T); limiting SSH on port 22.${NC}" >&2
    ports=22
  fi
  echo "$ports"
}

# Adds UFW rules without resetting: limit every sshd port, allow
# HTTP/HTTPS (the 'Nginx Full' profile when available). The default
# policy (deny incoming, allow outgoing) is set only while UFW is
# inactive, so rules and policy changed since are kept on a re-run.
configure_ufw() {
  local port

  echo -e "${GREEN}Configuring UFW (limit sshd port(s), allow 'Nginx Full'; existing rules kept)...${NC}"

  if ufw --version >/dev/null 2>&1; then
    # Captured first: grep -q in a pipe could SIGPIPE ufw under pipefail
    if [[ $(ufw status) == "Status: inactive"* ]]; then
      ufw default deny incoming
      ufw default allow outgoing
    fi

    for port in $(ssh_ports); do
      ufw limit "$port/tcp"
    done

    # Allow Nginx HTTP+HTTPS profile if available, otherwise explicit ports
    if ufw app list 2>/dev/null | grep -q "Nginx Full"; then
      ufw allow 'Nginx Full'
    else
      ufw allow 80/tcp
      ufw allow 443/tcp
    fi

    ufw --force enable
  fi
}

# Installs Certbot via snap, removing any apt version to avoid conflicts.
install_certbot() {
  echo -e "${GREEN}Installing Certbot (snap)...${NC}"

  # Avoid older apt certbot; nothing to remove is fine
  apt-get -qqy remove certbot || true
  systemctl --quiet enable --now snapd
  # Wait for snapd socket, then for seeding: installs before it finish
  # fail with "too early for operation". A timeout is not fatal here;
  # snap install below fails loudly if snapd never gets ready.
  timeout 60 bash -c 'until snap list >/dev/null 2>&1; do sleep 2; done' || true
  timeout 120 snap wait system seed.loaded || true
  snap install --classic certbot
  ln -sf /snap/bin/certbot /usr/bin/certbot
  snap set certbot trust-plugin-with-root=ok
}

# Installs Bun system-wide to /usr/local/bin/bun so the unprivileged
# bun-app user can execute it. Skips if that binary already works for a
# non-root user; replaces a legacy symlink into /root/.bun.
install_bun() {
  local bun_bin=/usr/local/bin/bun
  local installer

  # runuser, not setpriv: setpriv reports success on a binary under /root
  if runuser -u nobody -- "$bun_bin" --version >/dev/null 2>&1; then
    echo -e "${YELLOW}Bun already installed: $("$bun_bin" --version)${NC}"
    return
  fi

  if [[ -L $bun_bin ]]; then
    echo -e "${YELLOW}Replacing legacy Bun symlink $bun_bin...${NC}"
    rm -f "$bun_bin"
  fi

  echo -e "${GREEN}Installing Bun to /usr/local...${NC}"
  # mktemp: unpredictable name, no symlink race on a fixed /tmp path
  installer=$(mktemp)
  curl -fsSL https://bun.sh/install -o "$installer"
  BUN_INSTALL=/usr/local bash "$installer"
  rm -f "$installer"

  echo -e "${GREEN}Bun version: v$("$bun_bin" --version)${NC}"
}

# Creates the unprivileged bun-app system user the service runs as.
# Its home is the systemd StateDirectory; no login shell.
create_app_user() {
  skip_app && return

  if id -u bun-app >/dev/null 2>&1; then
    echo -e "${YELLOW}User bun-app already exists (skipping).${NC}"
    return
  fi

  echo -e "${GREEN}Creating system user bun-app...${NC}"
  useradd --system --user-group --home-dir /var/lib/bun-app \
    --no-create-home --shell /usr/sbin/nologin bun-app
}

# Creates a minimal Bun app under /srv/app unless disabled.
setup_sample_app() {
  skip_app && return

  mkdir -p "$APP_DIR"
  if [[ -f "$APP_DIR/server.ts" ]]; then
    echo -e "${YELLOW}Sample app directory exists: $APP_DIR (skipping).${NC}"
    return
  fi
  echo -e "${GREEN}Creating sample Bun app at $APP_DIR...${NC}"

  download_template "server.ts" "$APP_DIR/server.ts"
  download_template "package.json" "$APP_DIR/package.json"
  download_template "nginx-index-sample.html" "$NGINX_ROOT/index.html"

  chown -R www-data:www-data "$NGINX_ROOT"

  # set directories to 755 and files to 644
  find "$NGINX_ROOT" -type d -exec chmod 755 {} +
  find "$NGINX_ROOT" -type f -exec chmod 644 {} +
}

# Writes a static index page for the default Nginx site, unless one
# exists (stock Ubuntu ships only index.nginx-debian.html).
write_default_nginx_index() {
  if keep_existing "$NGINX_ROOT/index.html"; then
    return
  fi
  download_template "nginx-index-default.html" "$NGINX_ROOT/index.html"
}

# Writes the Bun reverse proxy configuration to the default Nginx site.
# A site carrying the installer marker (line 1 of the template) is kept;
# any other, such as Ubuntu's stock site, is replaced.
write_bun_nginx_config() {
  local site=/etc/nginx/sites-available/default
  local marker="# Managed by ubuntu-bun-server-setup."

  if [[ -f $site ]] && grep -qF "$marker" "$site"; then
    keep_existing "$site"
    return
  fi
  if [[ -e $site ]]; then
    echo -e "${YELLOW}Replacing $site (no installer marker).${NC}"
  fi
  download_template "nginx-default.conf" "$site"
  replace_placeholder "$site" "__NGINX_ROOT__" "$NGINX_ROOT"
}

# True when Nginx still includes the old helper's cloudflare-ip-filter.conf
# (allow <ranges>; deny all). With real client IP on, deny all would
# block every visitor, so conf.d/bun-cloudflare.conf must wait.
old_cloudflare_filter_active() {
  # -R follows the sites-enabled symlinks; -s hides missing paths
  grep -RqsE '^[[:space:]]*include[[:space:]]+(/etc/nginx/)?cloudflare-ip-filter\.conf' \
    /etc/nginx/nginx.conf /etc/nginx/conf.d /etc/nginx/sites-enabled
}

# Installs the Cloudflare IP updater with its daily timer, fetches the
# lists once if missing, and deploys the Nginx files that use them: real
# client IP for every site (conf.d) and an optional 403 rule (snippet).
# Keeps existing copies; the generated lists belong to the updater.
# Skipped with SKIP_CLOUDFLARE=1; a failed first fetch fails the install.
install_cloudflare() {
  local updater=/usr/local/sbin/cloudflare-update-ips
  local lists=/etc/nginx/cloudflare
  skip_cloudflare && return

  echo -e "${GREEN}Installing Cloudflare IP updater and timer...${NC}"

  deploy_templates \
    "cloudflare-update-ips.sh:$updater" \
    cloudflare-update-ips.service:/etc/systemd/system/cloudflare-update-ips.service \
    cloudflare-update-ips.timer:/etc/systemd/system/cloudflare-update-ips.timer
  chmod 755 "$updater"

  # Nginx is restarted by configure_nginx, so the updater must not reload
  if [[ ! -f $lists/real-ip.conf || ! -f $lists/edge-ips.conf ]]; then
    "$updater" --no-reload
  fi

  if old_cloudflare_filter_active && [[ ! -e /etc/nginx/conf.d/bun-cloudflare.conf ]]; then
    echo -e "${YELLOW}Cloudflare: Nginx still includes cloudflare-ip-filter.conf; real client IP not enabled (see README, Upgrading from 0.4.x).${NC}"
  else
    deploy_templates nginx-cloudflare.conf:/etc/nginx/conf.d/bun-cloudflare.conf
  fi
  deploy_templates nginx-cloudflare-only.conf:/etc/nginx/snippets/cloudflare-only.conf

  systemctl daemon-reload
  systemctl --quiet enable --now cloudflare-update-ips.timer

  if skip_app; then
    echo -e "${YELLOW}Cloudflare: only the real client IP applies; the stock site has no cloudflare-only include.${NC}"
  fi
}

# Deploys the Bun proxy snippet and its Connection-header map, which the
# default site includes, keeping existing copies.
write_nginx_proxy_files() {
  deploy_templates \
    nginx-bun-proxy.conf:/etc/nginx/snippets/bun-proxy.conf \
    nginx-connection-upgrade.conf:/etc/nginx/conf.d/bun-connection-upgrade.conf
}

# Configures Nginx defaults based on whether the Bun sample app is installed.
configure_nginx() {
  # First, so the updater's nginx -t checks its lists against the config
  # already in place; errors in the new site surface at nginx -t below
  install_cloudflare

  echo -e "${GREEN}Configuring Nginx default site...${NC}"

  if skip_app; then
    write_default_nginx_index
  else
    mkdir -p /etc/nginx/sites-available
    write_nginx_proxy_files
    write_bun_nginx_config
  fi

  # Validate first: on a bad config the running Nginx keeps serving
  nginx -t
  systemctl --quiet enable nginx
  systemctl restart nginx
}

# Writes /etc/bun-app.env (INSTANCE_ID, PORT) for the unit's
# EnvironmentFile, unless one exists. Root-only: users add secrets here.
write_app_env() {
  local env_file=/etc/bun-app.env

  if keep_existing "$env_file"; then
    return
  fi
  download_template "bun-app.env" "$env_file"
  chmod 600 "$env_file"
  replace_placeholder "$env_file" "__INSTANCE_ID__" "$INSTANCE_ID"
}

# Writes the bun-app systemd unit and its environment file unless they
# exist, then enables the unit and (re)starts it if /srv/app exists.
# Skipped with SKIP_BUN_APP=1.
create_systemd_service() {
  local unit=/etc/systemd/system/bun-app.service
  skip_app && return

  echo -e "${GREEN}Configuring systemd service bun-app...${NC}"

  if ! keep_existing "$unit"; then
    download_template "bun-app.service" "$unit"
  fi
  write_app_env

  # Writable state lives in StateDirectory (/var/lib/bun-app); expose it
  # as ./data. Never replace an existing data dir or link.
  if [[ -d $APP_DIR && ! -e $APP_DIR/data && ! -L $APP_DIR/data ]]; then
    ln -s /var/lib/bun-app "$APP_DIR/data"
  fi

  systemctl daemon-reload
  systemctl --quiet enable bun-app
  # Start only if app folder exists; restart also starts a stopped unit
  if [[ -d $APP_DIR ]]; then
    systemctl restart bun-app
  fi
}

# Emits build and environment metadata to /var/lib/app-info/application.info.
# Values include distro info and Bun version if available.
# Rewritten on every run: it records the latest install, not user data.
write_application_info() {
  echo -e "${GREEN}Writing application metadata...${NC}"
  local info_dir="/var/lib/app-info"
  mkdir -p "$info_dir"
  local info_file="$info_dir/application.info"
  local build_date
  build_date=$(date +%Y-%m-%d)
  local distro
  distro=$(lsb_release -s -i 2>/dev/null || echo "unknown")
  local distro_release
  distro_release=$(lsb_release -s -r 2>/dev/null || echo "unknown")
  local distro_codename
  distro_codename=$(lsb_release -s -c 2>/dev/null || echo "unknown")
  local distro_arch
  distro_arch=$(uname -m)
  local application_version
  application_version=$(bun --version 2>/dev/null || echo "unknown")
  local template_ref=$TEMPLATE_REF
  if [[ -n $TEMPLATE_LOCAL_DIR && -d $TEMPLATE_LOCAL_DIR ]]; then
    template_ref=local
  fi

  download_template "application.info" "$info_file"
  replace_placeholder "$info_file" "__BUILD_DATE__" "$build_date"
  replace_placeholder "$info_file" "__DISTRO__" "$distro"
  replace_placeholder "$info_file" "__DISTRO_RELEASE__" "$distro_release"
  replace_placeholder "$info_file" "__DISTRO_CODENAME__" "$distro_codename"
  replace_placeholder "$info_file" "__DISTRO_ARCH__" "$distro_arch"
  replace_placeholder "$info_file" "__APPLICATION_VERSION__" "$application_version"
  replace_placeholder "$info_file" "__INSTALLER_VERSION__" "$INSTALLER_VERSION"
  replace_placeholder "$info_file" "__TEMPLATE_REF__" "$template_ref"
}

# Records INSTANCE_ID in /etc/environment as exactly one line; also
# collapses duplicates appended by older installer versions.
write_instance_id() {
  touch /etc/environment
  sed -i '/^INSTANCE_ID=/d' /etc/environment
  echo "INSTANCE_ID=${INSTANCE_ID}" >>/etc/environment
}

# Moves Ubuntu's MOTD header and help text out of /etc/update-motd.d via
# dpkg diversions, so base-files upgrades write there instead of
# re-enabling them. Re-adding an existing diversion is a no-op.
disable_stock_motd() {
  local name src dest
  local disabled_dir=/var/lib/bun-installer/motd-disabled

  mkdir -p "$disabled_dir"
  for name in 00-header 10-help-text; do
    src=/etc/update-motd.d/$name
    dest=$disabled_dir/$name
    # --no-rename: --rename warns on files of Essential packages
    dpkg-divert --quiet --local --no-rename --divert "$dest" --add "$src"
    if [[ -e $src && ! -e $dest ]]; then
      mv "$src" "$dest"
    fi
  done
}

# Adds a helpful MOTD script under /etc/update-motd.d/00-custom, unless
# one exists. Displays access info and common commands.
write_motd() {
  # Simple informative MOTD; does not expose passwords
  local motd=/etc/update-motd.d/00-custom

  disable_stock_motd

  if keep_existing "$motd"; then
    return
  fi

  echo -e "${GREEN}Creating MOTD entry at ${motd}...${NC}"

  download_template "motd.sh" "$motd"
  replace_placeholder "$motd" "__NGINX_ROOT__" "$NGINX_ROOT"

  chmod +x "$motd"
}

# Prints a summary of installed components and next steps. Checks that
# certbot runs and nginx (and bun-app unless skipped) are active; lists
# anything missing and returns 1 if so.
print_summary() {
  local bun_path bun_ver nginx_ver service_line problem reboot_line=""
  local problems=()

  bun_path=$(command -v bun || echo "not found")
  bun_ver=$(bun --version 2>/dev/null || echo "unknown")
  nginx_ver=$(nginx -v 2>&1 || echo "not found")
  service_line=""

  # --version catches a dangling /usr/bin/certbot symlink
  if ! certbot --version >/dev/null 2>&1; then
    problems+=("Certbot does not run; see: snap list certbot")
  fi
  if ! systemctl is-active --quiet nginx; then
    problems+=("Nginx is not active; see: systemctl status nginx")
  fi
  if [[ -e /var/run/reboot-required ]]; then
    reboot_line=" * Reboot required to finish package upgrades: sudo reboot"
  fi
  if ! skip_app; then
    if systemctl is-active --quiet bun-app; then
      service_line=" * Service 'bun-app' is active. View logs: journalctl -u bun-app -f"
    else
      problems+=("Service 'bun-app' is not active; see: journalctl -u bun-app")
    fi
  fi

  if [[ ${#problems[@]} -gt 0 ]]; then
    echo -e "${RED}Installation finished with problems:${NC}"
    for problem in "${problems[@]}"; do
      echo " * $problem"
    done
    echo " * Log: $LOG_FILE"
    return 1
  fi

  cat <<EOF
${GREEN}Installation complete.${NC}

 * Instance ID: ${INSTANCE_ID}
 * Bun: ${bun_path} (${bun_ver})
 * Nginx: ${nginx_ver}
${service_line}
${reboot_line}
 * Certbot installed. To obtain a certificate for an Nginx site:
   certbot --nginx
 * Log: ${LOG_FILE}

EOF
}

# Opens the installer log (root:adm, 640) and appends a run header.
start_log() {
  touch "$LOG_FILE"
  chown root:adm "$LOG_FILE"
  chmod 640 "$LOG_FILE"
  echo "=== bun-installer ${INSTALLER_VERSION} $(date -Is) args: ${*:-none} ===" >>"$LOG_FILE"
}

# Runs every install step. Runs in the tee pipeline's subshell, so the ERR
# trap set here reports the failing line once and the parent stays quiet.
main() {
  trap 'echo -e "${RED}install failed at line $LINENO (${FUNCNAME[0]:-main})${NC}" >&2' ERR

  echo -e "${GREEN}Starting Ubuntu Bun installation script...${NC}"
  print_version
  if verify_templates; then
    echo "Downloaded templates are checked against the SHA-256 sums of ${INSTALLER_REF}."
  elif [[ -n $TEMPLATE_SHA256 ]]; then
    echo -e "${YELLOW}TEMPLATE_REF=${TEMPLATE_REF} differs from ${INSTALLER_REF}; templates are not verified.${NC}"
  fi
  require_ubuntu
  apt_update_upgrade
  install_base_packages
  configure_ufw
  install_certbot
  install_bun
  create_app_user
  mkdir -p "$NGINX_ROOT"
  setup_sample_app
  configure_nginx
  create_systemd_service
  write_application_info
  write_instance_id
  write_motd
  # A conditional, so the ERR trap stays quiet; the summary explains
  print_summary || exit 1
}

# Runs unless sourced (unit tests); a piped run has no BASH_SOURCE
if [[ ${BASH_SOURCE[0]:-$0} == "$0" ]]; then
  parse_args "$@"
  require_root
  start_log "$@"
  # pipefail carries main's exit status; tee is waited for, so no log loss
  main 2>&1 | tee -a "$LOG_FILE"
fi
