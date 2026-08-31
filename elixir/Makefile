# The elixir port.
#
# EVERY PORT DEFINES ALL FOUR of test, build, inspect and clean (see the
# top-level Makefile).
#
# NO MIX PROJECT, AND NO `deps` LIST. Section 16 permits one runtime
# dependency and elixir has no port of it, so the JSON parser is in
# lib/voxgig_plugin/json.ex and the corpus runner is a plain script rather
# than ExUnit. `elixirc` compiles the library the way mix would; what it
# does not do is invite a `mix.exs` that every embedding host inherits.
#
# --warnings-as-errors is the point of `build`: elixir warns rather than
# fails on an unused variable, a clause that can never match, or a call to
# a function that does not exist, and every one of those is a defect this
# repo would otherwise ship.

ELIXIR ?= elixir
ELIXIRC ?= elixirc

SRC = lib/voxgig_plugin.ex lib/voxgig_plugin/*.ex

.PHONY: test build inspect clean

test: build
	@$(ELIXIR) -pa build test/run.exs

build:
	@mkdir -p build
	@$(ELIXIRC) --warnings-as-errors -o build $(SRC)
	@echo "elixir: $$(ls build/*.beam | wc -l) modules compile"

inspect:
	@$(ELIXIR) --version

clean:
	@rm -rf build
