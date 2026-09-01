# voxgig/plugin — java

The java port of [voxgig/plugin](../README.md). It is a **port**, not an
independent implementation: behaviour is defined by `typescript/`, and
`spec/plugin.json` — the same corpus every port runs — is the arbiter.

```bash
make build     # compile the library and the suite
make test      # the corpus, all 19 sections
make inspect   # toolchain version
make clean
```

Java 17 or later. **No maven, no gradle, no JUnit, no Jackson**: §16
permits one runtime dependency (`voxgig/struct`, which has no java port),
so this is `javac` and `java` over a source tree — which is also what makes
`make test` work with nothing fetched.

## Layout

| | |
|---|---|
| `src/voxgig/plugin/Json.java` | the value model, and the only parser this port has |
| `src/voxgig/plugin/*.java` | the library, one class per §-area |
| `src/voxgig/plugin/Plugin.java` | the public surface — forwards, nothing else |
| `test/voxgig/plugin/test/` | the driver (DOCS.md §4), the corpus runner, `Runner.main` |

## Using it

```java
Definition retry = new Definition("retry");
retry.define = i -> i.bind("request", (next, args) -> next.call(args), null);

Host host = Plugin.makeHost(options);
host.define(retry);
host.ready("retry$fast");
```

Definitions are **data with functions in it**, not a class to extend: a
document could produce one, which is the property that makes a catalog a
data structure rather than a compile-time registry — and an abstract base
class would make every plugin a subclass of this library.

Errors are **thrown**, as the canonical raises them: `PluginException` is
unchecked (a checked one would put `throws` on every lifecycle callback
signature in every plugin ever written) and carries the §12 `code` the
corpus compares by.

## The two decisions that shaped this port

**The value model is plain `Object`, with ONE java spelling per JSON
type**: `null`, `Boolean`, `Double`, `String`, `List<Object>`,
`Map<String,Object>` — and a map is always a `TreeMap`. Sorted keys are not
a convenience: every port has to sort before iterating, and a sorted map
makes that the default rather than a discipline to remember.

**A number is always a `Double`.** `Integer.valueOf(1).equals(Double.valueOf(1))`
is *false*, so a stray `Integer` anywhere in this data would compare unequal
to the `Double` the parser produced for the same literal — and the corpus
would fail on a distinction the model does not have. JSON has one number
type; so does this port.

What java gives for free: `Boolean.equals(Double)` is false, so the
type-strict `match` rule needs no guard here. `capability/match` pins it
anyway, for php, perl and lua.

## What the corpus cannot see here

> **Three of these are no longer invisible.** Shape validation at catalog
> registration, `providersof` comparing refs uncanonicalized, and a nested
> host counted as an open resource are now pinned by `declare/shape`,
> `declare/register`, `depend/byref`, `depend/cycle`, `graph/resolve` and
> `nest/open`. Anything else below still stands.

Mutation testing: 19 mutations, 16 caught. The three survivors are the
**same three** php, perl and rust found independently — `order.band`
accepting a non-integer, `providersof` without `canon`, and `config_pick`
reading null as absent. Two of those are unpinned rules the design states
and no entry exercises; they are recorded in the plan register rather than
worked around here.
