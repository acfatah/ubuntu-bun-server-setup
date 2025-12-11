const server = Bun.serve({
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
