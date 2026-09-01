# The rust port.
#
# EVERY PORT DEFINES ALL FOUR of test, build, inspect and clean (see the
# top-level Makefile). Unlike the interpreted ports, `build` here is a real
# compile - `cargo build` on the library alone, so a type error in a file
# no test happens to exercise still fails.
#
# `--offline` throughout: the crate has NO DEPENDENCIES (§16), so a network
# fetch would mean something had silently acquired one.

CARGO ?= cargo

.PHONY: test build inspect clean

test:
	$(CARGO) test --offline --quiet -- --nocapture

build:
	$(CARGO) build --offline --quiet
	@echo "rust: library builds"

inspect:
	@$(CARGO) --version

clean:
	@$(CARGO) clean --offline --quiet 2>/dev/null || true
