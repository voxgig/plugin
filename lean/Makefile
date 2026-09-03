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

# `lake build | grep -v info:` MUST NOT BE THE WHOLE GATE. A pipeline
# exits with the status of its LAST command, so grep's 0 hid lake's
# failure and the stale binary from the previous build then ran the
# corpus and printed a pass. Redirect, then test lake's own status.
build:
	@$(LAKE) build > .lake-build.log 2>&1; status=$$?; \
	  grep -v '^info:' .lake-build.log; \
	  rm -f .lake-build.log; \
	  test $$status -eq 0 || (echo "lean: build failed" && exit 1)
	@test -x $(BIN) || (echo "lean: build produced no binary" && exit 1)
	@echo "lean: $$(ls src/Plugin/*.lean test/*.lean | wc -l) modules compile"

inspect:
	@lean --version | head -1

clean:
	@rm -rf .lake/build
