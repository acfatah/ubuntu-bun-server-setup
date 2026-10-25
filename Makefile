SHELLCHECK ?= shellcheck
SHELLCHECK_FLAGS ?=

SHFMT ?= shfmt

ACTIONLINT ?= actionlint

BATS ?= bats

SHELL_FILES = install.sh release.sh build-installer.sh \
	$(wildcard tests/docker/*.sh tests/docker/scripts/*.sh tests/release/*.sh templates/*.sh tests/unit/*.bats)
TEST_RUNNER = tests/docker/run.sh

.PHONY: lint lint-actions format format-check test test-unit test-release dist release

lint:
	$(SHELLCHECK) $(SHELLCHECK_FLAGS) $(SHELL_FILES)

# Workflow YAML; uses shellcheck from PATH for run: blocks
lint-actions:
	$(ACTIONLINT)

format:
	$(SHFMT) -w $(SHELL_FILES)

format-check:
	$(SHFMT) -d $(SHELL_FILES)

test:
	$(TEST_RUNNER)

# bats unit tests: pure functions and motd.sh; no Docker, no root
test-unit:
	$(BATS) tests/unit

# release.sh against a throwaway repo; needs only git
test-release:
	tests/release/run.sh

# Pinned release installer in dist/; VERSION defaults to the VERSION file
VERSION ?= $(shell cat VERSION)
dist:
	./build-installer.sh $(VERSION)

# Release target
release:
	./release.sh
