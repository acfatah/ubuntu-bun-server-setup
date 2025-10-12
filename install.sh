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
#   SKIP_SAMPLE_APP=1    -> skip creating /root/app sample
#
# Usage:
#   sudo bash install.sh
# ==============================================================================

BASE_PACKAGES=(curl unzip lsb-release ca-certificates nginx ufw snapd)
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
NC="\033[0m"

# Uniquely identifies this installation instance
INSTANCE_ID=$(uuidgen)

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
  # Honors: SKIP_SAMPLE_APP -> skip entirely. Idempotent: skips if dir exists.
  [[ -n "${SKIP_SAMPLE_APP:-}" ]] && return

  local app_dir=/root/app
  if [[ -d "$app_dir" ]]; then
    echo -e "${YELLOW}Sample app directory exists: $app_dir (skipping).${NC}"
    return
  fi
  echo -e "${GREEN}Creating sample Bun app at $app_dir...${NC}"
  mkdir -p "$app_dir"

  # File: /root/app/server.ts
  # Simple Bun server with two routes
  cat > "$app_dir/server.ts" <<'EOF'
const server = Bun.serve({
  async fetch(req) {
    const path = new URL(req.url).pathname;

    // respond with text/html
    if (path === "/") return new Response("Welcome to Bun!");

    // respond with JSON
    if (path === "/api") return Response.json({
      message: "Welcome to Bun!"
    });

    // 404s
    return new Response("Page not found", { status: 404 });
  },
});

console.log(`Listening on ${server.url}`);
EOF

  # File: /root/app/package.json
  # Minimal package.json to run server.ts
  cat > "$app_dir/package.json" <<'EOF'
{
  "name": "bun-app",
  "version": "0.0.0",
  "description": "Hello from bun!",
  "main": "server.ts",
  "scripts": {
    "start": "bun run server.ts",
    "restart": "systemctl restart bun-app"
  }
}
EOF
}

# Writes a static index page for the default Nginx site.
write_default_nginx_index() {
  cat > /var/www/html/index.html <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Hello World!</title>
  <style type="text/css">
    body {
      margin: 40px auto;
      max-width: 650px;
      line-height: 1.6;
      font-size: 18px;
      color: #444;
      padding: 0 10px;
    }

    h1,
    h2,
    h3 {
      line-height: 1.2;
    }
  </style>
</head>

<body>
  <h1>Hello World!</h1>
</body>
</html>
EOF
}

# Writes the Bun reverse proxy configuration to the default Nginx site.
write_bun_nginx_config() {
  cat > /etc/nginx/sites-available/default <<'EOF'
##
# You should look at the following URL's in order to grasp a solid understanding
# of Nginx configuration files in order to fully unleash the power of Nginx.
# https://www.nginx.com/resources/wiki/start/
# https://www.nginx.com/resources/wiki/start/topics/tutorials/config_pitfalls/
# https://wiki.debian.org/Nginx/DirectoryStructure
#
# In most cases, administrators will remove this file from sites-enabled/ and
# leave it as reference inside of sites-available where it will continue to be
# updated by the nginx packaging team.
#
# This file will automatically load configuration files provided by other
# applications, such as Drupal or Wordpress. These applications will be made
# available underneath a path with that package name, such as /drupal8.
#
# Please see /usr/share/doc/nginx-doc/examples/ for more detailed examples.
##

# Default server configuration
server {
  listen 80 default_server;
  listen [::]:80 default_server;

  # SSL configuration
  #
  # listen 443 ssl default_server;
  # listen [::]:443 ssl default_server;
  #
  # Note: You should disable gzip for SSL traffic.
  # See: https://bugs.debian.org/773332
  #
  # Read up on ssl_ciphers to ensure a secure configuration.
  # See: https://bugs.debian.org/765782
  #
  # Self signed certs generated by the ssl-cert package
  # Don't use them in a production server!
  #
  # include snippets/snakeoil.conf;

  root /var/www/html;

  # Add index.php to the list if you are using PHP
  index index.html index.htm index.nginx-debian.html;

  server_name bun;

  location ^~ /assets/ {
    gzip_static on;
    expires 12h;
    add_header Cache-Control public;
  }

  location / {
    proxy_http_version 1.1;
    proxy_cache_bypass $http_upgrade;

    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection 'upgrade';
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    proxy_pass http://localhost:3000;
  }
}
EOF
}

# Configures Nginx defaults based on whether the Bun sample app is installed.
configure_nginx() {
  echo -e "${GREEN}Configuring Nginx default site...${NC}"

  mkdir -p /var/www/html

  if [[ -n "${SKIP_SAMPLE_APP:-}" ]]; then
    write_default_nginx_index
  else
    mkdir -p /etc/nginx/sites-available
    write_bun_nginx_config
  fi

  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl restart nginx || true
}

# Creates and enables systemd unit for the Bun app (bun-app).
# Starts/restarts only if /root/app exists. Idempotent: overwrite-safe.
# Side effects: writes /etc/systemd/system/bun-app.service, daemon-reload, enable, (re)start.
create_systemd_service() {
  # Honors: SKIP_SAMPLE_APP -> skip entirely. Idempotent: skips if dir exists.
  [[ -n "${SKIP_SAMPLE_APP:-}" ]] && return

  echo -e "${GREEN}Configuring systemd service bun-app...${NC}"

  # File: /etc/systemd/system/bun-app.service
  # Create systemd service file
  cat > /etc/systemd/system/bun-app.service <<'EOF'
[Unit]
Description=Bun App
After=network.target

[Service]
Type=simple
WorkingDirectory=/root/app
ExecStart=/root/.bun/bin/bun run start
Restart=always
RestartSec=3
User=root
Environment=NODE_ENV=production
Environment=INSTANCE_ID=${INSTANCE_ID}
StandardOutput=journal
StandardError=journal
SyslogIdentifier=bun-app

[Install]
WantedBy=multi-user.target
EOF
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
  local build_date; build_date=$(date +%Y-%m-%d)
  local distro; distro=$(lsb_release -s -i 2>/dev/null || echo "unknown")
  local distro_release; distro_release=$(lsb_release -s -r 2>/dev/null || echo "unknown")
  local distro_codename; distro_codename=$(lsb_release -s -c 2>/dev/null || echo "unknown")
  local distro_arch; distro_arch=$(uname -m)
  local application_version; application_version=$(bun --version 2>/dev/null || echo "unknown")

  # File: /var/lib/app-info/application.info
  cat > "$info_file" <<EOF
application_name="${application_name}"
build_date="${build_date}"
distro="${distro}"
distro_release="${distro_release}"
distro_codename="${distro_codename}"
distro_arch="${distro_arch}"
application_version="${application_version}"
EOF
}

write_instance_id() {
  local INSTANCE_LINE

  INSTANCE_LINE="INSTANCE_ID=${INSTANCE_ID}"
  if ! sudo grep -Fxq "$INSTANCE_LINE" /etc/environment; then
      echo "$INSTANCE_LINE" | sudo tee -a /etc/environment > /dev/null
  fi
}

# Adds a helpful MOTD script under /etc/update-motd.d/99-bun.
# Displays access info, common commands, and how to remove the MOTD.
# Side effects: writes executable file used at login.
write_motd() {
  # Simple informative MOTD; does not expose passwords
  local motd=/etc/update-motd.d/00-custom
  echo -e "${GREEN}Creating MOTD entry at ${motd}...${NC}"

  chmod -x /etc/update-motd.d/00-header
  chmod -x /etc/update-motd.d/10-help-text

  cat > "$motd" <<'EOF'
#!/bin/sh
set -e

if [ -z "$DISTRIB_DESCRIPTION" ] && [ -x /usr/bin/lsb_release ]; then
  # Fall back to using the very slow lsb_release utility
  DISTRIB_DESCRIPTION=$(lsb_release -s -d)
fi

bun_version=$(bun --version 2>/dev/null || echo "-unknown")
nginx_version=$(nginx -v 2>&1 | awk -F/ '{print $2}' || echo "-unknown")

cat <<EOM
Welcome to $DISTRIB_DESCRIPTION, with Bun v$bun_version and Nginx v$nginx_version.
UFW is enabled with SSH(22), HTTP(80), and HTTPS(443) allowed.

 * Documentation: https://bun.sh
 * Nginx docs: https://nginx.org/en/docs
 * Certbot docs: https://certbot.eff.org

 Additional info:

 * Nginx root: /var/www/html
 * App dir: /root/app (service: bun-app)
 * Public access: http://$(hostname -I | awk '{print$1}')

 Commands:
   systemctl status bun-app    # Bun app status
   journalctl -u bun-app -f    # Bun app logs
   certbot --nginx             # Get HTTPS certs

EOM
EOF

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
  setup_sample_app
  configure_nginx
  create_systemd_service
  write_application_info
  write_instance_id
  write_motd
  print_summary
}

main "$@"
