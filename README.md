# Ubuntu Bun Server Setup

<p>
  <a href="./LICENSE">
    <img alt="GitHub" src="https://img.shields.io/github/license/acfatah/ubuntu-bun-server-setup?style=flat-square"></a>
  <a href="https://github.com/acfatah/ubuntu-bun-server-setup/releases">
    <img alt="GitHub Release" src="https://img.shields.io/github/v/release/acfatah/ubuntu-bun-server-setup"></a>
  <a href="https://github.com/acfatah/ubuntu-bun-server-setup/commits/main">
    <img
      alt="GitHub last commit (by committer)"
      src="https://img.shields.io/github/last-commit/acfatah/ubuntu-bun-server-setup?display_timestamp=committer&style=flat-square"></a>
</p>

Bootstrap an opinionated, production-ready Bun application environment for Ubuntu.

- Installs Bun, Nginx, UFW, Certbot (via snap), and sets up a Bun app under `/srv/app`.
- Creates a systemd service `bun-app` for running the Bun app as an
  unprivileged `bun-app` user inside a systemd sandboxing profile (see
  [Security](#security)).
- Installs Bun system-wide at `/usr/local/bin/bun`.
- Configures Nginx as a reverse proxy to `localhost:3000` and serves static files 
  from `/var/www/app/dist` (or `/var/www/html` if sample app is skipped). The
  sample app binds `127.0.0.1` only, so Bun is reachable just through Nginx.
- Configures UFW: limits SSH on every port `sshd -T` reports (22 if sshd is
  absent), allows HTTP (80) and HTTPS (443) via the 'Nginx Full' profile when
  available. It never resets UFW: existing rules are kept, and the default
  policy (deny incoming, allow outgoing) is set only while UFW is inactive.
- Upgrades packages with `apt-get upgrade` (`FULL_UPGRADE=1` for
  `full-upgrade`) and prints a reboot hint when one is required.
- Optionally creates a sample Bun app at `/srv/app` and enables the bun-app service 
  (set `SKIP_BUN_APP=1` to skip; Ubuntu's stock Nginx site is then kept).
- Safe to re-run: files you may have edited are kept (see
  [Re-running the installer](#re-running-the-installer)).
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

The same toggle also works as an environment variable:

```bash
curl -fsSL https://raw.githubusercontent.com/acfatah/ubuntu-bun-server-setup/main/install.sh | sudo SKIP_BUN_APP=1 bash
```

Or after cloning this repository:

```bash
sudo bash install.sh
```

When done:

- Check Bun: `bun --version`
- Bun app service: `systemctl status bun-app` (logs: `journalctl -u bun-app -f`)
- App data (DB, uploads): `/var/lib/bun-app`, also reachable as
  `/srv/app/data`.
- Sandbox score: `systemd-analyze security bun-app`.
- Nginx default site: `http://<server-ip>` serving `/var/www/html`.
- Get HTTPS cert for your Nginx site: `certbot --nginx`.
- Installer log: `/var/log/bun-installer.log` (every run is appended).

If a step fails, the installer stops, exits non-zero and prints
`install failed at line N (<step>)`. If it completes but something is not
running (Certbot, Nginx, `bun-app`), the summary lists it and the exit
status is non-zero.

## Re-running the installer

Re-running upgrades packages and Bun, and keeps what you changed. Each kept
file is reported as `Kept existing <path>`:

- `/etc/systemd/system/bun-app.service` and `/etc/bun-app.env`.
- `/etc/nginx/sites-available/default`, while its first line is the
  `# Managed by ubuntu-bun-server-setup.` marker. Without the marker (for
  example Ubuntu's stock site) the installer replaces it. In skip mode it
  is never touched.
- `/var/www/html/index.html` in skip mode.
- `/etc/nginx/snippets/bun-proxy.conf` and
  `/etc/nginx/conf.d/bun-connection-upgrade.conf` (not installed in skip
  mode).
- `/etc/nginx/cloudflare-ip-filter.conf` and
  `/etc/nginx/cloudflare-update-ips.sh`.
- `/etc/update-motd.d/00-custom`.
- `INSTANCE_ID` in `/etc/environment`: reused, kept to a single line.
- The sample app, if `/srv/app/server.ts` exists. Hosts installed before
  0.3.0 keep a `server.ts` that listens on all interfaces; add
  `hostname: "127.0.0.1"` to `Bun.serve` to match new installs.
- UFW rules and the default policy. Rules are re-added only if missing, and
  none is removed. If you later move sshd to another port, re-running limits
  the new port, but the old rule stays; remove it yourself, for example
  `sudo ufw delete limit 22/tcp`.

Because of this, template improvements in newer releases reach new installs
only. To pick one up on an existing host, delete the file (or, for the
Nginx site, its marker line) and re-run.

### Upgrading from 0.3.x

- **`/api/` keeps its prefix.** Nginx now passes `/api/x` to Bun as
  `/api/x`, as the `@bun` fallback always did. Before, it arrived as `/x`.
  An app that routes `/x` for `/api/x` must route `/api/x` instead, once
  the new Nginx site is in place.
- **Existing hosts keep their old files.** The old site still strips the
  prefix, and the old unit still sets `Environment=INSTANCE_ID=...`.
- **To adopt the new templates,** delete the marker line of
  `/etc/nginx/sites-available/default` and delete
  `/etc/systemd/system/bun-app.service` (move your changes to a drop-in
  first), then re-run. A re-run on an old host also installs the proxy
  snippet, the map file and `/etc/bun-app.env`; they stay unused until the
  site and unit that use them are replaced.

The installer hides Ubuntu's MOTD header and help text with dpkg
diversions, so package upgrades do not bring them back. Undo with:

```bash
for f in 00-header 10-help-text; do
  sudo dpkg-divert --no-rename --remove /etc/update-motd.d/$f
  sudo mv /var/lib/bun-installer/motd-disabled/$f /etc/update-motd.d/$f
done
```

## Cloudflare IP updates (optional)

The [templates/cloudflare-update-ips.sh](templates/cloudflare-update-ips.sh)
  script downloads Cloudflare's IPv4 and IPv6 ranges, converts each line into an `allow`
  directive, and rewrites `/etc/nginx/cloudflare-ip-filter.conf` before reloading Nginx.

The nginx default config already ships with the include commented out. To enable
this feature, uncomment the `include cloudflare-ip-filter.conf;` line in the server
block to apply the allowlist to the default host.

If you need the rules applied globally, place the include in the `http { ... }` block
of `/etc/nginx/nginx.conf` instead, so every server block inherits it.

Schedule the script with cron (runs as root so it can reload Nginx) by using `crontab -e`;
for example, adding the following line:

```
1 2 * * * /etc/nginx/cloudflare-update-ips.sh
```

This runs shortly after 2:00 AM every day to keep Cloudflare's allowlist current. The script logs warnings to `/var/log/cloudflare-update-ips.log` if it can’t download enough addresses.

## Security

### Service user

The Bun app runs as `bun-app`, a system user with no login shell
(`/usr/sbin/nologin`) and no password. Remote code execution in the app
yields that user's rights, not root.

Bun is installed to `/usr/local/bin/bun` (via `BUN_INSTALL=/usr/local`) so
non-root users can execute it. Hosts provisioned by older versions of this
installer had `/usr/local/bin/bun` symlinked into `/root/.bun`, which
`bun-app` cannot read; re-running the installer replaces that symlink with a
real binary. `/root/.bun` is left in place and can be removed manually.

### Environment file

The unit reads `/etc/bun-app.env` (`EnvironmentFile=`), which holds
`INSTANCE_ID` and `PORT=3000`:

- **Root-only (`0600`).** systemd reads it as root, so the app gets the
  values but `bun-app` cannot read the file. Put secrets here, not in
  `/srv/app`.
- **Apply edits** with `sudo systemctl restart bun-app`. Re-runs keep the
  file.
- **A `PORT` change** must be mirrored in `proxy_pass` in
  `/etc/nginx/snippets/bun-proxy.conf`, then `sudo nginx -t && sudo
  systemctl reload nginx`.

### Filesystem layout

Code and state are kept apart:

| What               | Path                                  | Owner   | Service access |
| ------------------ | ------------------------------------- | ------- | -------------- |
| Code, node_modules | `/srv/app`                            | root    | read-only      |
| DB, uploads, state | `/var/lib/bun-app` (= `/srv/app/data`) | bun-app | read-write     |
| Cache              | `/var/cache/bun-app`                  | bun-app | read-write     |

- `/var/lib/bun-app` and `/var/cache/bun-app` are created and owned by
  systemd (`StateDirectory=`, `CacheDirectory=`). The state dir is mode
  `0750` and the unit sets `UMask=0027`, so other users cannot read your
  data.
- `/srv/app/data` is a symlink to the state dir, so apps can use relative
  paths. systemd also exports the path as `$STATE_DIRECTORY`:

  ```ts
  import { Database } from "bun:sqlite";

  const db = new Database(`${process.env.STATE_DIRECTORY}/app.db`);
  // or: new Database("./data/app.db")
  ```

- The data outlives code deploys: wiping and replacing `/srv/app` never
  touches `/var/lib/bun-app`. Back up that one directory.

### Sandboxing

`templates/bun-app.service` enables these systemd options. Each one only
affects the `bun-app` process tree; the rest of the host is unchanged.

| Directive | Blocks | May break |
| --- | --- | --- |
| `NoNewPrivileges=yes` | Gaining privileges via setuid binaries (`sudo`, `su`) or file capabilities | Apps that shell out to `sudo` |
| `ProtectSystem=strict` | Writing anywhere on the filesystem except the state/cache dirs and any `ReadWritePaths=` | Writing logs or files elsewhere, e.g. `/var/log/myapp` (log to stdout instead) |
| `ProtectHome=yes` | Reading `/home`, `/root`, `/run/user` (SSH keys, dotfiles, `.env` in homes) | Apps reading files from a home dir |
| `PrivateTmp=yes` | Seeing or tampering with other processes' `/tmp` and `/var/tmp`; private copy, wiped on stop | Sharing files or unix sockets via `/tmp` (use `RuntimeDirectory=`) |
| `PrivateDevices=yes` | Access to physical devices (`/dev/sda`, ...); only `null`, `zero`, `random`, `urandom`, `tty` remain | GPU, serial, USB access |
| `ProtectKernelTunables=yes` | Writing `/proc/sys`, `/sys` (sysctl changes) | Nothing a web app does |
| `ProtectKernelModules=yes` | Loading kernel modules | Nothing a web app does |
| `ProtectKernelLogs=yes` | Reading the kernel log (`dmesg`) | Nothing a web app does |
| `ProtectControlGroups=yes` | Writing `/sys/fs/cgroup` (escaping resource limits) | Container managers only |
| `ProtectClock=yes` | Changing the system clock | Nothing a web app does |
| `ProtectHostname=yes` | Changing the hostname | Nothing a web app does |
| `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK` | Raw packet sockets (sniffing), bluetooth and other exotic socket types | Apps needing other socket families |
| `RestrictNamespaces=yes` | Creating namespaces/containers | Apps that sandbox children themselves |
| `RestrictRealtime=yes` | Realtime scheduling (starving the CPU) | Nothing a web app does |
| `RestrictSUIDSGID=yes` | Creating setuid/setgid files | Nothing a web app does |
| `LockPersonality=yes` | Switching execution domain (an exploit aid) | Nothing a web app does |
| `CapabilityBoundingSet=` (empty) | Every root-like capability, even if privileges are somehow gained | Binding ports below 1024 (keep Bun on 3000 behind Nginx) |
| `SystemCallArchitectures=native` | 32-bit syscalls (an exploit trick) | Running 32-bit binaries |

Deliberately **not** set:

- `MemoryDenyWriteExecute=yes`: Bun's JavaScript engine compiles code into
  memory that is both writable and executable. With this option Bun crashes
  on start and the unit restarts every 3 seconds.
- `SystemCallFilter=`: the most likely option to break apps in hard to
  debug ways.

`AF_NETLINK` is allowed because `os.networkInterfaces()` needs it, and some
libraries call it indirectly.

### Customising the sandbox

Prefer a drop-in to editing `/etc/systemd/system/bun-app.service`. The
installer keeps an existing unit on re-runs, but a drop-in keeps your
changes apart from the installed defaults:

```bash
sudo systemctl edit bun-app
```

```ini
[Service]
# Allow writes to an extra directory
ReadWritePaths=/srv/app/public/uploads
# Or create /var/log/bun-app owned by the service user
LogsDirectory=bun-app
```

Then `sudo systemctl restart bun-app`. Revert with
`sudo systemctl revert bun-app`.

### Troubleshooting

Check `journalctl -u bun-app` for these symptoms:

| Symptom | Likely cause |
| --- | --- |
| `EROFS: read-only file system` | Writing outside the state/cache dirs (`ProtectSystem=strict`) |
| `EACCES: permission denied` | File owned by root, or in a home dir (`ProtectHome`) |
| `EAFNOSUPPORT` | Socket family not in `RestrictAddressFamilies` |
| `status=226/NAMESPACE` | systemd could not set up the sandbox (missing path in `ReadWritePaths=`, or unsupported container) |
| `status=203/EXEC` | `/usr/local/bin/bun` missing or not executable; re-run the installer |

Score the unit (0 = locked down, 10 = unprotected) with:

```bash
systemd-analyze security bun-app
```

### Gotchas

- Deploy as root: copy code into `/srv/app` and run `bun install` there as
  root. The service only needs to read it.
- `/srv/app/data` is a symlink. `rm -rf /srv/app` removes the link but not
  the data; re-run the installer (or `ln -s /var/lib/bun-app
  /srv/app/data`) to restore it. Beware `rm -rf /srv/app/data/`: the
  trailing slash follows the link and deletes the data.
- Nginx (`www-data`) cannot read the `0750` state dir. Serve uploads
  through Bun, or grant access with a drop-in (`StateDirectoryMode=0755`)
  after considering what else lives there.
- `su bun-app` and `sudo -iu bun-app` fail (no login shell). To test
  permissions as the service user, run a single command:
  `sudo -u bun-app touch /srv/app/data/probe`. This runs outside the
  sandbox, so it checks file ownership only, not `ProtectSystem` rules.

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
tests/docker/run.sh test_idempotent
tests/docker/run.sh test_host_safety
```

The `.sh` suffix is optional; both `test_default` and `test_default.sh` work.

### Test scenarios

- `test_root_guard.sh` — ensures the installer fails when run as a non-root
  user.
- `test_default.sh` — runs a default install and verifies systemd units,
  application files, Nginx configuration, HTTP response (`"Hello Bun"`),
  the `/api/` proxy to Bun (prefix kept), security headers, a single
  `Cache-Control` on `/assets/`, a `Connection: upgrade` header sent only
  for upgrade requests, the root-only `/etc/bun-app.env`, the non-root `bun-app` service user, read-only
  code / writable state dir, Bun listening on `127.0.0.1:3000` only, port
  22 limited when no sshd is installed, and `certbot` availability.
- `test_skip_sample.sh` — runs the installer with `SKIP_BUN_APP=1` and checks
  that Nginx serves `/var/www/html` and returns the expected `"Hello World"`
  content, that the stock Nginx site is kept and no proxy snippet or map
  file is installed, and that a re-run keeps a
  custom `index.html`.
- `test_idempotent.sh` — rejects `SKIP_BUN_APP=yes`, installs with
  `SKIP_BUN_APP=0`, edits installed files, re-runs, and checks the edits
  survive, `INSTANCE_ID` stays a single stable line (also in
  `/etc/bun-app.env` and the process environment), and the MOTD
  diversions outlast a `base-files` reinstall.
- `test_piped_install.sh` — pipes the installer into `bash -s --
  SKIP_BUN_APP=1` the way the Quick Start does, checks the argument takes
  effect, that no `BASH_SOURCE` error is printed, that remote templates are
  used, and that unknown arguments are rejected.
- `test_host_safety.sh` — rejects `FULL_UPGRADE=yes`, installs
  openssh-server on port 2222 and checks UFW limits `2222/tcp` (not 22) and
  the default run uses `apt-get upgrade`. After adding a rule and changing
  the default incoming policy, a `FULL_UPGRADE=1` re-run keeps both, uses
  `full-upgrade`, prints the reboot hint, and adds no duplicate SSH rule.

You can override the test image name with the `BUN_INSTALLER_TEST_IMAGE`
environment variable if you want to reuse or inspect the image:

```bash
BUN_INSTALLER_TEST_IMAGE=my-registry/ubuntu-bun-installer-tests make test
```

## Environment toggles

Pass toggles as environment variables or as `KEY=VALUE` arguments to
`install.sh`. Unknown arguments are rejected. Only `1` enables a toggle;
`0`, `false` or empty leave it off, and any other value is rejected:

- `SKIP_BUN_APP=1` — Do not create sample `/srv/app` and use `/var/www/html` 
  for Nginx static root. Ubuntu's stock Nginx site is kept as is: there is
  no `/api/` proxy, no Bun fallback and no Cloudflare include line.
  You are now responsible for building/copying your own Bun-generated HTML assets into `/var/www/html`.

  Build steps typically look like `bun install && bun run build` from your project and then `cp -R dist/* /var/www/html` before managing your own Bun service.

- `FULL_UPGRADE=1` — Upgrade packages with `apt-get full-upgrade`, which
  may remove packages and install new kernels. By default the installer runs
  `apt-get upgrade`, which never removes packages. Either way, the summary
  prints `Reboot required to finish package upgrades: sudo reboot` when
  `/var/run/reboot-required` exists.

Example:

```bash
sudo SKIP_BUN_APP=1 bash install.sh
# or
sudo bash install.sh SKIP_BUN_APP=1 FULL_UPGRADE=1
```

## Notes

- The default Bun app runs from `/srv/app` and executes `bun run start`.
- Static files are served by Nginx from `/var/www/app/dist` (or `/var/www/html` if 
  sample app is skipped). Place your built assets in that directory and set the correct 
  permissions:

  ```bash
  sudo chown -R www-data:www-data /var/www/app/dist
  sudo find /var/www/app/dist -type d -exec chmod 755 {} +
  sudo find /var/www/app/dist -type f -exec chmod 644 {} +
  ```

- Static files are served at `/`; anything not found falls back to Bun.
  `/api/` always goes to Bun with the full URI (`/api/x` arrives as
  `/api/x`). Both share `/etc/nginx/snippets/bun-proxy.conf`.
- To use your own Bun app, replace `/srv/app` contents (keep the `data`
  symlink). Change `ExecStart` or other settings with
  `sudo systemctl edit bun-app` rather than editing the unit file (see
  [Customising the sandbox](#customising-the-sandbox)).
- If you skip the default app, set up your own Bun application and systemd
  unit file. Create the service user first
  (`sudo useradd --system --user-group --home-dir /var/lib/bun-app
  --no-create-home --shell /usr/sbin/nologin bun-app`). Example, identical
  to the installed unit:

  ```ini
  [Unit]
  Description=Bun App
  Wants=network-online.target
  After=network-online.target

  [Service]
  Type=simple
  User=bun-app
  Group=bun-app
  WorkingDirectory=/srv/app
  ExecStart=/usr/local/bin/bun run start
  Restart=always
  RestartSec=3
  Environment=NODE_ENV=production
  Environment=XDG_CACHE_HOME=/var/cache/bun-app
  # INSTANCE_ID, PORT and any secrets; root-only, kept on re-run
  EnvironmentFile=-/etc/bun-app.env
  StandardOutput=journal
  StandardError=journal
  SyslogIdentifier=bun-app

  # Writable dirs, created and chowned to User= by systemd.
  # /srv/app/data is a symlink to the state dir.
  StateDirectory=bun-app
  StateDirectoryMode=0750
  CacheDirectory=bun-app
  UMask=0027

  # Sandboxing. Score with: systemd-analyze security bun-app
  # Loosen per host with `systemctl edit bun-app` (drop-ins survive re-runs).
  NoNewPrivileges=yes
  ProtectSystem=strict
  ProtectHome=yes
  PrivateTmp=yes
  PrivateDevices=yes
  ProtectKernelTunables=yes
  ProtectKernelModules=yes
  ProtectKernelLogs=yes
  ProtectControlGroups=yes
  ProtectClock=yes
  ProtectHostname=yes
  RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
  RestrictNamespaces=yes
  RestrictRealtime=yes
  RestrictSUIDSGID=yes
  LockPersonality=yes
  CapabilityBoundingSet=
  SystemCallArchitectures=native
  # No MemoryDenyWriteExecute: Bun's JIT needs writable+executable memory.

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
