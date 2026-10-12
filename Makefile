SHELLCHECK ?= shellcheck
SHELLCHECK_FLAGS ?=

SHFMT ?= shfmt

ACTIONLINT ?= actionlint

SHELL_FILES = install.sh release.sh \
	$(wildcard tests/docker/*.sh tests/docker/scripts/*.sh templates/*.sh)
TEST_RUNNER = tests/docker/run.sh

.PHONY: lint lint-actions format format-check test release

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

# Release target
release:
	./release.sh
