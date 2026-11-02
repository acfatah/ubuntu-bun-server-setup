# Configuration

The toggles and `KEY=VALUE` arguments the installer accepts. Template
and Bun download sources are in [Installation](installation.md).

## Environment toggles

Pass toggles as environment variables or as `KEY=VALUE` arguments to
`install.sh`. Unknown arguments are rejected. Only `1` enables a toggle;
`0`, `false` or empty leave it off, and any other value is rejected:

- `SKIP_BUN_APP=1` — Do not create sample `/srv/app` and use `/var/www/html` 
  for Nginx static root. Ubuntu's stock Nginx site is kept as is: there is
  no `/api/` proxy, no Bun fallback and no `cloudflare-only.conf` include
  line (real client IP still applies; see [Cloudflare](cloudflare.md)).
  You then serve your own files from `/var/www/html` and run your own
  app; see [Bring your own
  stack](app.md#bring-your-own-stack-skip_bun_app1).

- `SKIP_CLOUDFLARE=1` — Do not install the Cloudflare updater, its timer
  or its Nginx files, and do not fetch Cloudflare's IP ranges. See
  [Cloudflare](cloudflare.md).

- `FULL_UPGRADE=1` — Upgrade packages with `apt-get full-upgrade`, which
  may remove packages and install new kernels. By default the installer runs
  `apt-get upgrade`, which never removes packages. Either way, the summary
  prints `Reboot required to finish package upgrades: sudo reboot` when
  `/var/run/reboot-required` exists.

- `SKIP_UPGRADE=1` — Run `apt-get update` (base packages need fresh
  indexes) but upgrade no package. Use it to re-run for a config fix on a
  host under change control. It cannot be combined with `FULL_UPGRADE=1`:
  the pair exits 1 before anything runs. Missing base packages are still
  installed, at the candidate version.

  Snaps refresh on snapd's own schedule, not the installer's: the Certbot
  snap updates itself up to four times a day whatever you pass here. To
  hold it until you refresh it by hand, run
  `sudo snap refresh --hold certbot`; to keep all snap refreshes in a
  window, set it, for example
  `sudo snap set system refresh.timer=fri,23:00-01:00`. A held snap still
  updates on an explicit `sudo snap refresh certbot`.

- `SKIP_CERTBOT=1` — Install neither snapd nor Certbot, and leave out the
  summary's Certbot check. Bring your own ACME client (acme.sh, lego, a
  load balancer's certificates) to get certificates. A later run without it
  installs snapd and Certbot.

- `SKIP_UFW=1` — Leave UFW untouched: no rules, no default policy, no
  `ufw enable`. Use it when another firewall or your cloud's security
  groups filter traffic. A later run without it enables UFW; see
  [Re-running the installer](operations.md#re-running-the-installer).

- `BUN_VERSION=X.Y.Z` or `BUN_VERSION=latest` — Not an on/off toggle:
  install that Bun release instead of the pinned one. Any other value is
  rejected. See [Bun version](installation.md#bun-version).

Example:

```bash
sudo SKIP_BUN_APP=1 bash install.sh
# or
sudo bash install.sh SKIP_BUN_APP=1 FULL_UPGRADE=1
sudo bash install.sh SKIP_CLOUDFLARE=1
sudo bash install.sh SKIP_UFW=1
sudo bash install.sh SKIP_UPGRADE=1
sudo bash install.sh SKIP_CERTBOT=1
sudo bash install.sh BUN_VERSION=latest
```

---

<div align="center">

[← Installation](installation.md) · [Documentation index](README.md) · [Operations →](operations.md)

</div>
