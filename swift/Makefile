# The swift port.
#
# EVERY PORT DEFINES ALL FOUR of test, build, inspect and clean (see the
# top-level Makefile). `build` compiles the library to a real module and shared
# object and then the suite against it - not one big `swiftc *.swift`, because
# a port that only ever compiles its tests has never proved the library is
# consumable on its own.
#
# `-warnings-as-errors` is the gate. Swift warns rather than fails on an unused
# result, an unreachable `catch`, and a `var` that is never mutated, and every
# one of those is a defect this repo would otherwise ship.
#
# NO PACKAGE.SWIFT AND NO DEPENDENCIES. Section 16 permits one runtime
# dependency and swift has no port of it; `swiftc` is the whole build system,
# which is also what keeps `swift build` from wanting a network it does not
# need. THE LIBRARY IMPORTS FOUNDATION NOWHERE - see swift/README.md.

SWIFTC ?= swiftc
MODULE = VoxgigPlugin

.PHONY: test build inspect clean

test: build
	@LD_LIBRARY_PATH=build ./build/run

build:
	@mkdir -p build
	@$(SWIFTC) -warnings-as-errors -emit-module -emit-library \
	  -module-name $(MODULE) -o build/lib$(MODULE).so \
	  -emit-module-path build/$(MODULE).swiftmodule src/*.swift
	@$(SWIFTC) -warnings-as-errors -I build -L build -l$(MODULE) \
	  test/*.swift -o build/run
	@echo "swift: $$(ls src/*.swift test/*.swift | wc -l) files compile"

inspect:
	@$(SWIFTC) --version | head -1

clean:
	@rm -rf build
