SHELLCHECK ?= shellcheck
SHELLCHECK_FLAGS ?=

SHFMT ?= shfmt

SHELL_FILES = install.sh release.sh \
	$(wildcard tests/docker/*.sh tests/docker/scripts/*.sh templates/*.sh)
TEST_RUNNER = tests/docker/run.sh

.PHONY: lint format format-check test release

lint:
	$(SHELLCHECK) $(SHELLCHECK_FLAGS) $(SHELL_FILES)

format:
	$(SHFMT) -w $(SHELL_FILES)

format-check:
	$(SHFMT) -d $(SHELL_FILES)

test:
	$(TEST_RUNNER)

# Release target
release:
	./release.sh
