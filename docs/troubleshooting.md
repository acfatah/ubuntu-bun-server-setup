# Troubleshooting

Failures a first production install tends to meet, each with the message
you see, its cause and the fix. Problems inside the systemd sandbox
(`EROFS`, `EACCES`, a crash loop) are in Security,
[Troubleshooting](security.md#troubleshooting).

## The install stopped

**`install failed at line N (<step>)`**

- **Cause:** a command in that step failed; the lines above it in the
  output say which and why.
- **Fix:** read the end of the log, fix the cause, and run the installer
  again. Re-running is safe: finished steps are repeated or skipped, and
  your edits are kept.

  ```bash
  sudo tail -n 50 /var/log/bun-installer.log
  ```

**`Another installer run is in progress (lock: /run/bun-installer.lock).`**

- **Cause:** another run holds the lock, for example one that cloud-init
  or an earlier SSH session started. The run exits 1 before it changes
  anything, the log included.
- **Fix:** wait for the other run to finish
  (`sudo fuser -v /run/bun-installer.lock` shows who holds it), then run
  again. The lock goes with the process that held it, so a
  crashed run leaves none behind.

**`/var/www/app/dist is a symlink to a missing path (/srv/app/dist/client).`**

- **Cause:** the web root is a link you made whose target is not there
  yet, for example the Astro SSR link to
  `/srv/app/dist/client` before the app's first deploy. The run exits 1
  before it changes anything.
- **Fix:** deploy the app that provides the target, then run again; or
  remove the link (`sudo rm /var/www/app/dist`) and let the installer
  create a plain directory. With `SKIP_BUN_APP=1` the same check applies
  to `/var/www/html`.

**`Template <name> failed its checksum`** or **`Bun <zip> failed its
checksum`**

- **Cause:** the download does not match the sums the installer
  expects: a broken mirror, a proxy that rewrites content, or a
  tampered file. Nothing is replaced.
- **Fix:** check the mirror or proxy, then run again. Never work around
  it by pointing `TEMPLATE_REF` elsewhere: that turns the check off.

## apt and snapd

**`Another apt or dpkg process holds the package lists lock; waiting ...`**

- **Cause:** on a fresh VM, `apt-daily`, unattended-upgrades or
  cloud-init run apt for the first minutes after boot.
- **Fix:** nothing; the installer waits up to 10 minutes, printing this
  line every 10 seconds.

**`Could not get lock /var/lib/...`** followed by **`apt-get update
failed after 3 attempts.`**

- **Cause:** the other apt held its lock for more than 10 minutes, or
  the archive could not be reached three times.
- **Fix:** see what holds the lock and let it finish, then run again:

  ```bash
  ps -o pid,etime,cmd -C apt,apt-get,dpkg,unattended-upgr
  ```

**`snapd is masked, but Certbot is installed as a snap. Either:`**
or **`snapd is not installed and apt cannot install it (removed or
pinned), but Certbot is installed as a snap. Either:`**

- **Cause:** Certbot comes only from the snap store, and this host cannot
  run snaps. The run stops right after `apt-get update`, before any
  package changes.
- **Fix:** one of the two printed ways out. Unmask snapd
  (`sudo systemctl unmask snapd.service snapd.socket`) or restore its
  apt source, then run again; or run with `SKIP_CERTBOT=1` and get
  certificates another way.

**Services restart during `apt-get upgrade`**

- **Cause:** `needrestart` (on Ubuntu 22.04 and later server images) may
  restart services whose libraries the upgrade replaced, `sshd`
  included, and lists them in the log. Open SSH sessions survive an
  `sshd` restart.
- **Fix:** nothing, usually. To have it only list them, set list mode:

  ```bash
  echo "\$nrconf{restart} = 'l';" | sudo tee /etc/needrestart/conf.d/50-list.conf
  ```

## SSH is refused after many connections

- **Cause:** UFW rate-limits the SSH port(s): `ufw limit` blocks a
  source address that opens 6 or more connections in 30 seconds.
  Ansible with many forks, or a deploy that opens one SSH connection per
  file, trips it. The block lifts once the rate drops.
- **Check:** `sudo ufw status numbered` shows the rule as `LIMIT`.
- **Fix, keeping the limit:** reuse one connection. In `~/.ssh/config`
  on the client:

  ```text
  Host myserver
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 10m
  ```

- **Fix, dropping the limit:** allow the port instead. Tradeoff: no
  throttle on password guessing, so allow key logins only first
  (`PasswordAuthentication no` in `sshd_config`), or add fail2ban.

  ```bash
  sudo ufw allow 22/tcp    # replaces the LIMIT rule for that port
  ```

  A re-run turns it back into a limit rule (`ufw limit` updates the
  rule in place), so repeat this after each run, or run with
  `SKIP_UFW=1`.

## `--check` reports problems

| Problem | Look at |
| --- | --- |
| `No installation found (...)` | the host was never installed, or the record was deleted: run the installer |
| `Nginx is not active; see: systemctl status nginx` | `sudo nginx -t`, then `sudo systemctl restart nginx` |
| `Service 'bun-app' is not active; see: journalctl -u bun-app` | the app crashed or will not start: `journalctl -u bun-app -n 100` |
| `Health probe failed; see: curl -i http://127.0.0.1/healthz` | the app runs but does not answer `ok` on `/healthz`; your own app must serve it (see [Health check](operations.md#health-check)) |
| `Certbot does not run; see: snap list certbot` | `snap list certbot`, `snap changes`; reinstall with `sudo snap install --classic certbot` |

- **A proxy in the environment** (`http_proxy`) sends the probe to the
  proxy. Set `no_proxy=127.0.0.1,localhost`; see [Behind a
  proxy](installation.md#behind-a-proxy).

## The app sees the wrong client IP

- **Cause:** Bun sees every request from Nginx, so its own peer address
  is `127.0.0.1`. `X-Forwarded-For` is no better: Nginx appends to
  whatever the client sent, so its first entries are client-controlled.
- **Fix:** read `X-Real-IP`. `snippets/bun-proxy.conf` sets it to the
  address Nginx saw: the visitor's, after the real-IP step for
  Cloudflare. A site that does not include the snippet does not set it.

  ```ts
  const ip = req.headers.get("x-real-ip");
  ```

## Cloudflare lists are not updated

**`cloudflare-update-ips: fetching https://www.cloudflare.com/ips-v4
failed`** (or another `cloudflare-update-ips:` line) in the journal

- **Cause:** the daily fetch failed or was rejected. The current lists
  and Nginx stay as they were; the next try is the next day's timer.
  During an install, the same failure stops the install.
- **Fix:** read the reason, then run it by hand once the cause is gone:

  ```bash
  journalctl -u cloudflare-update-ips -n 20
  sudo cloudflare-update-ips
  ```

- **Behind a proxy or offline,** give the unit a proxy or a local
  source; see [Air-gapped and proxied
  installs](installation.md#air-gapped-and-proxied-installs).

---

<div align="center">

[← Security](security.md) · [Documentation index](README.md) · [Upgrading and support →](upgrading.md)

</div>
