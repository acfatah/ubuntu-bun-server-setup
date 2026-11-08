# Image for docs/cookbook/docker.md; test_docker_app.sh builds and runs it.
# Keep the tag equal to BUN_PINNED_VERSION in install.sh (the test checks).
FROM oven/bun:1.4.4

WORKDIR /app
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile --production
COPY src ./src

# State lives in the /data volume; a new volume inherits this owner.
RUN mkdir /data && chown bun:bun /data
USER bun

# 0.0.0.0 inside the container; publish it on 127.0.0.1 only.
ENV HOST=0.0.0.0 PORT=3000 STATE_DIRECTORY=/data
EXPOSE 3000
CMD ["bun", "run", "start"]
