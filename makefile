SHELLCHECK ?= shellcheck
SHELLCHECK_FLAGS ?= -x

SHFMT ?= shfmt
SHFMT_FLAGS ?= -w -i 2 -bn -ci

SHELL_FILES = install.sh

.PHONY: lint format

lint:
	$(SHELLCHECK) $(SHELLCHECK_FLAGS) $(SHELL_FILES)

format:
	$(SHFMT) $(SHFMT_FLAGS) $(SHELL_FILES)
