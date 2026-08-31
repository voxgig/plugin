# The java port.
#
# EVERY PORT DEFINES ALL FOUR of test, build, inspect and clean (see the
# top-level Makefile). `build` here is a real compile of the library AND
# the suite, so a type error in a file no test happens to reach still
# fails.
#
# NO MAVEN, NO GRADLE, NO JUNIT. §16 permits one runtime dependency and
# java has no port of it, so this is javac and java over a source tree -
# which is also what makes `make test` work with nothing fetched.

JAVAC ?= javac
JAVA ?= java

SOURCES = $(shell find src test -name '*.java')

.PHONY: test build inspect clean

test: build
	@$(JAVA) -cp build voxgig.plugin.test.Runner

build:
	@mkdir -p build
	@$(JAVAC) -Xlint:all -d build $(SOURCES)
	@echo "java: $(words $(SOURCES)) files compile"

inspect:
	@$(JAVA) -version 2>&1 | grep -v "Picked up" | head -1

clean:
	@rm -rf build
