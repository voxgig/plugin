# AGENTS.md — the java port

Read [`../AGENTS.md`](../AGENTS.md) first. The prime directives there are
not negotiable here: **TypeScript is canonical**, **the corpus is the
contract**, **change canonical first then propagate**, and **never weaken
the corpus to make this port pass**.

## The rule that matters most here

**A disagreement with the corpus is this port's bug — until you have
established it is the canonical's.** Both happen;
[`../doc/plan/handover.md`](../doc/plan/handover.md) §13 has the running
list.

## Java-specific traps

**Every number is a `Double`.** Not an `Integer`, not a `Long`, anywhere
in the value model — `Integer.valueOf(1).equals(Double.valueOf(1))` is
false, and one stray boxed int would fail a corpus entry with a message
that looks like a logic bug. `Types.asint` is the *reader* for the places
that need an integer (a band, a `$MERGE: {deep: n}`), and it returns null
for anything that is not an integral `Double`.

**Every map is a `TreeMap`.** `Json.parse` builds them, `Types.newmap`
builds them, and the sorted iteration order is what the status map, the
export walk and the pin application all rely on. A `HashMap` here would be
a port that passes today and reorders tomorrow.

**A method named `list` shadows a static import.** `Host` has `list()`
(the status map), so inside it `Types.list(...)` must be spelled out — the
compiler catches it, but the fix is the qualification, not a rename of the
canonical method.

**`Object.clone()` is inherited by everything**, so the deep-copy helper
is `Types.copy`. A static import of a helper named `clone` resolves to the
instance method and does not compile.

**No checked exceptions on callbacks.** `PluginException` is unchecked on
purpose (see its javadoc); adding a checked one would change every plugin
signature in every host.

**Compile with `-Xlint:all` and keep it clean.** The Makefile does. The one
warning this port ever had was real (a non-serializable field on a
serializable class) and was fixed rather than suppressed.

## What the corpus cannot currently distinguish

> **Three of the mutations listed below are no longer survivors.** Shape
> validation at catalog registration (`declare/shape`, `declare/register`),
> `providersof` comparing refs uncanonicalized (`depend/byref`,
> `depend/cycle#through-refs-noncanonical`, `graph/resolve#byref`) and a
> nested host counted as an open resource (`nest/open`) are all pinned now,
> and each mutation fails its group. Anything else in this list still
> stands. `doc/plan/handover.md` §18 has the account — including that
> closing them turned up four defects the corpus could not previously see.

Three mutations survive, and all three are gaps the php, perl and rust
ports found independently:

- `Order.band` accepting a numeric string or a boolean: no entry writes a
  band that is not already an integer.
- `providersof` without `Refs.canon`: no requirement names an uncanonical
  ref.
- `Config.pick` reading an authored `null` as absence: no entry writes
  `active: null`, `start: null` or `order: null` for an instance.

None is a licence to relax the code. If they are pinned, they are pinned in
`spec/plugin.aon` and propagated to every port.

## Local shape

- One class per §-area; `Plugin` forwards to them so the canonical surface
  is visible in one place.
- `Entry` is the mutable record, `Inst` the view a callback gets. A plugin
  that could reach `status` could also write it.
- `make build` compiles the suite as well as the library, so a type error
  in a file no test reaches still fails.

## Adding a corpus section

Dispatch it explicitly in `test/voxgig/plugin/test/Runner.java`. The runner
fails on a *group* with no subject, and its coverage block fails if a whole
SECTION exists in the corpus and nothing runs it. A section or group
silently not run is worse than a failing one.
