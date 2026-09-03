# The haskell port.
#
# EVERY PORT DEFINES ALL FOUR of test, build, inspect and clean (see the
# top-level Makefile). `build` is a real gate: -Wall -Werror, so an
# incomplete pattern or an unused binding fails CI rather than scrolling
# past.
#
# NO DEPENDENCIES, not even a JSON library: §16 permits exactly one
# runtime dependency (voxgig/struct) and Haskell has no port of it, so
# src/Value.hs parses the corpus. NO CABAL FILE AND NO STACK PROJECT —
# `ghc --make` against the boot libraries alone, which is the only way
# to be sure nothing was pulled in.

GHC ?= ghc
GHCFLAGS ?= -Wall -Werror -O1 -isrc -itest -outputdir build/obj

BIN = build/run

.PHONY: test build inspect clean

test: build
	@./$(BIN)

build: $(BIN)

$(BIN): $(wildcard src/*.hs) $(wildcard test/*.hs)
	@mkdir -p build/obj
	@$(GHC) $(GHCFLAGS) --make test/Main.hs -o $(BIN) > /dev/null
	@echo "haskell: $(words $(wildcard src/*.hs) $(wildcard test/*.hs)) modules compile"

inspect:
	@$(GHC) --version | head -1

clean:
	@rm -rf build
