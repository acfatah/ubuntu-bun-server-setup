SHELLCHECK ?= shellcheck
SHELLCHECK_FLAGS ?= -x

SHFMT ?= shfmt
SHFMT_FLAGS ?= -w -i 2 -bn -ci

SHELL_FILES = install.sh
TEST_RUNNER = tests/docker/run.sh

.PHONY: lint format test release release-major release-minor release-patch

lint:
	$(SHELLCHECK) $(SHELLCHECK_FLAGS) $(SHELL_FILES)

format:
	$(SHFMT) $(SHFMT_FLAGS) $(SHELL_FILES)

test:
	$(TEST_RUNNER)

# Release targets
release: release-patch

release-major:
	./release.sh major

release-minor:
	./release.sh minor

release-patch:
	./release.sh patch
