# AGENTS.md — the python port

Read [`../AGENTS.md`](../AGENTS.md) first. The prime directives there are
not negotiable here: **TypeScript is canonical**, **the corpus is the
contract**, **change canonical first then propagate**, and **never weaken
the corpus to make this port pass**.

This file is only what is specific to python.

## The rule that matters most here

**A disagreement with the corpus is this port's bug — until you have
established it is the canonical's.** Both happen; see
[`../doc/plan/handover.md`](../doc/plan/handover.md) §13 for the six the
proving pair found and how they had stayed invisible. But the default is
that a port got a coercion rule wrong, and the burden is on the change to
show otherwise.

When it *is* the canonical: fix `typescript/`, add corpus entries that pin
the fixed reading, then propagate. In one change set. Never a local
workaround.

## Why this port is the easy one, and why that is the risk

Python raises where the canonical raises, has ordered dicts, stable sorts
and first-class closures. The translation is close to line-for-line, which
means **the differences that remain are all silent ones** — no compiler
will stop you, and the corpus is the only thing that will.

The four that bit, in order of how quietly they fail:

**`True == 1`.** A boolean and an integer compare equal. The canonical
uses `===`, and JSON gives them distinct types. `capability.matchvalue`
and the runner's `corpus.same`/`corpus.matches` each carry an explicit
`isinstance(x, bool)` guard for this, and `capability/match` now pins it.

**`isinstance(True, int)`.** Follows from the same rule and breaks range
checks: `config.check_shape` must reject `{"deep": true}` rather than
reading it as depth 1.

**Late binding in closures.** A `lambda` captures the *variable*. In
`point.compose`, `fn` and `inner` are bound into default arguments; write
it the obvious way and every layer calls the last one.

**`dict.get` collapses absent and `None`.** JavaScript distinguishes
`undefined` from `null`, and several rules turn on it — `config.pick` uses
`key in src`, and the runner carries a `MISSING` sentinel so `__UNDEF__`
and `__NULL__` stay different assertions.

## Layout

- `voxgig_plugin/` — the library. One module per canonical module, same
  names, snake_case functions (parity matching is case- and
  underscore-insensitive).
- `test/` — `driver.py` (DOCS.md §4's probe catalog and command
  interpreter), `corpus.py` (the runner), and one `test_*.py` per group of
  sections.

All four Makefile targets are real; the top-level Makefile deliberately
refuses tolerant ones. `build` is a `compileall`, which is the nearest
thing an interpreted language has to "does this compile" — and it is not a
no-op, because a syntax error in a module no test imports would otherwise
ship.

## Mutation testing needs the cache cleared

Bytecode is cached on source mtime **and size**. Restoring a mutated file
can land on the same pair, and the run then executes the *old* `.pyc` — so
a "caught" may be a mismatch artifact and a "survived" may be a run that
never saw the mutation. Delete `voxgig_plugin/__pycache__` and
`test/__pycache__` around every run whose point is that the source
changed. One batch here was invalidated by exactly this and had to be
redone.

## Adding a corpus section

Dispatch it explicitly. `test_coverage.py` fails if a section exists in
the corpus and no test names it, and each section's test fails on a
*group* with no subject. A section or group silently not run is worse than
a failing one, which is why both guards exist.
