# Contributing to Ubuntu Bun Server Setup

Thank you for your interest in contributing to the Ubuntu Bun Server Setup project! This document outlines the guidelines for contributing to this repository.

## Table of Contents

<!-- TOC -->

- [Contributing to Ubuntu Bun Server Setup](#contributing-to-ubuntu-bun-server-setup)
  - [Table of Contents](#table-of-contents)
  - [Getting Started](#getting-started)
  - [Development Setup](#development-setup)
    - [Prerequisites](#prerequisites)
    - [Local Development](#local-development)
  - [Testing](#testing)
    - [Requirements](#requirements)
    - [Running Tests](#running-tests)
    - [Running Individual Tests](#running-individual-tests)
    - [Unit Tests](#unit-tests)
    - [Release Script Tests](#release-script-tests)
    - [Test Scenarios](#test-scenarios)
    - [Test Development](#test-development)
  - [Code Style](#code-style)
    - [Bash Scripting](#bash-scripting)
    - [Formatting](#formatting)
    - [Configuration](#configuration)
  - [Submitting Changes](#submitting-changes)
    - [Pull Request Guidelines](#pull-request-guidelines)
  - [Project Structure](#project-structure)
  - [Issue Reporting](#issue-reporting)
  - [Security](#security)
  - [License](#license)

<!-- /TOC -->

## Getting Started

This project is a bash script that bootstraps an opinionated, production-ready Bun application environment for Ubuntu. It installs Bun, Nginx, UFW, Certbot, and sets up a sample Bun app with systemd service and Nginx reverse proxy configuration.

Before contributing, please familiarize yourself with:
- Bash scripting
- System administration concepts (systemd, Nginx, UFW)
- Docker (for testing)
- The project's [README.md](README.md) for an overview, and the operator
  documentation in [docs/](docs/README.md)

## Development Setup

### Prerequisites

- Ubuntu 22.04+ or 24.04
- Docker for running tests
- Git
- Basic Unix/Linux tools (curl, bash, etc.)

### Local Development

1. Fork the repository on GitHub
2. Clone your fork locally:
   ```bash
   git clone https://github.com/YOUR_USERNAME/ubuntu-bun-server-setup.git
   cd ubuntu-bun-server-setup
   ```
3. Create a new branch for your feature or bug fix:
   ```bash
   git checkout -b feature/your-feature-name
   ```

## Testing

This project includes a Docker-based end-to-end test harness that provisions an Ubuntu systemd environment in a container and runs the installer in realistic scenarios.

### Requirements

- Docker installed and the Docker daemon running.
- Ability to run privileged containers (the test container runs systemd).
- Run commands from the repository root.

### Running Tests

From the project root:

```bash
make test
```

This will:
- Build a test image from `tests/docker/Dockerfile` (Ubuntu 22.04 by default)
- Start short-lived, privileged containers mounting this repo read-only at `/workspace`
- Execute every `tests/docker/scripts/test_*.sh` script

To test against another Ubuntu release, set `UBUNTU_VERSION`:

```bash
UBUNTU_VERSION=24.04 make test
```

CI runs the same suite on both 22.04 and 24.04 for every pull request, plus `make lint`, `make format-check`, `make lint-actions`, `make test-unit` and `make test-release`.

### Unit Tests

Pure functions and the MOTD script have a [bats-core](https://github.com/bats-core/bats-core) suite under `tests/unit/`. It runs in seconds, without Docker or root:

```bash
make test-unit
# without a local bats (v1.14.0, as in CI); make turns $$PWD into $PWD:
make test-unit BATS='docker run --rm -v "$$PWD:/code:ro" -w /code bats/bats:1.14.0'
```

- `install.bats` sources `install.sh` (its install steps run only when the script is executed, not sourced) and covers `replace_placeholder`, `parse_args`, the toggles and `TEMPLATE_REF` validation
- `release.bats` covers `release.sh`'s version helpers and `build-installer.sh`'s version check
- `motd.bats` runs `templates/motd.sh` with stubbed `bun`, `nginx` and `hostname` commands

### Release Script Tests

`release.sh` has its own harness, which needs only `git` and `bash` (no Docker):

```bash
make test-release
```

Each scenario in `tests/release/run.sh` runs the script without a terminal in a throwaway clone with a bare `origin` under `mktemp -d`, ignoring your git config. It covers a full release, a linked worktree, every refusal (off `main`, uncommitted changes, behind or ahead of `origin/main`, existing tag, version not greater, broken installer build), `--dry-run`, a rejected push and unknown options. See [RELEASE.md](RELEASE.md) for the release process.

### Running Individual Tests

You can target a specific scenario by calling the test runner directly:

```bash
tests/docker/run.sh test_root_guard
tests/docker/run.sh test_default
tests/docker/run.sh test_skip_sample
tests/docker/run.sh test_piped_install
tests/docker/run.sh test_idempotent
tests/docker/run.sh test_host_safety
tests/docker/run.sh test_cloudflare
tests/docker/run.sh test_release_build
tests/docker/run.sh test_fail_loudly
tests/docker/run.sh test_custom_app
tests/docker/run.sh test_docker_app
```

The `.sh` suffix is optional; both `test_default` and `test_default.sh` work. Several names run in one call, e.g. `tests/docker/run.sh test_root_guard test_default`. The runner runs every selected test even after one fails, then prints a pass/fail count and names each failed test; it exits non-zero if any failed.

### Test Scenarios

- `test_root_guard.sh` — ensures the installer fails when run as a non-root
  user.
- `test_default.sh` — runs a default install and verifies systemd units,
  application files, Nginx configuration, HTTP response (`"Hello Bun"`),
  the `/api/` proxy to Bun (prefix kept), security headers, a single
  `Cache-Control` on `/assets/`, a `Connection: upgrade` header sent only
  for upgrade requests, the root-only `/etc/bun-app.env`, the non-root `bun-app` service user, read-only
  code / writable state dir, Bun listening on `127.0.0.1:3000` only, port
  22 limited when no sshd is installed, `certbot` availability, the
  pinned Bun version with its embedded checksum and `bunx` link, the
  unit's stop timeout and file limit, `systemd-analyze verify` on
  both units, `/healthz` (`ok`, no access-log line), `--check` passing as
  `nobody`, `logrotate -d` on the rule, and `--check` failing with
  `bun-app` stopped, naming the service and the probe.
- `test_bun_pin.sh` — rejects `BUN_VERSION=yes`; a tampered zip on a
  `file://` mirror fails with nothing in `/usr/local/bin`; a bad
  `SHASUMS256.txt` for `BUN_VERSION=1.4.3` fails and leaves the installed
  Bun byte-identical; `BUN_VERSION=1.4.3` replaces the pin, a default run
  brings it back, another run leaves it alone, and `BUN_VERSION=latest`
  installs the newest release.
- `test_skip_sample.sh` — runs the installer with `SKIP_BUN_APP=1` and checks
  that Nginx serves `/var/www/html` and returns the expected `"Hello World"`
  content, that the stock Nginx site is kept and no proxy snippet or map
  file is installed, that the Cloudflare real-IP config is installed with
  the stock site untouched, that `SKIP_UFW=1` leaves UFW inactive with
  no rules, that `SKIP_CERTBOT=1` installs neither snapd nor Certbot, and
  that `--check` passes checking neither `bun-app`, the probe nor Certbot.
  A re-run without either toggle keeps a custom `index.html`, enables UFW
  and installs Certbot, which `--check` then checks.
- `test_custom_app.sh` — runs what [docs/app.md](docs/app.md) shows:
  replaces the sample with `docs/examples/hono` and checks `/healthz`,
  `/api/x` and a SQLite counter in the state dir; a re-run keeps the
  app's `package.json` and writes no sample `server.ts`; static files in
  `/var/www/app/dist` are served beside `/api/`. Then
  `docs/examples/deploy.sh` deploys over SSH to `localhost` as a sudo
  user, in place and with `--release` (after the one-time migration it
  prints), prunes old releases, survives an installer re-run and
  `--rollback`s to the previous release. Needs the npm registry for
  `bun install`.
- `test_docker_app.sh` — runs what
  [docs/cookbook/docker.md](docs/cookbook/docker.md) shows: a
  `SKIP_BUN_APP=1` install, Docker inside the test container, the copied
  proxy site, and `docs/examples/hono` built as an image and published on
  `127.0.0.1:3000`. Checks `/healthz`, `/api/x` and its counter through
  Nginx, that port 3000 is reachable on loopback only, the read-only and
  `--cap-drop ALL` flags, that a re-run keeps the site and `--check`
  skips the app, and that a new image keeps the volume's state and the
  old one rolls back. Also fails when the Dockerfile's `oven/bun` tag
  differs from `BUN_PINNED_VERSION`. Needs Docker Hub and the npm
  registry.
- `test_idempotent.sh` — rejects `SKIP_BUN_APP=yes`, installs with
  `SKIP_BUN_APP=0`, edits installed files, checks a run is refused and
  changes nothing while the lock is held, re-runs, and checks the edits
  survive, `INSTANCE_ID` stays a single stable line (also in
  `/etc/bun-app.env` and the process environment), and the MOTD
  diversions outlast a `base-files` reinstall. The edited files include the
  logrotate rule.
- `test_piped_install.sh` — pipes the installer into `bash -s --
  SKIP_BUN_APP=1` the way the Quick Start does, with
  `TEMPLATE_BASE_URL=file:///workspace/templates` so the branch's templates
  are used. Checks the argument takes effect, Cloudflare support is
  installed, no `BASH_SOURCE` error is printed, downloaded (not local)
  templates are used, and that unknown arguments, a `TEMPLATE_REF` with
  `..` and an `http://` `TEMPLATE_BASE_URL` are rejected; `--version` names
  the ref and says the dev channel is not verified, and `--help` runs as
  non-root.
- `test_release_build.sh` — builds a pinned installer with
  `build-installer.sh 9.9.9`, checks its `SHA256SUMS` and `--version`, and
  pipes it with `file://` templates: `--version` says templates are
  verified, they are, and `application.info` records
  `installer_version="9.9.9"`. A re-run with a tampered `application.info`
  fails with a checksum error and leaves the installed file unchanged; with
  `TEMPLATE_REF=main` it warns, skips verification and logs why.
- `test_fail_loudly.sh` — runs a copy of the repo with a broken
  `nginx-default.conf` and checks the installer exits non-zero with the
  `install failed at line N` message and no colour escapes off a terminal.
  With snapd masked, a run is refused with the masked message before any
  package upgrade; on a faked Ubuntu 20.04, likewise.
- `test_host_safety.sh` — rejects `FULL_UPGRADE=yes` and
  `SKIP_UPGRADE=1` with `FULL_UPGRADE=1`, installs
  openssh-server on port 2222 and checks UFW limits `2222/tcp` (not 22) and
  the default run uses `apt-get upgrade`. After adding a rule and changing
  the default incoming policy, a `FULL_UPGRADE=1` re-run keeps both, uses
  `full-upgrade`, prints the reboot hint, and adds no duplicate SSH rule.
  It also rejects `SKIP_UFW=yes`, and after `ufw disable` a third run,
  with `SKIP_UPGRADE=1`, leaves UFW disabled and runs `apt-get update`
  but no upgrade. That run starts while a helper holds the package lists
  lock and dpkg's frontend lock: it waits for both and succeeds.
- `test_cloudflare.sh` — rejects `SKIP_CLOUDFLARE=yes`, checks the updater,
  enabled timer, generated lists and geo after a default install. Against a
  stubbed source (`CLOUDFLARE_IPS_SOURCE`), an HTML body, a junk line, a
  short list, an empty family, and a list `nginx -t` refuses all fail and
  leave the lists and Nginx unchanged; a good list applies, a repeat run
  reports `unchanged`, the access log shows the `CF-Connecting-IP` address,
  and the `cloudflare-only.conf` include answers 200 from an edge and 403
  otherwise, except `/healthz` from `127.0.0.1` (and `::1` when present),
  which still gets 200; from the container's own address it gets 403. Through `systemctl start`, inside the unit's sandbox, a
  changed list applies and reloads Nginx, and a list `nginx -t` refuses
  fails the unit with the lists unchanged. A re-run on a host whose site still includes the old
  `cloudflare-ip-filter.conf` does not enable real client IP.

You can override the test image name with the `BUN_INSTALLER_TEST_IMAGE` environment variable if you want to reuse or inspect the image:

```bash
BUN_INSTALLER_TEST_IMAGE=my-registry/ubuntu-bun-installer-tests make test
```

### Test Development

When adding new functionality, please:
- For a pure function, add a case to `tests/unit/*.bats`; use plain bats (`run`, `[ "$status" -eq 1 ]`, `[[ $output == *text* ]]`), no helper libraries
- For an install behaviour, add a Docker test:

1. Add a `tests/docker/scripts/test_<name>.sh` script; the runner picks up every `test_*.sh` automatically
2. Put a `# Test: <label>` line right after the shebang; the runner prints it as the test name
3. Source `common.sh` for `run_installer` and the `assert_*` helpers, and follow the existing test patterns

A new [cookbook](docs/cookbook/README.md) page ships an example in `docs/examples/<name>/` and a Docker test that runs the page's steps against it. The page links `docs/app.md` "What the host expects" instead of restating the contract, sits outside the footer chain, and ends with a "Back to Your app" link.

## Code Style

### Bash Scripting

- Use `#!/usr/bin/env bash` as the shebang
- Include `set -euo pipefail` for error handling
- Use descriptive variable names
- Follow the existing code formatting and structure
- Use functions to organize code logically
- Include comments for complex logic
- Use local variables in functions to avoid global scope pollution

### Formatting

The project uses `shellcheck` for linting and `shfmt` for formatting:

- Run `make lint` to check every shell script for linting issues
- Run `make format` to format every shell script in place
- Run `make format-check` to list formatting differences without writing
- Indentation and shfmt options come from `.editorconfig`

### Configuration

- Keep environment toggles consistent with existing patterns
- Use consistent color codes and output formatting
- Follow the existing parameter handling patterns

## Submitting Changes

1. Ensure your changes pass all tests:
   ```bash
   make test
   ```
2. Lint and format your code:
   ```bash
   make lint
   make format
   ```
3. Write clear, descriptive commit messages
4. Push your changes to your fork
5. Submit a pull request with a clear description of your changes

### Pull Request Guidelines

- Keep pull requests focused on a single feature or bug fix
- Include tests for new functionality
- Update documentation as needed
- A breaking change to the stable surface in
  [docs/compatibility.md](docs/compatibility.md) (toggles, flags, exit
  codes, installed paths, the re-run contract) needs a major release; say
  so in the PR. When you add to the surface, list the addition there
- Reference any related issues in your pull request description
- Ensure all CI checks pass

## Project Structure

```
ubuntu-bun-server-setup/
├── .editorconfig              # Indentation and shfmt options
├── .shellcheckrc              # shellcheck options
├── .github/
│   ├── assets/sponsors/       # Sponsor logos for the README
│   ├── dependabot.yml         # Weekly GitHub Actions updates
│   └── workflows/
│       ├── ci.yml             # Lint, unit and release tests on every PR
│       ├── e2e.yml            # Docker e2e tests (22.04/24.04)
│       └── release.yml        # GitHub Release on v* tags
├── build-installer.sh         # Pinned release installer (dist/)
├── docs/                      # Operator documentation
│   ├── README.md              # Index of the pages
│   ├── app.md                 # Your app: contract, recipes, deploys
│   ├── architecture.md        # Install flow, units, Nginx files, re-runs
│   ├── examples/              # Run by test_custom_app and test_docker_app
│   │   ├── deploy.sh          # Deploy over SSH: in place or release dirs
│   │   └── hono/              # Example app replacing the sample
│   │       ├── .dockerignore
│   │       ├── Dockerfile     # Image for the cookbook's container page
│   │       ├── bun.lock
│   │       ├── package.json
│   │       └── src/index.ts
│   ├── cloudflare.md          # Real client IP, updater
│   ├── compatibility.md       # Stability promise and support window
│   ├── cookbook/              # Setups beyond the stock app, one page each
│   │   ├── README.md          # Index of the recipes
│   │   └── docker.md          # Run your app in a container
│   ├── configuration.md       # Settings reference, environment toggles
│   ├── installation.md        # Install options, channels, Bun, offline
│   ├── operations.md          # Health check, re-runs, TLS, backups
│   ├── security.md            # Threat model, service user, sandbox
│   ├── troubleshooting.md     # Failure messages, causes and fixes
│   └── upgrading.md           # Newer releases, support, known gaps
├── install.sh                 # Main installation script (dev channel)
├── Makefile                   # Build and test automation
├── README.md                  # Project overview
├── CLAUDE.md                  # Notes for Claude Code
├── CONTRIBUTING.md            # This file
├── RELEASE.md                 # Release process
├── SECURITY.md                # Reporting vulnerabilities
├── release.sh                 # Checked, atomic release (VERSION, tag, push)
├── VERSION                    # Current SemVer version
├── LICENSE                    # License information
├── templates/                 # Template files for config generation
│   ├── application.info       # Application metadata template
│   ├── bun-app.env            # Service environment file template
│   ├── bun-app.service        # Systemd service template
│   ├── cloudflare-update-ips.sh # Cloudflare IP list updater
│   ├── cloudflare-update-ips.service # Updater oneshot unit
│   ├── cloudflare-update-ips.timer # Daily updater timer
│   ├── motd.sh                # MOTD script template
│   ├── nginx-bun-proxy.conf   # Nginx proxy snippet for Bun
│   ├── nginx-cloudflare.conf  # Real client IP + Cloudflare edge geo
│   ├── nginx-cloudflare-only.conf # Optional 403 for non-Cloudflare requests
│   ├── nginx-connection-upgrade.conf # Nginx WebSocket Connection map
│   ├── nginx-default.conf     # Nginx configuration template
│   ├── nginx-index-default.html # Default Nginx index template
│   ├── nginx-index-sample.html # Sample app index template
│   ├── package.json           # Sample Bun app package.json
│   └── server.ts              # Sample Bun app server
└── tests/
    ├── release/
    │   └── run.sh             # release.sh tests (make test-release)
    ├── unit/                  # bats unit tests (make test-unit)
    │   ├── install.bats
    │   ├── motd.bats
    │   └── release.bats
    └── docker/                # Docker-based test environment
        ├── Dockerfile         # Test environment Dockerfile
        ├── run.sh             # Test runner script
        └── scripts/           # Individual test scripts
            ├── common.sh      # Common test utilities
            ├── test_bun_pin.sh
            ├── test_cloudflare.sh
            ├── test_custom_app.sh
            ├── test_default.sh
            ├── test_fail_loudly.sh
            ├── test_host_safety.sh
            ├── test_idempotent.sh
            ├── test_piped_install.sh
            ├── test_release_build.sh
            ├── test_root_guard.sh
            └── test_skip_sample.sh
```

## Issue Reporting

When reporting issues, please include:

- Ubuntu version you're running on
- Steps to reproduce the issue
- Expected behavior
- Actual behavior
- Any error messages or logs
- Whether you're running the script with `sudo` as required

For feature requests, please explain:
- The problem you're trying to solve
- Your proposed solution
- Any alternatives you've considered

## Security

If you discover a security vulnerability, please do not open a public issue. Report it privately as described in [SECURITY.md](SECURITY.md).

## License

By contributing to this project, you agree that your contributions will be licensed under the same license as the project (see [LICENSE](LICENSE)).

