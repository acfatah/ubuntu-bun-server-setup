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
- The project's [README.md](README.md) for an overview

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
# without a local bats (v1.14.0, as in CI):
make test-unit BATS='docker run --rm -v "$PWD:/code:ro" -w /code bats/bats:1.14.0'
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
```

The `.sh` suffix is optional; both `test_default` and `test_default.sh` work.

### Test Scenarios

- `test_root_guard.sh` — ensures the installer fails when run as a non-root user
- `test_default.sh` — runs a default install and verifies systemd units, application files, Nginx configuration, HTTP response (`"Hello Bun"`), `/api/x` reaching Bun with its prefix, security and cache headers, the WebSocket `Connection` header sent only on upgrade requests, the root-only `/etc/bun-app.env`, Bun listening on `127.0.0.1` only, port 22 limited when no sshd is installed, and `certbot` availability
- `test_skip_sample.sh` — runs the installer with `SKIP_BUN_APP=1` and checks that Nginx serves `/var/www/html` and returns the expected `"Hello World"` content, keeps the stock Nginx site without the proxy snippet or map file, installs the Cloudflare real-IP config without touching the stock site, and keeps a custom `index.html` on a re-run
- `test_idempotent.sh` — rejects `SKIP_BUN_APP=yes`, installs with `SKIP_BUN_APP=0`, edits installed files, re-runs, and checks the edits survive, `INSTANCE_ID` stays a single stable line, and the MOTD diversions outlast a `base-files` reinstall
- `test_piped_install.sh` — pipes the installer through `bash -s` with `SKIP_BUN_APP=1` as an argument and `TEMPLATE_BASE_URL=file:///workspace/templates`, so the branch's templates are downloaded (Cloudflare included) before they reach `main`; checks that unknown arguments and an invalid `TEMPLATE_REF` are rejected, `--version` names the ref, and `--help` runs as non-root
- `test_release_build.sh` — builds a pinned installer with `build-installer.sh 9.9.9`, checks `SHA256SUMS` and `--version`, runs it piped with verified `file://` templates, then checks a tampered template fails the re-run and leaves the installed file unchanged, and that `TEMPLATE_REF=main` skips verification with a warning
- `test_host_safety.sh` — rejects `FULL_UPGRADE=yes`, runs sshd on port 2222 and checks UFW limits `2222/tcp` instead of 22 with `apt-get upgrade`, then checks a `FULL_UPGRADE=1` re-run keeps an added rule and a changed default policy, and prints the reboot hint
- `test_cloudflare.sh` — rejects `SKIP_CLOUDFLARE=yes`, checks the updater, timer and Nginx files after a default install, then runs the updater on a stubbed `CLOUDFLARE_IPS_SOURCE`: bad lists (HTML body, junk line, short list, empty family, a list `nginx -t` refuses) leave the lists and Nginx unchanged, a good list applies and reloads once, the access log shows the `CF-Connecting-IP` address, the `cloudflare-only.conf` include returns 403 to non-edge clients, and a re-run under the old `cloudflare-ip-filter.conf` does not enable real client IP

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
- Reference any related issues in your pull request description
- Ensure all CI checks pass

## Project Structure

```
ubuntu-bun-server-setup/
├── .github/
│   ├── dependabot.yml         # Weekly GitHub Actions updates
│   └── workflows/
│       ├── ci.yml             # Lint, unit and release tests on every PR
│       ├── e2e.yml            # Docker e2e tests (22.04/24.04)
│       └── release.yml        # GitHub Release on v* tags
├── build-installer.sh         # Pinned release installer (dist/)
├── install.sh                 # Main installation script (dev channel)
├── Makefile                   # Build and test automation
├── README.md                  # Project documentation
├── CONTRIBUTING.md            # This file
├── RELEASE.md                 # Release process
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
            ├── test_cloudflare.sh
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

If you discover a security vulnerability, please report it responsibly by contacting the maintainers directly rather than creating a public issue.

## License

By contributing to this project, you agree that your contributions will be licensed under the same license as the project (see [LICENSE](LICENSE)).

