# AGENTS.md — the swift port

Read [`../AGENTS.md`](../AGENTS.md) first. The prime directives there are not
negotiable here: **TypeScript is canonical**, **the corpus is the contract**,
**change canonical first then propagate**, and **never weaken the corpus to
make this port pass**.

## The rule that matters most here

**A disagreement with the corpus is this port's bug — until you have
established it is the canonical's.** Both happen;
[`../doc/plan/handover.md`](../doc/plan/handover.md) §13 has the running list.

## Swift-specific traps

**`[String: Any]` cannot hold a null.** `dict["k"] = nil` removes the key. That
is why `Value` is an enum: `.null` is a present null and a `nil` optional is an
absent key, and `Value.get` returns an optional for exactly that reason while
`Value.at` flattens the two for the many sites that treat them alike. Never
reach for `Any`.

**Nothing is `async`, and nothing is an actor.** A suspending transition would
make §5.2's "one at a time, in call order" a claim about an executor. If you
find yourself writing `await` in `src/`, the design has been changed rather
than ported.

**`Host`, `Inst` and `Entry` are classes; everything else is a value.** Those
three are the state machine, and value semantics there would mean a callback
mutating a copy nobody reads back. A `Catalog` is a class for the same reason:
the driver's §6.5 nest case adds to a live host's.

**A closure cannot mutate a captured `var`.** The idempotence flag on a release
handle is a `Flag` box for that reason — swift captures by value, and a `var`
captured by two closures would give each its own.

**`Host.instance` uses `canonRef`, not `canon`.** A lookup with a malformed ref
is `plugin_bad_name`, not a miss. Swallowing the parse is what let
`declare/lookup#malformed` pass while the port answered "no such instance" to a
ref that was never well formed.

**The driver's spec carries a null for every absent key**, as every other
port's does — so `declare` and `load` test PRESENT AND NOT NULL, never `has`.
Reading an omitted `options` as an authored empty is what `declare/clear` catches.

**No Foundation.** Not in the library and not in the suite. The ref grammar is
a character loop, string replacement is in `Env.swift`, the corpus file is read
through `Glibc`, and the ten `/re/` expectations go through `Rex` — which
**traps on any metacharacter it does not implement**, so a new corpus pattern
fails loudly rather than matching the wrong thing.

**`Types.stableSortBy` decorates with the index.** Swift's `sort` is a timsort
and stable at every size measured here, and the documentation declines to
promise it — which makes relying on it a bet on an implementation detail.

## What the corpus cannot currently distinguish

Three mutations survive, and they are exactly the three every other port also
finds: `Catalog.add` skipping `checkShape` (no corpus definition carries a
`shape`, so §10.1's "fails once, and in the same place everywhere" is pinned
nowhere), `providersOf` without `Refs.canon`, and `Inst.nest` counting the
inner host as an open resource. 21 of 24 mutations are caught.

None is a licence to relax the code.

## Local shape

- One file per §-area under `src/`; there is no facade file, because
  `import VoxgigPlugin` already names the surface and a swift module has no
  re-export to write.
- Internal shapes are STRUCTS where they are never corpus values: `OrderNode`,
  `Binding`, `Export.Exported`, `GraphNode`, `Picked`. `Capability`'s
  candidates stay `Value`, because `provides` is corpus data.
- `Definition`, `HostOptions` and `PointSpec` are structs because they hold
  closures, which the JSON enum cannot. That is the one place this port's
  public shape differs from every other's, and `README.md` says why.
- `make build` compiles the library to a real module and `.so` FIRST and then
  the suite against it. A port that only ever compiles its tests has never
  proved the library is consumable on its own.

## Adding a corpus section

Add it to `test/main.swift`, and to `pureSections` or `driverSections`. The
runner fails on a *group* with no subject, and its coverage block fails if a
whole SECTION exists in the corpus and nothing runs it. A section or group
silently not run is worse than a failing one.
