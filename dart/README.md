# voxgig/plugin — dart

The dart port of [voxgig/plugin](../README.md). It is a **port**, not an
independent implementation: behaviour is defined by `typescript/`, and
`spec/plugin.json` — the same corpus every port runs — is the arbiter.

```bash
make build     # dart analyze, with warnings promoted to errors
make test      # the corpus, all 19 sections
make inspect   # dart --version
make clean
```

Dart 3. **No pubspec, and so no dependencies**: §16 permits one runtime
dependency and dart has no port of it. `dart:convert` and `dart:io` are the
SDK's own libraries rather than packages, so JSON parsing costs nothing, the
suite is a plain script rather than `package:test`, and imports are relative
— a `package:` import would need a pubspec and a `dart pub get`, which is a
dependency step for a library that has none.

## Layout

| | |
|---|---|
| `lib/types.dart` | the value model, the error type, the JSON writer |
| `lib/*.dart` | the library, one file per §-area |
| `lib/host.dart` | the state machine, `Entry` and `Inst` |
| `lib/plugin.dart` | the public surface — one export list |
| `test/` | the driver (DOCS.md §4), the corpus runner, and `run.dart` |
| `analysis_options.yaml` | the warnings this port treats as errors, and why |

## Using it

```dart
import 'lib/plugin.dart' as p;

final host = p.makeHost({
  'catalog': p.makeCatalog([
    {
      'name': 'retry',
      'define': (p.Inst i) => i.bind('request', (next, req) => next(req)),
    }
  ]),
  'points': {'request': {'kind': 'chain', 'base': transport}},
});

host.ready('retry\$fast');
```

Definitions are plain maps with function values, which is what makes a
catalog a data structure a document could produce. Errors are a
`PluginError` carrying the §12 `code` the corpus compares by, whose
`message` is the pinned `plugin/<code>: <text> [k=v]` format.

## The two things dart gets wrong for you

**`List.sort` is not stable, and visibly so.** Sorting two hundred
elements by a two-valued key visibly reorders equal ones; dart uses an
insertion sort below 32 elements and a dual-pivot quicksort beyond, so the
break arrives exactly when a host gets big. §7's comparators fall through to
a `pos` or ref tie-break that javascript's stable sort resolves BY POSITION,
so `types.stableSortBy` decorates with the original index and breaks the
last tie on it. Every sort in the port goes through it.

**Nothing here returns a `Future`.** Dart invites an `async` host at every
turn, and an `async` transition would make §5.2's "one at a time, in call
order" a claim about a microtask queue rather than about the code.
Reconciliation is eager (§18) and the host is synchronous throughout;
§6.1's four fan-out modes stay *data* rather than becoming a `Future.wait`.

What dart gives free: `Map` is not `List`; a map holds `null` as a value and
`containsKey` separates an authored null from an absent key; `true == 1` is
false, so the type-strict `match` rule needs no guard; and a `RegExp` without
`multiLine` anchors `$` at the end of input, so the four `#trailing-newline`
entries pass without the port having to know they exist — turn `multiLine`
on and `ref/name#trailing-newline` fails immediately.

One thing dart does NOT give: a map iteration order that means anything
across runs. A `Map` literal is a `LinkedHashMap`, so iteration is INSERTION
order — deterministic within one run and meaningless between two. Every walk
goes through `types.sortedKeys`.

## What the corpus cannot see here

Mutation testing: 25 mutations, **19 caught**. Four survivors:

- **`stableSortBy` without its index tiebreak.** Every sort the corpus
  performs is over a handful of bindings, and dart's insertion sort below 32
  elements is stable — so the corpus cannot reach the case, and a host with
  32 live bindings on one point can. The decoration stays.
- **Shape validation skipped at catalog registration.** §10.1 puts it there
  so a malformed shape "fails once, and in the same place everywhere", but
  no corpus definition carries a `shape`, so every port could defer it to
  `resolveOptions` and stay green. Found independently by elixir and
  clojure.
- **`_providersOf` comparing refs uncanonicalized** — the gap seven other
  ports each found.
- **A nested host counted as an open resource.** Nothing in `nest` asserts
  `open` while an inner host is live.

Two more looked like survivors and are not: `sortedKeys` returning insertion
order, and `order` sorting by `pos` instead of `seq`, both pass only because
the map's own order happens to agree. Reverse `sortedKeys` and
`order/order/pinorder#two-names` fails; break `order`'s fallback as well and
`order/order/seqtie#shared-pos` fails.
