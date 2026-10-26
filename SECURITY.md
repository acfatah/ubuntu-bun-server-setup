# Security Policy

## Supported versions

Only the [latest release][latest] gets security fixes. Older releases get
none; upgrade to the latest one instead. The `install.sh` on `main` is the
development channel and may change at any time.

## Reporting a vulnerability

Report it privately through GitHub's private vulnerability reporting:

<https://github.com/acfatah/ubuntu-bun-server-setup/security/advisories/new>

Please do not open a public issue, pull request or discussion for a
vulnerability.

## What to include

- The installer version, from `bash install.sh --version`.
- The Ubuntu release (`lsb_release -ds`).
- Steps to reproduce, and the toggles you used (`SKIP_BUN_APP`,
  `SKIP_CLOUDFLARE`, `FULL_UPGRADE`).
- The impact: what an attacker can do, and from where.

## Response

This project has one maintainer, so responses are best effort and no
response time is promised. Valid reports are fixed in a new release and
credited in a GitHub security advisory, unless you prefer otherwise.

## Scope

In scope:

- `install.sh` and the files it installs from `templates/` (Nginx config,
  systemd units, the Cloudflare updater, the sample app).
- The release tooling: `release.sh`, `build-installer.sh` and the release
  workflow.

Out of scope: bugs in Bun, Nginx, Certbot, Ubuntu or Cloudflare
themselves. Report those to their own projects.

[latest]: https://github.com/acfatah/ubuntu-bun-server-setup/releases/latest
