# Installation

How to install: prerequisites, the ways to run the installer, pinned
and development channels, where templates come from, which Bun it
installs, and how to install without direct internet access. The first
install command is in the [README Quick Start](../README.md#quick-start).

## Prerequisites

- Ubuntu 22.04 or later, run as root or with sudo. Older releases are refused before any package is installed.
- Internet access for package and snap installs, or mirrors and a
  proxy; see [Air-gapped and proxied
  installs](#air-gapped-and-proxied-installs).
- A usable snapd, unless `SKIP_CERTBOT=1`. Certbot comes only from the
  snap, so a host where snapd is masked, or not installed and not
  installable through apt (removed from the sources or pinned away), is
  refused right after `apt-get update`, before any package changes. The
  message names both ways out: unmask (or unpin) snapd, or re-run with
  `SKIP_CERTBOT=1`.
- No long-running apt or dpkg. On a fresh cloud VM, unattended-upgrades,
  `apt-daily` or cloud-init often hold the apt locks for the first
  minutes; the installer waits up to 10 minutes for them, printing a
  wait line every 10 seconds while the package lists are locked. A lock
  held longer fails the install with `Could not get lock`; re-run it once
  the other apt is done.

## Other ways to install

To skip sample app:

```bash
curl -fsSL https://github.com/acfatah/ubuntu-bun-server-setup/releases/latest/download/install.sh | sudo bash -s -- SKIP_BUN_APP=1
```

The same toggle also works as an environment variable:

```bash
curl -fsSL https://github.com/acfatah/ubuntu-bun-server-setup/releases/latest/download/install.sh | sudo SKIP_BUN_APP=1 bash
```

Or after cloning this repository (the development channel; templates are
read from the clone):

```bash
sudo bash install.sh
```

## Pin and check a version

Download a fixed release, check it against the release's `SHA256SUMS`, then
run it:

```bash
v=1.0.0   # any release from 0.5.0 on
curl -fsSLO "https://github.com/acfatah/ubuntu-bun-server-setup/releases/download/v$v/install.sh"
curl -fsSLO "https://github.com/acfatah/ubuntu-bun-server-setup/releases/download/v$v/SHA256SUMS"
sha256sum -c SHA256SUMS
sudo bash install.sh
```

`--version` prints the installer version, where its templates come from,
whether they are verified, and the Bun version it installs; `--help` lists
the toggles. Neither needs root, nor does `--check` (see
[Health check](operations.md#health-check)):

```bash
curl -fsSL https://github.com/acfatah/ubuntu-bun-server-setup/releases/latest/download/install.sh | bash -s -- --version
```

## Development channel

The `install.sh` on `main` is the development channel: it reports version
`dev`, fetches templates from `main`, and does not verify them. Its
`--version` says `templates: not verified (dev channel)`.

```bash
curl -fsSL https://raw.githubusercontent.com/acfatah/ubuntu-bun-server-setup/main/install.sh | sudo bash
```

## Template source

Two environment variables change where templates are downloaded from. They
are not `KEY=VALUE` arguments; with `sudo`, put them after it, as in
`sudo TEMPLATE_REF=dev bash`.

- `TEMPLATE_REF=<ref>` — a branch, tag or commit of this repository. A
  release installer pointed at another ref skips verification and prints a
  warning, since the files are expected to differ. Letters, digits, `.`,
  `_`, `/` and `-` only, and no `..`.
- `TEMPLATE_BASE_URL=<url>` — the templates directory itself, such as an
  `https://` mirror or `file:///path/to/templates`. Any other scheme,
  `http://` included, is refused before anything is installed. A release
  installer still verifies what it downloads from there.

Downloads use TLS 1.2 or later, follow redirects to `https://` only, retry
transient errors 3 times, and give up after 60 seconds per attempt (10
minutes for the Bun zip).

## Bun version

Bun comes from its GitHub release zip, not from `bun.sh/install`. Each
installer pins one Bun version (1.4.4), the same in the development channel
and in releases; `--version` prints it as a `bun:` line.

- **Pinned (default):** the zip is checked against SHA-256 sums built into
  the installer, for `linux-x64`, `linux-x64-baseline` (x64 CPUs without
  AVX2) and `linux-aarch64`.
- **`BUN_VERSION=X.Y.Z`:** that release, checked against the release's own
  `SHASUMS256.txt`. Weaker than the pin: the sums come from the same place
  as the zip.
- **`BUN_VERSION=latest`:** the newest release, looked up on GitHub first,
  then handled like `X.Y.Z`.
- **Anything else** (`v1.2.3`, `1.2`, `yes`) exits 1 before anything is
  installed.

The zip is downloaded, verified and unpacked in a temporary directory.
Only then is the binary copied next to `/usr/local/bin/bun`, where it must
report the expected version before it is renamed over the old one. A
checksum mismatch stops the install with nothing written to
`/usr/local/bin`, and the existing Bun stays as it was.
`/usr/local/bin/bunx` is a link to `bun`, as the upstream installer makes
it.

`BUN_DOWNLOAD_BASE_URL=<url>` (environment only, like `TEMPLATE_BASE_URL`)
points at a mirror laid out like the releases:
`<url>/bun-v1.4.4/bun-linux-x64.zip`, plus `SHASUMS256.txt` for unpinned
versions. `https://` and `file://` only. `latest` is still looked up on
GitHub.

```bash
sudo bash install.sh BUN_VERSION=1.3.0
sudo BUN_VERSION=latest bash install.sh
```

## Air-gapped and proxied installs

Every download the installer and the Cloudflare updater make, and what
replaces it on a host without direct internet access:

| What | From | Mirror or skip |
| --- | --- | --- |
| Ubuntu packages | the apt sources on the host | a local apt mirror in the host's apt sources |
| snapd's snaps and Certbot | the snap store | `SKIP_CERTBOT=1` (no snap mirror) |
| Templates | `raw.githubusercontent.com`, the installer's ref | `TEMPLATE_BASE_URL=file:///...` or `https://` mirror |
| Bun zip and `SHASUMS256.txt` | `github.com/oven-sh/bun` releases | `BUN_DOWNLOAD_BASE_URL=file:///...` or `https://` mirror |
| `BUN_VERSION=latest` lookup | `github.com`, always | use the pin or `BUN_VERSION=X.Y.Z` |
| Cloudflare IP lists | `www.cloudflare.com/ips-v4`, `ips-v6` | `CLOUDFLARE_IPS_SOURCE=<dir>`, or `SKIP_CLOUDFLARE=1` |
| The installer itself | GitHub Releases | download it once, copy it over |

### No internet access

1. **Point apt at a local mirror** of the Ubuntu archive (and the
   security pocket), so `apt-get update` and the base packages work.
2. **Skip Certbot** with `SKIP_CERTBOT=1`. Certbot comes only from the
   snap store; get certificates another way, or install it later when
   the host can reach the store.
3. **Copy the release installer and its templates.** Take `install.sh`
   from a release, and the `templates/` directory of the same tag (for
   example from `git clone --branch vX.Y.Z`). A release installer checks
   `file://` templates against its built-in sums, as it does for
   downloads. Keep `install.sh` out of the directory that holds
   `templates/`: a `templates/` next to the script is used as is,
   without that check.
4. **Mirror the pinned Bun zip** in the release layout:
   `<dir>/bun-v<version>/bun-linux-x64.zip` (or `-x64-baseline`,
   `-aarch64`). The pinned zip needs no `SHASUMS256.txt`; another
   `BUN_VERSION=X.Y.Z` needs that file next to the zip. Never use
   `latest`: it always asks GitHub.
5. **Give the Cloudflare lists from a directory** holding `ips-v4` and
   `ips-v6`, or skip Cloudflare support with `SKIP_CLOUDFLARE=1`.
6. **Run it from the file:**

   ```bash
   # install.sh in the current directory, the mirrors under /opt/bun-installer
   sudo TEMPLATE_BASE_URL=file:///opt/bun-installer/templates \
     BUN_DOWNLOAD_BASE_URL=file:///opt/bun-installer/bun \
     CLOUDFLARE_IPS_SOURCE=/opt/bun-installer/cloudflare \
     bash install.sh SKIP_CERTBOT=1
   ```

`CLOUDFLARE_IPS_SOURCE` set for the installer only reaches its first
fetch. The daily timer runs the updater as a systemd unit, with its own
environment; give it the directory in a drop-in, outside `/root` and
`/home` (the unit hides both):

```bash
sudo systemctl edit cloudflare-update-ips.service
# [Service]
# Environment=CLOUDFLARE_IPS_SOURCE=/opt/bun-installer/cloudflare
```

Refresh the files in that directory yourself; the updater only reads
them and checks them as it checks a fetch (see Cloudflare,
[Updates](cloudflare.md#updates)).

### Behind a proxy

`sudo` resets the environment (Ubuntu's `/etc/sudoers` keeps no proxy
variables), so put the proxy variables after `sudo`, in the piped form
too:

```bash
curl -fsSL https://github.com/acfatah/ubuntu-bun-server-setup/releases/latest/download/install.sh \
  | sudo https_proxy=http://proxy:3128 http_proxy=http://proxy:3128 \
    no_proxy=127.0.0.1,localhost bash
```

- **apt and curl read them.** Use the lowercase names: curl ignores an
  uppercase `HTTP_PROXY`.
- **Set `no_proxy=127.0.0.1,localhost`.** With `http_proxy` set, the
  summary's `/healthz` probe to `http://127.0.0.1` goes to the proxy
  too, and fails.
- **snapd ignores the installer's environment.** It needs its own
  proxy setting before the Certbot snap can install. Where snapd is
  already installed (Ubuntu's server and cloud images), set it first.
  Where it is not, run once with `SKIP_CERTBOT=1`, install snapd with
  apt, set the proxy, then re-run without the toggle:

  ```bash
  sudo snap set system proxy.https=http://proxy:3128
  sudo snap set system proxy.http=http://proxy:3128
  ```

- **The Cloudflare updater** runs from its timer, without your shell's
  variables. Give it the proxy in a drop-in:

  ```bash
  sudo systemctl edit cloudflare-update-ips.service
  # [Service]
  # Environment=https_proxy=http://proxy:3128
  ```

---

<div align="center">

[Documentation index](README.md) · [Configuration →](configuration.md)

</div>
