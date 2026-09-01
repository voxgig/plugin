# voxgig/plugin — kotlin

The kotlin port of [voxgig/plugin](../README.md). It is a **port**, not an
independent implementation: behaviour is defined by `typescript/`, and
`spec/plugin.json` — the same corpus every port runs — is the arbiter.

```bash
make build     # kotlinc -Werror
make test      # the corpus, all 19 sections
make inspect   # kotlinc -version
make clean
```

Kotlin 1.3 or later on any JDK 8+. **No gradle, no maven, no `dependencies`
block**: §16 permits one runtime dependency and kotlin has no port of it, so
the JSON parser is `src/Json.kt`, the suite is a plain `main` rather than JUnit
or `kotlin.test`, and `kotlinc` plus `java` is the whole build system.

## Layout

| | |
|---|---|
| `src/Types.kt` | the value model, the error type, the stable sort |
| `src/Json.kt` | the parser and the writer |
| `src/*.kt` | the library, one file per §-area |
| `src/Host.kt` | the state machine, `Entry` and `Inst` |
| `src/Plugin.kt` | the public surface — eleven forwards, nothing else |
| `test/` | the driver (DOCS.md §4), the corpus runner, and `Run.kt` |

## Using it

```kotlin
import voxgig.plugin.*

val host = Plugin.makeHost(mapOf(
    "catalog" to Plugin.makeCatalog(listOf(mapOf(
        "name" to "retry",
        "define" to { i: Inst ->
            i.bind("request") { next, req ->
                @Suppress("UNCHECKED_CAST")
                (next as (Any?) -> Any?)(req)
            }
        }
    ))),
    "points" to mapOf("request" to mapOf("kind" to "chain", "base" to transport))
))

host.ready("retry\$fast")
```

Definitions are plain maps with function values, which is what makes a catalog
a data structure a document could produce. Errors are a `PluginError` carrying
the §12 `code` the corpus compares by, whose `message` is the pinned
`plugin/<code>: <text> [k=v]` format.

## The value model, and the one arithmetic trap

**Every number is a `Double`.** JSON has one number type, the canonical is
javascript, and `1L == 1.0` is false for `Any?` in kotlin exactly as
`Integer.valueOf(1).equals(Double.valueOf(1))` is in java — so a `Long`
anywhere in this data would make the corpus fail on a distinction the model
does not have. Maps are `TreeMap`, so sorted iteration is the default rather
than a discipline to remember.

That choice has a second, sharper consequence, and the corpus catches it:
**`major + 1` at `COMPONENT_MAX` is 2147483648**, which an `Int` cannot hold.
Writing §11.2's range arithmetic in `Int` wraps to the negative bound, and
`version/range#component-max` fails immediately. `Version` works in `Double`
throughout, and `BigInteger` parses the component itself so a forty-digit
version cannot overflow past the check that is meant to reject it.

**Nothing is `suspend`.** Kotlin puts a coroutine one keyword away, and a
suspending transition would make §5.2's "one at a time, in call order" a claim
about a dispatcher rather than about the code. Reconciliation is eager (§18)
and §6.1's four fan-out modes stay *data*.

What kotlin gives free: `true == 1` and `"1" == 1` are both false for `Any?`,
so the type-strict `match` rule needs no guard; `sortedWith` is
`java.util.Arrays.sort`, a documented-stable TimSort, so §7's fall-through to
`pos` lands where the canonical's does; and `Regex.matches` requires the WHOLE
input to match, so the ref grammar's anchors are unnecessary rather than
load-bearing — swapping `matches` for `containsMatchIn` is what
`ref/name#trailing-newline` catches.

## The 1.3 compiler

The toolchain here is `kotlinc-jvm 1.3`, which shapes two things a reader
would otherwise find odd:

- `Types.stableSortBy` writes `Comparator { a, b -> … }` rather than a bare
  lambda. SAM conversion for a *kotlin* functional interface arrived in 1.4;
  `java.util.Comparator` converts in every version.
- `"" == s` appears where `s.isEmpty()` would read better. On a modern JDK the
  1.3 compiler resolves `String.isEmpty` to the JDK's own default method and
  warns that it may not survive — and this port promotes warnings to errors.

## What the corpus cannot see here

Mutation testing: 24 mutations, **21 caught**. Three survivors, and every one
is a gap another port found too:

- **Shape validation skipped at catalog registration.** §10.1 puts it there so
  a malformed shape "fails once, and in the same place everywhere", but no
  corpus definition carries a `shape`. Found independently by elixir, clojure
  and dart.
- **`providersOf` comparing refs uncanonicalized** — the gap eight other ports
  each found.
- **A nested host counted as an open resource.** Nothing in `nest` asserts
  `open` while an inner host is live.

None is a licence to relax the code.
