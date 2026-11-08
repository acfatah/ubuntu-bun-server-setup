# Your app

The installer puts a sample Bun app in `/srv/app` so the stack works end
to end on day one. This page shows how to extend it or replace it with
your own app. What the installer sets up for it (paths, unit, user,
re-run rules) is part of the [stable
surface](compatibility.md#stable-surface); `deploy.sh` and its release
dirs are an example you adapt.

## What the host expects

Any app the `bun-app` unit runs, sample or yours, must meet these:

- **Start command:** `bun run start` from `/srv/app`, so `package.json`
  needs a `start` script. A different command goes in an `ExecStart`
  drop-in (see [Compiled binary](#compiled-binary)).
- **Listen on `127.0.0.1:$PORT`.** `PORT` comes from `/etc/bun-app.env`
  (default `3000`). Loopback only: Nginx is the only client.
- **Answer `GET /healthz`** with `200` and the body `ok`. `--check` and
  the summary of every installer run probe it.
- **Route `/api/...` with its prefix.** Nginx passes the full URI:
  `/api/x` arrives as `/api/x`, not `/x`.
- **Write only to the state and cache dirs.** The code dir is read-only to
  the service. State goes in `/var/lib/bun-app` (`./data`,
  `$STATE_DIRECTORY`), cache in `/var/cache/bun-app`.
- **Root owns the code.** Copy files and run `bun install` as root; the
  service only reads them.
- **Re-runs keep your app.** The installer writes the sample only into an
  `/srv/app` with neither `server.ts` nor `package.json`.
- **Re-runs restart the unit,** so a re-run also picks up a new deploy.

| Item | Where it is set |
| --- | --- |
| Start command, user, sandbox | `/etc/systemd/system/bun-app.service` (kept on re-run) |
| `PORT`, `INSTANCE_ID`, secrets | `/etc/bun-app.env` (root `0600`, kept) |
| Proxy target `127.0.0.1:3000` | `/etc/nginx/snippets/bun-proxy.conf` (kept) |
| `/`, `@bun`, `/api/`, `/healthz`, `/assets/` | `/etc/nginx/sites-available/default` (kept with its marker) |
| Static files | `/var/www/app/dist` |
| State, cache | `/var/lib/bun-app` (= `/srv/app/data`), `/var/cache/bun-app` |

## Request flow

```text
                           client (or Cloudflare)
                                     |
                                     v
+--------------------------------------------------------------------+
| Nginx, port 80/443                                                 |
|                                                                    |
|  /          file in /var/www/app/dist? --yes--> served by Nginx    |
|                  | no                           (/assets/: 12h)    |
|                  v                                                 |
|  @bun  -----------------+                                          |
|  /api/...  (full URI) --+  all through snippets/bun-proxy.conf     |
|  /healthz  (no log) ----+                                          |
+-------------------------|------------------------------------------+
                          v
+--------------------------------------------------------------------+
| Bun app on 127.0.0.1:3000 (PORT), user bun-app                     |
| code: /srv/app (read-only)    state: /var/lib/bun-app = ./data     |
+--------------------------------------------------------------------+
```

- **Static first.** `/` serves a file from `/var/www/app/dist` when one
  exists, else falls back to `@bun`: Bun handles server routes and
  single-page-app paths.
- **`/api/` always reaches Bun,** even when a file of that name exists.
- **`/healthz`** reaches Bun without an access-log line. Under the
  optional [Cloudflare only](cloudflare.md#cloudflare-only-off) rule (off
  by default), it answers only requests from the host itself.

## Recipes

### Extend the sample

The sample is one file, `/srv/app/server.ts`, using plain `Bun.serve`.
Edit it in place as root, then restart:

```ts
import { Database } from "bun:sqlite";

// State dir: writable, kept across deploys
const db = new Database(`${process.env.STATE_DIRECTORY}/app.sqlite`, { create: true });
db.run("CREATE TABLE IF NOT EXISTS notes (body TEXT NOT NULL)");

const server = Bun.serve({
  hostname: "127.0.0.1",
  port: Number(process.env.PORT ?? 3000),
  fetch(req) {
    const path = new URL(req.url).pathname;
    if (path === "/healthz") {
      return new Response("ok", {
        headers: { "Content-Type": "text/plain", "Cache-Control": "no-store" },
      });
    }
    if (path === "/api/notes") {
      return Response.json(db.query("SELECT body FROM notes").all());
    }
    return new Response("Page not found", { status: 404 });
  },
});
```

```bash
sudoedit /srv/app/server.ts
sudo systemctl restart bun-app
bash install.sh --check
```

Keep the `/healthz` branch and the `hostname: "127.0.0.1"` line.

### Replace it with your own app

The unit, user, sandbox and Nginx site stay; only the code changes. The
example in [`examples/hono/`](examples/hono/) is a Hono app laid out as
`src/index.ts`, and `test_custom_app` deploys it in CI:

```json
{
  "scripts": {
    "start": "bun run src/index.ts"
  },
  "dependencies": {
    "hono": "4.13.16"
  }
}
```

```ts
const stateDir = process.env.STATE_DIRECTORY ?? "./data";
const db = new Database(`${stateDir}/app.sqlite`, { create: true });

app.get("/healthz", (c) => {
  c.header("Cache-Control", "no-store");
  return c.text("ok");
});

// Nginx passes the full URI, so API routes keep their /api prefix
app.all("/api/*", (c) =>
  c.json({ message: MESSAGE, path: c.req.path, visits: countVisit.get()?.n })
);

const server = Bun.serve({
  hostname: "127.0.0.1",
  port: Number(process.env.PORT ?? 3000),
  fetch: app.fetch,
});
```

The first time, on the host, clear the sample and copy your app in. Keep
`data`: it is the link to your state.

```bash
sudo find /srv/app -mindepth 1 -maxdepth 1 ! -name data -exec rm -rf {} +
sudo cp -r ./my-app/. /srv/app/
cd /srv/app && sudo bun install --frozen-lockfile --production
sudo systemctl restart bun-app
```

From then on, deploy with [`deploy.sh`](#deploying). Re-running the
installer leaves the app alone, because `/srv/app/package.json` exists.

### Frontend and API

A Vite (or any) single-page app builds into `/var/www/app/dist`; Nginx
serves it, and Bun handles `/api/` and every path with no file.

```bash
bun run build        # on your machine: writes dist/
rsync -a --delete --rsync-path='sudo rsync' dist/ host:/var/www/app/dist/
ssh host 'sudo chown -R root:root /var/www/app/dist &&
  sudo find /var/www/app/dist -type d -exec chmod 755 {} + &&
  sudo find /var/www/app/dist -type f -exec chmod 644 {} +'
```

- **Hashed assets go in `dist/assets/`.** Nginx caches them for 12 hours
  with one `Cache-Control` header. Vite's default `assetsDir` is `assets`.
- **Client-side routes fall back to Bun,** not to `index.html`. Serve
  `index.html` from the app for unknown non-API paths, or add your own
  `try_files ... /index.html` to the site (it is kept on re-run).
- **Call the API with relative URLs** (`fetch("/api/x")`): same origin,
  no CORS.

### Bring your own stack (`SKIP_BUN_APP=1`)

With [`SKIP_BUN_APP=1`](configuration.md#environment-toggles), the
installer sets up Bun, Nginx, UFW, Certbot and Cloudflare support, but no
app, unit, service user or proxy site:

- **Nginx keeps Ubuntu's stock site** with root `/var/www/html`: no
  `/api/` proxy, no `@bun` fallback, no `/healthz`. Copy your build there,
  or write your own site.
- **`--check` covers Nginx** (and Certbot) only.
- **To run a Bun app anyway,** create the user and a unit. The installed
  unit is [`templates/bun-app.service`](../templates/bun-app.service); copy
  it whole to keep the sandbox:

  ```bash
  sudo useradd --system --user-group --home-dir /var/lib/bun-app \
    --no-create-home --shell /usr/sbin/nologin bun-app
  sudo curl -fsSL -o /etc/systemd/system/bun-app.service \
    https://raw.githubusercontent.com/acfatah/ubuntu-bun-server-setup/main/templates/bun-app.service
  sudo mkdir -p /srv/app    # your code here, then:
  sudo ln -s /var/lib/bun-app /srv/app/data
  sudo systemctl daemon-reload && sudo systemctl enable --now bun-app
  ```

  Use your release's tag (`v1.2.3`) instead of `main` to get the unit it
  installs. Then add a site, or a `location` in the stock one, that proxies to
  `127.0.0.1:3000`. A later run without the toggle installs the managed
  site, snippet and sample, but never over an app already in `/srv/app`.

### More setups

The [Cookbook](cookbook/README.md) holds setups beyond these recipes,
each with a tested example, such as [running your app in a
container](cookbook/docker.md) behind the installer's Nginx.

## Build and dependencies

Pick where `bun install` (and any build) runs:

| | On the host, as root | Off the host, ship the output |
| --- | --- | --- |
| How | sync source, `bun install --frozen-lockfile --production` | build in CI or locally, copy the result |
| Gains | simple; native modules match the host | no compiler or registry access on the host; faster deploys |
| Costs | registry access and CPU at deploy time | the build must match the host's arch and libc |
| Used by | `deploy.sh` | [Compiled binary](#compiled-binary) below |

- **Commit `bun.lock`.** `--frozen-lockfile` refuses a lockfile that does
  not match `package.json`, so the host installs what you tested.
- **Gotcha: native modules built off the host** must match its CPU
  architecture (`x64` or `arm64`) and libc (glibc on Ubuntu). A
  `node_modules` copied from macOS will not load.

### Compiled binary

`bun build --compile` produces one executable that embeds Bun and your
code; no `node_modules` on the host.

```bash
bun build --compile --target=bun-linux-x64 --outfile app ./src/index.ts
rsync -a --rsync-path='sudo rsync' --chown=root:root app host:/srv/app/app
```

Point the unit at it with a drop-in, which survives re-runs:

```bash
sudo systemctl edit bun-app
```

```ini
[Service]
ExecStart=
ExecStart=/srv/app/app
```

- **The empty `ExecStart=`** clears the unit's own line; without it
  systemd refuses two.
- **Keep a `package.json`** in `/srv/app` (any content), so a re-run
  never writes the sample there.
- Use `--target=bun-linux-arm64` for arm64 hosts, and
  `bun-linux-x64-baseline` for CPUs without AVX2.

## Deploying

### In place, by hand

Copy the code, exclude `data`, install, restart:

```bash
rsync -a --delete --exclude /data --exclude /node_modules \
  --rsync-path='sudo rsync' --chown=root:root --chmod=go-w,a+rX \
  ./ host:/srv/app/
ssh host 'cd /srv/app && sudo bun install --frozen-lockfile --production &&
  sudo systemctl restart bun-app'
```

**Gotcha: `--delete` without `--exclude /data`** removes the `data` link
(not the data). The app then fails to write until you re-create it with
`sudo ln -s /var/lib/bun-app /srv/app/data`.

### With `deploy.sh`

[`examples/deploy.sh`](examples/deploy.sh) does the above in one step and
checks the result. Copy it into your project.

```bash
./deploy.sh deploy@host            # sync ., install, restart, check
./deploy.sh deploy@host ./my-app   # another source dir
./deploy.sh --release deploy@host  # new release dir, atomic switch
./deploy.sh --rollback deploy@host # back to the previous release
```

- **Needs** SSH as root or a user with passwordless `sudo`, and `rsync`
  on both ends (`sudo apt install rsync`).
- **The health check** curls `http://127.0.0.1/healthz` on the host. Set
  `INSTALLER_PATH=/path/to/install.sh` (a path on the host) to run its
  `--check` instead.
- **A failed check** exits non-zero. The code is already live: fix
  forward, or roll back (release dirs only).

### Release dirs and rollback (advanced)

Each `--release` deploy goes into its own `/srv/app-releases/<UTC time>`
and `/srv/app` becomes a symlink to the current one:

```text
/srv/app -> /srv/app-releases/20261103T101500Z
/srv/app-releases/
  0-initial/
  20261102T170000Z/
  20261103T101500Z/      data -> /var/lib/bun-app
```

- **The switch is atomic:** a new link is renamed over `/srv/app`, then
  the unit restarts. The unit, the installer's checks and re-runs all
  follow the link.
- **`--rollback`** points the link at the release before the current one
  and restarts. Only code rolls back; the state dir is shared, so undo a
  schema migration yourself.
- **`KEEP=5`** (the default) old releases stay; older ones are removed,
  never the current one.
- **Static files** in `/var/www/app/dist` are not part of a release.

**One-time migration.** The first `--release` onto a plain `/srv/app`
refuses and prints these steps. Run them on the host, then deploy again:

```bash
sudo mkdir -p /srv/app-releases
sudo mv /srv/app /srv/app-releases/0-initial
sudo ln -s /srv/app-releases/0-initial /srv/app
```

The running service is unaffected until the next restart.

## Port and environment

- **Variables and secrets** go in `/etc/bun-app.env` (root `0600`): the
  app gets them, but `bun-app` cannot read the file. Never put secrets in
  `/srv/app`. Apply with `sudo systemctl restart bun-app`.
- **To change the port,** edit both, then restart and reload:

  ```bash
  sudoedit /etc/bun-app.env                    # PORT=4000
  sudoedit /etc/nginx/snippets/bun-proxy.conf  # proxy_pass http://127.0.0.1:4000;
  sudo systemctl restart bun-app
  sudo nginx -t && sudo systemctl reload nginx
  ```

  `--check` goes through Nginx, so it follows the new port.

## WebSockets

Nginx already forwards upgrades (`Upgrade` header and the
`$bun_connection_upgrade` map) and keeps idle connections for 3600 s. Only
the app needs code:

```ts
Bun.serve({
  hostname: "127.0.0.1",
  port: Number(process.env.PORT ?? 3000),
  fetch(req, server) {
    if (new URL(req.url).pathname === "/api/ws" && server.upgrade(req)) return;
    return new Response("Not found", { status: 404 });
  },
  websocket: {
    message(ws, msg) {
      ws.send(`echo: ${msg}`);
    },
  },
});
```

Put the socket under `/api/` (or any path with no static file), so Nginx
sends it to Bun.

## Logs and failed deploys

- **Logs:** `journalctl -u bun-app -f`. Output goes to the journal; see
  [Shipping logs](operations.md#health-check) to forward it.
- **Health:** `bash install.sh --check` lists what is down and exits 1.
- **Crash loop:** the unit has `Restart=always` with `RestartSec=3`, so a
  bad deploy restarts every 3 s. `systemctl status bun-app` shows the
  last exit; the journal shows why.
- **Sandbox errors** (`EROFS`, `EACCES`, `226/NAMESPACE`): see
  [Troubleshooting](security.md#troubleshooting).
- **Roll back** with `deploy.sh --rollback` (release dirs), or deploy the
  previous commit again (in place).

## Multiple apps (unsupported)

The installer manages one app. A second one is possible by hand, but
`--check`, re-runs and the [stable surface](compatibility.md) know nothing
about it. A sketch:

1. **User and code:** `useradd --system ... app2`, code in `/srv/app2`.
2. **Unit:** copy `bun-app.service` to `app2.service`; change `User=`,
   `Group=`, `WorkingDirectory=`, `EnvironmentFile=/etc/app2.env`,
   `StateDirectory=app2`, `CacheDirectory=app2`, `SyslogIdentifier=app2`
   and `XDG_CACHE_HOME`.
3. **Port:** `PORT=3001` in `/etc/app2.env`.
4. **Nginx:** a `location ^~ /app2/ { proxy_pass http://127.0.0.1:3001; }`
   in the default site, or a separate `server` block in
   `/etc/nginx/sites-available/app2` with its own `server_name`.
5. **Health:** monitor its own endpoint; `--check` does not.

## Gotchas

- **Never add `MemoryDenyWriteExecute`.** Bun's JIT needs writable and
  executable memory; the unit crash-loops.
- **`/tmp` is private** (`PrivateTmp=yes`) and emptied on restart. Keep
  anything that must last in the state dir.
- **`/home` and `/root` are hidden** (`ProtectHome=yes`). An app or a
  `.env` there cannot be read by the service.
- **`rsync --delete` must exclude `data`;** see [In place, by
  hand](#in-place-by-hand).
- **Kept files stay old.** A unit or site installed by an earlier
  release keeps its old content after an upgrade; see [Re-running the
  installer](operations.md#re-running-the-installer).

---

<div align="center">

[← Operations](operations.md) · [Documentation index](README.md) · [Cloudflare →](cloudflare.md)

</div>
