# Ubuntu Bun Installer

<p>
  <a href="https://github.com/acfatah/ubuntu-bun-installer/commits/main">
    <img
      alt="GitHub last commit (by committer)"
      src="https://img.shields.io/github/last-commit/acfatah/ubuntu-bun-installer?display_timestamp=committer&style=flat-square"></a>
</p>

Run a single script to bootstrap a production-ready Bun environment on Ubuntu (22.04+/24.04).

- Installs Bun, Nginx, UFW
- Installs Certbot via snap (optional)
- Sets up a sample Bun app in `/root/app`
- Creates a `bun-app` systemd service (`NODE_ENV=production`)
- Writes application metadata and a helpful MOTD


## Software Included

| Software    | Version     | License |
| ---         | ---         | ---     |
| [Bun][1]    | [1.2.x][2]  | [MIT][3] |
| [Nginx][4]  | [1.17.x][5] | [Artistic License 2.0][6] |
| [Certbot][7]    | [4.1.x][8]  | [Apache 2 on GitHub][9] |

## Prerequisites

- Ubuntu 22.04+ or 24.04, run as root or with sudo.
- Internet access for package and snap installs.

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/acfatah/ubuntu-bun-installer/main/install.sh -o install.sh
sudo bash install.sh
```

Or from this repo folder:

```bash
sudo bash install.sh
```

When done:

- Check Bun: `bun --version`
- Bun app service: `systemctl status bun-app` (logs: `journalctl -u bun-app -f`)
- Nginx default site: `http://<server-ip>` serving `/var/www/html`.
- Get HTTPS cert for your Nginx site: `certbot --nginx`.

## Environment toggles

Set any to `1` to skip:

- `SKIP_UFW=1` — Skip firewall configuration
- `SKIP_CERTBOT=1` — Skip Certbot installation
- `SKIP_SAMPLE_APP=1` — Do not create sample `/root/app`
- `SKIP_NGINX=1` — Skip Nginx install/config

Example:

```bash
sudo SKIP_CERTBOT=1 bash install.sh
```

## Notes

- The service runs from `/root/app` and executes `bun run start`.
- Adjust to your app by replacing `/root/app` contents and updating the service ExecStart if needed.
- This script intentionally avoids DO marketplace cleanup (e.g., disk zeroing).

[1]: https://bun.sh
[2]: https://github.com/oven-sh/bun/releases
[3]: https://github.com/oven-sh/bun/blob/main/LICENSE
[4]: https://nginx.org
[5]: https://packages.ubuntu.com/focal/nginx
[6]: https://www.npmjs.com/policies/npm-license
[7]: https://certbot.eff.org/pages/about
[8]: https://github.com/certbot/certbot/releases
[9]: https://github.com/certbot/certbot/blob/master/LICENSE.txt

[21]: https://cloud.digitalocean.com/login
[22]: https://letsencrypt.org
