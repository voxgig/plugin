# AGENTS.md — the scala port

Read [`../AGENTS.md`](../AGENTS.md) first. The prime directives there are not
negotiable here: **TypeScript is canonical**, **the corpus is the contract**,
**change canonical first then propagate**, and **never weaken the corpus to
make this port pass**.

## The rule that matters most here

**A disagreement with the corpus is this port's bug — until you have
established it is the canonical's.** Both happen;
[`../doc/plan/handover.md`](../doc/plan/handover.md) §13 and §18 have the
running list.

## Scala-specific traps

**`match` binds tighter than `||`.** `a || b match {...}` is
`a || (b match {...})`, so a disjunction guarding a match short-circuits past
it. `Refs.checkName` carries an explicit parenthesis and says why; it compiled
silently in the wrong shape first.

**`Value` is a sealed trait, and `-Xfatal-warnings` is what makes that pay.**
Adding a case makes every non-exhaustive match an ERROR rather than a note.
Never widen a match to `case _ =>` to silence one — the whole point is being
told where the new case has to be handled.

**Nothing returns a `Future`, and nothing takes an implicit
`ExecutionContext`.** A `Future`-returning transition would make §5.2's "one at
a time, in call order" a claim about a scheduler. If you find yourself
importing `scala.concurrent` in `src/`, the design has been changed rather than
ported.

**`Host` and `Entry` are the only mutable things in the port.** Every `Value`
is immutable and every other type is a case class. Those two are the state
machine, and threading a rebuilt registry through every method would make a
callback's writes land in a copy nobody reads back.

**`Map` past four entries has no order at all.** Every walk of a map goes
through `Value.keys` (sorted) and every walk of the registry through `refs`.
Not tidiness: a mutation that returns them unsorted fails
`order/order/pinorder#two-names`.

**A version component parses through `BigInt`, and the arithmetic is
`Double`.** `major + 1` at `componentMax` is 2147483648; a forty-digit
component read straight into a `Long` would wrap past the check meant to reject
it. `version/rangebad` is the entry that says so.

**`Refs` and `Version` scan characters rather than matching a regex.** A
grammar this small is clearer as the character classes it is, and it removes
the `^`/`$`-versus-`\A`/`\z` trap three other ports document from three sides:
there is no anchor to get wrong because there is no search.

What scala gives free: `VBool(true) == VNum(1)` is impossible, so `match` needs
no type guard; `sortBy` is a documented-stable TimSort; and immutability makes
the canonical's "REFILL rather than REBIND" (§9.6) a problem this port does not
have — `Inst.options` reads the entry, so `apply` replaces the map.

## What the corpus cannot currently distinguish

> **Three of the mutations listed below are no longer survivors.** Shape
> validation at catalog registration (`declare/shape`, `declare/register`),
> `providersof` comparing refs uncanonicalized (`depend/byref`,
> `depend/cycle#through-refs-noncanonical`, `graph/resolve#byref`) and a
> nested host counted as an open resource (`nest/open`) are all pinned now,
> and each mutation fails its group. Anything else in this list still
> stands. `doc/plan/handover.md` §18 has the account — including that
> closing them turned up four defects the corpus could not previously see.

The same three every other port leaves, and none is a licence to relax the
code: `Catalog.add` skipping `Config.checkShape` (no corpus definition carries
a `shape`, so §10.1's "fails once, and in the same place everywhere" is pinned
nowhere), `providersOf` without `Refs.canon`, and `Inst.nest` counting the
inner host as an open resource. 21 of 25 mutations are caught;
`../doc/plan/handover.md` §18 records all three, and the remedy is corpus work
rather than port work.

One more looks like a survivor and is not: `Value.keys` unsorted passes only
because a `Map` of four entries or fewer iterates in insertion order. Reverse
the sort and `order/order/pinorder#two-names` fails immediately.

## Local shape

- One file per §-area under `src/`; `src/Plugin.scala` forwards so the
  canonical surface is visible in one place.
- `Entry` is the internal record and `Inst` is what a definition sees — a
  plugin that could reach `status` could also write it.
- Internal shapes are CASE CLASSES where they are never corpus values:
  `Binding`, `OrderNode`, `Export.Exported`, `GraphNode`, `Picked`.
  `Capability`'s candidates stay `Value`, because `provides` is corpus data.
- `make build` is `scalac -Xlint -Xfatal-warnings`. `-Xlint` is what turns most
  of the useful warnings on at all — an inferred `Any`, a discarded non-Unit
  value, an unreachable case.

## Adding a corpus section

Add it to `main` in `test/Run.scala`, and to `pure` or `driver`. The runner
fails on a *group* with no subject, and its coverage block fails if a whole
SECTION exists in the corpus and nothing runs it. A section or group silently
not run is worse than a failing one.
