# The ruby port.
#
# EVERY PORT DEFINES ALL FOUR of test, build, inspect and clean (see the
# top-level Makefile). Ruby has nothing to compile, so `build` is a
# SYNTAX CHECK of every file — the nearest thing to "does this parse",
# and not a no-op, because a syntax error in a file no test happens to
# require would otherwise ship.

RUBY ?= ruby

.PHONY: test build inspect clean

test:
	$(RUBY) -Ilib -Itest test/run.rb

build:
	@for f in lib/voxgig_plugin/*.rb lib/*.rb test/*.rb; do \
	  $(RUBY) -c "$$f" >/dev/null || exit 1; \
	done
	@echo "ruby: $$(ls lib/voxgig_plugin/*.rb lib/*.rb test/*.rb | wc -l) files parse"

inspect:
	@$(RUBY) --version

clean:
