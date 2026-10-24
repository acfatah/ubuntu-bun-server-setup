const server = Bun.serve({
  // Loopback only: clients reach Bun through Nginx
  hostname: "127.0.0.1",
  port: Number(process.env.PORT ?? 3000),
  async fetch(req) {
    const path = new URL(req.url).pathname;

    if (path === "/") {
      return Response.json({
        message: "Welcome to Bun!"
      });
    }

    // Nginx passes the full URI, so API routes keep their /api prefix
    if (path.startsWith("/api/")) {
      return Response.json({
        message: "Welcome to Bun!",
        path
      });
    }

    return new Response("Page not found", { status: 404 });
  }
});

console.log(`Listening on ${server.url}`);
