// Example app for docs/app.md: Hono on Bun, run by the bun-app unit.
// tests/docker/scripts/test_custom_app.sh deploys exactly this file, and
// test_docker_app.sh builds it as an image (docs/cookbook/docker.md).
import { Database } from "bun:sqlite";
import { Hono } from "hono";

const MESSAGE = "Hello from Hono";

// /srv/app is read-only to the service; state goes in the state dir
// (/var/lib/bun-app, also reachable as /srv/app/data). systemd sets
// STATE_DIRECTORY; ./data covers a run outside the unit.
const stateDir = process.env.STATE_DIRECTORY ?? "./data";
const db = new Database(`${stateDir}/app.sqlite`, { create: true });
db.run("PRAGMA journal_mode = WAL");
db.run("CREATE TABLE IF NOT EXISTS visits (id INTEGER PRIMARY KEY CHECK (id = 1), n INTEGER NOT NULL)");
db.run("INSERT OR IGNORE INTO visits (id, n) VALUES (1, 0)");
const countVisit = db.query<{ n: number }, []>(
  "UPDATE visits SET n = n + 1 WHERE id = 1 RETURNING n"
);

const app = new Hono();

// Health probe for monitors and install.sh --check
app.get("/healthz", (c) => {
  c.header("Cache-Control", "no-store");
  return c.text("ok");
});

app.get("/", (c) => c.json({ message: MESSAGE }));

// Nginx passes the full URI, so API routes keep their /api prefix
app.all("/api/*", (c) =>
  c.json({ message: MESSAGE, path: c.req.path, visits: countVisit.get()?.n })
);

// Paths with no static file reach Bun through Nginx's @bun fallback
app.notFound((c) => c.text(`${MESSAGE}: no route for ${c.req.path}`, 404));

// Loopback only: clients reach Bun through Nginx. A container sets
// HOST=0.0.0.0: its own loopback is out of the published port's reach.
const server = Bun.serve({
  hostname: process.env.HOST ?? "127.0.0.1",
  port: Number(process.env.PORT ?? 3000),
  fetch: app.fetch,
});

console.log(`Listening on ${server.url}`);
