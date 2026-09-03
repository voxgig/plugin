# The lean port.
#
# EVERY PORT DEFINES ALL FOUR of test, build, inspect and clean (see the
# top-level Makefile).
#
# `build` IS A REAL GATE ONLY BECAUSE THE LAKEFILE MAKES IT ONE. Lake
# builds what a target's import graph reaches and nothing else, so a
# module no target imports reports no errors because it is never
# compiled — fifteen modules in this port sat "green" that way while
# every one of them had a syntax error. `lakefile.lean` names both
# libraries `@[default_target]` and lists every module in `roots`, and
# `src/Plugin.lean` imports the lot. Do not remove either.
#
# NO DEPENDENCIES: the lakefile declares no `require`, so `lake build`
# never touches the network. §16 permits one runtime dependency
# (voxgig/struct) and Lean has no port of it, so src/Plugin/Value.lean
# parses the corpus.

LAKE ?= lake
BIN = .lake/build/bin/run

.PHONY: test build inspect clean

test: build
	@$(BIN)

build:
	@$(LAKE) build 2>&1 | grep -v '^info:' || true
	@test -x $(BIN) || (echo "lean: build produced no binary" && exit 1)
	@echo "lean: $$(ls src/Plugin/*.lean test/*.lean | wc -l) modules compile"

inspect:
	@lean --version | head -1

clean:
	@rm -rf .lake/build
