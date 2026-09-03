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

**Numbers compare across their Go spellings, never across kinds.** The
model has one number type; Go has twelve. `matchvalue` normalises them
through `numval` so a host declaring `Attrs{"max": 5}` (an `int`) still
matches a corpus `match: {"max": 5}` (a `float64`). `bool` is
deliberately not numeric there, because canonical is type-strict between
KINDS: `true` never matches `1`.

**THIS PORT CLAIMS THREAD SAFETY** — one of two that do (`elixir` is
the other), per [`../docs/ADR.md`](../docs/ADR.md) ADR-2. §14's
guarantee is a per-port property rather than a repo-wide one, so a claim
here is a commitment this port keeps and not an inherited default.

**The mutex is at the door, and only there.** `Host.enter` is the single
place `h.mu` is taken; below it the unlocked bodies (`declare`, `load`,
`activate`, `deactivate`, `unload`, `ready`, `apply`, `setoptions`,
`closeall`) call each other freely, because a Go mutex is not reentrant
and `ready` walks three of them. A new public transition adds a
four-line wrapper and puts its body in a lowercase twin; calling a
PUBLIC method from inside another one self-deadlocks.

Its stated limit: §5.2 wants a transition from inside a lifecycle
callback to answer `plugin_reentrant` without blocking, and that caller
is the goroutine already holding the lock. `TryLock` plus
`intransition` separates the two as far as Go allows, and the residual
window is real — a genuinely concurrent caller arriving while a callback
runs gets `plugin_reentrant` rather than waiting, because Go exposes no
goroutine identity to tell it from the reentrant one. The corpus is
single-threaded and cannot see this either way; it is written down
because a host that needs the other answer must serialise its own calls.

**The test cache does not know about the corpus.** `spec/plugin.json`
lives outside this module, so it is not part of go's cache key: change
the corpus without changing a `.go` file and `go test` replays the
previous result, reporting `ok (cached)` for entries it never ran.
`make test` passes `-count=1` for exactly this. It is the same trap as
python's stale `__pycache__`, and it cost a batch there before it cost
one here.

**Struct tags are the contract.** The corpus runner decodes entries into
typed inputs, so a field spelled differently from the corpus arrives
zero and the entry fails — which is the check a dynamic port gets for
free.

## Adding a corpus section

Dispatch it explicitly. `coverage_test.go` fails if a section exists in
the corpus and no test names it, and each section's test fails on a
*group* with no subject. A section or group silently not run is worse
than a failing one, which is why both guards exist.
