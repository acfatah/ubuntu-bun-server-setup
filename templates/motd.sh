#!/bin/sh
set -e

if [ -z "$DISTRIB_DESCRIPTION" ] && [ -x /usr/bin/lsb_release ]; then
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

 * Nginx root: __NGINX_ROOT__
 * App dir: /root/app (service: bun-app)
 * Public access: http://$(hostname -I | awk '{print$1}')

 Commands:
   systemctl status bun-app    # Bun app status
   journalctl -u bun-app -f    # Bun app logs
   certbot --nginx             # Get HTTPS certs

EOM
