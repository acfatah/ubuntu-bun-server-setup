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
  `full-upgrade`) and prints a reboot hint when one is required. A failed
  `apt-get update` is retried up to three times, 10 seconds apart.
- Installs a Cloudflare IP updater with a daily systemd timer, so Nginx logs
  the real client IP behind Cloudflare and can optionally refuse requests
  that bypass it (set `SKIP_CLOUDFLARE=1` to skip; see
  [Cloudflare](#cloudflare)).
- Optionally creates a sample Bun app at `/srv/app` and enables the bun-app service 
  (set `SKIP_BUN_APP=1` to skip; Ubuntu's stock Nginx site is then kept).
- Safe to re-run: files you may have edited are kept (see
  [Re-running the installer](#re-running-the-installer)).
- Intended for provisioning Ubuntu servers (22.04+); run as root/sudo with internet access.

## Prerequisites

- Ubuntu 22.04 or later, run as root or with sudo. Older releases are refused before any package is installed.
- Internet access for package and snap installs.


## Software Included

| Software     | Source | License |
| ---          | ---    | ---     |
| [Bun][1]     | Official installer, [latest release][2] | [MIT][3] |
| [Nginx][4]   | Ubuntu apt ([22.04][5], [24.04][10]) | [BSD-2-Clause][6] |
| [Certbot][7] | Snap, [latest release][8] | [Apache 2.0][9] |

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

To skip sample app:

```bash
curl -fsSL https://github.com/acfatah/ubuntu-bun-server-setup/releases/latest/download/install.sh | sudo bash -s -- SKIP_BUN_APP=1
```

The same toggle also works as an environment variable:

```bash
curl -fsSL https://github.com/acfatah/ubuntu-bun-server-setup/releases/latest/download/install.sh | sudo SKIP_BUN_APP=1 bash
```

Or after cloning this repository (the development channel; templates are
read from the clone):

```bash
sudo bash install.sh
```

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
running (Certbot, Nginx, `bun-app`), the summary lists it and the exit
status is non-zero.

### Pin and check a version

Download a fixed release, check it against the release's `SHA256SUMS`, then
run it:

```bash
v=0.5.1   # any release from 0.5.0 on
curl -fsSLO "https://github.com/acfatah/ubuntu-bun-server-setup/releases/download/v$v/install.sh"
curl -fsSLO "https://github.com/acfatah/ubuntu-bun-server-setup/releases/download/v$v/SHA256SUMS"
sha256sum -c SHA256SUMS
sudo bash install.sh
```

`--version` prints the installer version and where its templates come from;
`--help` lists the toggles. Neither needs root:

```bash
curl -fsSL https://github.com/acfatah/ubuntu-bun-server-setup/releases/latest/download/install.sh | bash -s -- --version
```

### Development channel

The `install.sh` on `main` is the development channel: it reports version
`dev`, fetches templates from `main`, and does not verify them.

```bash
curl -fsSL https://raw.githubusercontent.com/acfatah/ubuntu-bun-server-setup/main/install.sh | sudo bash
```

### Template source

Two environment variables change where templates are downloaded from. They
are not `KEY=VALUE` arguments; with `sudo`, put them after it, as in
`sudo TEMPLATE_REF=dev bash`.

- `TEMPLATE_REF=<ref>` — a branch, tag or commit of this repository. A
  release installer pointed at another ref skips verification and prints a
  warning, since the files are expected to differ. Letters, digits, `.`,
  `_`, `/` and `-` only, and no `..`.
- `TEMPLATE_BASE_URL=<url>` — the templates directory itself, such as a
  mirror or `file:///path/to/templates`. A release installer still verifies
  what it downloads from there.

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
- The Cloudflare updater, its service and timer units,
  `/etc/nginx/conf.d/bun-cloudflare.conf` and
  `/etc/nginx/snippets/cloudflare-only.conf`. The generated lists under
  `/etc/nginx/cloudflare/` belong to the updater; the installer fetches them
  only when missing.
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

### Upgrading from 0.4.x

- **The old Cloudflare helper is left alone.** Hosts installed before keep
  `/etc/nginx/cloudflare-update-ips.sh`, `/etc/nginx/cloudflare-ip-filter.conf`
  and any cron line that runs the script. A re-run adds the new updater,
  timer and Nginx files beside them, and real client IP takes effect.
- **Gotcha: an active old filter holds back real client IP.** With real
  client IP on, the old `deny all` would see visitor addresses and block
  everyone. So while any Nginx config still includes
  `cloudflare-ip-filter.conf`, a re-run skips
  `/etc/nginx/conf.d/bun-cloudflare.conf` and prints a notice.
- **To retire the old helper,** remove its line with `sudo crontab -e`.
  If your site includes `cloudflare-ip-filter.conf`, replace that line with
  `include snippets/cloudflare-only.conf;` to keep blocking (see
  [Cloudflare](#cloudflare)), or delete it. Then delete both old files and
  re-run the installer before reloading Nginx: it adds `bun-cloudflare.conf`,
  which the new include needs, and restarts Nginx.

The installer hides Ubuntu's MOTD header and help text with dpkg
diversions, so package upgrades do not bring them back. Undo with:

```bash
for f in 00-header 10-help-text; do
  sudo dpkg-divert --no-rename --remove /etc/update-motd.d/$f
  sudo mv /var/lib/bun-installer/motd-disabled/$f /etc/update-motd.d/$f
done
```

## Cloudflare

Installed by default; `SKIP_CLOUDFLARE=1` leaves it out. It keeps Nginx in
step with Cloudflare's published IP ranges:

| Path | What it is |
|---|---|
| `/usr/local/sbin/cloudflare-update-ips` | Updater script (kept on re-run) |
| `/etc/systemd/system/cloudflare-update-ips.{service,timer}` | Daily timer (kept on re-run) |
| `/etc/nginx/cloudflare/real-ip.conf`, `edge-ips.conf` | Generated lists; never edit |
| `/etc/nginx/conf.d/bun-cloudflare.conf` | Real client IP + `$bun_cloudflare_edge` geo (kept) |
| `/etc/nginx/snippets/cloudflare-only.conf` | Optional 403 rule (kept) |

The installer fetches the lists once; if that fetch fails, the install
fails.

### Real client IP (on)

Behind Cloudflare, every connection comes from a Cloudflare edge, so
`$remote_addr` and the access log would show Cloudflare, not the visitor.
`bun-cloudflare.conf` restores the visitor's address from the
`CF-Connecting-IP` header, for every site. The header is trusted only on
connections from Cloudflare's ranges, so a client cannot forge it by
connecting directly, and a host not behind Cloudflare sees no change.

### Cloudflare only (off)

To answer 403 to every request that bypasses Cloudflare, uncomment this line
in the server block of `/etc/nginx/sites-available/default`:

```nginx
include snippets/cloudflare-only.conf;
```

Then run `sudo nginx -t && sudo systemctl reload nginx`. The rule checks the
connecting address (`$realip_remote_addr`), not the restored client IP.

- **Gotcha: it locks out direct access.** Requests to the server's IP, from
  the host itself, or from monitors and health checks that skip Cloudflare
  all get 403. Make sure the DNS records are proxied (orange cloud) first.
- In skip mode, Ubuntu's stock site has no such line; add it yourself to
  any server block.

### Updates

`cloudflare-update-ips.timer` runs the updater daily (randomised by up to an
hour, caught up after downtime). Each run:

1. Fetches `https://www.cloudflare.com/ips-v4` and `ips-v6`.
2. Rejects the whole fetch if any line is not a CIDR, if a family is empty,
   or if there are fewer than 8 ranges. Nginx would even try to resolve a
   hostname in `set_real_ip_from`, so nothing else gets through.
3. Exits without a reload if nothing changed.
4. Swaps the new files in, runs `nginx -t`, and puts the old files back if
   it fails.
5. Reloads Nginx when it is running.

A failed run leaves Nginx and the current lists untouched. Check runs with:

```bash
systemctl list-timers cloudflare-update-ips.timer
journalctl -u cloudflare-update-ips
sudo cloudflare-update-ips              # run now
```

To use a mirror or a pinned copy instead of Cloudflare, set
`CLOUDFLARE_IPS_SOURCE` to a directory holding `ips-v4` and `ips-v6`: on the
command line, or for the timer with
`sudo systemctl edit cloudflare-update-ips.service`:

```ini
[Service]
Environment=CLOUDFLARE_IPS_SOURCE=/srv/cloudflare-ips
```

### Removing it

Remove the `cloudflare-only.conf` include from any site first, then:

```bash
sudo systemctl disable --now cloudflare-update-ips.timer
sudo rm /etc/systemd/system/cloudflare-update-ips.{service,timer} \
  /usr/local/sbin/cloudflare-update-ips \
  /etc/nginx/conf.d/bun-cloudflare.conf /etc/nginx/snippets/cloudflare-only.conf
sudo rm -r /etc/nginx/cloudflare
sudo systemctl daemon-reload
```

Then run `sudo nginx -t && sudo systemctl reload nginx`. Pass
`SKIP_CLOUDFLARE=1` on later re-runs, or the installer puts it back.

## Security

To report a vulnerability, see [SECURITY.md](SECURITY.md); please do not
open a public issue.

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
  file is installed, that the Cloudflare real-IP config is installed with
  the stock site untouched, and that a re-run keeps a custom `index.html`.
- `test_idempotent.sh` — rejects `SKIP_BUN_APP=yes`, installs with
  `SKIP_BUN_APP=0`, edits installed files, re-runs, and checks the edits
  survive, `INSTANCE_ID` stays a single stable line (also in
  `/etc/bun-app.env` and the process environment), and the MOTD
  diversions outlast a `base-files` reinstall.
- `test_piped_install.sh` — pipes the installer into `bash -s --
  SKIP_BUN_APP=1` the way the Quick Start does, with
  `TEMPLATE_BASE_URL=file:///workspace/templates` so the branch's templates
  are used. Checks the argument takes effect, Cloudflare support is
  installed, no `BASH_SOURCE` error is printed, downloaded (not local)
  templates are used, and that unknown arguments and a `TEMPLATE_REF` with
  `..` are rejected; `--version` names the ref and `--help` runs as
  non-root.
- `test_release_build.sh` — builds a pinned installer with
  `build-installer.sh 9.9.9`, checks its `SHA256SUMS` and `--version`, and
  pipes it with `file://` templates: templates are verified and
  `application.info` records `installer_version="9.9.9"`. A re-run with a
  tampered `application.info` fails with a checksum error and leaves the
  installed file unchanged; with `TEMPLATE_REF=main` it warns and skips
  verification.
- `test_fail_loudly.sh` — runs a copy of the repo with a broken
  `nginx-default.conf` and checks the installer exits non-zero with the
  `install failed at line N` message and no colour escapes off a terminal.
- `test_host_safety.sh` — rejects `FULL_UPGRADE=yes`, installs
  openssh-server on port 2222 and checks UFW limits `2222/tcp` (not 22) and
  the default run uses `apt-get upgrade`. After adding a rule and changing
  the default incoming policy, a `FULL_UPGRADE=1` re-run keeps both, uses
  `full-upgrade`, prints the reboot hint, and adds no duplicate SSH rule.
- `test_cloudflare.sh` — rejects `SKIP_CLOUDFLARE=yes`, checks the updater,
  enabled timer, generated lists and geo after a default install. Against a
  stubbed source (`CLOUDFLARE_IPS_SOURCE`), an HTML body, a junk line, a
  short list, an empty family, and a list `nginx -t` refuses all fail and
  leave the lists and Nginx unchanged; a good list applies, a repeat run
  reports `unchanged`, the access log shows the `CF-Connecting-IP` address,
  and the `cloudflare-only.conf` include answers 200 from an edge and 403
  otherwise. A re-run on a host whose site still includes the old
  `cloudflare-ip-filter.conf` does not enable real client IP.

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
  no `/api/` proxy, no Bun fallback and no `cloudflare-only.conf` include
  line (real client IP still applies; see [Cloudflare](#cloudflare)).
  You are now responsible for building/copying your own Bun-generated HTML assets into `/var/www/html`.

  Build steps typically look like `bun install && bun run build` from your project and then `cp -R dist/* /var/www/html` before managing your own Bun service.

- `SKIP_CLOUDFLARE=1` — Do not install the Cloudflare updater, its timer
  or its Nginx files, and do not fetch Cloudflare's IP ranges. See
  [Cloudflare](#cloudflare).

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
sudo bash install.sh SKIP_CLOUDFLARE=1
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
[5]: https://packages.ubuntu.com/jammy/nginx
[6]: https://nginx.org/LICENSE
[7]: https://certbot.eff.org/pages/about
[8]: https://github.com/certbot/certbot/releases
[9]: https://github.com/certbot/certbot/blob/master/LICENSE.txt
[10]: https://packages.ubuntu.com/noble/nginx
