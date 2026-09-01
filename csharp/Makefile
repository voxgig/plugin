# The csharp port.
#
# EVERY PORT DEFINES ALL FOUR of test, build, inspect and clean (see the
# top-level Makefile). `build` is a real compile of the library AND the
# suite, so a type error in a file no test happens to reach still fails.
#
# NO PACKAGE REFERENCES anywhere (§16), which is what lets every target run
# with `dotnet` offline: there is nothing to restore.

DOTNET ?= dotnet

# Neither is a behaviour flag: the first stops the first-run telemetry
# notice from landing in the middle of a test report, the second the logo.
export DOTNET_CLI_TELEMETRY_OPTOUT = 1
export DOTNET_NOLOGO = 1

.PHONY: test build inspect clean

test: build
	@$(DOTNET) test/bin/Debug/net8.0/Runner.dll

build:
	@$(DOTNET) build test/Runner.csproj --nologo -v q

inspect:
	@printf "dotnet %s\n" "$$($(DOTNET) --version)"

clean:
	@rm -rf src/bin src/obj test/bin test/obj
