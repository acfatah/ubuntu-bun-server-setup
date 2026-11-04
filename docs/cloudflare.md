# Cloudflare

The Cloudflare support the installer adds: real client IP, the
optional "Cloudflare only" rule, the daily IP list updater, and how to
remove it. The updater's systemd sandbox is in
[Security](security.md#cloudflare-updater-sandbox).

Real client IP is on by default; the "Cloudflare only" filter is off until
you uncomment its include (see [Cloudflare only](#cloudflare-only-off)).

- **No setting turns the filter on.** It needs that one edit to the site,
  since the installer cannot tell whether your DNS records are proxied.
- **`SKIP_CLOUDFLARE=1`** is the only Cloudflare setting, and it works the
  other way: it leaves all Cloudflare support out. Pass it as an
  environment variable (`sudo SKIP_CLOUDFLARE=1 bash install.sh`) or as an
  argument (`sudo bash install.sh SKIP_CLOUDFLARE=1`); see
  [Configuration](configuration.md#environment-toggles).

Unless skipped, the installer keeps Nginx in step with Cloudflare's
published IP ranges:

| Path | What it is |
|---|---|
| `/usr/local/sbin/cloudflare-update-ips` | Updater script (kept on re-run) |
| `/etc/systemd/system/cloudflare-update-ips.{service,timer}` | Daily timer (kept on re-run) |
| `/etc/nginx/cloudflare/real-ip.conf`, `edge-ips.conf` | Generated lists; never edit |
| `/etc/nginx/conf.d/bun-cloudflare.conf` | Real client IP, `$bun_cloudflare_edge` geo and `$bun_cloudflare_deny` map (kept) |
| `/etc/nginx/snippets/cloudflare-only.conf` | Optional 403 rule (kept) |

The installer fetches the lists once; if that fetch fails, the install
fails.

## Real client IP (on)

Behind Cloudflare, every connection comes from a Cloudflare edge, so
`$remote_addr` and the access log would show Cloudflare, not the visitor.
`bun-cloudflare.conf` restores the visitor's address from the
`CF-Connecting-IP` header, for every site. The header is trusted only on
connections from Cloudflare's ranges, so a client cannot forge it by
connecting directly, and a host not behind Cloudflare sees no change.

## Cloudflare only (off)

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
  The one exception is `/healthz` from the host itself, so
  `install.sh --check` keeps working; see [Health check](operations.md#health-check).
- The decision comes from the `$bun_cloudflare_deny` map in
  `bun-cloudflare.conf`. Hosts installed before it keep the older snippet
  (`if ($bun_cloudflare_edge = 0)`), which blocks `/healthz` too; delete
  both files and re-run to get the pair.
- In skip mode, Ubuntu's stock site has no such line; add it yourself to
  any server block.

### Other Cloudflare customers

"Cloudflare only" admits every Cloudflare edge, and every Cloudflare
customer sends traffic from those edges. Anyone can point their own
Cloudflare zone, or a Worker, at your server's IP and reach it through
an edge, past your zone's WAF and rules. To admit only your own zone,
add one of these:

- **Authenticated Origin Pulls** (recommended): Cloudflare presents a
  client certificate on every request, and Nginx refuses connections
  without it. It needs HTTPS on the origin (SSL/TLS mode Full (strict);
  see [TLS with Certbot](operations.md#tls-with-certbot)). Turn it on
  in the zone, save Cloudflare's origin-pull CA certificate outside
  `/etc/nginx/cloudflare/` (the updater owns that directory), and add
  to the HTTPS server block:

  ```nginx
  ssl_client_certificate /etc/nginx/certs/cloudflare-origin-pull-ca.pem;
  ssl_verify_client on;
  ```

- **A secret header:** a Cloudflare Transform Rule (Modify Request
  Header) sets a header with a long random value on every request to
  your zone, and the site refuses requests without it. Requests from the
  host itself stay allowed, so `--check` keeps working. In the server
  block, after the `cloudflare-only.conf` include:

  ```nginx
  set $origin_ok 0;
  if ($http_x_origin_auth = "long-random-secret") {
    set $origin_ok 1;
  }
  if ($realip_remote_addr = 127.0.0.1) {
    set $origin_ok 1;
  }
  if ($origin_ok = 0) {
    return 403;
  }
  ```

  Treat the value as a password: keep it out of git, and change it in
  both places if it leaks.

## Updates

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

The unit is sandboxed and cannot see home dirs; see
[Cloudflare updater sandbox](security.md#cloudflare-updater-sandbox).

## Removing it

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

---

<div align="center">

[← Your app](app.md) · [Documentation index](README.md) · [Security →](security.md)

</div>
