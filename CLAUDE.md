# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

## What this is

A single Bash installer (`install.sh`) that provisions an Ubuntu 22.04+ host
with Bun, Nginx, UFW, Certbot (snap), a sample Bun app under `/srv/app`, a
`bun-app` systemd unit, and a Cloudflare IP updater on a daily timer. No
application code to build; `templates/` holds the
files the installer drops onto the target host.

## Commands

```bash
make lint          # shellcheck every *.sh and tests/unit/*.bats
make format        # shfmt -w; style comes from .editorconfig
make format-check  # shfmt -d; fails on unformatted files
make lint-actions  # actionlint on .github/workflows (shellchecks run: blocks)
make test          # all Docker e2e tests (needs Docker + privileged containers)
UBUNTU_VERSION=24.04 make test            # e2e on another Ubuntu (default 22.04)
tests/docker/run.sh test_default          # single test (.sh suffix optional)
make test-unit     # bats unit tests (tests/unit): seconds, no Docker or root
make test-release  # release.sh against a throwaway repo (git + bash only)
./release.sh --dry-run minor              # every release check, no changes
make dist VERSION=1.2.3                   # pinned installer in dist/ (default: VERSION file)
./build-installer.sh 1.2.3 /tmp/out       # same, any out-dir
```

- Lint and format cover `install.sh`, `release.sh`, `build-installer.sh`,
  `tests/docker/**/*.sh`, `tests/release/*.sh`, `templates/*.sh` and
  `tests/unit/*.bats` (`SHELL_FILES` in `Makefile`; both tools detect
  bats from the shebang or extension).
- Style lives in `.editorconfig` (2-space, `-bn -ci`, for `*.sh` and
  `*.bats`); shfmt reads it only
  when no printer flags are passed. `.shellcheckrc` sets
  `external-sources=true`, so no `-x`.
- `shellcheck`, `shfmt` and `actionlint` must be on `PATH`, or pass an
  override, e.g.
  `make lint SHELLCHECK='docker run --rm -v "$PWD:/mnt:ro" -w /mnt koalaman/shellcheck:v0.10.0'`
  (`SHFMT`: `mvdan/shfmt:v3.8.0`; `ACTIONLINT`: `rhysd/actionlint:1.7.12`;
  `BATS`: `docker run --rm -v "$PWD:/code:ro" -w /code bats/bats:1.14.0`).

## Architecture

### Template resolution (`download_template` in `install.sh`)

- If `templates/<name>` exists next to the script, it is copied (cloned-repo
  or test run). Only when run from a real file: a piped run has no
  `BASH_SOURCE[0]`, so it never uses a local `templates/`.
- Otherwise it is fetched from `TEMPLATE_BASE_URL`, default
  `raw.githubusercontent.com/.../$TEMPLATE_REF/templates`;
  `TEMPLATE_REF` defaults to `INSTALLER_REF`. Both are **env only** (not
  `KEY=VALUE` args); `parse_args` rejects a `TEMPLATE_REF` outside
  `[A-Za-z0-9._/-]` or containing `..`, before the root check.
- Three lines near the top are release slots: `INSTALLER_VERSION=dev`,
  `INSTALLER_REF=main`, `TEMPLATE_SHA256=''`. The repo copy is the **dev
  channel** (templates from `main`, unverified). `build-installer.sh`
  rewrites exactly those lines (it fails unless each matches once, so
  keep them verbatim): version, `vX.Y.Z`, and `<sha>  <name>` per
  template.
- A download goes to a `mktemp` file in the destination's directory,
  is checked by `verify_template`, then `chmod 644` + `mv`; a failed
  check never replaces an existing file. Verification runs only when
  `TEMPLATE_SHA256` is set and `TEMPLATE_REF == INSTALLER_REF` (also via
  a `TEMPLATE_BASE_URL` mirror); another ref prints one warning and
  skips it. Local templates are never verified.
- `--version`/`-V` and `--help`/`-h` exit 0 before the root check;
  `print_version` also runs at the start of `main`; `start_log` writes
  the version; `application.info` records `installer_version` and
  `template_ref` (`local` when a local `templates/` exists).
- Gotcha: template edits on a branch reach curl-piped installs only once
  merged to `main` (dev channel) or released (pinned). Tests pipe with
  `TEMPLATE_BASE_URL=file:///workspace/templates` to cover them earlier.

### Placeholders

Templates contain `__NAME__` tokens (`__NGINX_ROOT__`, `__INSTANCE_ID__`,
`__BUILD_DATE__`, `__DISTRO__`, ...) substituted post-copy by
`replace_placeholder`: a literal replacement in awk, with placeholder and
value passed through `ENVIRON` (no character is special, `\` included).
The result is written back with `cat >`, so the file keeps its inode,
mode and owner. Adding
a token means editing both the template and the matching
`replace_placeholder` call. `__INSTANCE_ID__` lives in
`templates/bun-app.env`, not in the unit. `__INSTALLER_VERSION__` and
`__TEMPLATE_REF__` are in `templates/application.info`.

### Install flow (`main`)

Top level: `parse_args` → root check → `start_log` → `main 2>&1 | tee -a
/var/log/bun-installer.log` (`pipefail` carries `main`'s status). It runs
only when `${BASH_SOURCE[0]:-$0} == $0`: true when executed or piped (no
`BASH_SOURCE`), false when sourced, so unit tests can source the script.
Sourcing still runs the top-level assignments (`INSTANCE_ID` read,
colours) and `set -Eeuo pipefail`.

`main`: ERR trap → Ubuntu 22.04+ check (`OS_RELEASE`) → `apt-get upgrade` (`full-upgrade` with
`FULL_UPGRADE=1`) → base packages → UFW rules (no reset) → Certbot snap → Bun (`BUN_INSTALL=/usr/local` →
`/usr/local/bin/bun`) → `bun-app` system user → sample app →
`install_cloudflare` (updater, units, first fetch, `conf.d`, timer; first
in `configure_nginx`, so its `nginx -t` sees the old site) → Nginx config →
`nginx -t` → restart → systemd unit +
`/etc/bun-app.env` + `/srv/app/data` symlink → `/var/lib/app-info/application.info` → `INSTANCE_ID` line
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
- `EnvironmentFile=-/etc/bun-app.env` (`INSTANCE_ID`, `PORT`; root `0600`,
  written by `write_app_env`) replaces a placeholder in the unit. The unit
  waits for `network-online.target`.
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

### Toggles (`SKIP_BUN_APP`, `SKIP_CLOUDFLARE`, `FULL_UPGRADE`)

- Set as env var or `KEY=VALUE` arg (`parse_args`, allowlisted; unknown
  args exit 1 before the root check).
- Only **`1`** enables; checks go through `skip_app` / `skip_cloudflare` /
  `full_upgrade`. `parse_args` accepts empty, `0`, `false` (off) and `1`
  for all three; any
  other value exits 1 with `Invalid <NAME>=<value>` before the root check.
  Adding a toggle means extending both loops in `parse_args` and `USAGE`.
- `FULL_UPGRADE=1` swaps `apt-get upgrade` for `full-upgrade`. The summary
  prints a reboot hint when `/var/run/reboot-required` exists (a note, not
  a problem: the return value is unchanged).

### `SKIP_BUN_APP` mode

- `NGINX_ROOT` is chosen in `parse_args`, not at top level, so the arg form
  takes effect.
- Changes `NGINX_ROOT` from `/var/www/app/dist` to `/var/www/html`.
- Skips sample app, systemd unit, **and** `nginx-default.conf`: Ubuntu's
  stock default site is left in place; only `index.html` is written, and
  only if absent.
- Cloudflare support installs in both modes; in skip mode only real-IP
  applies (the stock site has no `cloudflare-only.conf` include) and the
  installer prints a note. The proxy snippet and map file are app mode
  only.

### Nginx (`templates/nginx-default.conf`)

- `templates/server.ts` binds `127.0.0.1` and reads `PORT` (default 3000);
  only Nginx reaches it.

- `/` serves static files, falls back to `@bun` → `127.0.0.1:3000`.
- `/api/` and `@bun` both `include snippets/bun-proxy.conf`
  (`templates/nginx-bun-proxy.conf`): `proxy_pass` has no URI, so the
  `/api` prefix is **kept**. Port 3000 is hardcoded there; it must match
  `PORT` in `/etc/bun-app.env`.
- `Connection` comes from a map in `conf.d/bun-connection-upgrade.conf`
  (`templates/nginx-connection-upgrade.conf`); the variable is
  `$bun_connection_upgrade`, unique so a user's own `$connection_upgrade`
  map can't collide. Both files are written by `write_nginx_proxy_files`
  before the site, so `nginx -t` sees them.
- Security headers are `add_header ... always` at server level. Never add
  an `add_header` inside a location (e.g. `/assets/`): it drops every
  inherited header. `/assets/` gets its one `Cache-Control` from `expires`.
- `#include snippets/cloudflare-only.conf;` ships commented out (see
  Cloudflare below).

### Cloudflare (`install_cloudflare`, skipped with `SKIP_CLOUDFLARE=1`)

- Updater `templates/cloudflare-update-ips.sh` →
  `/usr/local/sbin/cloudflare-update-ips`, run daily by
  `cloudflare-update-ips.{service,timer}` (`RandomizedDelaySec=1h`,
  `Persistent=true`).
- It writes the **generated** `/etc/nginx/cloudflare/real-ip.conf`
  (`set_real_ip_from` + `real_ip_header CF-Connecting-IP`) and
  `edge-ips.conf` (`<cidr> 1;`). Never `keep_existing`; the installer runs
  the updater only when either file is missing, with `--no-reload` (it
  restarts Nginx itself). A failed first fetch fails the install.
- Every line must match a strict CIDR regex, both families non-empty,
  >= 8 in total; else the whole fetch is rejected. Gotcha: Nginx resolves
  hostnames in `set_real_ip_from`, so never loosen the regex.
- Swap by rename, then `nginx -t`; on failure the old files are restored
  (removed on a first run). `cmp` on both files: no change → no reload.
  `flock -n` on `/run/lock/cloudflare-update-ips.lock`. Errors go to stderr
  (journal). `CLOUDFLARE_IPS_SOURCE=<dir>` reads `<dir>/ips-v4`/`ips-v6`
  instead of fetching (tests, mirrors).
- **Kept** (`keep_existing`): updater, both units,
  `conf.d/bun-cloudflare.conf` (`templates/nginx-cloudflare.conf`: includes
  `real-ip.conf`; `geo $realip_remote_addr $bun_cloudflare_edge` includes
  `edge-ips.conf`) and `snippets/cloudflare-only.conf`
  (`templates/nginx-cloudflare-only.conf`: 403 when
  `$bun_cloudflare_edge = 0`).
- The geo keys on `$realip_remote_addr` (the peer before the real-IP swap);
  `$remote_addr` would be the visitor.
- `old_cloudflare_filter_active`: while any Nginx config includes the old
  `cloudflare-ip-filter.conf` (`allow ...; deny all;`), `bun-cloudflare.conf`
  is not written: with real IP on, `deny all` would block every visitor.
  Old files (`/etc/nginx/cloudflare-update-ips.sh`, the filter, cron) are
  never touched.

### Idempotency expectations

Re-running must be safe and never clobber user edits:

- `keep_existing <path>` prints `Kept existing <path>` and skips the write.
  Used for `bun-app.service`, `/etc/bun-app.env`, the Nginx proxy snippet
  and map file, skip-mode `index.html`, the Cloudflare updater, units,
  `conf.d` file and snippet, and `00-custom` MOTD. Sample app skipped if
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
- `application.info` is rewritten every run; `bun-app` user and
  `/srv/app/data` only created if absent.
- UFW is never reset. Default policy is set only while `ufw status` is
  `inactive`; rules are re-added (an existing one is skipped, exit 0) and
  none removed. `ssh_ports` limits every `port` from `sshd -T` (creates
  `/run/sshd` first: socket-activated 24.04 hosts lack it), falling back
  to 22 with a notice.
- Consequence: template improvements reach new installs only.

## Tests (`tests/docker/`)

- `run.sh` builds an Ubuntu systemd image (`UBUNTU_VERSION`, default
  `22.04`, passed as a build arg and used as the image tag), starts one
  privileged container per test with the repo mounted read-only at
  `/workspace`, and runs `tests/docker/scripts/<test>.sh` inside it.
- Scenarios: `test_root_guard` (non-root fails), `test_default` (full
  install, `curl` expects `"Hello Bun"` and `/api/x` → `"path":"/api/x"`,
  security headers, one `Cache-Control` on `/assets/`, env file `600` and
  in the process environ, `Connection: upgrade` only on upgrade requests
  (a `bun -e` probe replaces `bun-app` at the end), service runs as
  `bun-app`, code read-only, state dir writable, Bun only
  on `127.0.0.1:3000`, `22/tcp` limited without sshd),
  `test_skip_sample` (`SKIP_BUN_APP=1`, expects `"Hello World"`, no
  `bun-app` user, stock site kept, no snippet or map file, Cloudflare
  `conf.d` present and real-IP-only note, re-run keeps a custom `index.html`),
  `test_idempotent` (`SKIP_BUN_APP=yes` rejected, `=0` installs, edits
  survive a re-run (unit, env file, site, snippet, map, Cloudflare updater,
  units, `conf.d` file and snippet, MOTD), one stable `INSTANCE_ID` in `/etc/environment`, the env file and
  the process, MOTD diversions survive a
  `base-files` reinstall), `test_piped_install` (`bash -s -- SKIP_BUN_APP=1
  <install.sh` with `TEMPLATE_BASE_URL=file:///workspace/templates`;
  Cloudflare updater and `conf.d` installed; unknown-arg and
  `TEMPLATE_REF=../x` rejection; `--version` names the ref; `--help` as
  non-root),
  `test_release_build` (`build-installer.sh 9.9.9 /root/...`;
  `SHA256SUMS` and `--version`; pinned piped install verifies `file://`
  templates; a tampered `application.info` fails the re-run, old file
  byte-identical, no temp file left; `TEMPLATE_REF=main` warns and skips
  verification),
  `test_fail_loudly` (broken `nginx-default.conf` in a copy of the repo
  exits non-zero with the trap message, no colour escapes off-TTY; then a
  faked 20.04 `/etc/os-release` is refused before `Upgrading packages`),
  `test_host_safety` (`FULL_UPGRADE=yes` rejected, openssh-server on port
  2222 → `2222/tcp` limited and no `22/tcp`; extra rule and `allow`
  incoming policy survive a `FULL_UPGRADE=1` re-run; reboot hint),
  `test_cloudflare` (`SKIP_CLOUDFLARE=yes` rejected; files, enabled timer,
  geo in `nginx -T`; stubbed `CLOUDFLARE_IPS_SOURCE`: HTML body, junk
  line, short list, empty family and an `nginx -t` failure all exit
  non-zero with the lists byte-identical; good stub applies, repeat says
  `unchanged`; access log shows `CF-Connecting-IP`; the include gives 200
  from an edge, 403 otherwise; re-run under an active old filter skips
  `conf.d`).
- Gotcha: files a test writes under `/tmp` during an install were gone by
  assert time; `test_piped_install` keeps its files under `/root`.
- Adding a test: create `scripts/test_x.sh` sourcing `common.sh`
  (`run_installer`, `assert_*` helpers), with a `# Test: <label>` line
  right after the shebang. `run.sh` discovers every `scripts/test_*.sh`;
  the label falls back to the file name.
- Override image name (used verbatim, no version tag) with
  `BUN_INSTALLER_TEST_IMAGE`.

### Unit tests (`tests/unit/`)

- bats-core v1.14.0, plain (`run`, `[ "$status" -eq … ]`,
  `[[ $output == *…* ]]`); no bats-assert/support.
- `setup` sources `install.sh` or `release.sh`, then `set +u` (both set
  `-u`). Functions that `exit` (`parse_args`, `die`) go through `run`.
- Gotcha: a bare `! cmd` never fails a bats test (set -e ignores it);
  wrap the negation in a function, as `not_gt` in `release.bats` does.
- `install.bats`: `replace_placeholder` (`\1`, `&`, `|`, newline, empty,
  mode and inode), `parse_args` toggles as arg and env, `TEMPLATE_REF`,
  `NGINX_ROOT`, `require_ubuntu` (fake os-release via `OS_RELEASE`: below
  22.04, other distro, bad or missing `VERSION_ID`, missing file);
  sourcing runs nothing, executed and piped runs still do.
- `release.bats`: `increment_version`, `version_gt`, `validate_version`
  (leading zeros refused) and `build-installer.sh`'s version check.
- `motd.bats`: copies `templates/motd.sh`, substitutes `__NGINX_ROOT__`
  with `replace_placeholder`, runs it with `bun`/`nginx`/`hostname` stubs
  first on `PATH`.
- Runs on GNU tools (CI, host) and busybox (`bats/bats` image); keep
  both green. `tests/release/run.sh` stays plain bash: it needs `git`,
  which the `bats/bats` image lacks.

### Release script tests (`tests/release/run.sh`)

- Plain bash, no Docker: each `test_*` function gets a fresh `mktemp -d`
  with a bare `origin.git` and a clone holding copies of `release.sh`,
  `build-installer.sh`, `install.sh`, `templates/` and `VERSION=1.2.3`.
  `GIT_CONFIG_GLOBAL=/dev/null` and `GIT_CONFIG_NOSYSTEM=1` keep the
  user's git config out.
- `release` runs `<dir>/release.sh` with stdin from `/dev/null` (no
  TTY), setting `OUT` and `RC`; `CWD=` runs it from another directory.
- Tests run inside `if`, where `set -e` is off: chain assertions with
  `&&` or `|| return 1`; `fail` also sets `T_FAILED`, so a failed
  assertion mid-function still fails the test.
- A rejected push is simulated with a `pre-receive` hook in `origin.git`.

## CI (`.github/`)

- `ci.yml`: on every PR and push to `main`, runs `make lint`,
  `make format-check`, `make lint-actions`, `make test-unit` and
  `make test-release`. Tools are sha256-verified release binaries; bats
  is the `bats-core` tag source tarball, installed by its own
  `install.sh` into `$RUNNER_TEMP`. Versions and hashes live in the
  job's `env:` and are bumped by hand (keep them in step with the Docker
  overrides above).
- `e2e.yml`: `make test` on a 22.04/24.04 matrix; skipped when a change
  touches only `**.md`, `LICENSE` or `.vscode/**`.
- Both cancel superseded PR runs. Runners are pinned to `ubuntu-24.04`.
- Actions are pinned to commit SHAs with a `# vX.Y.Z` comment;
  `dependabot.yml` bumps those weekly, but not the tool versions or
  `changelogithub`.

## Release

- `VERSION` file holds SemVer. `./release.sh [-y] [-d]
  [patch|minor|major|X.Y.Z]` (no type: prompt on a TTY, patch default)
  bumps it, commits `release: vX.Y.Z`, creates the **annotated** tag
  `vX.Y.Z`, and runs `git push --atomic origin main refs/tags/vX.Y.Z`.
  `RELEASE.md` is the user-facing doc; keep the two in sync.
- `preflight` collects every problem before anything is written: on
  `RELEASE_BRANCH` (`main`), no tracked changes (staged or not; untracked
  allowed), `git fetch origin main --tags` OK and `HEAD == origin/main`
  (behind **and** ahead refused), tag absent locally and on `origin`
  (`ls-remote` exit 2), target is `X.Y.Z` without leading zeros
  (`validate_version`; `build-installer.sh` uses the same regex) and
  greater than `VERSION`, `build-installer.sh` builds
  into a `mktemp -d`. Any problem → exit 1.
- `--dry-run` runs the same checks (fetch and build included), prints
  them and the plan, exits 1 if a real run would refuse.
- `confirm` prompts `[y/N]` on a TTY; without one it exits 1 unless
  `--yes`. A rejected push prints the unwind commands, never runs them.
- Repo check is `git rev-parse` and the script `cd`s to the toplevel
  (`.git` is a file in a linked worktree). `main "$@"` runs only when
  executed, not sourced, so `tests/unit/release.bats` tests
  `increment_version`, `version_gt` and `validate_version`.
- `.github/workflows/release.yml` fails if the tag is not an ancestor of
  `origin/main`; it then generates notes via `changelogithub` (pinned in
  the workflow).
- The workflow also checks `VERSION` equals the tag without `v`, runs
  `./build-installer.sh` before `changelogithub` creates the release,
  then `gh release upload`s `dist/install.sh` and `dist/SHA256SUMS`
  (`--clobber`). README's main install URL is
  `releases/latest/download/install.sh`; assets exist from 0.5.0 on.
- `dist/` is git-ignored output of `build-installer.sh`.
- `make release` has no args; it just runs `./release.sh` (interactive).
- Tests: `tests/release/run.sh` (see Tests above).

## Conventions

- Scripts: `#!/usr/bin/env bash`, `set -euo pipefail` (`-E` in
  `install.sh`), one function per install step with a leading comment,
  `local` vars, colored output via `GREEN`/`YELLOW`/`RED`/`NC`.
- Commit prefixes seen in history: `fix(scope):`, `refactor:`, `ci:`,
  `release:`, `docs:`, `test(scope):`.
- User docs: `README.md`, `CONTRIBUTING.md`, `RELEASE.md` and
  `SECURITY.md`. Vulnerability reports go through GitHub private
  vulnerability reporting (no email); README "Security" and CONTRIBUTING
  link to `SECURITY.md`. Keep its supported-versions line (latest release
  only) true.
- `.claude/plans/` (plan links and completed copies) and `drafts/` hold
  local working notes; don't commit them.
