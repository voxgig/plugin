# The php port.
#
# EVERY PORT DEFINES ALL FOUR of test, build, inspect and clean (see the
# top-level Makefile). PHP has nothing to compile, so `build` is a SYNTAX
# CHECK of every file - the nearest thing to "does this parse", and not a
# no-op, because a syntax error in a file no test happens to require would
# otherwise ship.

PHP ?= php

.PHONY: test build inspect clean

# Every notice is an error here. PHP's defaults would let an undefined
# index or a wrong-type argument warn and continue with null, which is a
# corpus failure in a different file three functions later.
test:
	$(PHP) -d error_reporting=E_ALL -d display_errors=1 test/run.php

build:
	@for f in src/*.php test/*.php; do \
	  $(PHP) -l "$$f" >/dev/null || exit 1; \
	done
	@echo "php: $$(ls src/*.php test/*.php | wc -l) files parse"

inspect:
	@$(PHP) --version | head -1

clean:
