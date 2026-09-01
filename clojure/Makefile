# The clojure port.
#
# EVERY PORT DEFINES ALL FOUR of test, build, inspect and clean (see the
# top-level Makefile). Clojure is late-bound, so "it loaded" is the only
# compile-time claim available - and it is worth making, because loading a
# namespace macroexpands and compiles every form in it. `build` loads all
# seventeen with reflection warnings turned into failures; test/build.clj
# says why that is the check worth running.
#
# NO deps.edn AND NO leiningen. Section 16 permits one runtime dependency
# and clojure has no port of it, so the JSON parser is
# src/voxgig/plugin/json.clj and the suite is a plain script rather than
# clojure.test. The debian `clojure` launcher takes `-cp`; that is the
# whole build system this port needs.

CLOJURE ?= clojure

.PHONY: test build inspect clean

test:
	@$(CLOJURE) -cp src:test test/run.clj

build:
	@$(CLOJURE) -cp src:test test/build.clj

inspect:
	@$(CLOJURE) -e '(println "clojure" (clojure-version) "on java" (System/getProperty "java.version"))'

clean:
	@rm -rf build
