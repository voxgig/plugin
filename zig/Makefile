# The zig port.
#
# EVERY PORT DEFINES ALL FOUR of test, build, inspect and clean (see the
# top-level Makefile). `build` is a real gate: zig has no separate
# warning switch because unused variables and unreachable code are
# COMPILE ERRORS, which is stricter than -Werror and not optional.
#
# NO DEPENDENCIES: no build.zig.zon, no package fetch, and nothing
# outside the standard library. §16 permits one runtime dependency
# (voxgig/struct) and zig has no port of it, so src/value.zig parses the
# corpus — see its header for why the reader is hand-written even though
# `std.json` would have been permitted.

ZIG ?= zig
ZIGFLAGS ?= -O ReleaseSafe --cache-dir build/cache

BIN = build/run

.PHONY: test build inspect clean

test: build
	@./$(BIN)

build: $(BIN)

$(BIN): $(wildcard src/*.zig) $(wildcard test/*.zig)
	@mkdir -p build
	@$(ZIG) build-exe run.zig $(ZIGFLAGS) -femit-bin=$(BIN)
	@echo "zig: $(words $(wildcard src/*.zig) $(wildcard test/*.zig)) modules compile"

inspect:
	@$(ZIG) version

clean:
	@rm -rf build
