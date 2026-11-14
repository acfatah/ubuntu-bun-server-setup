// Nginx passes the full URI, so API routes keep their /api prefix.
// visits counts this browser's requests in its session, stored in the
// state dir (astro.config.mjs).
import type { APIRoute } from 'astro';

const MESSAGE = 'Hello from Astro';

export const ALL: APIRoute = async ({ url, session }) => {
  const visits = ((await session?.get('visits')) ?? 0) + 1;
  session?.set('visits', visits);
  return Response.json({ message: MESSAGE, path: url.pathname, visits });
};
