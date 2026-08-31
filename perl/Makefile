# The perl port.
#
# EVERY PORT DEFINES ALL FOUR of test, build, inspect and clean (see the
# top-level Makefile). Perl has nothing to compile, so `build` is a SYNTAX
# CHECK of every file - the nearest thing to "does this parse", and not a
# no-op, because a syntax error in a file no test happens to require would
# otherwise ship.

PERL ?= perl

.PHONY: test build inspect clean

test:
	$(PERL) -Ilib -Itest test/run.pl

build:
	@for f in lib/Voxgig/*.pm lib/Voxgig/Plugin/*.pm test/*.pm test/*.pl; do \
	  $(PERL) -Ilib -Itest -c "$$f" >/dev/null 2>&1 || \
	    { $(PERL) -Ilib -Itest -c "$$f"; exit 1; }; \
	done
	@echo "perl: $$(ls lib/Voxgig/*.pm lib/Voxgig/Plugin/*.pm test/*.pm test/*.pl | wc -l) files parse"

inspect:
	@$(PERL) -e 'printf "perl %vd\n", $$^V'

clean:
