# The kotlin port.
#
# EVERY PORT DEFINES ALL FOUR of test, build, inspect and clean (see the
# top-level Makefile). `build` is `kotlinc -Werror`, which is the real gate:
# kotlin reports a deprecated member, an unreachable branch and an unused
# expression as WARNINGS, and every one of those is a defect this repo would
# otherwise ship.
#
# NO GRADLE, NO MAVEN, NO `dependencies` BLOCK. Section 16 permits one runtime
# dependency and kotlin has no port of it, so the JSON parser is src/Json.kt
# and the suite is a plain `main` rather than JUnit or kotlin.test. `kotlinc`
# and `java` are the whole build system - which is also why the stdlib jar is
# located from the compiler rather than fetched.

KOTLINC ?= kotlinc
JAVA ?= java

# The stdlib that ships beside the compiler, so the test run needs no
# download and no `-include-runtime` repack of a jar nothing installs.
STDLIB = $(shell dirname $$(readlink -f $$(command -v $(KOTLINC))))/../lib/kotlin-stdlib.jar

.PHONY: test build inspect clean

test: build
	@$(JAVA) -cp build:$(STDLIB) voxgig.plugin.test.Run

# The JVM this image ships prints a deprecation notice for the flags kotlinc
# passes it, on every invocation and on stderr. Filtering it through a pipe
# would take the PIPELINE's exit status and hide a compile failure, so the
# status is saved before the noise is dropped.
build:
	@mkdir -p build
	@$(KOTLINC) -Werror src/*.kt test/*.kt -d build 2>build/kotlinc.log; \
	  status=$$?; \
	  grep -v 'Xverify\|noverify' build/kotlinc.log || true; \
	  test 0 -eq $$status
	@echo "kotlin: $$(ls src/*.kt test/*.kt | wc -l) files compile"

inspect:
	@$(KOTLINC) -version 2>&1 | grep -v 'Xverify\|noverify' || true

clean:
	@rm -rf build
