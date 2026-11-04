# Documentation

Operator documentation for the installer. The project overview and the
first install command are in the [README](../README.md).

- [Installation](installation.md): prerequisites, install options,
  pinned and development channels, template source, Bun version,
  air-gapped and proxied installs.
- [Configuration](configuration.md): a reference table of every
  setting and flag, then the environment toggles in detail.
- [Architecture](architecture.md): the install flow step by step,
  what runs, the Nginx files, and what a re-run keeps or rewrites.
- [Operations](operations.md): health check, logs, re-running the
  installer, upgrading from older releases, TLS with Certbot, upgrading
  Bun, restarts, backups.
- [Your app](app.md): what the host expects from an app, extending
  or replacing the sample, frontend plus API, deploying with rollback.
- [Cloudflare](cloudflare.md): real client IP, "Cloudflare only", the IP
  list updater, removing it.
- [Security](security.md): threat model, service user,
  environment file, filesystem layout, what the web root serves, systemd
  sandbox and limits, troubleshooting.
- [Compatibility](compatibility.md): the 1.x stability promise and
  support window.
