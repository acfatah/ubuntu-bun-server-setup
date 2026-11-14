# Cookbook

Setups beyond the stock app, each with a tested example. Every page
builds on the contract in [What the host
expects](../app.md#what-the-host-expects) instead of restating it.

- [Run your app in a container](docker.md): Docker runs your app image
  on `127.0.0.1:3000` behind the installer's Nginx, installed with
  `SKIP_BUN_APP=1`.
- [Deploy an Astro site](astro.md): a static build served from
  `/var/www/app/dist`, or server rendering with `@astrojs/node` under
  the `bun-app` unit.

---

<div align="center">

[← Back to Your app](../app.md) · [Documentation index](../README.md)

</div>
