# The c port.
#
# EVERY PORT DEFINES ALL FOUR of test, build, inspect and clean (see the
# top-level Makefile). `build` is a real gate: -Wall -Wextra -Werror, and
# the same flags the test binary is built with, so a warning fails CI
# rather than scrolling past.
#
# NO DEPENDENCIES, not even a JSON library: §16 permits exactly one
# runtime dependency (voxgig/struct) and C has no port of it, so
# src/value.c parses the corpus. POSIX <regex.h> is libc, not a package.

CC ?= cc
CFLAGS ?= -std=c11 -Wall -Wextra -Werror -O1 -g
LDLIBS = -lm

SRC = $(wildcard src/*.c)
TESTSRC = $(wildcard test/*.c)
BIN = build/run

.PHONY: test build inspect clean

test: build
	@cd . && ./$(BIN)

build: $(BIN)

$(BIN): $(SRC) $(TESTSRC)
	@mkdir -p build
	@$(CC) $(CFLAGS) -I src -o $(BIN) $(SRC) $(TESTSRC) $(LDLIBS)
	@echo "c: $(words $(SRC) $(TESTSRC)) files compile"

inspect:
	@$(CC) --version | head -1

clean:
	@rm -rf build
