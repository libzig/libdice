.PHONY: build test test-dual-mode ci ci-fast ci-integration integration-coturn install coturn-up coturn-down coturn-wait

build:
	zig build -Doptimize=ReleaseFast

test:
	zig build test --summary all

test-dual-mode:
	zig build test-dual-mode-regression --summary all

ci:
	$(MAKE) ci-fast

ci-fast:
	zig build test-dual-mode-regression --summary all
	zig build test --summary all
	zig build -Doptimize=ReleaseFast

ci-integration:
	$(MAKE) integration-coturn

integration-coturn: coturn-up coturn-wait
	zig build test-coturn-integration

install: build
	install -Dm644 "./zig-out/lib/libdice.a" "$(HOME)/.local/lib/libdice.a"

coturn-up:
	bash "./scripts/coturn_up.sh"

coturn-down:
	bash "./scripts/coturn_down.sh"

coturn-wait:
	bash "./scripts/coturn_wait.sh"

# Release
# ==================================================================================================
TYPE ?= patch
HAS_REL := $(shell command -v git-rel 2>/dev/null)

release:
	@if [ -z "$(HAS_REL)" ]; then \
		echo "git-rel is not installed. Please install it first."; \
		exit 1; \
	fi
	@if [ -z "$(TYPE)" ]; then \
		echo "Release type not specified. Use 'make release TYPE=[patch|minor|major|m.m.p]'"; \
		exit 1; \
	fi
	@git rel $(TYPE)
