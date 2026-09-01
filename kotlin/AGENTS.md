# AGENTS.md — the kotlin port

Read [`../AGENTS.md`](../AGENTS.md) first. The prime directives there are not
negotiable here: **TypeScript is canonical**, **the corpus is the contract**,
**change canonical first then propagate**, and **never weaken the corpus to
make this port pass**.

## The rule that matters most here

**A disagreement with the corpus is this port's bug — until you have
established it is the canonical's.** Both happen;
[`../doc/plan/handover.md`](../doc/plan/handover.md) §13 has the running list.

## Kotlin-specific traps

**Every number is a `Double`, and §11.2's arithmetic needs it.** `major + 1`
at `COMPONENT_MAX` is 2147483648, which an `Int` wraps to the negative bound;
`version/range#component-max` is the entry that says so. `Version` returns
`Double` lists and parses components through `BigInteger`. Any new numeric
field goes in as a `Double` too, or `Types.same` will call it unequal to the
`Double` the parser produced for the same literal.

**`Regex.matches` requires the WHOLE input.** So the ref grammar carries no
`^`/`$` — writing them would suggest they are what rejects `"abc\n"`, and they
are not. Reaching for `containsMatchIn` is the mutation `ref/name#trailing-newline`
catches.

**Nothing is `suspend`.** A suspending transition would make §5.2's "one at a
time, in call order" a claim about a dispatcher. If you find yourself writing
`suspend` in `src/`, the design has been changed rather than ported.

**`kotlinc` here is 1.3.** SAM conversion for a kotlin functional interface
does not exist, so `Types.stableSortBy` builds a `java.util.Comparator`
explicitly; and `String.isEmpty()`/`List.reversed()` resolve to JDK default
methods the 1.3 compiler warns about, so this port writes `"" == s` and
`asReversed()`.

**Bindings are arity two, `(next, arg)`, hook and chain alike.** `next` is null
for a hook. One signature means `Point` does not have to know which kind of
point it is holding — and the kind is the HOST's property.

What kotlin gives free: `true == 1` and `"1" == 1` are both false for `Any?`,
so `match` needs no type guard; a `TreeMap` iterates sorted, so a map walk is
ordered by construction; and `sortedWith` is a documented-stable TimSort.

## What the corpus cannot currently distinguish

> **Three of the mutations listed below are no longer survivors.** Shape
> validation at catalog registration (`declare/shape`, `declare/register`),
> `providersof` comparing refs uncanonicalized (`depend/byref`,
> `depend/cycle#through-refs-noncanonical`, `graph/resolve#byref`) and a
> nested host counted as an open resource (`nest/open`) are all pinned now,
> and each mutation fails its group. Anything else in this list still
> stands. `doc/plan/handover.md` §18 has the account — including that
> closing them turned up four defects the corpus could not previously see.

Three mutations survive, all of them gaps other ports found too:

- **`Catalog.add` skipping `Config.checkShape`.** No corpus definition carries
  a `shape`, so §10.1's "fails once, and in the same place everywhere" is
  pinned nowhere. Elixir, clojure and dart found it independently; the register
  has it.
- **`providersOf` without `Refs.canon`** — the gap eight other ports found.
- **`Inst.nest` counting the inner host as an open resource.**

None is a licence to relax the code.

## Local shape

- One file per §-area under `src/`; `src/Plugin.kt` forwards so the canonical
  surface is visible in one place.
- `Entry` is the internal record and `Inst` is what a definition sees — a
  plugin that could reach `status` could also write it.
- Internal shapes are DATA CLASSES where they are never corpus values:
  `Binding`, `OrderNode`, `Export.Exported`, `GraphNode`. `Capability`'s
  candidates stay maps, because `provides` is corpus data.
- `make build` is `kotlinc -Werror`. The JVM in this image prints a deprecation
  notice on every `kotlinc` run, so the Makefile saves the exit status BEFORE
  filtering the noise — piping through `grep` would take the pipeline's status
  and hide a compile failure.

## Adding a corpus section

Add it to `main` in `test/Run.kt`, and to `PURE` or `DRIVER`. The runner fails
on a *group* with no subject, and its coverage block fails if a whole SECTION
exists in the corpus and nothing runs it. A section or group silently not run
is worse than a failing one.
