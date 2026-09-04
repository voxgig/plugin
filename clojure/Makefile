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
# clojure.test. Nothing here is resolved or installed.
#
# TWO DIFFERENT PROGRAMS ANSWER TO `clojure`, AND THEY SHARE NO ARGUMENT
# SYNTAX. Each rejects the other's form outright, so the port has to ask
# which one it has:
#
#   debian's `clojure` package   a shell script: takes `-cp`, hands the rest
#                                to clojure.main. This is what CI installs
#                                (`apt-get install -y clojure`, ci.yml).
#   the official Clojure CLI     `-cp` reaches clojure.main as a SCRIPT PATH
#                                and dies `FileNotFoundException: -cp`, which
#                                reads as a broken suite rather than a wrong
#                                launcher. `-Scp` is worse: it REPLACES the
#                                computed classpath, clojure's own jar
#                                included, so clojure.main is then not on it
#                                at all. `-Sdeps` adds the paths and keeps
#                                the jar, which is the form that works.
#
# `-Sdescribe` exists only on the official CLI, so it is the probe. A
# contributor is more likely to have that one; CI has debian's. Both work.
CLOJURE ?= clojure

OFFICIAL := $(shell $(CLOJURE) -Sdescribe >/dev/null 2>&1 && echo yes)

ifeq ($(OFFICIAL),yes)
  CLJ_MAIN = $(CLOJURE) -Sdeps '{:paths ["src" "test"]}' -M
  CLJ_EVAL = $(CLOJURE) -M -e
else
  CLJ_MAIN = $(CLOJURE) -cp src:test
  CLJ_EVAL = $(CLOJURE) -e
endif

.PHONY: test build inspect clean

test:
	@$(CLJ_MAIN) test/run.clj

build:
	@$(CLJ_MAIN) test/build.clj

inspect:
	@$(CLJ_EVAL) '(println "clojure" (clojure-version) "on java" (System/getProperty "java.version"))'

clean:
	@rm -rf build
