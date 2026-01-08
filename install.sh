#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Ubuntu Bun installer
# - Installs Nginx, UFW, Certbot (snap), Bun
# - Sets up a simple Bun app under /root/app
# - Creates systemd service bun-app
# - Optionally configures UFW and writes application info + MOTD
#
# Environment toggles (set to 1 to skip):
#   SKIP_BUN_APP=1    -> skip creating /root/app Bun app
#
# Usage:
#   sudo bash install.sh
# ==============================================================================

APP_DIR=/root/app
NGINX_ROOT=/var/www/app/dist
BASE_PACKAGES=(curl unzip lsb-release ca-certificates nginx ufw snapd)
GREEN=$(printf '\033[0;32m')
YELLOW=$(printf '\033[1;33m')
RED=$(printf '\033[0;31m')
NC=$(printf '\033[0m')
TEMPLATE_BASE_URL="https://raw.githubusercontent.com/acfatah/ubuntu-bun-server-setup/refs/heads/main/templates"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_LOCAL_DIR="$SCRIPT_DIR/templates"

download_template() {
  local template_name="$1"
  local dest_path="$2"
  mkdir -p "$(dirname "$dest_path")"
  local local_template="$TEMPLATE_LOCAL_DIR/$template_name"

  if [[ -f "$local_template" ]]; then
    echo -e "${YELLOW}Using local template for $template_name...${NC}"
    cp "$local_template" "$dest_path"
    return
  fi

  echo -e "${YELLOW}Downloading template $template_name...${NC}"
  curl -fsSL "${TEMPLATE_BASE_URL}/${template_name}" -o "$dest_path"
}

replace_placeholder() {
  local target_file="$1"
  local placeholder="$2"
  local value="$3"
  local escaped_placeholder
  local escaped_value
  escaped_placeholder=$(printf '%s' "$placeholder" | sed -e 's/[|&]/\\\&/g')
  escaped_value=$(printf '%s' "$value" | sed -e 's/[|&]/\\\&/g')
  sed -i "s|$escaped_placeholder|$escaped_value|g" "$target_file"
}

if [ -n "${SKIP_BUN_APP:-}" ]; then
  NGINX_ROOT=/var/www/html
fi

# Uniquely identifies this installation instance
INSTANCE_ID=$(cat /proc/sys/kernel/random/uuid)

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
    # shellcheck source=/etc/os-release
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

# Updates APT metadata and performs a non-interactive full upgrade.
# Uses --force-confdef/--force-confold to keep existing configs.
apt_update_upgrade() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get -qqy update
  # Keep existing configs if prompted
  apt-get -qqy -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold' full-upgrade
}

# Installs base packages needed by the stack.
install_base_packages() {
  echo -e "${GREEN}Installing base packages: ${BASE_PACKAGES[*]}...${NC}"
  apt-get -qqy install "${BASE_PACKAGES[@]}"
}

# Resets and configures UFW: deny incoming, allow outgoing, limit SSH, allow HTTP/HTTPS.
# Prefers the 'Nginx Full' app profile when available.
configure_ufw() {
  echo -e "${GREEN}Configuring UFW (allow 'Nginx Full', limit ssh)...${NC}"

  # Ensure profiles are loaded
  if ufw --version >/dev/null 2>&1; then
    ufw --force reset >/dev/null 2>&1 || true
    ufw default deny incoming
    ufw default allow outgoing
    ufw limit ssh || true

    # Allow Nginx HTTP+HTTPS profile if available, otherwise explicit ports
    if ufw app list 2>/dev/null | grep -q "Nginx Full"; then
      ufw allow 'Nginx Full' || true
    else
      ufw allow 80/tcp || true
      ufw allow 443/tcp || true
    fi

    ufw --force enable
  fi
}

# Installs Certbot via snap, removing any apt version to avoid conflicts.
install_certbot() {
  echo -e "${GREEN}Installing Certbot (snap)...${NC}"

  # Avoid older apt certbot
  apt-get -qqy remove certbot || true
  systemctl enable snapd >/dev/null 2>&1 || true
  systemctl start snapd || true
  # Wait for snapd socket
  timeout 60 bash -c 'until snap list >/dev/null 2>&1; do sleep 2; done' || true
  snap install --classic certbot || true
  ln -sf /snap/bin/certbot /usr/bin/certbot
  snap set certbot trust-plugin-with-root=ok || true
}

# Installs Bun if not present and ensures it's on PATH via symlink.
install_bun() {
  if command -v bun >/dev/null 2>&1; then
    echo -e "${YELLOW}Bun already installed: $(bun --version)${NC}"
    return
  fi

  echo -e "${GREEN}Installing Bun...${NC}"
  curl -fsSL https://bun.sh/install -o /tmp/bun_setup.sh
  bash /tmp/bun_setup.sh
  rm -f /tmp/bun_setup.sh

  # Ensure bun is globally accessible
  if [[ -x /root/.bun/bin/bun && ! -e /usr/local/bin/bun ]]; then
    ln -s /root/.bun/bin/bun /usr/local/bin/bun
  fi

  echo -e "${GREEN}Bun version: v$(bun --version)${NC}"
}

# Creates a minimal Bun app under /root/app unless disabled.
setup_sample_app() {
  [[ -n "${SKIP_BUN_APP:-}" ]] && return

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

# Writes a static index page for the default Nginx site.
write_default_nginx_index() {
  download_template "nginx-index-default.html" "$NGINX_ROOT/index.html"
}

# Writes the Bun reverse proxy configuration to the default Nginx site.
write_bun_nginx_config() {
  download_template "nginx-default.conf" /etc/nginx/sites-available/default
  replace_placeholder "/etc/nginx/sites-available/default" "__NGINX_ROOT__" "$NGINX_ROOT"
}

# Deploys the Cloudflare helper templates into the main Nginx directory.
copy_cloudflare_templates() {
  echo -e "${GREEN}Copying Cloudflare helper files to /etc/nginx...${NC}"
  local nginx_dir="/etc/nginx"

  for template in cloudflare-ip-filter.conf cloudflare-update-ips.sh; do
    download_template "$template" "$nginx_dir/$template"
  done

  chmod +x "$nginx_dir/cloudflare-update-ips.sh" || true
}

# Configures Nginx defaults based on whether the Bun sample app is installed.
configure_nginx() {
  echo -e "${GREEN}Configuring Nginx default site...${NC}"

  if [[ -n "${SKIP_BUN_APP:-}" ]]; then
    write_default_nginx_index
  else
    mkdir -p /etc/nginx/sites-available
    write_bun_nginx_config
  fi

  copy_cloudflare_templates

  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl restart nginx || true
}

# Creates and enables systemd unit for the Bun app (bun-app).
# Starts/restarts only if /root/app exists. Idempotent: overwrite-safe.
# Side effects: writes /etc/systemd/system/bun-app.service, daemon-reload, enable, (re)start.
create_systemd_service() {
  # Honors: SKIP_BUN_APP -> skip entirely. Idempotent: skips if dir exists.
  [[ -n "${SKIP_BUN_APP:-}" ]] && return

  echo -e "${GREEN}Configuring systemd service bun-app...${NC}"

  # File: /etc/systemd/system/bun-app.service
  # Create systemd service file
  download_template "bun-app.service" /etc/systemd/system/bun-app.service
  replace_placeholder "/etc/systemd/system/bun-app.service" "__INSTANCE_ID__" "$INSTANCE_ID"
  systemctl daemon-reload
  systemctl enable bun-app >/dev/null 2>&1 || true
  # Start only if app folder exists
  if [[ -d /root/app ]]; then
    systemctl restart bun-app || systemctl start bun-app || true
  fi
}

# Emits build and environment metadata to /var/lib/app-info/application.info.
# Values include distro info and Bun version if available.
# Side effects: creates/overwrites metadata file.
write_application_info() {
  echo -e "${GREEN}Writing application metadata...${NC}"
  local info_dir="/var/lib/app-info"
  mkdir -p "$info_dir"
  local info_file="$info_dir/application.info"
  local application_name="Bun.sh"
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

  download_template "application.info" "$info_file"
  replace_placeholder "$info_file" "__BUILD_DATE__" "$build_date"
  replace_placeholder "$info_file" "__DISTRO__" "$distro"
  replace_placeholder "$info_file" "__DISTRO_RELEASE__" "$distro_release"
  replace_placeholder "$info_file" "__DISTRO_CODENAME__" "$distro_codename"
  replace_placeholder "$info_file" "__DISTRO_ARCH__" "$distro_arch"
  replace_placeholder "$info_file" "__APPLICATION_VERSION__" "$application_version"
}

write_instance_id() {
  local INSTANCE_LINE

  INSTANCE_LINE="INSTANCE_ID=${INSTANCE_ID}"
  if ! grep -Fxq "$INSTANCE_LINE" /etc/environment; then
    echo "$INSTANCE_LINE" | tee -a /etc/environment >/dev/null
  fi
}

# Adds a helpful MOTD script under /etc/update-motd.d/00-custom.
# Displays access info, common commands, and how to remove the MOTD.
# Side effects: writes executable file used at login.
write_motd() {
  # Simple informative MOTD; does not expose passwords
  local motd=/etc/update-motd.d/00-custom

  if [[ -d $motd ]]; then
    echo -e "${YELLOW}MOTD script already exists: $motd (skipping).${NC}"
    return
  fi

  echo -e "${GREEN}Creating MOTD entry at ${motd}...${NC}"

  chmod -x /etc/update-motd.d/00-header
  chmod -x /etc/update-motd.d/10-help-text

  download_template "motd.sh" "$motd"
  replace_placeholder "$motd" "__NGINX_ROOT__" "$NGINX_ROOT"

  chmod +x "$motd"
}

# Prints a concise summary of installed components and next steps.
# Includes Bun path/version, Nginx presence, bun-app service status, and Certbot hint.
print_summary() {
  local bun_path bun_ver nginx_ver service_line

  bun_path=$(command -v bun || echo "not found")
  bun_ver=$(bun --version 2>/dev/null || echo "unknown")
  nginx_ver=$(nginx -v 2>&1 || echo "not found")

  if systemctl is-enabled bun-app >/dev/null 2>&1; then
    service_line=" * Service 'bun-app' is enabled. View logs: journalctl -u bun-app -f"
  else
    service_line=""
  fi

  cat <<EOF
${GREEN}Installation complete.${NC}

 * Instance ID: ${INSTANCE_ID}
 * Bun: ${bun_path} (${bun_ver})
 * Nginx: ${nginx_ver}
${service_line}
 * Certbot installed. To obtain a certificate for an Nginx site:
   certbot --nginx

EOF
}

main() {
  echo -e "${GREEN}Starting Ubuntu Bun installation script...${NC}"
  require_root
  require_ubuntu
  apt_update_upgrade
  install_base_packages
  configure_ufw
  install_certbot
  install_bun
  mkdir -p "$NGINX_ROOT"
  setup_sample_app
  configure_nginx
  create_systemd_service
  write_application_info
  write_instance_id
  write_motd
  print_summary
}

main "$@"
