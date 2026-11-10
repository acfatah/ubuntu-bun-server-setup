# Security

What the installer trusts and what the installed host exposes, how to
add SSH brute-force bans, how CIS benchmarks fit in, then how the
installed services are confined: the service user, the environment file,
the filesystem layout, the systemd sandbox and limits of both units, and
how to customise and troubleshoot them.

To report a vulnerability, see [SECURITY.md](../SECURITY.md); please do not
open a public issue.

## Threat model

**The installer** runs as root and downloads code. What it checks:

| Download | Checked against | Trust rests on |
| --- | --- | --- |
| Templates, release installer | SHA-256 sums built into the installer | the installer you ran |
| Templates, `main` (dev channel) or another `TEMPLATE_REF` | nothing | GitHub and TLS |
| Templates, a `templates/` next to `install.sh` | nothing | whoever wrote that directory |
| Bun, pinned version | SHA-256 sums built into the installer | the installer you ran |
| Bun, `BUN_VERSION=X.Y.Z` or `latest` | the release's `SHASUMS256.txt` | GitHub and TLS: sums and zip come from the same place |
| Ubuntu packages | apt's signed indexes | Ubuntu's archive keys |
| Certbot | the snap store's signatures | Canonical's snap store |
| Cloudflare IP ranges | a strict CIDR check, a minimum count | Cloudflare and TLS |

- **Every download uses TLS 1.2 or later** and follows redirects to
  `https://` only; `http://` mirrors are refused.
- **A release installer is as trustworthy as its download.** Check it
  against the release's `SHA256SUMS` (see [Pin and check a
  version](installation.md#pin-and-check-a-version)). Both files come
  from GitHub Releases: there is no build provenance and no signed tag
  yet, so the check catches a broken download, not a compromised
  release.

**The installed host** exposes:

- **Nginx on 80** (and 443 after Certbot), the only service open to
  the network besides SSH. UFW rate-limits the SSH port(s) and denies
  everything else incoming.
- **Bun on `127.0.0.1:3000` only,** reached through Nginx, run as the
  unprivileged `bun-app` with no capabilities and read-only code.
- **The Cloudflare updater** runs as root, sandboxed, once a day.
- **Plain HTTP until you run Certbot.** The installer gets no
  certificate, and the HSTS header ships commented out in the site. See
  Operations, [TLS with Certbot](operations.md#tls-with-certbot).
- **Snaps update on their own.** The Certbot snap refreshes outside any
  change window unless you hold it; see `SKIP_UPGRADE` in
  [Configuration](configuration.md#environment-toggles).
- **"Cloudflare only" admits other Cloudflare customers.** It checks
  that a request comes from a Cloudflare edge, not from your zone. See
  Cloudflare, [Other Cloudflare
  customers](cloudflare.md#other-cloudflare-customers).

## SSH brute force

The installer ships no fail2ban: host hardening is out of scope (see
README, [Out of scope](../README.md#out-of-scope)). What it does is
`ufw limit` on every SSH port, which blocks a source address that opens
6 or more connections in 30 seconds. With key-only logins that is
enough for most hosts:

```bash
# /etc/ssh/sshd_config.d/50-keys-only.conf
PasswordAuthentication no
KbdInteractiveAuthentication no
```

Test a key login in a second session before you close the first, then
`sudo systemctl reload ssh`.

To also ban addresses that keep failing, add fail2ban with the SSH jail
only:

```bash
sudo apt-get install -y fail2ban python3-systemd
```

```ini
# /etc/fail2ban/jail.d/sshd.local
[sshd]
enabled  = true
backend  = systemd
port     = ssh
maxretry = 5
findtime = 10m
bantime  = 1h
# Never ban these: your office, VPN or CI runners
ignoreip = 127.0.0.1/8 ::1 203.0.113.10
```

```bash
sudo systemctl restart fail2ban
sudo fail2ban-client status sshd                  # failed and banned counts
sudo fail2ban-client set sshd unbanip 203.0.113.7  # lift a ban
```

- **Set `port` to your SSH port.** `ssh` means 22. On another port
  (`2222`), a ban blocks port 22 and the attacker keeps going. Use the
  ports `sudo ufw status` shows as `LIMIT`.
- **`backend = systemd` reads the journal.** It needs `python3-systemd`
  and works whether or not `/var/log/auth.log` exists.
- **Check it counts failures.** Fail one login from another address,
  then `sudo fail2ban-client status sshd` should show `Currently
  failed: 1`. A `0` means the jail does not see sshd's log lines.
- **The installer leaves it alone.** A re-run adds UFW rules again and
  removes none, so fail2ban's own firewall rules survive it.
- **Do not add Nginx jails behind Cloudflare.** Proxied requests reach
  Nginx from a Cloudflare edge, so a ban blocks that edge for every
  visitor using it. Block abusive visitors in Cloudflare's WAF instead.
- **Shared addresses lock out everyone behind them.** CI runners and
  office NAT can collect failures from several users; list them in
  `ignoreip`.

## CIS benchmarks

The [CIS benchmarks](https://www.cisecurity.org/cis-benchmarks) are
hardening checklists for Ubuntu, Nginx and other products, published by
the Center for Internet Security. The installer does not apply one, and a
host it sets up is not CIS-compliant. Hardening the base system belongs
to your host's baseline image (see [Out of scope](../README.md#out-of-scope)).

Some benchmark checks already pass: UFW is enabled with incoming traffic
denied and the SSH port(s) rate-limited, and both units run sandboxed.
To audit or apply a full profile, use Ubuntu Pro's
[Ubuntu Security Guide](https://ubuntu.com/security/certifications/docs/usg)
(`usg audit cis_level1_server`) or start from a CIS-hardened image.

Test a profile on a spare host before production. These items conflict
with what the installer sets up:

- **A deny-outgoing UFW policy** blocks apt, Certbot renewals, Bun
  downloads and the daily Cloudflare IP fetch. The installer sets
  `allow outgoing` only on a host whose UFW was inactive, so allow
  outbound DNS, 80 and 443 if your profile denies the rest.
- **Removing snapd** breaks Certbot, which is installed only as a snap.
  Use `SKIP_CERTBOT=1` and get certificates another way.
- **`MemoryDenyWriteExecute=yes` on `bun-app`** crashes Bun at start (see
  [Sandboxing](#sandboxing)). Leave it out of any drop-in a hardening
  tool adds.
- **A `noexec` `/tmp`** is fine: the installer never runs anything from
  it.

## Service user

The Bun app runs as `bun-app`, a system user with no login shell
(`/usr/sbin/nologin`) and no password. Remote code execution in the app
yields that user's rights, not root.

Bun is installed to `/usr/local/bin/bun`, a root-owned `0755` file, so
non-root users can execute it but not change it. The installer never runs
a downloaded script as root: it installs the verified release binary (see
[Bun version](installation.md#bun-version)). Hosts provisioned by older versions of this
installer had `/usr/local/bin/bun` symlinked into `/root/.bun`, which
`bun-app` cannot read; re-running the installer replaces that symlink with a
real binary. `/root/.bun` is left in place and can be removed manually.

## Environment file

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

## Filesystem layout

Code and state are kept apart:

| What               | Path                                  | Owner   | Service access |
| ------------------ | ------------------------------------- | ------- | -------------- |
| Code, node_modules | `/srv/app`                            | root    | read-only      |
| DB, uploads, state | `/var/lib/bun-app` (= `/srv/app/data`) | bun-app | read-write     |
| Cache              | `/var/cache/bun-app`                  | bun-app | read-write     |
| Installer log      | `/var/log/bun-installer.log` (rotated by `/etc/logrotate.d/bun-installer`) | root:adm | none |
| Web root           | `/var/www/app/dist`                   | root    | none (Nginx reads it) |

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
  touches `/var/lib/bun-app`. Back up that one directory. See [Your
  app](app.md) for deploy recipes that keep it.
- The web root is owned by root (directories `755`, files `644`), so an
  Nginx worker can read the files it serves but not change them. Hosts
  installed before 1.0 have it owned by `www-data`; re-runs leave it as
  it is. Fix it once with:

  ```bash
  sudo chown -R root:root /var/www/app/dist
  ```

## What the web root serves

Nginx serves every file under the web root (`/var/www/app/dist`, or
`/var/www/html` with `SKIP_BUN_APP=1`) to anyone, so put only build
output there.

- **Dotfiles answer 404.** Any path with a segment starting with a dot,
  such as `/.env` or `/.git/config`, gets a 404 with the usual security
  headers. `/.well-known/` stays open, for ACME webroot challenges and
  `security.txt`.
- **`/assets/` and `/api/` skip that check.** Nginx does not test regex
  locations for `^~` prefixes, so `/assets/.env` would be served. Never
  copy a project folder or a git clone into the web root.
- **Hosts installed before 1.0** keep their site file, which has no such
  block. Add it to `/etc/nginx/sites-available/default`, before
  `location /`, then run `sudo nginx -t && sudo systemctl reload nginx`:

  ```nginx
  location ~ /\.(?!well-known/) {
    return 404;
  }
  ```

- **The stock site** (`SKIP_BUN_APP=1`) is Ubuntu's, not the
  installer's, so it never gets the block. Add it there by hand too.

## Sandboxing

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

## Limits

The unit also sets these limits:

| Directive | Effect | Change it when |
| --- | --- | --- |
| `TimeoutStopSec=30` | systemd sends `SIGTERM`, waits 30 s for in-flight requests, then `SIGKILL`s | Shutdown work (draining queues, closing sockets) takes longer |
| `LimitNOFILE=65536` | Up to 65536 open files and sockets (the default soft limit is 1024) | Many thousands of WebSockets per process |
| `#MemoryMax=` (commented out) | No memory cap by default; set one to have the kernel kill a leaking app instead of the host swapping | You know the app's peak memory |

Set any of them in a drop-in (see below), e.g. `MemoryMax=512M`.

- **Gotcha: new installs only.** A re-run keeps an existing
  `bun-app.service`, so hosts installed before these limits keep systemd's
  defaults (90 s stop timeout, 1024 files). Add them with
  `sudo systemctl edit bun-app`.

## Cloudflare updater sandbox

`cloudflare-update-ips.service` runs as root, because the Nginx reload goes
through systemd, which wants uid 0. The unit confines it instead
(`systemd-analyze security cloudflare-update-ips`: 9.0 before, 2.2 now):

| Directive | Blocks |
| --- | --- |
| `NoNewPrivileges=yes`, `PrivateTmp=yes` | Same as for `bun-app` above |
| `ProtectSystem=strict` | Writing anywhere except `ReadWritePaths=` |
| `ReadWritePaths=/etc/nginx/cloudflare /var/log/nginx` | Nothing: the lists, and the logs `nginx -t` opens for writing |
| `RuntimeDirectory=cloudflare-update-ips`, `RuntimeDirectoryPreserve=yes` | Nothing: holds the updater's lock in `/run/cloudflare-update-ips` (`0755 root`), kept until reboot so a manual run's lock is never removed under it |
| `ProtectHome=yes` | Reading `/home`, `/root`, `/run/user` |
| `PrivateDevices=yes` | Access to physical devices |
| `ProtectKernelTunables=yes`, `ProtectKernelModules=yes`, `ProtectKernelLogs=yes` | Sysctl writes, module loading, `dmesg` |
| `ProtectControlGroups=yes`, `ProtectClock=yes`, `ProtectHostname=yes` | Cgroup writes, clock and hostname changes |
| `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX` | Every socket family but IP (the fetch) and unix (D-Bus, for the reload) |
| `RestrictNamespaces=yes`, `RestrictRealtime=yes`, `RestrictSUIDSGID=yes` | Namespaces, realtime scheduling, setuid files |
| `LockPersonality=yes`, `SystemCallArchitectures=native` | Execution domain switches, 32-bit syscalls |
| `MemoryDenyWriteExecute=yes` | Writable and executable memory (no JIT runs here) |
| `CapabilityBoundingSet=CAP_DAC_OVERRIDE` | Every capability but one: `nginx -t` opens `/var/log/nginx/*.log`, owned by `www-data`, for writing |
| `SystemCallFilter=@system-service`, `SystemCallErrorNumber=EPERM` | Syscalls outside systemd's set for ordinary services (mount, reboot, kexec, ...) |

- **Gotcha: a mirror must sit outside home dirs.** `ProtectHome=yes` hides
  `/root` and `/home`, so a `CLOUDFLARE_IPS_SOURCE` there fails under the
  timer (it still works from a shell). Use a path such as
  `/srv/cloudflare-ips`.
- **New installs only,** as for the limits: a re-run keeps an existing
  unit. Copy the `[Service]` lines from
  `templates/cloudflare-update-ips.service` into
  `sudo systemctl edit cloudflare-update-ips.service` to apply them.
- **Gotcha: older hosts keep the old lock.** The updater script and its
  unit are kept files, so hosts installed before keep
  `/run/lock/cloudflare-update-ips.lock`, which any local user can take
  first and so stop the updates. Replace both
  (`/usr/local/sbin/cloudflare-update-ips` and the unit) with the
  templates to move it.

## Customising the sandbox

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

## Troubleshooting

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

## Gotchas

- Deploy as root: copy code into `/srv/app` and run `bun install` there as
  root. The service only needs to read it. [Your app](app.md#deploying)
  has the full recipe.
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

---

<div align="center">

[← Cloudflare](cloudflare.md) · [Documentation index](README.md) · [Troubleshooting →](troubleshooting.md)

</div>
