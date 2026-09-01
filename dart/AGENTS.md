# AGENTS.md — the dart port

Read [`../AGENTS.md`](../AGENTS.md) first. The prime directives there are
not negotiable here: **TypeScript is canonical**, **the corpus is the
contract**, **change canonical first then propagate**, and **never weaken
the corpus to make this port pass**.

## The rule that matters most here

**A disagreement with the corpus is this port's bug — until you have
established it is the canonical's.** Both happen;
[`../doc/plan/handover.md`](../doc/plan/handover.md) §13 has the running
list.

## Dart-specific traps

**`List.sort` IS NOT STABLE.** Not "not guaranteed" — not stable: two
hundred elements sorted by a two-valued key come back reordered. Dart uses
insertion sort below 32 elements and a dual-pivot quicksort above, so the
corpus (which never sorts more than a handful) cannot see it and a real host
can. Every sort goes through `types.stableSortBy`.

**A `Map` iterates in INSERTION order, which means nothing across runs.**
Every walk of a map goes through `types.sortedKeys`, and every walk of the
registry through `Host._refs()`. A mutation that reverses `sortedKeys` fails
`order/order/pinorder#two-names`.

**NOTHING RETURNS A `Future`.** An `async` host would make §5.2's "one at a
time, in call order" a claim about the microtask queue. If you find yourself
writing `await` in `lib/`, the design has been changed rather than ported.

**`RegExp` without `multiLine` is the correct anchor.** Dart's `$` matches
only at the end of input unless `multiLine` is on; turning it on admits
`'abc\n'` as a plugin name and `ref/name#trailing-newline` says so.

**`BigInt.parse`, not `int.parse`, for a version component.** A dart `int`
is 64-bit and wraps silently in a release build, so a forty-digit component
would pass the `componentMax` check for a value plainly out of range.

**Bindings are arity two, `(next, arg)`, hook and chain alike.** `next` is
null for a hook. One signature means `point.dart` does not have to know
which kind of point it is holding — and the kind is the HOST's property.

**`analysis_options.yaml` promotes six analyser notes to errors.** They are
notes by default, and each of them is a defect: a `?? 0` on a value that can
never be null tells the reader something untrue about the type.

What dart gives free: `Map` is not `List`; `containsKey` separates an
authored null from absence with no sentinel; `true == 1` and `'1' == 1` are
both false, so `match` needs no type guard.

## What the corpus cannot currently distinguish

Four mutations survive:

- **`stableSortBy` without its index tiebreak** — the corpus never sorts
  more than a handful of bindings, and dart's small-list insertion sort is
  stable. This is the one survivor that is a SCALE gap rather than a
  coverage gap, and the only port where it appears.
- **`Catalog.add` skipping `checkShape`.** No corpus definition carries a
  `shape`, so §10.1's "fails once, and in the same place everywhere" is
  pinned nowhere. Found independently by elixir and clojure; the register
  has it.
- **`_providersOf` without `canon`** — the gap seven other ports found.
- **`Inst.nest` counting the inner host as an open resource.**

Two more look like survivors and are not — `sortedKeys` in insertion order
and `order` sorting by `pos` — both masked by the map's own order. Reverse
`sortedKeys`, or break `order`'s fallback as well, and the corpus catches
each.

None is a licence to relax the code.

## Local shape

- One file per §-area under `lib/`; `lib/plugin.dart` is an export list so
  the canonical surface is visible in one place.
- `Entry` is the internal record and `Inst` is what a definition sees — a
  plugin that could reach `status` could also write it.
- Internal shapes are CLASSES rather than maps where they are never corpus
  values: `order.OrderNode`, `point.Binding`, `export.Exported`,
  `depend.GraphNode`. `Capability`'s candidates stay maps, because
  `provides` is corpus data.
- `make build` is `dart analyze`, which is the front end dart's compilers
  use; with `analysis_options.yaml` it is a real gate rather than advice.

## Adding a corpus section

Add it to `main` in `test/run.dart`, and to `pureSections` or
`driverSections`. The runner fails on a *group* with no subject, and its
coverage block fails if a whole SECTION exists in the corpus and nothing
runs it. A section or group silently not run is worse than a failing one.
