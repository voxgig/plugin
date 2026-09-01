# AGENTS.md — the clojure port

Read [`../AGENTS.md`](../AGENTS.md) first. The prime directives there are
not negotiable here: **TypeScript is canonical**, **the corpus is the
contract**, **change canonical first then propagate**, and **never weaken
the corpus to make this port pass**.

## The rule that matters most here

**A disagreement with the corpus is this port's bug — until you have
established it is the canonical's.** Both happen;
[`../doc/plan/handover.md`](../doc/plan/handover.md) §13 has the running
list.

## Clojure-specific traps

**`swap!` RETRIES its function.** So no callback, no `t/fail`, and nothing
with a side effect may run inside one. Every function in `host.clj`
computes outside the atom and writes with a short, pure `swap!`;
`catalog-add!` builds the new catalog first and stores the result for
exactly this reason.

**Never write back a whole snapshot.** A callback mutates the registry
while it runs, so an entry read before running one is stale afterwards.
Every internal function takes a REF and writes through `entry-update!` or
`set-field!`. Reintroducing a read-modify-write over the whole state would
silently drop whatever the callback wrote.

**`swap-vals!`, not `swap!`, when you need the OLD value.** `scope-push!`,
`scope-release!` and `unwind!` all need what was there before the write —
reading the atom and then writing is two operations and the wrong shape.

**Keys are STRINGS.** Corpus data is JSON and stays JSON; `t/get`, `t/has?`
and `t/sorted-keys` are the accessors. Internal shapes that are never
corpus values use keyword keys and say so in their docstring — `Order`'s
`{:ref :pos :order}`, `Point`'s bindings, `Export`'s `{:ref :key :value}`,
`Depend`'s nodes. `Capability`'s candidates are string-keyed, because
`provides` is corpus data.

**`clojure.core/Inst` is a protocol.** `(deftype Inst ...)` fails with a
`ClassCastException` that names neither. The type is `Instance`.
`host.clj` excludes `list`, `load`, `apply` and `declare` from
`clojure.core` so the host verbs keep their cross-port names; use
`clojure.core/declare` explicitly for forward declarations there.

**`keys` on a map past eight entries is HASH ORDER.** Every walk of a map
goes through `t/sorted-keys`, and every walk of the registry through
`refs`. Not tidiness: a mutation that reverses `t/sorted-keys` fails
`order/order/pinorder#two-names`.

**Bindings are arity two, `(next arg)`, hook and chain alike.** `next` is
nil for a hook. One arity means `Point` does not have to know which kind of
point it is holding — and the kind is the HOST's property.

**Clojure has no tail-call elimination.** `dependency-cycle` is an
iterative DFS with an explicit stack, as in every other port; `recur`
cannot express its two-way branch.

What clojure gives free: `{}` is not `[]`; `contains?` separates an
authored null from absence with no sentinel; `(= true 1)` and `(= "1" 1)`
are both false, so `match` needs no type guard; `sort-by` is stable;
`re-matches` requires a whole-input match, so the ref grammar's anchors are
belt-and-braces rather than the load-bearing thing they are in ruby.

## What the corpus cannot currently distinguish

> **Three of the mutations listed below are no longer survivors.** Shape
> validation at catalog registration (`declare/shape`, `declare/register`),
> `providersof` comparing refs uncanonicalized (`depend/byref`,
> `depend/cycle#through-refs-noncanonical`, `graph/resolve#byref`) and a
> nested host counted as an open resource (`nest/open`) are all pinned now,
> and each mutation fails its group. Anything else in this list still
> stands. `doc/plan/handover.md` §18 has the account — including that
> closing them turned up four defects the corpus could not previously see.

Three mutations survive:

- **`Catalog/add` skipping `check-shape`.** §10.1 puts shape validation at
  REGISTRATION so a malformed shape fails once and in the same place
  everywhere, but no corpus definition carries a `shape` — so the check is
  reachable only through `resolve-options`, and every port could defer it
  and stay green. The elixir port found this independently; the register
  has it.
- **`providers-of` without `canon`** — the gap six other ports each found.
- **`nest!` counting the inner host as an open resource.** Nothing in
  `nest` asserts `open` while an inner host is live.

Three more are **non-mutations** and are recorded so nobody re-derives
them: `==` for `=` on numbers in `t/same` (the parser produces a `Long` for
every integer, so no entry compares `1` with `1.0`); `\A`/`\z` for `^`/`$`
in the ref grammar (`re-matches` anchors already); and `sort-by seq` for
`sort-by pos` in `order`, which the map's insertion order masks until the
fallback is broken too — break both and `order/order/seqtie` catches it.

None is a licence to relax the code.

## Local shape

- One namespace per §-area under `src/voxgig/plugin/`; `src/voxgig/plugin.clj`
  aliases so the canonical surface is visible in one place.
- `Host` and `Instance` are `deftype`s in ONE namespace, unlike every other
  port's two files: `Instance` calls back into the host and the host
  constructs `Instance`, clojure namespaces cannot be circular, and a
  protocol whose only purpose is to break that cycle would be machinery for
  a problem the design does not have.
- `make build` loads every namespace with `*warn-on-reflection*` on and
  fails on any output. Clojure is late-bound, so "it loaded" is the only
  compile-time claim available — and it is a real one, because loading
  macroexpands and compiles every form.

## Adding a corpus section

Add it to `subjects` in `test/run.clj`, and to `pure-sections` or
`driver-sections`. The runner fails on a *group* with no subject, and its
coverage block fails if a whole SECTION exists in the corpus and nothing
runs it. A section or group silently not run is worse than a failing one.
