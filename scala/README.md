# voxgig/plugin — scala

The scala port of [voxgig/plugin](../README.md). It is a **port**, not an
independent implementation: behaviour is defined by `typescript/`, and
`spec/plugin.json` — the same corpus every port runs — is the arbiter.

```bash
make build     # scalac -Xlint -Xfatal-warnings
make test      # the corpus, all 19 sections
make inspect   # scala -version
make clean
```

Scala 2.11 or later on any JDK 8+. **No sbt, no mill, no
`libraryDependencies`**: §16 permits one runtime dependency and scala has no
port of it, so the JSON parser is `src/Json.scala`, the suite is a plain `main`
rather than ScalaTest or munit, and `scalac` plus `scala` is the whole build
system.

## Layout

| | |
|---|---|
| `src/Value.scala` | the value model — a sealed trait, not `Any` |
| `src/Types.scala` | the error type, the sort key, the stable sort |
| `src/Json.scala` | the parser |
| `src/*.scala` | the library, one file per §-area |
| `src/Host.scala` | the state machine, `Definition`, `Catalog`, `Entry`, `Inst` |
| `src/Plugin.scala` | the public surface — eleven forwards, nothing else |
| `test/` | the driver (DOCS.md §4), the corpus runner, and `Run.scala` |

## Using it

```scala
import voxgig.plugin._

val host = Plugin.makeHost(HostOptions(
  catalog = Some(Plugin.makeCatalog(List(
    Definition(
      name = "retry",
      define = Some((i: Inst) => i.bind("request", (next, req) => next.get(req)))
    )
  ))),
  points = Map("request" -> PointSpec(kind = "chain", base = Some(transport)))
))

host.ready(VStr("retry$fast"))
```

## The value model

**`Value` is a sealed trait, not `Any`.** Scala can express the JSON model
exactly, and `Map[String, Any]` would throw away the guarantee that matters
most here: **a pattern match over a sealed hierarchy is checked for
exhaustiveness**. Adding a case to `Value.scala` makes the compiler name every
place that has to handle it, which is a stronger discipline than any untyped
port can have — and with `-Xfatal-warnings` a missed case is an error rather
than a note.

`VNum` is a `Double`, because JSON has one number type and the canonical is
javascript. `VNull` is a present null and `Option[Value]` is absence — the
distinction `__NULL__` and `__UNDEF__` pin — which is why `Value.get` returns
an `Option` and `Value.at` flattens the two only where a site treats them
alike.

**`Definition`, `HostOptions` and `PointSpec` are case classes, not `Value`
maps.** Every other port passes a definition as a plain map with function
values, because its maps hold closures; scala's sealed hierarchy cannot, and a
`VOpaque` per callback with a cast at every call would be a worse lie than a
type. The corpus does not notice: the driver builds them from the same command
data every other driver reads.

**An exception, not an `Either`.** Scala offers both and the canonical raises;
threading a `Left` through `Host.ready` would change the shape of every call in
the port for a difference no corpus entry can see, and would make this the one
port whose control flow does not read like the design.

**Nothing returns a `Future`.** `Future` and an implicit `ExecutionContext` are
one import away, and either would make §5.2's "one at a time, in call order" a
claim about a scheduler rather than about the code. Reconciliation is eager
(§18) and §6.1's four fan-out modes stay *data*.

## The precedence trap

Scala binds `match` tighter than `||`, so

```scala
isAlpha(c) || c == '@' match { case true => rest.forall(ok); case false => false }
```

parses as `isAlpha(c) || (c == '@' match {...})` — a name starting with a letter
short-circuits to `true` and **the rest of the name is never checked**. It
compiles, it is silent, and `ref/name` catches it only because the corpus has
an entry with a space in the middle. `Refs.checkName` carries the parenthesis
and a comment saying why.

What scala gives free: a sealed `Value` makes `VBool(true) == VNum(1)`
impossible, so the type-strict `match` rule needs no guard; `sortBy` is a
documented-stable TimSort, so §7's fall-through to `pos` lands where the
canonical's does; and immutable collections everywhere mean the only mutable
things in the port are the two classes that have to be — `Host` and `Entry`.

## What the corpus cannot see here

Mutation testing: 25 mutations, **21 caught**. The three survivors are
exactly the ones every other port also leaves:

- **Shape validation skipped at catalog registration.** §10.1 puts it there so
  a malformed shape "fails once, and in the same place everywhere", but no
  corpus definition carries a `shape`.
- **`providersOf` comparing refs uncanonicalized.**
- **A nested host counted as an open resource.**

One more looked like a survivor and is not: `Value.keys` returning hash order
passes only because a scala `Map` of four entries or fewer is a `Map4` and
happens to iterate in insertion order. Reverse the sort instead and
`order/order/pinorder#two-names` fails — the guard is load-bearing, and the
corpus sees it once the masking is gone.
