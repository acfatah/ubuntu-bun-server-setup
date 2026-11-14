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
