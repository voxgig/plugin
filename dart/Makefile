# The dart port.
#
# EVERY PORT DEFINES ALL FOUR of test, build, inspect and clean (see the
# top-level Makefile). `build` is `dart analyze`, which is the real compile
# check: dart's analyser is the front end its compilers use, and with the
# repo's `analysis_options.yaml` an unused variable, an unreachable branch
# or a nullable value used where a non-null one is required is an ERROR
# rather than a note.
#
# NO PUBSPEC DEPENDENCIES, and no pubspec at all. Section 16 permits one
# runtime dependency and dart has no port of it; `dart:convert` and
# `dart:io` are the SDK's own libraries, not packages, so JSON parsing costs
# nothing and the suite is a plain script rather than `package:test`.
# Imports are relative for the same reason - a `package:` import would need
# a pubspec and a `dart pub get`, which is a dependency step for a library
# that has no dependencies.

DART ?= dart

.PHONY: test build inspect clean

test:
	@$(DART) run test/run.dart

build:
	@$(DART) analyze lib test
	@echo "dart: $$(ls lib/*.dart test/*.dart | wc -l) files analyze clean"

inspect:
	@$(DART) --version

clean:
	@rm -rf .dart_tool
