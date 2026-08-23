# The javascript port.
#
# EVERY PORT DEFINES ALL FOUR of test, build, inspect and clean (see the
# top-level Makefile). JavaScript has nothing to compile, so `build` is a
# SYNTAX CHECK of every source and test file — the nearest thing to "does
# this parse", and not a no-op, because a syntax error in a module no
# test happens to require would otherwise ship.

.PHONY: test build inspect clean

test:
	npm test

build:
	node --check src/index.js
	@for f in src/*.js test/*.js; do node --check "$$f" || exit 1; done
	@echo "javascript: $$(ls src/*.js test/*.js | wc -l) files parse"

inspect:
	@node --version

clean:
