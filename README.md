# Ubuntu Bun Server Setup

<p>
  <a href="./LICENSE">
    <img alt="GitHub" src="https://img.shields.io/github/license/acfatah/vue-shadcn-spa?style=flat-square"></a>
  <a href="https://github.com/acfatah/ubuntu-bun-server-setup/commits/main">
    <img
      alt="GitHub last commit (by committer)"
      src="https://img.shields.io/github/last-commit/acfatah/ubuntu-bun-server-setup?display_timestamp=committer&style=flat-square"></a>
</p>

Bootstrap an opinionated, production-ready Bun application environment for Ubuntu.

- Installs Bun, Nginx, UFW, Certbot (via snap), and sets up a Bun app under `/root/app`.
- Creates a systemd service `bun-app` for running the Bun app.
- Configures Nginx as a reverse proxy to `localhost:3000` and serves static files 
  from `/var/www/app/dist` (or `/var/www/html` if sample app is skipped).
- Configures UFW: allows SSH (22), HTTP (80), and HTTPS (443), limits SSH, and prefers 
  the 'Nginx Full' profile.
- Optionally creates a sample Bun app at `/root/app` and enables the bun-app service 
  (set `SKIP_BUN_APP=1` to skip).
- Intended for provisioning Ubuntu servers (22.04+); run as root/sudo with internet access.

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

> [!IMPORTANT]
> Piping remote scripts to a shell executes code from the network — review the script before running.

```bash
curl -fsSL https://raw.githubusercontent.com/acfatah/ubuntu-bun-server-setup/main/install.sh | sudo bash
```

To skip sample app:

```bash
curl -fsSL https://raw.githubusercontent.com/acfatah/ubuntu-bun-server-setup/main/install.sh | sudo bash -s -- SKIP_BUN_APP=1
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

## Testing

This project includes a Docker-based end-to-end test harness that provisions
an Ubuntu systemd environment in a container and runs the installer in
realistic scenarios.

### Requirements

- Docker installed and the Docker daemon running.
- Ability to run privileged containers (the test container runs systemd).
- Run commands from the repository root.

### Run the full test suite

From the project root:

```bash
make test
```

This will:

- Build a test image from `tests/docker/Dockerfile`.
- Start short-lived, privileged containers mounting this repo read-only at
  `/workspace`.
- Execute the test scripts under `tests/docker/scripts/*.sh`.

### Run an individual test

You can target a specific scenario by calling the test runner directly:

```bash
tests/docker/run.sh test_root_guard
tests/docker/run.sh test_default
tests/docker/run.sh test_skip_sample
```

The `.sh` suffix is optional; both `test_default` and `test_default.sh` work.

### Test scenarios

- `test_root_guard.sh` — ensures the installer fails when run as a non-root
  user.
- `test_default.sh` — runs a default install and verifies systemd units,
  application files, Nginx configuration, HTTP response (`"Hello Bun"`), and
  `certbot` availability.
- `test_skip_sample.sh` — runs the installer with `SKIP_BUN_APP=1` and checks
  that Nginx serves `/var/www/html` and returns the expected `"Hello World"`
  content.

You can override the test image name with the `BUN_INSTALLER_TEST_IMAGE`
environment variable if you want to reuse or inspect the image:

```bash
BUN_INSTALLER_TEST_IMAGE=my-registry/ubuntu-bun-installer-tests make test
```

## Environment toggles

Set any to `1` to skip:

- `SKIP_BUN_APP=1` — Do not create sample `/root/app` and use `/var/www/html` 
  for Nginx static root. 
  You are now responsible for building/copying your own Bun-generated HTML assets into `/var/www/html`.

  Build steps typically look like `bun install && bun run build` from your project and then `cp -R dist/* /var/www/html` before managing your own Bun service.

Example:

```bash
sudo SKIP_BUN_APP=1 bash install.sh
```

## Notes

- The default Bun app runs from `/root/app` and executes `bun run start`.
- Static files are served by Nginx from `/var/www/app/dist` (or `/var/www/html` if 
  sample app is skipped). Place your built assets in that directory and set the correct 
  permissions:

  ```bash
  sudo chown -R www-data:www-data /var/www/app/dist
  sudo find /var/www/app/dist -type d -exec chmod 755 {} +
  sudo find /var/www/app/dist -type f -exec chmod 644 {} +
  ```

- Static files are served at `/` and API is proxied to Bun at `/api`.
- To use your own Bun app, replace `/root/app` contents and update the systemd service 
  ExecStart as needed.
- If you skip the default app, set up your own Bun application and systemd unit file. 
  Example:

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
  Environment=INSTANCE_ID= # Value from /etc/environment
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
