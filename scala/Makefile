# The scala port.
#
# EVERY PORT DEFINES ALL FOUR of test, build, inspect and clean (see the
# top-level Makefile). `build` turns the compiler's warnings into errors, and
# that is the real gate: scala reports an inferred `Any`, a discarded non-Unit
# value, an unreachable case and a nullary method called with `()` as
# WARNINGS, and every one of those is a defect this repo would otherwise ship.
#
# NO SBT, NO MILL, NO `libraryDependencies`. Section 16 permits one runtime
# dependency and scala has no port of it, so the JSON parser is
# src/Json.scala and the suite is a plain `main` rather than ScalaTest or
# munit. `scalac` and `scala` are the whole build system.

SCALAC ?= scalac
SCALA ?= scala

# SCALA 2 AND SCALA 3 ARE TWO COMPILERS SHARING ONE COMMAND NAME, and this port
# builds under whichever one the machine has. CI installs ubuntu's `scala`
# package (2.11.12); a checkout that also builds voxgig/struct has a scala 3 on
# PATH, because that port is scala 3 only and apt's scala 2 cannot compile it.
# So the flags and the run command are PROBED, not assumed.
#
# THE FLAGS ARE NOT COMMON GROUND. `-Xlint` is scala 2's switch for most of the
# warnings above and `-Werror` does not exist there at all. On scala 3 the same
# pair is worse than unnecessary: `-Xlint` is deprecated ("use -Wshadow",
# scheduled for removal) and `-Xfatal-warnings` is a deprecated alias for
# `-Werror` -- and A DEPRECATED OPTION IS ITSELF A WARNING, so the pair fails
# the build over its own spelling, two warnings and one error, before reading a
# line of source. `-Werror` alone is scala 3's spelling of the same gate.
SCALA_MAJOR := $(shell $(SCALAC) -version 2>&1 | sed -n 's/.*version \([0-9][0-9]*\)\..*/\1/p' | head -1)
ifeq ($(SCALA_MAJOR),3)
  WARN = -Werror
else
  WARN = -Xlint -Xfatal-warnings
endif

# NEITHER IS THE RUN COMMAND. Scala 3.5 replaced the `scala` runner with Scala
# CLI, which does not accept `-classpath <dir> <MainClass>`: every input must
# be named explicitly, and a directory of compiled classes is one. The 2.x
# runner has no `run` subcommand and the new one has no bare-main-class form,
# so the two spellings do not overlap and the launcher has to be asked which
# one it is. The scala 3 spelling here is the one voxgig/omni's scala port
# already runs under this same toolchain, long flags and all -- see its
# `scala/Makefile`.
#
# THE PROBE ASKS FOR THE CAPABILITY, NOT FOR A NAME. Matching a version banner
# was the first attempt and it is wrong twice over: the same launcher renames
# itself by the program name it is invoked as -- `scala` and `scala-cli` do
# not print the same first line -- and the scala 3 runners BEFORE 3.5 take the
# legacy form and would be misread as new by any test for "scala 3". Whether
# `run` is a subcommand is the thing the recipe actually depends on, it is one
# cheap `--help` away, and the 2.x runner answers it by looking for a class
# called `run` and exiting 1. Stdin is closed so no runner can sit in a REPL
# waiting for input with `make` blocked behind it.
SCALA_HAS_RUN := $(shell $(SCALA) run --help </dev/null >/dev/null 2>&1 && echo yes)
ifeq ($(SCALA_HAS_RUN),yes)
  RUN = $(SCALA) run --classpath build --main-class voxgig.plugin.test.Run
else
  RUN = $(SCALA) -cp build voxgig.plugin.test.Run
endif

.PHONY: test build inspect clean

test: build
	@$(RUN)

build:
	@mkdir -p build
	@$(SCALAC) $(WARN) -d build src/*.scala test/*.scala
	@echo "scala: $$(ls src/*.scala test/*.scala | wc -l) files compile"

# THE COMPILER, not the runner: the compiler is what decides whether this port
# builds, and a major version arriving unannounced is exactly the surprise this
# target exists to make visible.
inspect:
	@$(SCALAC) -version 2>&1 | grep -v 'Picked up' || true

clean:
	@rm -rf build
