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
- Build a test image from `tests/docker/Dockerfile`
- Start short-lived, privileged containers mounting this repo read-only at `/workspace`
- Execute the test scripts under `tests/docker/scripts/*.sh`

### Running Individual Tests

You can target a specific scenario by calling the test runner directly:

```bash
tests/docker/run.sh test_root_guard
tests/docker/run.sh test_default
tests/docker/run.sh test_skip_sample
```

The `.sh` suffix is optional; both `test_default` and `test_default.sh` work.

### Test Scenarios

- `test_root_guard.sh` — ensures the installer fails when run as a non-root user
- `test_default.sh` — runs a default install and verifies systemd units, application files, Nginx configuration, HTTP response (`"Hello Bun"`), and `certbot` availability
- `test_skip_sample.sh` — runs the installer with `SKIP_BUN_APP=1` and checks that Nginx serves `/var/www/html` and returns the expected `"Hello World"` content

You can override the test image name with the `BUN_INSTALLER_TEST_IMAGE` environment variable if you want to reuse or inspect the image:

```bash
BUN_INSTALLER_TEST_IMAGE=my-registry/ubuntu-bun-installer-tests make test
```

### Test Development

When adding new functionality, please:
1. Add appropriate test cases in the `tests/docker/scripts/` directory
2. Follow the existing test patterns
3. Ensure your tests run in the Docker-based test environment

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

- Run `make lint` to check for linting issues
- Run `make format` to automatically format the bash script

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
ubuntu-bun-installer/
├── install.sh                 # Main installation script
├── makefile                   # Build and test automation
├── README.md                  # Project documentation
├── CONTRIBUTING.md            # This file
├── LICENSE                    # License information
├── templates/                 # Template files for config generation
│   ├── application.info       # Application metadata template
│   ├── bun-app.service        # Systemd service template
│   ├── motd.sh                # MOTD script template
│   ├── nginx-default.conf     # Nginx configuration template
│   ├── nginx-index-default.html # Default Nginx index template
│   ├── nginx-index-sample.html # Sample app index template
│   ├── package.json           # Sample Bun app package.json
│   └── server.ts              # Sample Bun app server
└── tests/
    └── docker/                # Docker-based test environment
        ├── Dockerfile         # Test environment Dockerfile
        ├── run.sh             # Test runner script
        └── scripts/           # Individual test scripts
            ├── common.sh      # Common test utilities
            ├── test_default.sh
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

