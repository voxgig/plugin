# The python port.
#
# EVERY PORT DEFINES ALL FOUR of test, build, inspect and clean (see the
# top-level Makefile). Python has nothing to compile, so `build` is a
# BYTECODE COMPILE of the whole package rather than a no-op: it is the
# nearest thing to "does this parse", and `-q` makes it silent on
# success and loud on a syntax error.

PY ?= python3

.PHONY: test build inspect clean

test:
	$(PY) -m unittest discover -s test -t . -p 'test_*.py' -v

build:
	$(PY) -m compileall -q voxgig_plugin test

inspect:
	@$(PY) --version

clean:
	rm -rf voxgig_plugin/__pycache__ test/__pycache__
