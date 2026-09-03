# The cpp port.
#
# EVERY PORT DEFINES ALL FOUR of test, build, inspect and clean (see the
# top-level Makefile). `build` is a real gate: -Wall -Wextra -Werror, and
# the same flags the test binary is built with, so a warning fails CI
# rather than scrolling past.
#
# NO DEPENDENCIES, not even a JSON library: §16 permits exactly one
# runtime dependency (voxgig/struct) and C++ has no port of it, so
# src/value.cpp parses the corpus. <regex> is the standard library, not
# a package.

CXX ?= c++
CXXFLAGS ?= -std=c++17 -Wall -Wextra -Werror -O1 -g

SRC = $(wildcard src/*.cpp)
TESTSRC = $(wildcard test/*.cpp)
BIN = build/run

.PHONY: test build inspect clean

test: build
	@./$(BIN)

build: $(BIN)

$(BIN): $(SRC) $(TESTSRC)
	@mkdir -p build
	@$(CXX) $(CXXFLAGS) -I src -o $(BIN) $(SRC) $(TESTSRC)
	@echo "cpp: $(words $(SRC) $(TESTSRC)) files compile"

inspect:
	@$(CXX) --version | head -1

clean:
	@rm -rf build
