# The lua port.
#
# EVERY PORT DEFINES ALL FOUR of test, build, inspect and clean (see the
# top-level Makefile). Lua has nothing to compile, so `build` is a SYNTAX
# CHECK of every file with `luac -p` - the nearest thing to "does this
# parse", and not a no-op, because a syntax error in a file no test happens
# to require would otherwise ship.
#
# NO LUAROCKS. Section 16 permits one runtime dependency and lua has no
# port of it, so the JSON parser is in src/plugin/json.lua.

LUA ?= lua5.4
LUAC ?= luac5.4

LUA_PATH_SET = src/?.lua;test/?.lua;;

.PHONY: test build inspect clean

test:
	@LUA_PATH="$(LUA_PATH_SET)" $(LUA) test/run.lua

build:
	@for f in src/*.lua src/plugin/*.lua test/*.lua; do \
	  $(LUAC) -p "$$f" || exit 1; \
	done
	@echo "lua: $$(ls src/*.lua src/plugin/*.lua test/*.lua | wc -l) files parse"

inspect:
	@$(LUA) -v

clean:
