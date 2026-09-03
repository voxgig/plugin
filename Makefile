# Top-level Makefile for all plugin language ports.
#
# Usage:
#   make test          - run tests for every port
#   make test-go       - run tests for one port
#   make build         - build every port
#   make inspect       - show toolchain versions
#   make clean         - clean build artifacts
#   make parity        - check that every port has the canonical API
#   make probes        - check that every port implements every probe
#   make spec          - recompile spec/*.json from spec/*.aon
#   make spec-check    - fail if a committed spec/*.json is stale
#   make check         - spec-check + parity + probes + test
#
# P0 STATE: LANGS is empty. The per-port targets are wired now so that the
# first port added is built, tested and parity-checked from its first
# commit. `make test` on no ports says so and exits 0 - an empty run is a
# real result, and a green tick over nothing would be a lie.

# Every port directory. Target names are the directory names, used verbatim
# as `make -C <dir>`.
#
# EVERY PORT DEFINES ALL FOUR of test, build, inspect and clean — as a
# no-op where the language has nothing to do. Inherited drafts of this
# file invoked the last three "tolerantly", with `|| echo "(no build
# target)"`, and that unconditional `||` converts a real compiler or
# packaging failure into a successful run: a port build exiting 7 left the
# top-level `make build` exiting 0, indistinguishable from an absent
# optional target.
#
# Requiring the targets costs a two-line no-op per port and removes the
# error-swallowing branch entirely. It is free to decide now, with no
# ports written, and expensive to retrofit across twenty.
# P4 is complete; P5 is under way. P6 the rest.
LANGS = typescript go python javascript ruby php perl rust java lua csharp elixir clojure dart kotlin swift scala c cpp ocaml haskell zig lean

.PHONY: all test build inspect clean parity probes versions check spec spec-check omni-check

all: test

# ---- per-port targets ----

test-%:
	@echo "======== $* ========"
	@$(MAKE) -C $* test

build-%:
	@echo "======== $* ========"
	@$(MAKE) -C $* build

inspect-%:
	@printf "%-12s " "$*"
	@$(MAKE) -s -C $* inspect

clean-%:
	@$(MAKE) -C $* clean

# ---- aggregates ----

test:
	@if [ -z "$(LANGS)" ]; then \
	  echo "plugin: no ports"; \
	else \
	  for lang in $(LANGS); do $(MAKE) test-$$lang || exit 1; done; \
	fi

build:
	@if [ -z "$(LANGS)" ]; then \
	  echo "plugin: no ports yet"; \
	else \
	  for lang in $(LANGS); do $(MAKE) build-$$lang || exit 1; done; \
	fi

# inspect prints toolchain versions - a port that cannot report one is a
# diagnostic gap rather than a build failure, so this one stays tolerant
# and says so, instead of being tolerant by accident.
inspect:
	@if [ -z "$(LANGS)" ]; then \
	  echo "plugin: no ports yet"; \
	else \
	  for lang in $(LANGS); do $(MAKE) inspect-$$lang || echo "(inspect failed)"; done; \
	fi

clean:
	@for lang in $(LANGS); do $(MAKE) clean-$$lang || exit 1; done

# ---- contract ----

# The corpus is the contract (§16, prime directive 2). `spec` compiles the
# aontu sources; `spec-check` proves the committed JSON still matches them,
# and additionally checks each source against the spec-format shape in
# spec/def/plugin-spec.aon. Never hand-edit spec/*.json.
spec:
	@cd tools && npm install --no-audit --no-fund --silent && npm run --silent build-spec

spec-check:
	@cd tools && npm install --no-audit --no-fund --silent && npm run --silent build-spec-check && npm run --silent check-spec-shape

parity:
	@python3 tools/check_parity.py

# The probe catalog is a contract (DOCS.md §4.3), not a fixture: a
# driver section's expected `log` is written against what `noisy` does,
# so a port whose `noisy` fails at a different callback passes its own
# suite and disagrees with every other port. This checks presence;
# behaviour is what the corpus is for.
probes:
	@python3 tools/check_probes.py

# VERSION is the one version line (docs/ADR.md ADR-4): every port ships at
# it and the release tags `<port>/vX.Y.Z` say so. Most ports declare no
# version at all - for those the tag IS the version - so this checks only
# the four manifests that state one, plus their lockfiles, which `npm ci`
# and `cargo build --locked` would otherwise reject in CI.
versions:
	@python3 tools/check_versions.py

# Prove the corpus still runs under voxgig/omni's own runner (ADR-3).
#
# NOT part of `check`, and deliberately: it needs voxgig/omni checked out
# beside this repo and skips when it is not, so folding it in would put a
# check that silently passes into the gate. Run it when the corpus format
# changes. Point it elsewhere with `make omni-check OMNI=/path/to/omni`.
omni-check:
	@node tools/omni-check.js

check: spec-check parity probes versions test
