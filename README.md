<div align="center">
  <a href="https://ubuntu.com"
    ><img width="100" src="https://raw.githubusercontent.com/marwin1991/profile-technology-icons/refs/heads/main/icons/ubuntu.png" alt="Ubuntu" title="Ubuntu"/></a>
  <a href="https://bun.sh"
    ><img width="100" src="https://raw.githubusercontent.com/marwin1991/profile-technology-icons/refs/heads/main/icons/bun_js.png" alt="Bun.js" title="Bun.js"/></a>
  <a href="https://www.typescriptlang.org"
    ><img width="100" src="https://raw.githubusercontent.com/marwin1991/profile-technology-icons/refs/heads/main/icons/typescript.png" alt="TypeScript" title="TypeScript"/></a>

  <h1>Ubuntu Bun Server Setup</h1>

  <p>
    <a href="./LICENSE">
      <img alt="GitHub" src="https://img.shields.io/github/license/acfatah/ubuntu-bun-server-setup?style=flat-square"></a>
    <a href="https://github.com/acfatah/ubuntu-bun-server-setup/releases">
      <img alt="GitHub Release" src="https://img.shields.io/github/v/release/acfatah/ubuntu-bun-server-setup?style=flat-square"></a>
    <a href="https://github.com/acfatah/ubuntu-bun-server-setup/commits/main">
      <img
        alt="GitHub last commit (by committer)"
        src="https://img.shields.io/github/last-commit/acfatah/ubuntu-bun-server-setup?display_timestamp=committer&style=flat-square"></a>
  </p>

  <h3>Sponsored by</h3>
  <a href="https://grandwizardtech.com/"
    ><img width="250" src=".github/assets/sponsors/grandwizardtech.png" alt="Grand Wizard Tech" title="Grand Wizard Tech"/></a>
</div>

## Introduction

Bootstrap an opinionated, production-ready Bun application environment for Ubuntu.

- Installs Bun, Nginx, UFW, Certbot (via snap; `SKIP_CERTBOT=1` to bring your own ACME client), and sets up a Bun app under `/srv/app`.
- Creates a systemd service `bun-app` for running the Bun app as an
  unprivileged `bun-app` user inside a systemd sandboxing profile (see
  [Security](docs/security.md)).
- Installs a pinned Bun release system-wide at `/usr/local/bin/bun`, after
  checking its SHA-256 sum (`BUN_VERSION` picks another; see
  [Bun version](docs/installation.md#bun-version)).
- Configures Nginx as a reverse proxy to `localhost:3000` and serves static files 
  from `/var/www/app/dist` (or `/var/www/html` if sample app is skipped). The
  sample app binds `127.0.0.1` only, so Bun is reachable just through Nginx.
- Configures UFW: limits SSH on every port `sshd -T` reports (22 if sshd is
  absent), allows HTTP (80) and HTTPS (443) via the 'Nginx Full' profile when
  available. It never resets UFW: existing rules are kept, and the default
  policy (deny incoming, allow outgoing) is set only while UFW is inactive.
  If you disable UFW after an install, re-runs leave it disabled
  (`SKIP_UFW=1` leaves UFW untouched altogether).
- Upgrades every installed package with `apt-get upgrade` on each run,
  re-runs included (`FULL_UPGRADE=1` for `full-upgrade`, `SKIP_UPGRADE=1`
  for none), and prints a reboot hint when one is required. A failed
  `apt-get update` is retried up to three times, 10 seconds apart; a
  running apt or dpkg is waited for first (see
  [Prerequisites](docs/installation.md#prerequisites)).
- Installs a Cloudflare IP updater with a daily systemd timer, so Nginx logs
  the real client IP behind Cloudflare and can optionally refuse requests
  that bypass it (set `SKIP_CLOUDFLARE=1` to skip; see
  [Cloudflare](docs/cloudflare.md)).
- Optionally creates a sample Bun app at `/srv/app` and enables the bun-app service 
  (set `SKIP_BUN_APP=1` to skip; Ubuntu's stock Nginx site is then kept).
- Safe to re-run: files you may have edited are kept (see
  [Re-running the installer](docs/operations.md#re-running-the-installer)). A second run
  started while one is in progress exits 1 and changes nothing.
- Intended for provisioning Ubuntu servers (22.04+); run as root/sudo with internet access.

## Software Included

| Software     | Source | License |
| ---          | ---    | ---     |
| [Bun][1]     | [GitHub release][2] zip, pinned (1.4.4), SHA-256 verified | [MIT][3] |
| [Nginx][4]   | Ubuntu apt ([22.04][5], [24.04][10]) | [BSD-2-Clause][6] |
| [Certbot][7] | Snap, [latest release][8] | [Apache 2.0][9] |

Certbot is the snap only, as its docs recommend; there is no apt
fallback. snapd is installed through apt when missing. With
`SKIP_CERTBOT=1`, neither is installed.

## Out of scope

The installer sets up one host for one Bun app. It does not cover:

- **Several apps per host, containers, or config management.** Ansible, Terraform and similar tools can run the installer, but it ships no integration for them.
- **Host hardening.** SSH hardening, fail2ban and CIS benchmarks belong to your host's baseline image. [docs/security.md](docs/security.md#ssh-brute-force) shows a minimal fail2ban setup, and [CIS benchmarks](docs/security.md#cis-benchmarks) lists what a CIS profile conflicts with.
- **Logging and metrics agents.** The data lives in the systemd journal (`journalctl -u bun-app`), the Nginx logs under `/var/log/nginx/`, and the app state in `/var/lib/bun-app`; pick your own agent to ship it.

What the installer does promise, and for how long: [docs/compatibility.md](docs/compatibility.md).

## Quick Start

Pipe the latest release's installer to bash (runs as root with sudo):

> [!IMPORTANT]
> Piping remote scripts to a shell executes code from the network — review the script before running.

```bash
curl -fsSL https://github.com/acfatah/ubuntu-bun-server-setup/releases/latest/download/install.sh | sudo bash
```

A release installer fetches the templates of its own tag and checks each one
against the SHA-256 sums built into it; a mismatch stops the install before
the file is written.

> [!NOTE]
> Release installers exist from 0.5.0 on. Older releases have no
> `install.sh` asset, so their versioned URLs return 404.

**Versioning.** Releases follow SemVer from 1.0.0. The release notes on
[GitHub Releases](https://github.com/acfatah/ubuntu-bun-server-setup/releases)
are the changelog. What stays stable, what each bump means and how long a
release is supported: [docs/compatibility.md](docs/compatibility.md).

Other ways to install (skipping the sample app, from a clone, a pinned
and checked version, the development channel, another Bun version):
[docs/installation.md](docs/installation.md). Prerequisites, such as
Ubuntu 22.04+ and a usable snapd, are listed
[there too](docs/installation.md#prerequisites).

When done:

- Check Bun: `bun --version`
- Bun app service: `systemctl status bun-app` (logs: `journalctl -u bun-app -f`)
- App data (DB, uploads): `/var/lib/bun-app`, also reachable as
  `/srv/app/data`.
- Sandbox score: `systemd-analyze security bun-app`.
- Nginx default site: `http://<server-ip>` serving `/var/www/app/dist`
  (`/var/www/html` with `SKIP_BUN_APP=1`).
- Get HTTPS cert for your Nginx site: `certbot --nginx`.
- Installer log: `/var/log/bun-installer.log` (every run is appended).

If a step fails, the installer stops, exits non-zero and prints
`install failed at line N (<step>)`. If it completes but something is not
running (Certbot unless skipped, Nginx, `bun-app`, the `/healthz` probe),
the summary lists it and the exit status is non-zero.

## Documentation

Operator documentation lives in [docs/](docs/README.md):

- [Installation](docs/installation.md): prerequisites, install options,
  pinned and development channels, template source, Bun version,
  air-gapped and proxied installs.
- [Configuration](docs/configuration.md): a reference table of every
  setting and flag, then the environment toggles in detail.
- [Architecture](docs/architecture.md): the install flow step by step,
  what runs, the Nginx files, and what a re-run keeps or rewrites.
- [Operations](docs/operations.md): health check, logs, re-running the
  installer, upgrading from older releases, TLS with Certbot, upgrading
  Bun, restarts, backups.
- [Your app](docs/app.md): what the host expects from an app, extending
  or replacing the sample, frontend plus API, deploying with rollback.
- [Cloudflare](docs/cloudflare.md): real client IP, "Cloudflare only",
  the IP list updater, removing it.
- [Security](docs/security.md): threat model, service user,
  environment file, filesystem layout, what the web root serves, systemd
  sandbox and limits, troubleshooting.
- [Troubleshooting](docs/troubleshooting.md): install failures, apt and
  snapd, the SSH rate limit, `--check` problems, client IPs, Cloudflare
  fetches.
- [Upgrading and support](docs/upgrading.md): moving a host to a newer
  release, the support window, known gaps.
- [Compatibility](docs/compatibility.md): the 1.x stability promise and
  support window.

Contributors: [CONTRIBUTING.md](CONTRIBUTING.md) covers the test suites.

## Health check

The sample app answers `GET /healthz` with `ok`, and `install.sh --check`
re-runs the summary's checks at any time, without root (exit 0 when
healthy, 1 on any problem). Endpoint, `--check`, shipping logs and the
installer log: [docs/operations.md](docs/operations.md#health-check).

## Re-running the installer

Re-running is safe: it upgrades packages, brings Bun to the pinned
version, and keeps every file you may have edited (`Kept existing
<path>`). The list of kept files, and the notes for Upgrading from 0.3.x
and Upgrading from 0.4.x:
[docs/operations.md](docs/operations.md#re-running-the-installer)
([0.3.x](docs/operations.md#upgrading-from-03x),
[0.4.x](docs/operations.md#upgrading-from-04x)).

## Cloudflare

Installed by default (`SKIP_CLOUDFLARE=1` leaves it out): Nginx logs the
real client IP behind Cloudflare, a daily timer keeps Cloudflare's IP
ranges current, and an optional include answers 403 to requests that
bypass Cloudflare. Setup, updates and removal:
[docs/cloudflare.md](docs/cloudflare.md).

## Security

To report a vulnerability, see [SECURITY.md](SECURITY.md); please do not
open a public issue.

The app runs as the unprivileged `bun-app` user in a systemd sandbox,
with its code read-only and its state in `/var/lib/bun-app`. Service
user, environment file, filesystem layout, sandbox and limits:
[docs/security.md](docs/security.md).

[1]: https://bun.sh
[2]: https://github.com/oven-sh/bun/releases
[3]: https://github.com/oven-sh/bun/blob/main/LICENSE
[4]: https://nginx.org
[5]: https://packages.ubuntu.com/jammy/nginx
[6]: https://nginx.org/LICENSE
[7]: https://certbot.eff.org/pages/about
[8]: https://github.com/certbot/certbot/releases
[9]: https://github.com/certbot/certbot/blob/master/LICENSE.txt
[10]: https://packages.ubuntu.com/noble/nginx
