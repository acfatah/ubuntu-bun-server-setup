# Compatibility and support

What stays stable across releases, what each version bump means, and how
long a release is supported. This promise holds from 1.0.0 on; 0.x
releases promised nothing.

## Versioning

- **SemVer from 1.0.0.** Versions are `MAJOR.MINOR.PATCH`. The stable
  surface below is the public API that SemVer talks about.
- **Changelog:** the release notes on [GitHub Releases][releases]. There
  is no separate `CHANGELOG` file.
- **Release installers are pinned.** The `install.sh` asset of a release
  fetches the templates of its own tag and checks them against the
  SHA-256 sums built into it. The promise covers those assets.
- **`main` is the development channel.** Its `install.sh` reports version
  `dev`, fetches templates from `main` without verifying them, and may
  change at any time. Nothing here applies to it.

## Stable surface

A breaking change to anything in this section needs a major release.

### Command line

- **Flags:** `--version` / `-V`, `--help` / `-h` and `--check` / `-c`.
  None of them needs root.
- **`--check` exit codes:** `0` healthy, `1` problems found (or no
  installation). `2` is reserved for a future drift report.
- **Installer exit status:** `0` on success, non-zero on any failure,
  including a finished run whose summary lists a problem.

### Toggles and settings

Each toggle works as an environment variable or as a `KEY=VALUE`
argument:

| Toggle            | Effect when `1`                                   |
| ---               | ---                                               |
| `SKIP_BUN_APP`    | No sample app, `bun-app` unit or managed site     |
| `SKIP_CLOUDFLARE` | No Cloudflare updater, timer or Nginx files       |
| `FULL_UPGRADE`    | `apt-get full-upgrade` instead of `upgrade`       |
| `SKIP_UPGRADE`    | No package upgrade (the index update still runs)  |
| `SKIP_CERTBOT`    | No snapd or Certbot                               |
| `SKIP_UFW`        | UFW left untouched                                |

- **Values:** only `1` turns a toggle on. Empty, `0` and `false` leave it
  off. Any other value is refused before anything changes, and so is
  `SKIP_UPGRADE=1` with `FULL_UPGRADE=1`.
- **`BUN_VERSION`** (variable or argument): `X.Y.Z` or `latest`; the
  default is the release's pinned Bun.
- **Environment only:** `TEMPLATE_REF`, `TEMPLATE_BASE_URL` and
  `BUN_DOWNLOAD_BASE_URL`, with the accepted forms the README describes
  (`https://` or `file://` URLs only).
- **Cloudflare updater:** `CLOUDFLARE_IPS_SOURCE=<dir>` reads
  `<dir>/ips-v4` and `<dir>/ips-v6` instead of fetching.

### Installed paths and names

- **App:** code in `/srv/app` (root-owned, read-only to the service),
  state in `/var/lib/bun-app` (also `/srv/app/data`), cache in
  `/var/cache/bun-app`.
- **Service:** `bun-app.service`, run by the system user `bun-app`, with
  `/etc/bun-app.env` holding `INSTANCE_ID` and `PORT`.
- **Bun:** `/usr/local/bin/bun`, with `bunx` linked to it.
- **Cloudflare:** `/usr/local/sbin/cloudflare-update-ips`, run by
  `cloudflare-update-ips.service` and `cloudflare-update-ips.timer`, and
  the generated lists in `/etc/nginx/cloudflare/`.
- **Nginx:** `snippets/bun-proxy.conf`, `snippets/cloudflare-only.conf`
  and the `conf.d/bun-*.conf` files under `/etc/nginx/`.
- **Nginx variables for your own config:** `$bun_cloudflare_edge` (`1`
  for a request from a Cloudflare edge) and `$bun_cloudflare_deny`.
- **Health:** `GET /healthz` answers `200` with the body `ok`.
- **Records:** `/var/lib/app-info/application.info` and its keys
  (`application_version`, `installer_version`, `template_ref`, `ufw`,
  the `distro*` keys and the others it holds today); the `INSTANCE_ID`
  line in `/etc/environment`.
- **Installer:** the log `/var/log/bun-installer.log`, its logrotate rule
  `/etc/logrotate.d/bun-installer`, and the lock
  `/run/lock/bun-installer.lock`.

### Re-run contract

Re-running the installer is safe and never clobbers your edits:

- **Kept files stay kept.** A file the installer reports as `Kept
  existing <path>` is never rewritten by a later release.
- **The Nginx default site** (`/etc/nginx/sites-available/default`) is
  kept, edits included, while it holds the marker line `# Managed by
  ubuntu-bun-server-setup.`. A site without the marker, such as Ubuntu's
  stock one, is replaced (in app mode).
- **`INSTANCE_ID`** stays the same across runs.
- **UFW** is never reset, and a firewall you turned off stays off.

### Release assets

Each release has an `install.sh` and a `SHA256SUMS` asset, and
`releases/latest/download/install.sh` points to the latest one.

## Not stable

These may change in any release, including a patch:

- **Wording** of output, the summary and the log. Scripts should rely on
  exit codes, not on text.
- **The sample app** and the content of templates for new installs.
  Existing hosts keep their kept files; see the README's
  [Re-running the installer][rerun].
- **The pinned Bun version,** within Bun's current major.
- **Package lists** and which apt packages get installed.
- **Sandbox directives** of the systemd units, when they only tighten.
- **Internal function names,** the test harness and the release tooling.

## What each bump means

- **Major:** removing, renaming or changing the meaning of anything in
  the stable surface; a re-run that rewrites a kept file or otherwise
  loosens the re-run contract; pinning a new Bun major.
- **Minor:** new toggles, files, checks or supported Ubuntu releases; a
  Bun pin bump within its major; dropping an Ubuntu release whose
  standard support has ended (see below).
- **Patch:** fixes that change nothing in the stable surface.

## Supported platforms

- **Ubuntu 22.04 and 24.04 LTS,** on x86_64 and aarch64. x86_64 hosts
  without AVX2 get Bun's baseline build.
- **End of life:** an Ubuntu release whose standard support has ended may
  be dropped in a minor release. The notes of the minor release before it
  announce the drop. For example, 22.04's standard support ends in April
  2027.

## Support window

- **The latest release only** gets fixes, security fixes included (see
  [SECURITY.md](../SECURITY.md)). There are no backport releases.
- **Upgrade** by re-running the latest release's installer; the re-run
  contract above keeps your edits.
- **One maintainer,** so support is best effort, with no response time
  promised.

## Scope

What the installer does not cover is listed in the README's
[Out of scope][out-of-scope].

[releases]: https://github.com/acfatah/ubuntu-bun-server-setup/releases
[rerun]: ../README.md#re-running-the-installer
[out-of-scope]: ../README.md#out-of-scope
