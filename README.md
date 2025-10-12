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
| [Nginx][4]  | [1.17.x][5] | [Artistic License 2.0][6] |
| [Certbot][7]    | [4.1.x][8]  | [Apache 2 on GitHub][9] |

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/acfatah/ubuntu-bun-installer/main/install.sh -o install.sh
sudo bash install.sh
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
