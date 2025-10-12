# Ubuntu Bun Installer

<p>
  <a href="https://github.com/acfatah/ubuntu-bun-installer/commits/main">
    <img
      alt="GitHub last commit (by committer)"
      src="https://img.shields.io/github/last-commit/acfatah/ubuntu-bun-installer?display_timestamp=committer&style=flat-square"></a>
</p>

Run a single script to bootstrap a production-ready Bun environment on Ubuntu.

- Installs Bun, Nginx, UFW
- Installs Certbot via snap
- Sets up a sample Bun app in `/root/app` (optional)
- Creates a `bun-app` systemd service (`NODE_ENV=production`)
- Writes application metadata and a helpful MOTD

## Prerequisites

- Ubuntu 22.04+ or 24.04, run as root or with sudo.
- Internet access for package and snap installs.


## Software Included

| Software    | Version     | License |
| ---         | ---         | ---     |
| [Bun][1]    | [1.3.x][2]  | [MIT][3] |
| [Nginx][4]  | [1.24.x][5] | [Artistic License 2.0][6] |
| [Certbot][7]    | [5.1.x][8]  | [Apache 2 on GitHub][9] |

## Quick Start

Pipe the installer directly to bash (runs as root with sudo)

> [!WARNING]
> Piping remote scripts to a shell executes code from the network — review the script before running.

```bash
curl -fsSL https://raw.githubusercontent.com/acfatah/ubuntu-bun-installer/main/install.sh | sudo bash
```

To skip sample app:

```bash
curl -fsSL https://raw.githubusercontent.com/acfatah/ubuntu-bun-installer/main/install.sh | sudo bash -s -- SKIP_SAMPLE_APP=1
```

Or after cloning this repository:

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

- `SKIP_SAMPLE_APP=1` — Do not create sample `/root/app`

Example:

```bash
sudo SKIP_SAMPLE_APP=1 bash install.sh
```

## Notes

- The default Bun app runs from `/root/app` and executes `bun run start`.
- Adjust to your app by replacing `/root/app` contents and updating the service ExecStart if needed.
- If you skip the default app, you have to set up your own Bun application and service (unit file).
  You may use the following example:
  ```ini
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
  StandardOutput=journal
  StandardError=journal
  SyslogIdentifier=bun-app

  [Install]
  WantedBy=multi-user.target
  ```

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
