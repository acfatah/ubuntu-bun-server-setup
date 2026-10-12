# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

## What this is

A single Bash installer (`install.sh`) that provisions an Ubuntu 22.04+ host
with Bun, Nginx, UFW, Certbot (snap), a sample Bun app under `/srv/app`, and a
`bun-app` systemd unit. No application code to build; `templates/` holds the
files the installer drops onto the target host.

## Commands

```bash
make lint          # shellcheck every *.sh (install, release, tests, templates)
make format        # shfmt -w; style comes from .editorconfig
make format-check  # shfmt -d; fails on unformatted files
make lint-actions  # actionlint on .github/workflows (shellchecks run: blocks)
make test          # all Docker e2e tests (needs Docker + privileged containers)
UBUNTU_VERSION=24.04 make test            # e2e on another Ubuntu (default 22.04)
tests/docker/run.sh test_default          # single test (.sh suffix optional)
./release.sh --dry-run minor              # preview a release
```

- Lint and format cover `install.sh`, `release.sh`, `tests/docker/**/*.sh`
  and `templates/*.sh` (`SHELL_FILES` in `Makefile`).
- Style lives in `.editorconfig` (2-space, `-bn -ci`); shfmt reads it only
  when no printer flags are passed. `.shellcheckrc` sets
  `external-sources=true`, so no `-x`.
- `shellcheck`, `shfmt` and `actionlint` must be on `PATH`, or pass an
  override, e.g.
  `make lint SHELLCHECK='docker run --rm -v "$PWD:/mnt:ro" -w /mnt koalaman/shellcheck:v0.10.0'`
  (`SHFMT`: `mvdan/shfmt:v3.8.0`; `ACTIONLINT`: `rhysd/actionlint:1.7.12`).

## Architecture

### Template resolution (`download_template` in `install.sh`)

- If `templates/<name>` exists next to the script, it is copied (cloned-repo
  or test run). Only when run from a real file: a piped run has no
  `BASH_SOURCE[0]`, so it never uses a local `templates/`.
- Otherwise it is fetched from `TEMPLATE_BASE_URL`, which is pinned to
  **`main`** on GitHub (the `curl | sudo bash` path).
- Gotcha: template edits on a branch are exercised by tests (repo mounted
  locally) but never reach curl-piped installs until merged to `main`.

### Placeholders

Templates contain `__NAME__` tokens (`__NGINX_ROOT__`, `__INSTANCE_ID__`,
`__BUILD_DATE__`, `__DISTRO__`, ...) substituted post-copy by
`replace_placeholder` (sed with `|` delimiter; escapes `|` and `&`). Adding
a token means editing both the template and the matching
`replace_placeholder` call.

### Install flow (`main`)

Top level: `parse_args` → root check → `start_log` → `main 2>&1 | tee -a
/var/log/bun-installer.log` (`pipefail` carries `main`'s status).

`main`: ERR trap → Ubuntu check → apt full-upgrade → base packages → UFW
reset + rules → Certbot snap → Bun (`BUN_INSTALL=/usr/local` →
`/usr/local/bin/bun`) → `bun-app` system user → sample app → Nginx config +
Cloudflare helpers → `nginx -t` → restart → systemd unit + `/srv/app/data`
symlink → `/var/lib/app-info/application.info` → `INSTANCE_ID` line
rewritten in `/etc/environment` → MOTD → summary.

### Failure handling

- `set -Eeuo pipefail`; the ERR trap is set inside `main` (which runs in
  the pipeline subshell), so it prints
  `install failed at line N (<function>)` once.
- No `|| true` on essential steps. Each remaining one is benign and says
  why in a comment.
- `print_summary` checks `certbot --version`, `nginx` and (unless skipped)
  `bun-app` are active; it lists problems and returns 1, which `main`
  turns into `exit 1` without tripping the trap.
- Colours are empty unless stdout is a TTY (decided before the pipe).

### Service user and sandbox

- `bun-app.service` runs as `bun-app` (nologin) with a strict sandbox
  (`ProtectSystem=strict`, empty `CapabilityBoundingSet`, ...). README
  "Security" documents every directive; keep the two in sync.
- `/srv/app` is root-owned and read-only to the service. Writable state is
  `StateDirectory=bun-app` (`/var/lib/bun-app`, symlinked as
  `/srv/app/data`) and `CacheDirectory=bun-app`.
- Never add `MemoryDenyWriteExecute`: Bun's JIT needs W+X memory and the
  unit crash-loops.
- `install_bun` skips only if `/usr/local/bin/bun` runs as `nobody`
  (`runuser -u nobody`); a legacy symlink into `/root/.bun` is replaced.
  Gotcha: `setpriv --reuid=nobody <bin>` falsely succeeds for binaries
  under `/root`; don't use it for permission probes.
- `create_app_user` and the data symlink are skipped with `SKIP_BUN_APP=1`.

### `SKIP_BUN_APP` mode

- Set as env var or `KEY=VALUE` arg (`parse_args`, allowlisted; unknown
  args exit 1 before the root check).
- Only **`1`** skips; every check goes through `skip_app`. `parse_args`
  accepts empty, `0`, `false` (install) and `1`; any other value exits 1
  before the root check.
- `NGINX_ROOT` is chosen in `parse_args`, not at top level, so the arg form
  takes effect.
- Changes `NGINX_ROOT` from `/var/www/app/dist` to `/var/www/html`.
- Skips sample app, systemd unit, **and** `nginx-default.conf`: Ubuntu's
  stock default site is left in place; only `index.html` is written, and
  only if absent.
- Cloudflare helper files are copied to `/etc/nginx` in both modes.

### Nginx (`templates/nginx-default.conf`)

- `/` serves static files, falls back to `@bun` → `127.0.0.1:3000`.
- `/api/` proxies with trailing-slash `proxy_pass`, so the `/api` prefix is
  **stripped** before reaching Bun.
- `include cloudflare-ip-filter.conf;` ships commented out; the allowlist is
  regenerated by `templates/cloudflare-update-ips.sh` (installed to
  `/etc/nginx`, run via root cron by the user), which only rewrites the
  config if >8 lines were fetched.

### Idempotency expectations

Re-running must be safe and never clobber user edits:

- `keep_existing <path>` prints `Kept existing <path>` and skips the write.
  Used for `bun-app.service`, skip-mode `index.html`, both Cloudflare
  helper files and `00-custom` MOTD. Sample app skipped if
  `/srv/app/server.ts` exists.
- The Nginx default site is kept only if it carries the marker
  `# Managed by ubuntu-bun-server-setup.` (line 1 of
  `templates/nginx-default.conf`; keep it there). Ubuntu ships a stock
  `default`, so plain skip-if-present would never install the proxy.
- `INSTANCE_ID` is read from `/etc/environment` at top level (first match)
  and reused; `write_instance_id` deletes every `INSTANCE_ID=` line and
  appends one.
- `disable_stock_motd` diverts `00-header` and `10-help-text` to
  `/var/lib/bun-installer/motd-disabled/` (`dpkg-divert --no-rename` + `mv`:
  `--rename` warns on Essential `base-files`). They are conffiles, so a
  plain `chmod -x` survives a reinstall, likely not an upstream change.
- `application.info` is rewritten every run; UFW is `--force reset` every
  run; `bun-app` user and `/srv/app/data` only created if absent.
- Consequence: template improvements reach new installs only.

## Tests (`tests/docker/`)

- `run.sh` builds an Ubuntu systemd image (`UBUNTU_VERSION`, default
  `22.04`, passed as a build arg and used as the image tag), starts one
  privileged container per test with the repo mounted read-only at
  `/workspace`, and runs `tests/docker/scripts/<test>.sh` inside it.
- Scenarios: `test_root_guard` (non-root fails), `test_default` (full
  install, `curl` expects `"Hello Bun"` and `/api/` → `"Welcome to Bun"`,
  service runs as `bun-app`, code read-only, state dir writable),
  `test_skip_sample` (`SKIP_BUN_APP=1`, expects `"Hello World"`, no
  `bun-app` user, stock site kept, re-run keeps a custom `index.html`),
  `test_idempotent` (`SKIP_BUN_APP=yes` rejected, `=0` installs, edits
  survive a re-run, one stable `INSTANCE_ID`, MOTD diversions survive a
  `base-files` reinstall), `test_piped_install` (`bash -s -- SKIP_BUN_APP=1
  <install.sh`, remote templates from `main`, unknown-arg rejection),
  `test_fail_loudly` (broken `nginx-default.conf` in a copy of the repo
  exits non-zero with the trap message, no colour escapes off-TTY).
- Gotcha: files a test writes under `/tmp` during an install were gone by
  assert time; `test_piped_install` keeps its files under `/root`.
- Adding a test: create `scripts/test_x.sh` sourcing `common.sh`
  (`run_installer`, `assert_*` helpers), with a `# Test: <label>` line
  right after the shebang. `run.sh` discovers every `scripts/test_*.sh`;
  the label falls back to the file name.
- Override image name (used verbatim, no version tag) with
  `BUN_INSTALLER_TEST_IMAGE`.

## CI (`.github/`)

- `ci.yml`: on every PR and push to `main`, runs `make lint`,
  `make format-check` and `make lint-actions`. Tools are sha256-verified
  release binaries; versions and hashes live in the job's `env:` and are
  bumped by hand (keep them in step with the Docker overrides above).
- `e2e.yml`: `make test` on a 22.04/24.04 matrix; skipped when a change
  touches only `**.md`, `LICENSE` or `.vscode/**`.
- Both cancel superseded PR runs. Runners are pinned to `ubuntu-24.04`.
- Actions are pinned to commit SHAs with a `# vX.Y.Z` comment;
  `dependabot.yml` bumps those weekly, but not the tool versions or
  `changelogithub`.

## Release

- `VERSION` file holds SemVer. `./release.sh [patch|minor|major|X.Y.Z]`
  (default: interactive, patch) bumps it, commits `release: vX.Y.Z`, tags
  `vX.Y.Z`, and **pushes the current branch and tag immediately**.
- Run from `main` only: `.github/workflows/release.yml` fails if the tag is
  not an ancestor of `origin/main`; it then generates notes via
  `changelogithub` (pinned in the workflow).
- `make release` has no args; it just runs `./release.sh` (interactive).

## Conventions

- Scripts: `#!/usr/bin/env bash`, `set -euo pipefail` (`-E` in
  `install.sh`), one function per install step with a leading comment,
  `local` vars, colored output via `GREEN`/`YELLOW`/`RED`/`NC`.
- Commit prefixes seen in history: `fix(scope):`, `refactor:`, `ci:`,
  `release:`.
- `.claude/plans/` (plan links and completed copies) and `drafts/` hold
  local working notes; don't commit them.
