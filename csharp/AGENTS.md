# AGENTS.md — the csharp port

Read [`../AGENTS.md`](../AGENTS.md) first. The prime directives there are
not negotiable here: **TypeScript is canonical**, **the corpus is the
contract**, **change canonical first then propagate**, and **never weaken
the corpus to make this port pass**.

## The rule that matters most here

**A disagreement with the corpus is this port's bug — until you have
established it is the canonical's.** Both happen;
[`../doc/plan/handover.md`](../doc/plan/handover.md) §13 has the running
list.

## Csharp-specific traps

**ORDINAL, everywhere.** `StringComparer.CurrentCulture` sorts `a, A, b,
B`; the corpus wants byte order, `A, B, a, b`. Every map is
`SortedDictionary<string,object>(StringComparer.Ordinal)` (build one with
`Types.NewMap`), every explicit sort is `Types.SortStrings` or
`string.CompareOrdinal`, and every case fold is `ToUpperInvariant` /
`ToLowerInvariant`. `config/normmap#bytewise` catches the map that decides
document order; the rest are latent, and latent is not the same as safe.

**Every number is a `double`.** Never put an `int` or a `long` into the
value model: `1.Equals(1.0)` is false and the failure reads like a logic
bug three functions away. `Types.AsInt` is the *reader* for the places that
need an integer (a band, a `$MERGE: {deep: n}`).

**`List<T>.Sort` is NOT stable.** It is an introsort. Ordering that falls
through to a `pos` or ref tie-break goes through `Types.StableSorted`.

**`TreatWarningsAsErrors` is on.** That is deliberate: the one warning this
port ever had was real. It also means `if (false)` will not compile — when
mutation testing, write a runtime-false condition instead (`"never" ==
HostRef.Phase()`), which is how four of this port's mutations had to be
spelled.

**Nothing here is `async`.** §18 makes the host settle transitions eagerly;
a `Task`-returning callback would hand the host something it is specified
not to await, and the corpus could not see the difference until a
production log did.

What csharp gives for free: a boxed `bool` and a boxed `double` are
different types with no coercion, so the type-strict `match` rule needs no
guard — unlike php, perl and lua.

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

- `Types.NewMap` with a culture comparer. A NON-mutation: an output map is
  compared key-by-key and never by order. The map that IS order-sensitive
  is `Config`'s entry map, and mutating THAT one fails
  `config/normmap#bytewise` immediately.
- `ProvidersOf` without `Refs.Canon`: no requirement in the corpus names an
  uncanonical ref.
- `Config.Pick` reading an authored null as absence: no entry writes
  `active: null`, `start: null` or `order: null` for an instance.

The last two are the same gaps php, perl, rust, java and lua each found.
None is a licence to relax the code.

## Local shape

- One class per §-area; `Plugin` forwards to them so the canonical surface
  is visible in one place.
- `Entry` is the mutable record, `Inst` the view a callback gets. A plugin
  that could reach `Status` could also write it.
- Two projects: the library and an EXE suite that references it. `make
  build` compiles both, so a type error in a file no test reaches still
  fails.

## Adding a corpus section

Dispatch it explicitly in `test/Runner.cs`. The runner fails on a *group*
with no subject, and its coverage block fails if a whole SECTION exists in
the corpus and nothing runs it. A section or group silently not run is
worse than a failing one.
