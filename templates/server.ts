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

    return new Response("Page not found", { status: 404 });
  }
});

console.log(`Listening on ${server.url}`);
