# The go port.
#
# EVERY PORT DEFINES ALL FOUR of test, build, inspect and clean (see the
# top-level Makefile). `build` here is `go vet` plus a compile of the
# whole module: `go build ./...` alone does not compile test files, and
# the corpus runner lives in one.

.PHONY: test build inspect clean

# -race, because `golocal_test.go` asserts §5.2's sequential transitions
# across goroutines and a data race there is the failure it exists to
# catch — silent without the detector.
test:
	go test -race ./...

build:
	go build ./...
	go vet ./...

inspect:
	@go version

# `-testcache` takes no package arguments — `go clean -testcache ./...`
# is an error, not a no-op, which is exactly the kind of target the
# top-level Makefile refuses to swallow with `|| true`.
clean:
	go clean -testcache
	go clean ./...
