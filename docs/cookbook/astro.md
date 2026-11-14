# Deploy an Astro site

[Astro](https://astro.build/) runs on this host in two modes:

- **Static:** `astro build` writes plain files, and Nginx serves them
  from `/var/www/app/dist`. No app runs; the sample (or your API) stays
  behind `/api/`.
- **Server rendering (SSR):** the `@astrojs/node` adapter builds a
  server that the `bun-app` unit runs from `/srv/app`, and Nginx serves
  its client files through a link.

An SSR app must meet [What the host
expects](../app.md#what-the-host-expects); this page covers only what
Astro needs on top. Tested with Astro 7.4.5 and `@astrojs/node` 11.1.9
under the pinned Bun.

## Static site

The [static example](../examples/astro-static/) needs no adapter. Its
[`astro.config.mjs`](../examples/astro-static/astro.config.mjs):

```js
// Example for docs/cookbook/astro.md: a static Astro site, copied into
// /var/www/app/dist. tests/docker/scripts/test_astro_app.sh builds it.
import { defineConfig } from 'astro/config';

export default defineConfig({
  build: {
    // Hashed files under /assets/, which Nginx caches; Astro's default
    // is /_astro/. Stylesheets as files, so they are cached too.
    assets: 'assets',
    inlineStylesheets: 'never',
  },
});
```

Build it on your machine and copy `dist/` into the web root, with the
ownership and modes of [Frontend and API](../app.md#frontend-and-api):

```bash
bun install && bun run build   # writes dist/
rsync -a --delete --rsync-path='sudo rsync' dist/ host:/var/www/app/dist/
ssh host 'sudo chown -R root:root /var/www/app/dist &&
  sudo find /var/www/app/dist -type d -exec chmod 755 {} + &&
  sudo find /var/www/app/dist -type f -exec chmod 644 {} +'
```

That section's notes on client-side routes and relative API URLs apply
here too.

## Server rendering (SSR)

The [SSR example](../examples/astro/) has a prerendered home page, a
`/healthz` endpoint and an `/api/` endpoint that counts visits in a
session.

### The app

Its [`package.json`](../examples/astro/package.json) starts the built
server with Bun, and keeps `astro` in `dependencies`: the server bundle
imports it at runtime, and the host installs with `--production`.

```json
{
  "name": "astro-example",
  "version": "0.0.0",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "astro dev",
    "build": "astro build",
    "start": "bun ./dist/server/entry.mjs"
  },
  "dependencies": {
    "@astrojs/node": "11.1.9",
    "astro": "7.4.5"
  }
}
```

Its [`astro.config.mjs`](../examples/astro/astro.config.mjs) builds a
standalone server, puts hashed files under `/assets/` and keeps sessions
in the state dir:

```js
// Example for docs/cookbook/astro.md: Astro SSR on Bun, run by the
// bun-app unit. tests/docker/scripts/test_astro_app.sh deploys it.
import node from '@astrojs/node';
import { defineConfig, sessionDrivers } from 'astro/config';

export default defineConfig({
  output: 'server',
  adapter: node({ mode: 'standalone' }),
  build: {
    // Hashed files under /assets/, which Nginx caches; Astro's default
    // is /_astro/. Stylesheets as files, so they are cached too.
    assets: 'assets',
    inlineStylesheets: 'never',
  },
  session: {
    // /srv/app is read-only to the service; the default driver writes
    // into node_modules. Fixed at build time.
    driver: sessionDrivers.fsLite({ base: '/var/lib/bun-app/sessions' }),
  },
});
```

The health probe is an endpoint,
[`src/pages/healthz.ts`](../examples/astro/src/pages/healthz.ts):

```ts
// Health probe for monitors and install.sh --check
import type { APIRoute } from 'astro';

export const GET: APIRoute = () =>
  new Response('ok', {
    headers: { 'Content-Type': 'text/plain', 'Cache-Control': 'no-store' },
  });
```

API routes live under `src/pages/api/` and see the full path, `/api`
prefix included.

### Deploy it

1. **Bind to loopback.** The adapter reads `PORT` from
   `/etc/bun-app.env` but defaults its host to `localhost`, which can
   resolve to `::1` while Nginx proxies to `127.0.0.1`. Add `HOST` to
   the env file on the host:

   ```bash
   sudoedit /etc/bun-app.env   # add: HOST=127.0.0.1
   ```

2. **Build on your machine,** then deploy with
   [`deploy.sh`](../app.md#with-deploysh). It ships the source and
   `dist/` (it leaves out only `data`, `node_modules` and `.git`), runs
   `bun install --production` on the host, restarts `bun-app` and
   checks `/healthz`:

   ```bash
   bun install && bun run build   # writes dist/client and dist/server
   ./deploy.sh deploy@host
   ```

3. **Serve the client files through a link,** once, after the first
   deploy. Nginx then serves `dist/client` (the prerendered pages and
   `/assets/`) without reaching Bun, and every other path falls back to
   the Astro server:

   ```bash
   sudo rm -rf /var/www/app/dist && sudo ln -s /srv/app/dist/client /var/www/app/dist
   ```

Later deploys need only step 2: the link points into `/srv/app`, so it
picks up each new build.

## Release dirs

With [release dirs](../app.md#release-dirs-and-rollback-advanced),
`/srv/app` is itself a link to the current release, and
`/var/www/app/dist` resolves through it. So the client files switch with
`deploy.sh --release` and go back with `--rollback`, together with the
server code. That is the exception to the rule that static files are not
part of a release.

## Gotchas

- **Link `dist/client`, never `dist`.** `dist/server` holds the server
  bundle, which can contain values filled in at build time; linking
  `dist` would make it downloadable.
- **A dangling link stops a re-run.** If the link exists before its
  target does (before the first deploy, or after `/srv/app` was
  emptied), the installer refuses before it changes anything:

  ```text
  /var/www/app/dist is a symlink to a missing path (/srv/app/dist/client).
  ```

  Deploy first, or remove the link; see
  [Troubleshooting](../troubleshooting.md#the-install-stopped).
- **`astro` belongs in `dependencies`.** `dist/server` imports
  `astro` and its helpers from `node_modules`, so with it in
  `devDependencies` the host's `--production` install leaves it out and
  the unit fails to start.
- **The session path is baked in at build time.** The driver config is
  part of the build, not read from the environment. A different state
  dir means a rebuild. Without the setting, the default driver writes
  into `node_modules`, which is read-only to the service, and each
  session write logs `ENOENT`.
- **Only build output goes in `dist/client/assets/`.** Nginx's
  `/assets/` location skips the dotfile rule (see [What the web root
  serves](../security.md#what-the-web-root-serves)), so a file you copy
  there is public.
- **Static files are read from `/srv/app`.** Nginx (`www-data`) needs
  read access there; `deploy.sh` gives it (`a+rX`). A host that removes
  world-read from `/srv/app` breaks the site.
- **Bun is not Astro's main runtime.** Astro's [Bun
  guide](https://docs.astro.build/en/recipes/bun/) warns of rough edges.
  Only the core and `@astrojs/node` are tested here; check each
  integration (React, Tailwind, MDX, image optimization) yourself.

---

<div align="center">

[← Back to Your app](../app.md) · [Cookbook](README.md)

</div>
