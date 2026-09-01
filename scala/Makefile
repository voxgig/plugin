# The scala port.
#
# EVERY PORT DEFINES ALL FOUR of test, build, inspect and clean (see the
# top-level Makefile). `build` is `scalac -Xlint -Xfatal-warnings`, which is the
# real gate: scala reports an inferred `Any`, a discarded non-Unit value, an
# unreachable case and a nullary method called with `()` as WARNINGS, and every
# one of those is a defect this repo would otherwise ship. `-Xlint` is what
# turns most of them on at all.
#
# NO SBT, NO MILL, NO `libraryDependencies`. Section 16 permits one runtime
# dependency and scala has no port of it, so the JSON parser is
# src/Json.scala and the suite is a plain `main` rather than ScalaTest or
# munit. `scalac` and `scala` are the whole build system.

SCALAC ?= scalac
SCALA ?= scala

.PHONY: test build inspect clean

test: build
	@$(SCALA) -cp build voxgig.plugin.test.Run

build:
	@mkdir -p build
	@$(SCALAC) -Xlint -Xfatal-warnings -d build src/*.scala test/*.scala
	@echo "scala: $$(ls src/*.scala test/*.scala | wc -l) files compile"

inspect:
	@$(SCALA) -version 2>&1 | grep -v 'Picked up' || true

clean:
	@rm -rf build
