# AGENTS.md — the go port

Read [`../AGENTS.md`](../AGENTS.md) first. The prime directives there
are not negotiable here: **TypeScript is canonical**, **the corpus is
the contract**, **change canonical first then propagate**, and **never
weaken the corpus to make this port pass**.

This file is only what is specific to go.

## The rule that matters most here

**A disagreement with the corpus is this port's bug — until you have
established it is the canonical's.** Both happen. Three defects found
while writing this port were in the canonical and were fixed there;
[`../doc/plan/handover.md`](../doc/plan/handover.md) §13 says what they
were and how they had stayed invisible. But the default is that a
typed port got a JavaScript coercion rule wrong, and the burden is on
the change to show otherwise.

When it *is* the canonical: fix `typescript/`, add corpus entries that
pin the fixed reading, then propagate. In one change set. Never a local
workaround.

## Layout

- `plugin/` — the library. One file per canonical module, same names.
- `test/` — `driver.go` (DOCS.md §4's probe catalog and command
  interpreter), `corpus.go` (the runner), and one `_test.go` per group
  of sections.

`make build` is `go build` **plus `go vet`**, and `make test` runs the
whole corpus. All four Makefile targets are real; the top-level Makefile
deliberately refuses tolerant ones, because `|| true` turns a compiler
failure into a green run.

## Go-specific traps

**Map iteration is randomized.** Every traversal that produces output
goes through `sortedkeys`. A bare `for k := range m` over anything that
reaches a result is a bug that passes its own tests most of the time.
The house rule across voxgig is sorted-key order because it makes output
byte-stable, and here it is also the only way to be deterministic at
all.

**`sort.Slice` is not stable; `sort.SliceStable` is.** The canonical's
comparators fall through to a tie-break that JavaScript's stable sort
resolves by position. Use `SliceStable` wherever the canonical calls
`.sort()`.

**Absent is not nil.** `m[k]` returns the zero value for a missing key
and for a JSON `null` alike. Where the canonical tests `undefined !==
x`, use `v, ok := m[k]`. `config.go`'s `pick` exists for exactly this
and should be used rather than re-derived.

**JSON numbers are `float64`.** Anything decoded from a document or the
corpus is `float64`, never `int`. `tonumber` accepts both.

**`json.Marshal` escapes HTML by default.** `<` becomes `<`, which
breaks §12 message parity against every other port. Use `marshal` /
`compactjson` from `util.go`, which turn it off.

**Struct tags are the contract.** The corpus runner decodes entries into
typed inputs, so a field spelled differently from the corpus arrives
zero and the entry fails — which is the check a dynamic port gets for
free.

## Adding a corpus section

Dispatch it explicitly. `coverage_test.go` fails if a section exists in
the corpus and no test names it, and each section's test fails on a
*group* with no subject. A section or group silently not run is worse
than a failing one, which is why both guards exist.
