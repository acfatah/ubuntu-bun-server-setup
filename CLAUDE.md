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
  override. Write `$$PWD`: make turns `$$` into `$`, while a bare `$PWD`
  becomes `$P` plus `WD` and mounts the wrong directory.
  - `make lint SHELLCHECK='docker run --rm -v "$$PWD:/mnt:ro" -w /mnt koalaman/shellcheck:v0.10.0'`
  - `make format-check SHFMT='docker run --rm -v "$$PWD:/mnt:ro" -w /mnt mvdan/shfmt:v3.8.0'`
  - `make lint-actions ACTIONLINT='docker run --rm -v "$$PWD:/repo:ro" -w /repo rhysd/actionlint:1.7.12'`
  - `make test-unit BATS='docker run --rm -v "$$PWD:/code:ro" -w /code bats/bats:1.14.0'`

## Architecture

### Template resolution (`download_template` in `install.sh`)

- If `templates/<name>` exists next to the script, it is copied (cloned-repo
  or test run). Only when run from a real file: a piped run has no
  `BASH_SOURCE[0]`, so it never uses a local `templates/`.
- Otherwise it is fetched from `TEMPLATE_BASE_URL`, default
  `raw.githubusercontent.com/.../$TEMPLATE_REF/templates`;
  `TEMPLATE_REF` defaults to `INSTALLER_REF`. Both are **env only** (not
  `KEY=VALUE` args); `parse_args` rejects a `TEMPLATE_REF` outside
  `[A-Za-z0-9._/-]` or containing `..`, and a `TEMPLATE_BASE_URL` not
  matching `^(https|file)://.+` (case-sensitive; `http://` refused on dev
  and release builds alike), before the root check and `--version`.
- Downloads go through `fetch_url <url> <out> [max-time]`: `curl -fsSL
  --proto '=https,file' --proto-redir '=https' --tlsv1.2 --retry 3
  --max-time 60` (the third arg overrides 60; the Bun zip passes 600).
  `resolve_bun_version` runs its own `curl` (`-w '%{url_effective}'`,
  same flags, https only); the Cloudflare updater keeps its own flags.
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
- `--version`/`-V` and `--help`/`-h` exit 0 before the root check
  (`--check`/`-c` too, with 0 or 1; see Health checks);
  `print_version` prints a second `templates:` line: `verified against
  embedded SHA-256 sums`, `not verified (TEMPLATE_REF differs from
  INSTALLER_REF)` or `not verified (dev channel)`, then a `bun:` line
  (see Bun below). It also runs at the start of `main`; `start_log` writes
  the version; `application.info` records `installer_version` and
  `template_ref` (`local` when a local `templates/` exists).
- Gotcha: template edits on a branch reach curl-piped installs only once
  merged to `main` (dev channel) or released (pinned). Tests pipe with
  `TEMPLATE_BASE_URL=file:///workspace/templates` to cover them earlier.

### Bun (`install_bun`)

- **Pin:** `BUN_PINNED_VERSION` and `BUN_PINNED_SHA256` (`<sha>  <zip>`
  for `bun-linux-x64.zip`, `-x64-baseline.zip`, `-aarch64.zip`) sit under
  the release slots. Plain constants, same in dev and releases, bumped by
  hand (RELEASE.md "Bumping the Bun pin"); `build-installer.sh` never
  touches them.
- **`BUN_VERSION`** (env or `KEY=VALUE` arg; default the pin):
  `check_bun_version` accepts `latest` or `^[0-9]+\.[0-9]+\.[0-9]+$`,
  else `Invalid BUN_VERSION=<v> (use X.Y.Z or latest)`, exit 1. Runs on
  the env value before the arg loop (so `--version` never prints a bad
  value) and on each `BUN_VERSION=` arg. Not part of the 0/1 toggle loops.
- **`BUN_DOWNLOAD_BASE_URL`** (env only; default
  `github.com/oven-sh/bun/releases/download`): same `^(https|file)://.+`
  check as `TEMPLATE_BASE_URL`. URLs are `<base>/bun-v<ver>/<zip>` and
  `.../SHASUMS256.txt`. `latest` always resolves on GitHub.
- **Helpers:** `bun_asset` (`uname -m`; x64 without an `avx2` flag in
  `$CPUINFO` gets `-baseline`; other arches refused), `resolve_bun_version`
  (`latest` → redirect of `releases/latest` → `bun-vX.Y.Z` tag, checked),
  `bun_expected_sha <ver> <zip> <dir>` (embedded line for the pin, else the
  release's `SHASUMS256.txt` fetched into `<dir>`; missing entry fails),
  `fetch_bun <ver> <zip> <dir>` (download, `sha256sum`, `Checksum OK:
  <zip> (embedded|SHASUMS256.txt)` on stderr, `unzip`; prints the binary
  path, runs nothing).
- **Flow:** resolve target and asset → `runuser -u nobody -- bun
  --version` equals target: `Bun <v> already installed.`, return (no
  download) → `Replacing Bun <old> with <new>...` or `Installing ...` →
  `fetch_bun` in `mktemp -d` → `mktemp /usr/local/bin/.bun.XXXXXX`,
  `install -m 755` → its `--version` must equal the target → `mv` over
  `bun` (also replaces a legacy symlink) → `ln -sfn bun bunx`. Every
  failure removes the work dir and temp file and returns 1; nothing is
  written to `/usr/local/bin` before the checksum passes.
- Gotcha: never execute from the work dir. `/tmp` is a noexec tmpfs in
  the e2e containers (and on hardened hosts), so `--version` runs on the
  temp copy in `/usr/local/bin`.
- Helpers are called as `if ! x=$(helper)`, so a failure reaches the
  cleanup (`rm -rf` of the work dir) before `return 1`; a bare failing
  `x=$(helper)` would exit on errexit and leave the temp dir. Inside that
  `if`, errexit is off in the helpers too, so they check every step.
- `print_version` adds `bun: <BUN_VERSION> (pinned <pin>, verified
  against embedded SHA-256)`, or `... verified against the release's
  SHASUMS256.txt)` when it differs. No network.
- `application_version` in `application.info` is `/usr/local/bin/bun
  --version` (not `bun` on `PATH`). `bun-app` restarts every run, so a
  replaced Bun takes effect.

### Placeholders

Templates contain `__NAME__` tokens (`__NGINX_ROOT__`, `__INSTANCE_ID__`,
`__BUILD_DATE__`, `__DISTRO__`, ...) substituted post-copy by
`replace_placeholder`: a literal replacement in awk, with placeholder and
value passed through `ENVIRON` (no character is special, `\` included).
The result is written back with `cat >`, so the file keeps its inode,
mode and owner. Adding
a token means editing both the template and the matching
`replace_placeholder` call. `__INSTANCE_ID__` lives in
`templates/bun-app.env`, not in the unit. `__INSTALLER_VERSION__`,
`__TEMPLATE_REF__` and `__UFW_STATE__` are in `templates/application.info`.

### Install flow (`main`)

Top level: `parse_args` → root check → `take_lock` → `start_log` → `main
2>&1 | tee -a /var/log/bun-installer.log` (`pipefail` carries `main`'s
status). `take_lock` holds `flock -n` on fd 9 of `LOCK_FILE`
(`/run/lock/bun-installer.lock`) for the whole run (`main` and `tee`
inherit it); a second run exits 1 before the log header. `--help`,
`--version` and `--check` exit in `parse_args`, so they take no lock. It runs
only when `${BASH_SOURCE[0]:-$0} == $0`: true when executed or piped (no
`BASH_SOURCE`), false when sourced, so unit tests can source the script.
Sourcing still runs the top-level assignments (`INSTANCE_ID` read,
colours) and `set -Eeuo pipefail`.

`main`: ERR trap → Ubuntu 22.04+ check (`OS_RELEASE`) → `apt_update` (retried) → `require_snapd` → `upgrade_packages` (`apt-get upgrade`;
`full-upgrade` with `FULL_UPGRADE=1`, none with `SKIP_UPGRADE=1`) → base packages → UFW rules (no reset; see Idempotency) → snapd (apt) + Certbot snap → Bun (pinned release zip, verified →
`/usr/local/bin/bun`; see Bun) → `bun-app` system user → sample app →
`install_cloudflare` (updater, units, first fetch, `conf.d`, timer; first
in `configure_nginx`, so its `nginx -t` sees the old site) → Nginx config →
`nginx -t` → restart → systemd unit +
`/etc/bun-app.env` + `/srv/app/data` symlink → `APP_INFO_FILE` (`/var/lib/app-info/application.info`) → `INSTANCE_ID` line
rewritten in `/etc/environment` → MOTD → `write_logrotate`
(`templates/logrotate-bun-installer` → `/etc/logrotate.d/bun-installer`,
kept; `logrotate` is in `BASE_PACKAGES`, missing from the test image) →
summary.

### Health checks (`health_problems`, `--check`)

- `health_problems <app> <certbot>` (each `1` or `0`) fills the globals
  `PROBLEMS` (messages) and `CHECKS` (what ran): `certbot_runs` when
  certbot is 1 (`certbot --version` as root via `is_root`; otherwise
  `[[ -x $CERTBOT_BIN ]]`, since the snap fails for a user with no
  writable home, e.g. `nobody` in `test_default`); `nginx` active; with app 1, `bun-app` active and, only
  when `NGINX_SITE` has a `location = /healthz` line (kept older sites
  lack it), `healthz_ok`: `curl -fsS --max-time 5 --retry 5
  --retry-connrefused --retry-delay 1 $HEALTHZ_URL` must print `ok`. The
  retry covers the restart `create_systemd_service` just did; with
  `bun-app` down Nginx answers 502 and the probe takes ~5 s to fail.
- `print_summary` calls it with this run's toggles (`skip_app`,
  `skip_certbot`).
- `-c`/`--check` in `parse_args` runs `run_check` and exits 0 or 1 (2 is
  reserved for 0013's drift report, which will extend the same flag).
  Before the root check: no lock, log, writes or downloads. `run_check`
  infers instead of reading toggles: no `APP_INFO_FILE` → `No installation
  found` (1); app when `BUN_APP_UNIT` exists; certbot when `snap list
  certbot` succeeds or `CERTBOT_BIN` exists or is a (dangling) link.
- `NGINX_SITE`, `BUN_APP_UNIT`, `CERTBOT_BIN` and `HEALTHZ_URL` are
  top-level globals so unit tests can point them at the tmpdir.

### Failure handling

- `set -Eeuo pipefail`; the ERR trap is set inside `main` (which runs in
  the pipeline subshell), so it prints
  `install failed at line N (<function>)` once.
- No `|| true` on essential steps. Each remaining one is benign and says
  why in a comment.
- `apt_update` runs `apt-get update` with `Acquire::Retries=3`, up to
  `APT_UPDATE_TRIES` (3) times, `APT_UPDATE_DELAY` (10 s) apart, logging
  each retry; the last failure returns 1 and trips the trap (reported in
  `main`). `Acquire::Retries` alone misses an InRelease
  that downloads but fails verification. `test_host_safety` uses
  `apt_update_retry` from `common.sh` for its own update.
- `require_snapd` (skipped with `SKIP_CERTBOT=1`) runs between
  `apt_update` and `upgrade_packages`: fresh indexes, nothing changed yet.
  `systemctl is-enabled snapd.service snapd.socket` printing `masked`, or
  snapd not `install ok installed` (`dpkg-query`) with no `Candidate:` in
  `apt-cache policy` (empty or `(none)`), goes to `refuse_snapd`: RED
  reason plus the two ways out (fix snapd, or `SKIP_CERTBOT=1`), `exit 1`.
  An `exit` trips no ERR trap, so no `install failed` line. No apt
  `certbot` fallback, by decision: Certbot's docs recommend the snap.
- `print_summary` runs `health_problems` (see Health checks): Certbot
  (unless `SKIP_CERTBOT=1`), `nginx`, and (unless skipped) `bun-app` and
  the `/healthz` probe; it lists problems and returns 1, which `main`
  turns into `exit 1` without tripping the trap.
- Colours are empty unless stdout is a TTY (decided before the pipe).
- A run refused by `take_lock` changes nothing, not even the log.
  Gotcha: a process forked during the run that outlives it would keep
  fd 9 and the lock; services start through `systemctl`, so none does.

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
- Limits block: `TimeoutStopSec=30`, `LimitNOFILE=65536`, commented
  `#MemoryMax=` (set in a drop-in). README "Limits" lists them. Kept units
  on existing hosts never get them (README says to use a drop-in).
- `install_bun` probes `/usr/local/bin/bun` as `nobody`
  (`runuser -u nobody`); a Bun that fails the probe (a legacy symlink into
  `/root/.bun`) is replaced like one of another version.
  Gotcha: `setpriv --reuid=nobody <bin>` falsely succeeds for binaries
  under `/root`; don't use it for permission probes.
- `create_app_user` and the data symlink are skipped with `SKIP_BUN_APP=1`.

### Toggles (`SKIP_BUN_APP`, `SKIP_CLOUDFLARE`, `FULL_UPGRADE`, `SKIP_UPGRADE`, `SKIP_CERTBOT`, `SKIP_UFW`)

- Set as env var or `KEY=VALUE` arg (`parse_args`, allowlisted; unknown
  args exit 1 before the root check).
- Only **`1`** enables; checks go through `skip_app` / `skip_cloudflare` /
  `full_upgrade` / `skip_upgrade` / `skip_certbot` / `skip_ufw`.
  `parse_args` accepts empty, `0`, `false` (off) and `1` for all six; any
  other value exits 1 with `Invalid <NAME>=<value>` before the root check.
  Adding a toggle means extending both loops in `parse_args`, `USAGE`,
  `print_help`, the header comment, the three toggle loops in
  `install.bats`, the toggle table in `docs/compatibility.md` and the
  toggle list in `SECURITY.md` "What to include".
- `FULL_UPGRADE=1` swaps `apt-get upgrade` for `full-upgrade`. The summary
  prints a reboot hint when `/var/run/reboot-required` exists (a note, not
  a problem: the return value is unchanged).
- `SKIP_UPGRADE=1` keeps `apt_update` (base packages need fresh indexes)
  and makes `upgrade_packages` print `Skipping package upgrade` and
  return. With `FULL_UPGRADE=1` too, `parse_args` exits 1 with `Invalid
  combination: ...` before the root check: no precedence rule.
- `SKIP_CERTBOT=1` skips `require_snapd` and `install_certbot` (snapd
  left `BASE_PACKAGES`; `install_certbot` apt-installs it), and the
  summary prints `Certbot skipped` instead of checking `certbot`. A later
  run without it installs both.
- `SKIP_UFW=1` leaves UFW untouched (no rule, policy or enable) and
  records `ufw="skipped"`.

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
- `location = /healthz` (`access_log off`) proxies to Bun, which answers
  `ok` (`text/plain`, `Cache-Control: no-store`) before its other routes.
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
- The service stays root (the reload goes over D-Bus to systemd) but is
  sandboxed: `ProtectSystem=strict` with `ReadWritePaths=/etc/nginx/cloudflare
  /run/lock /var/log/nginx`, `ProtectHome`, kernel/namespace protections,
  `MemoryDenyWriteExecute`, `SystemCallFilter=@system-service`,
  `CapabilityBoundingSet=CAP_DAC_OVERRIDE` (`nginx -t` opens the
  `www-data`-owned logs for writing; an empty set fails it). README
  "Cloudflare updater sandbox" lists every directive; keep them in sync.
  Exposure 9.0 → 2.2 on 22.04. Gotcha: `/root` and `/home` are hidden, so a
  `CLOUDFLARE_IPS_SOURCE` there works from a shell but not under the unit.
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
  `$bun_cloudflare_deny`).
- `$bun_cloudflare_deny` is a `map` in `bun-cloudflare.conf` on
  `"$bun_cloudflare_edge:$realip_remote_addr:$uri"`: `~^0:` → 1, except
  the exact keys `0:127.0.0.1:/healthz` and `0:::1:/healthz` → 0 (exact
  keys beat regexes). The snippet's server-level `if` runs before location
  matching, so a location alone cannot exempt `/healthz`. Loopback only,
  by decision: an open `/healthz` would bypass Cloudflare's WAF. Both
  files are kept, so older hosts keep the matching old pair.
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
  `conf.d` file and snippet, `00-custom` MOTD and the logrotate rule. Sample app skipped if
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
- `application.info` is rewritten every run (except its `ufw=` record
  steers the next run's UFW; see below); `bun-app` user and
  `/srv/app/data` only created if absent.
- UFW is never reset. Default policy is set only while `ufw status` is
  `inactive`; rules are re-added (an existing one is skipped, exit 0) and
  none removed. `ssh_ports` limits every `port` from `sshd -T` (creates
  `/run/sshd` first: socket-activated 24.04 hosts lack it), falling back
  to 22 with a notice.
- UFW is enabled only when the operator has not turned it off.
  `configure_ufw` runs before `write_application_info`, so
  `previous_ufw_state` reads the **earlier** run's `ufw=` line (empty: no
  file; `legacy`: file without the line) and sets `UFW_STATE`:
  `SKIP_UFW=1` → `skipped`, nothing touched; active → rules added,
  `enabled`; inactive with no file or `skipped` → policy, rules, enable,
  `enabled`; inactive after `enabled`, `left-disabled` or `legacy` →
  nothing touched, a note, `left-disabled`. A crashed first run writes no
  file, so its re-run still enables.
- The MOTD (`templates/motd.sh`) prints the live `ufw status`: active,
  inactive or unknown. An existing `00-custom` keeps its fixed line.
- Consequence: template improvements reach new installs only.

## Tests (`tests/docker/`)

- `run.sh` builds an Ubuntu systemd image (`UBUNTU_VERSION`, default
  `22.04`, passed as a build arg and used as the image tag), starts one
  privileged container per test with the repo mounted read-only at
  `/workspace`, waits for its boot, and runs
  `tests/docker/scripts/<test>.sh` inside it.
- It runs every selected test, even after a failure, then prints
  `N passed, M failed` and each failed label, and exits 1 if any failed.
  `run_test` returns 1 and runs under `||`, so errexit is off inside it;
  check each status explicitly there.
- Scenarios: `test_root_guard` (non-root fails), `test_default` (full
  install, `curl` expects `"Hello Bun"` and `/api/x` → `"path":"/api/x"`,
  security headers, one `Cache-Control` on `/assets/`, env file `600` and
  in the process environ, `Connection: upgrade` only on upgrade requests
  (a `bun -e` probe replaces `bun-app` at the end), service runs as
  `bun-app`, code read-only, state dir writable, Bun only
  on `127.0.0.1:3000`, `22/tcp` limited without sshd, pinned Bun version
  with `Checksum OK: ... (embedded)`, `bunx` → `bun`,
  `application_version`, `TimeoutStopUSec=30s`, `LimitNOFILE=65536`,
  `systemd-analyze verify` on both units; `/healthz` → `ok` with
  `no-store` and no access-log line, `--check` passes as `nobody`,
  `logrotate -d` passes, `systemctl stop bun-app` → `--check` exits 1
  naming `bun-app` and the probe, then restarts it),
  `test_bun_pin` (re-runs use `SKIP_UPGRADE=1 SKIP_CERTBOT=1`;
  `BUN_VERSION=yes` writes nothing; a `file:///root/bun-mirror` zip with
  one appended byte fails with no `/usr/local/bin/bun` and no `.bun.*`
  temp; a bad `SHASUMS256.txt` for 1.4.3 leaves `bun` byte-identical
  (`cmp`); 1.4.3 from GitHub replaces the pin, a default run restores it,
  a third run is `already installed` with inode and mtime unchanged;
  `latest` installs and names an `X.Y.Z`; the asset comes from sourcing
  `install.sh` and calling `bun_asset`),
  `test_skip_sample` (`SKIP_BUN_APP=1`, expects `"Hello World"`, no
  `bun-app` user, stock site kept, no snippet or map file, Cloudflare
  `conf.d` present and real-IP-only note; first run with `SKIP_UFW=1`:
  UFW inactive, no rules added, `ufw="skipped"`; and `SKIP_CERTBOT=1`:
  no snapd package, no `certbot`, skip note, `--check` OK naming none of
  `bun-app`, `healthz`, `Certbot`; re-run keeps a custom
  `index.html`, enables UFW, `ufw="enabled"`, `certbot --version`
  works and `--check` lists `Certbot runs`),
  `test_idempotent` (`SKIP_BUN_APP=yes` rejected, `=0` installs, a run
  while the test shell holds the lock exits 1 with the log and
  `/etc/environment` unchanged, edits survive a re-run (unit, env file, site, snippet, map, Cloudflare updater,
  units, `conf.d` file and snippet, MOTD, logrotate rule), one stable `INSTANCE_ID` in `/etc/environment`, the env file and
  the process, MOTD diversions survive a
  `base-files` reinstall), `test_piped_install` (`bash -s -- SKIP_BUN_APP=1
  <install.sh` with `TEMPLATE_BASE_URL=file:///workspace/templates`;
  Cloudflare updater and `conf.d` installed; unknown-arg,
  `TEMPLATE_REF=../x` and `TEMPLATE_BASE_URL=http://...` rejection, error
  files under `/root/piped-errors`; `--version` names the ref and says
  `not verified (dev channel)`; `--help` as non-root),
  `test_release_build` (`build-installer.sh 9.9.9 /root/...`;
  `SHA256SUMS` and `--version` (`verified against embedded SHA-256
  sums`, and `bun: <pin> (pinned <pin>, verified against embedded
  SHA-256)` with the pin read from the built file and equal to the
  repo's); pinned piped install verifies `file://` templates; a tampered
  `application.info` fails the re-run, old file byte-identical, no temp
  file left; `TEMPLATE_REF=main` warns, skips verification and logs
  `not verified (TEMPLATE_REF differs ...)`),
  `test_fail_loudly` (broken `nginx-default.conf` in a copy of the repo
  exits non-zero with the trap message, no colour escapes off-TTY; then
  `systemctl mask snapd.service snapd.socket` is refused with the masked
  message, no trap line and no `Upgrading packages`, and unmasked; then a
  faked 20.04 `/etc/os-release` is refused before `Upgrading packages`),
  `test_host_safety` (`FULL_UPGRADE=yes` and `SKIP_UPGRADE=1
  FULL_UPGRADE=1` rejected, the latter with no log line; openssh-server on port
  2222 → `2222/tcp` limited and no `22/tcp`; extra rule and `allow`
  incoming policy survive a `FULL_UPGRADE=1` re-run; reboot hint;
  `SKIP_UFW=yes` rejected; after `ufw disable` a third run, with
  `SKIP_UPGRADE=1`, leaves UFW inactive with a note and
  `ufw="left-disabled"`, logs `apt-get update` and no `Upgrading
  packages`),
  `test_cloudflare` (`SKIP_CLOUDFLARE=yes` rejected; files, enabled timer,
  geo in `nginx -T`; stubbed `CLOUDFLARE_IPS_SOURCE`: HTML body, junk
  line, short list, empty family and an `nginx -t` failure all exit
  non-zero with the lists byte-identical; good stub applies, repeat says
  `unchanged`; access log shows `CF-Connecting-IP`; the include gives 200
  from an edge, 403 otherwise; off the edge list, `/healthz` from
  `127.0.0.1` (and `[::1]` when `lo` has it) → 200, from the container's
  own IP → 403, `/healthz/x` → 403; through `systemctl start` with a drop-in
  `Environment=CLOUDFLARE_IPS_SOURCE=/srv/cf-stub` (not `/root`:
  `ProtectHome`), a changed list applies and logs `Nginx reloaded`, an
  `nginx -t` failure fails the unit with the lists byte-identical; the
  drop-in is removed after; re-run under an active old filter skips
  `conf.d`).
- Gotcha: files a test wrote under `/tmp` vanished. Cause (confirmed):
  `docker exec` started the test while systemd still booted, and
  `systemd-tmpfiles-setup` emptied `/tmp` under it. `run.sh` now waits
  (`wait_for_boot` polls `systemctl is-system-running` for `running` or
  `degraded`, up to `BOOT_TIMEOUT` 120 s, then lists the pending jobs) and
  `LOG_DIR` is
  `/root/bun-installer-test`; keep test files under `/root` anyway.
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
  mode and inode), `parse_args` toggles as arg and env, the
  `SKIP_UPGRADE`/`FULL_UPGRADE` conflict (args, env, mixed), `TEMPLATE_REF`,
  `TEMPLATE_BASE_URL` (`http://`, `ftp://`, `HTTPS://`, no scheme, bare
  `file:` refused; `https://` and `file:///` accepted), `fetch_url` flags
  and third-arg time cap (`curl` stubbed), `print_version` verification
  line (dev, pinned on its ref, pinned on another ref) and `bun:` line
  (pin, other version, `latest`), `BUN_VERSION` (default is the pin;
  `X.Y.Z` and `latest` accepted, `yes`, `1.4`, `v1.4.4`, `-canary`,
  trailing space refused, as arg and env, before the root check),
  `BUN_DOWNLOAD_BASE_URL`, `BUN_PINNED_SHA256` shape, `bun_asset`
  (`uname` stubbed, `CPUINFO` in the tmpdir), `bun_expected_sha` and
  `resolve_bun_version` (`stub_curl_serving` copies a body to `-o` or
  prints a `-w` URL), `NGINX_ROOT`, `require_ubuntu` (fake os-release via `OS_RELEASE`: below
  22.04, other distro, bad or missing `VERSION_ID`, missing file),
  `apt_update` retries (`apt-get` and `sleep` stubbed as functions),
  `upgrade_packages` modes (default, full, skipped: no `apt-get` call),
  `require_snapd` (`systemctl`, `dpkg-query`, `apt-cache` stubbed: skip
  calls none, installed passes, either unit masked refused, absent with
  a candidate passes, absent with `(none)` or no line refused),
  `take_lock` free and held (`LOCK_FILE` in `$BATS_TEST_TMPDIR`),
  `previous_ufw_state` and each `configure_ufw` decision (`ufw` and
  `ssh_ports` stubbed as functions, `APP_INFO_FILE` in the tmpdir);
  `health_problems` (`systemctl`, `curl`, `certbot`, `snap`, `is_root`
  stubbed by `stub_health`, root unless `AS_ROOT=0`; `NGINX_SITE` in the
  tmpdir: healthy, one problem per failure, non-root Certbot by link,
  probe flags, both flags off, no `/healthz` location → no probe), `run_check` (no info file, no unit and no certbot → Nginx only,
  unit plus dangling `CERTBOT_BIN` link → problem), `parse_args --check`
  exit codes with `LOCK_FILE` untouched, and an executed `--check` never
  reaching the root check; sourcing runs nothing, executed and piped runs
  still do.
- `release.bats`: `increment_version`, `version_gt`, `validate_version`
  (leading zeros refused) and `build-installer.sh`'s version check.
- `motd.bats`: copies `templates/motd.sh`, substitutes `__NGINX_ROOT__`
  with `replace_placeholder`, runs it with `bun`/`nginx`/`hostname`/`ufw`
  stubs first on `PATH` (UFW line: active, inactive, failing `ufw`).
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
- User docs: `README.md`, `CONTRIBUTING.md`, `RELEASE.md`, `SECURITY.md`
  and `docs/compatibility.md`. Vulnerability reports go through GitHub
  private vulnerability reporting (no email); README "Security" and
  CONTRIBUTING link to `SECURITY.md`. Keep its supported-versions line
  (latest release only) true, and in step with `docs/compatibility.md`
  "Support window".
- `docs/compatibility.md` is the 1.x promise (SemVer from 1.0.0;
  changelog = GitHub Releases). Adding a toggle, flag, exit code,
  installed path, kept file or `application.info` key means adding it to
  its "Stable surface" list; removing or renaming one, or loosening the
  re-run contract, needs a major. Dropping an EOL Ubuntu is a minor,
  announced in the notes of the minor before.
- `.claude/plans/` (plan links and completed copies) and `drafts/` hold
  local working notes; don't commit them.
