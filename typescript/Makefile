# All four targets, per AGENTS.md §2 — none is optional, because
# "tolerantly invoked" and "silently swallows a compiler error" are the
# same `||`.
.PHONY: build test clean inspect

build:
	npm install --no-audit --no-fund --silent
	npm run build

test: build
	npm test

clean:
	rm -rf dist dist-test node_modules

inspect:
	@node --version
	@npx tsc --version
