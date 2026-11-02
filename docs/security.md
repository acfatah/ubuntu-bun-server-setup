# Security

How the installed services are confined: the service user, the
environment file, the filesystem layout, the systemd sandbox and limits
of both units, and how to customise and troubleshoot them.

To report a vulnerability, see [SECURITY.md](../SECURITY.md); please do not
open a public issue.

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
