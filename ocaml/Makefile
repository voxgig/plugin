# The ocaml port.
#
# EVERY PORT DEFINES ALL FOUR of test, build, inspect and clean (see the
# top-level Makefile). `build` is a real gate: warnings are errors, so a
# shadowed name or an unused binding fails CI rather than scrolling past.
#
# NO DEPENDENCIES, not even a JSON library: §16 permits exactly one
# runtime dependency (voxgig/struct) and OCaml has no port of it, so
# src/value.ml parses the corpus. `ocamlfind`, `dune` and `opam` are all
# absent by design — this builds with the compiler alone, and links
# nothing outside the distribution.
#
# MODULE ORDER IS THE DEPENDENCY ORDER. OCaml has no separate link step
# that would sort it out, so the list below is the build graph, written
# down.

OCAMLOPT ?= ocamlopt
# -w +a-4-9-40-41-42-44-45-70 turns the useful warnings on;
# -warn-error +a makes every one of them fail the build.
OCAMLFLAGS ?= -w +a-4-9-40-41-42-44-45-70 -warn-error +a -I src -I test

MODULES = src/value.ml src/types.ml src/ref.ml src/version.ml \
          src/capability.ml src/resolve.ml src/env.ml src/config.ml \
          src/graph.ml src/order.ml src/export.ml src/depend.ml \
          src/point.ml src/defs.ml src/catalog.ml src/host.ml \
          test/corpus.ml test/driver.ml test/run.ml

BIN = build/run

.PHONY: test build inspect clean

test: build
	@./$(BIN)

build: $(BIN)

$(BIN): $(MODULES)
	@mkdir -p build
	@$(OCAMLOPT) $(OCAMLFLAGS) -o $(BIN) $(MODULES)
	@rm -f src/*.cm* src/*.o test/*.cm* test/*.o
	@echo "ocaml: $(words $(MODULES)) modules compile"

inspect:
	@$(OCAMLOPT) -version | head -1

clean:
	@rm -rf build src/*.cm* src/*.o test/*.cm* test/*.o
