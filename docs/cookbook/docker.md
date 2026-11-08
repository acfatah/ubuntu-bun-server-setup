# Run your app in a container

Docker runs your app image; the installer still sets up Nginx, UFW,
Certbot and Cloudflare in front of it. The installer never installs or
manages Docker, and `--check` covers only Nginx (and Certbot).

The image must meet [What the host
expects](../app.md#what-the-host-expects), with the differences listed
under [The image](#the-image).

## Steps

1. **Install with
   [`SKIP_BUN_APP=1`](../configuration.md#environment-toggles),** on this
   and every later run. A run without it installs the `bun-app` unit and
   the sample, which then fight the container for port 3000.
2. **Install Docker Engine** from [Docker's Ubuntu
   guide](https://docs.docker.com/engine/install/ubuntu/).
3. **Add the proxy site.** Skip mode leaves Ubuntu's stock site, so copy
   the managed site, snippet and map from your release's tag:

   ```bash
   base=https://raw.githubusercontent.com/acfatah/ubuntu-bun-server-setup/v1.0.0/templates
   sudo curl -fsSL -o /etc/nginx/sites-available/default "$base/nginx-default.conf"
   sudo curl -fsSL -o /etc/nginx/snippets/bun-proxy.conf "$base/nginx-bun-proxy.conf"
   sudo curl -fsSL -o /etc/nginx/conf.d/bun-connection-upgrade.conf "$base/nginx-connection-upgrade.conf"
   sudo sed -i 's|__NGINX_ROOT__|/var/www/app/dist|' /etc/nginx/sites-available/default
   sudo mkdir -p /var/www/app/dist
   sudo nginx -t && sudo systemctl reload nginx
   ```

   Skip-mode runs leave all three files alone. The root is
   `/var/www/app/dist`, not `/var/www/html`, because every skip-mode run
   writes an `index.html` into `/var/www/html` when none is there, and
   that file would answer `/` instead of your app.
4. **Build the image.** The [Hono example](../examples/hono/) ships a
   `Dockerfile` (see [The image](#the-image)); from a clone of this
   repo, or your own app laid out the same way:

   ```bash
   sudo docker build -t my-app:1.0.0 docs/examples/hono
   ```

5. **Run the container,** published on loopback only. Secrets go in a
   root `0600` env file:

   ```bash
   sudo install -m 600 /dev/null /etc/my-app.env   # then sudoedit it
   sudo docker run -d --name my-app --restart unless-stopped \
     -p 127.0.0.1:3000:3000 \
     --env-file /etc/my-app.env -v my-app-data:/data \
     --read-only --tmpfs /tmp --cap-drop ALL \
     --security-opt no-new-privileges \
     my-app:1.0.0
   curl -fsS http://127.0.0.1/healthz   # ok
   ```

## The image

The example's
[`Dockerfile`](../examples/hono/Dockerfile):

```dockerfile
FROM oven/bun:1.4.4

WORKDIR /app
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile --production
COPY src ./src

# State lives in the /data volume; a new volume inherits this owner.
RUN mkdir /data && chown bun:bun /data
USER bun

# 0.0.0.0 inside the container; publish it on 127.0.0.1 only.
ENV HOST=0.0.0.0 PORT=3000 STATE_DIRECTORY=/data
EXPOSE 3000
CMD ["bun", "run", "start"]
```

- **Listen on `0.0.0.0:$PORT` inside the container.** `127.0.0.1` there
  is the container's own loopback, which the published port cannot
  reach. The example reads `HOST` (default `127.0.0.1`, for the
  `bun-app` unit), and the image sets it. The `-p 127.0.0.1:...` part
  keeps it private to the host.
- **State goes in the volume** (`/data`, `$STATE_DIRECTORY`);
  `--read-only` makes the rest of the container's filesystem
  read-only. Run as a non-root user (`USER bun` in the `oven/bun`
  images) that owns `/data` in the image, so the new volume inherits
  that owner.
- **`--read-only`, `--cap-drop ALL` and `no-new-privileges`** stand in
  for the unit's sandbox, which does not apply to a container.
- **`.dockerignore`** keeps a local `node_modules` and `data` out of the
  build.

## Deploying

Deploying means starting a new tag in place of the old one. Build it
on the host as above, or pull it from your registry. The app is down
for the few seconds between the last two commands:

```bash
sudo docker build -t my-app:1.0.1 docs/examples/hono   # or docker pull
sudo docker rm -f my-app
sudo docker run -d --name my-app ... my-app:1.0.1   # same flags as above
```

Roll back by running the previous tag the same way. The volume is
shared, so as with release dirs, undo a schema migration yourself.

## Gotchas

- **Never publish as `-p 3000:3000`.** Docker adds its own firewall
  rules ahead of UFW's, so that port is open to the internet even though
  UFW denies it.
- **`--env-file` keeps quotes.** `KEY="a b"` arrives with the quotes in
  the value; write `KEY=a b`.
- **Monitor `/healthz` yourself.** Without the `bun-app` unit,
  `--check` and the installer's summary do not probe it.
- **The copied files stay at their tag.** Fetch them again from a newer
  tag to pick up changes; see [Re-running the
  installer](../operations.md#re-running-the-installer).

---

<div align="center">

[← Back to Your app](../app.md) · [Cookbook](README.md)

</div>
