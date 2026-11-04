# Upgrading and support

How a host moves to a newer release, what reaches it and what stays with
new installs, how long a release is supported, and the gaps to know
before you adopt it. The binding promise is
[Compatibility](compatibility.md); this page summarises it.

## What a host runs

```bash
bash install.sh --version                     # the installer you hold
cat /var/lib/app-info/application.info        # what last ran on the host
```

- **`--version`** prints the installer version, whether its templates
  are verified, and the Bun version it installs. It needs no root and
  changes nothing.
- **`application.info`** records the last run: `installer_version`,
  `template_ref` (`local` for a clone's `templates/`),
  `application_version` (the Bun in `/usr/local/bin`), the distro and
  the UFW state.

## Moving to a newer release

Run the newer release's installer, as for the first install (see
[Pin and check a version](installation.md#pin-and-check-a-version)).
Use `SKIP_UPGRADE=1` if you want no package upgrades in the same run.

**What changes:**

- **Packages,** upgraded as on every run (unless `SKIP_UPGRADE=1`).
- **Bun,** moved to the new release's pin (or your `BUN_VERSION`);
  `bun-app` restarts on it.
- **`application.info`,** rewritten with the new versions.
- **Files the host does not have yet,** such as a file a newer release
  adds, are written.

**What does not change:**

- **Kept files.** The units, `/etc/bun-app.env`, the Nginx site (while
  its marker line stays), the snippets and `conf.d` files, the
  Cloudflare updater, the MOTD and the logrotate rule keep their old
  content, edits included. So a template fix in a newer release reaches
  new installs only. See [Architecture](architecture.md#files-and-re-runs)
  for the full list.
- **Your app,** state and environment file.
- **UFW,** beyond re-adding missing rules.

**To pick up a template fix** on an existing host, delete the file (for
the Nginx site, its marker line) and re-run, or copy the change by hand.
Two fixes in 1.0 apply to older hosts only by hand:

- **Root-owned web root:** see [Filesystem
  layout](security.md#filesystem-layout).
- **No dotfiles from the web root:** see [What the web root
  serves](security.md#what-the-web-root-serves).

From 0.3.x or 0.4.x, read the notes in Operations first:
[Upgrading from 0.3.x](operations.md#upgrading-from-03x) and
[Upgrading from 0.4.x](operations.md#upgrading-from-04x).

## Support

In short, from [Compatibility](compatibility.md):

- **Latest release only.** Fixes, security fixes included, go into the
  next release; there are no backports. Upgrade by re-running the latest
  installer.
- **Version bumps:** a major changes or removes something in the stable
  surface; a minor adds toggles, files, checks or Ubuntu releases, or
  bumps the Bun pin within its major; a patch changes nothing in the
  stable surface.
- **Platforms:** Ubuntu 22.04 and 24.04 LTS, x86_64 and aarch64. An
  Ubuntu release past its standard support may be dropped in a minor,
  announced one minor ahead.
- **Best effort.** One maintainer, no response time promised.
- **Security reports** go through [SECURITY.md](../SECURITY.md).

## Known gaps

What the project does not do yet, so you can decide whether it fits:

- **No build provenance or signed tags.** Release assets are checked
  only by `SHA256SUMS` from the same GitHub release.
- **`main` has no branch ruleset** or required reviews.
- **No managed template upgrade.** Kept files are never updated, and
  nothing reports how a host's files differ from the current templates.
- **No unattended TLS.** Certificates need a `certbot --nginx` run by
  hand after DNS points at the host.
- **aarch64 is not tested in CI.** The e2e suite runs on x86_64 only.
- **One maintainer.**
- **No uninstall.** Removing the installed services and files is a
  manual job; see [Removing it](cloudflare.md#removing-it) for the
  Cloudflare part.

---

<div align="center">

[← Troubleshooting](troubleshooting.md) · [Documentation index](README.md) · [Compatibility →](compatibility.md)

</div>
