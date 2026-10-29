#!/bin/sh
set -e

if [ -z "$DISTRIB_DESCRIPTION" ] && [ -x /usr/bin/lsb_release ]; then
  DISTRIB_DESCRIPTION=$(lsb_release -s -d)
fi

# Empty when a tool is missing or fails; printed as "version unknown"
bun_version=$(bun --version 2>/dev/null) || bun_version=
nginx_version=$(nginx -v 2>&1 | sed -n 's|^nginx version: nginx/||p') || nginx_version=
bun_label="Bun (version unknown)"
[ -z "$bun_version" ] || bun_label="Bun v$bun_version"
nginx_label="Nginx (version unknown)"
[ -z "$nginx_version" ] || nginx_label="Nginx v$nginx_version"

server_ip=$(hostname -I 2>/dev/null | awk '{print $1}') || server_ip=
[ -n "$server_ip" ] || server_ip="<server-ip>"

# Live state: the operator may disable UFW after the install
ufw_status=$(ufw status 2>/dev/null) || ufw_status=
case $ufw_status in
  "Status: active"*) ufw_line="UFW is active: SSH rate-limited, HTTP (80) and HTTPS (443) allowed." ;;
  "Status: inactive"*) ufw_line="UFW is inactive: no firewall rules are enforced." ;;
  *) ufw_line="UFW status unknown." ;;
esac

cat <<EOM
Welcome to $DISTRIB_DESCRIPTION, with $bun_label and $nginx_label.
$ufw_line

 * Documentation: https://bun.sh
 * Nginx docs: https://nginx.org/en/docs
 * Certbot docs: https://certbot.eff.org

 Additional info:

 * Nginx root: __NGINX_ROOT__
 * App dir: /srv/app (service: bun-app, runs as user bun-app)
 * App data: /var/lib/bun-app (= /srv/app/data)
 * Public access: http://$server_ip

 Commands:
   systemctl status bun-app    # Bun app status
   journalctl -u bun-app -f    # Bun app logs
   certbot --nginx             # Get HTTPS certs

EOM
