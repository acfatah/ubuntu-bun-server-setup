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
