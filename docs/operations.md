# Operations

Running an installed host: health checks and logs, re-running the
installer and what it keeps, upgrading from older releases, and
deploying your own app.

## Health check

**Endpoint.** The sample app answers `GET /healthz` with `200 ok`
(`text/plain`, `Cache-Control: no-store`). The Nginx site proxies it to Bun
without writing an access-log line, so a monitor polling every few seconds
does not flood the log.

- **Gotcha: your own app must answer `/healthz` too.** Otherwise
  `--check` below reports the probe as failed, and so does the summary of
  a re-run, which then exits non-zero. Return `200` with the body `ok`.
- **Monitor through the public hostname,** e.g.
  `https://example.com/healthz`. That checks DNS, TLS, Cloudflare (if used),
  Nginx and Bun in one request.
- **Under [Cloudflare only](cloudflare.md#cloudflare-only-off),** `/healthz` is reachable
  directly from the host itself (`127.0.0.1`, `::1`) only. Any other
  request that skips Cloudflare still gets 403, so the endpoint opens no
  path around Cloudflare's DDoS protection and WAF. Point outside monitors
  at the public hostname.

**`--check`.** Re-runs the summary's checks on an installed host, at any
time, without root:

```bash
bash install.sh --check
curl -fsSL https://github.com/acfatah/ubuntu-bun-server-setup/releases/latest/download/install.sh | bash -s -- --check
```

- **Gotcha: older installers lack it.** A release from before `--check`
  rejects it as an unknown argument (exit 1), which a monitor would read
  as unhealthy.

- **Checks:** Nginx is active; `bun-app` is active and
  `http://127.0.0.1/healthz` answers `ok` (when
  `/etc/systemd/system/bun-app.service` exists, and the site has the
  `/healthz` location); Certbot runs (when the snap or `/usr/bin/certbot`
  exists). It infers this from the host, so pass no toggles.
- **Caveat: Certbot is checked less as non-root.** As root it runs
  `certbot --version`; any other user only checks that `/usr/bin/certbot`
  leads to an executable, since the snap fails for users without a
  writable home dir (such as `nobody`).
- **Exit status:** `0` healthy, `1` on any problem (each is listed), and
  `2` is reserved for a future config drift report.
- **Changes nothing:** no lock, no log entry, no download beyond the
  script itself, no package or file change.
- **Gotcha: sites from before `/healthz` skip the probe.** A re-run keeps
  an existing site (see [Re-running the
  installer](#re-running-the-installer)), so older hosts have no
  `location = /healthz`; `--check` then checks only that `bun-app` is
  active. Copy the location block from `templates/nginx-default.conf` to
  add it.

**Shipping logs.** `bun-app` logs to the systemd journal; nothing here
ships it off the host. Some options:

- `journalctl -u bun-app -o json` gives one JSON object per line, ready
  for any collector.
- `systemd-journal-upload` (package `systemd-journal-remote`) pushes the
  journal to a `systemd-journal-remote` server.
- [Vector](https://vector.dev/docs/reference/configuration/sources/journald/)
  and [Fluent Bit](https://docs.fluentbit.io/manual/pipeline/inputs/systemd)
  read the journal directly and forward it anywhere.

**Installer log.** `/etc/logrotate.d/bun-installer` rotates
`/var/log/bun-installer.log` monthly and keeps six compressed months.
Re-runs keep an edited copy.

## Re-running the installer

Re-running upgrades packages (unless `SKIP_UPGRADE=1`), brings Bun to the
pinned version (or `BUN_VERSION`), and keeps what you changed. A Bun of
another version is replaced; the same version is left untouched, so
`BUN_VERSION=1.3.0` on one run is undone by a later run without it. Each
kept file is reported as `Kept existing <path>`. Only one run at a time:
a run holds `/run/bun-installer.lock` (in root-only `/run`, so no other
user can take it first), and another run started meanwhile (say, an
operator while cloud-init still installs) exits 1 with `Another installer
run is in progress` before it changes anything.

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
- `/etc/update-motd.d/00-custom` and `/etc/logrotate.d/bun-installer`.
- `INSTANCE_ID` in `/etc/environment`: reused, kept to a single line.
- The app in `/srv/app`, if it has a `server.ts` or a `package.json`;
  only an app dir with neither gets the sample. Hosts installed before
  0.3.0 keep a `server.ts` that listens on all interfaces; add
  `hostname: "127.0.0.1"` to `Bun.serve` to match new installs.
- UFW rules and the default policy. Rules are re-added only if missing, and
  none is removed. If you later move sshd to another port, re-running limits
  the new port, but the old rule stays; remove it yourself, for example
  `sudo ufw delete limit 22/tcp`.
- UFW's on/off state. Each run records what it did as `ufw=` in
  `/var/lib/app-info/application.info`: `enabled`, `skipped`
  (`SKIP_UFW=1`) or `left-disabled`. If UFW is inactive and an earlier
  run enabled it (or the host was installed before this record existed),
  the installer leaves it off and prints a note; run `sudo ufw enable`
  and re-run to have it managed again. After a `SKIP_UFW=1` run, a run
  without the toggle enables UFW.
- The MOTD's UFW line. New installs show the live state (`UFW is active`,
  `UFW is inactive` or `UFW status unknown`); an existing
  `/etc/update-motd.d/00-custom` keeps its fixed `UFW is enabled` line
  until you delete it and re-run.

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
  [Cloudflare](cloudflare.md)), or delete it. Then delete both old files and
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
  [Customising the sandbox](security.md#customising-the-sandbox)).
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

  # Limits. Override with `systemctl edit bun-app`, e.g. MemoryMax=512M
  TimeoutStopSec=30
  LimitNOFILE=65536
  #MemoryMax=

  [Install]
  WantedBy=multi-user.target
  ```

---

<div align="center">

[← Configuration](configuration.md) · [Documentation index](README.md) · [Cloudflare →](cloudflare.md)

</div>
