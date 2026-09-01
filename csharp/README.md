# voxgig/plugin — csharp

The csharp port of [voxgig/plugin](../README.md). It is a **port**, not an
independent implementation: behaviour is defined by `typescript/`, and
`spec/plugin.json` — the same corpus every port runs — is the arbiter.

```bash
make build     # compile the library and the suite
make test      # the corpus, all 19 sections
make inspect   # toolchain version
make clean
```

.NET 8. **No PackageReference anywhere** — not `System.Text.Json`, not
xunit: §16 permits one runtime dependency (`voxgig/struct`, which has no
csharp port), so `Json.cs` is the parser and the suite is a plain `Main`.
That is also what makes every target run offline: there is nothing to
restore.

## Layout

| | |
|---|---|
| `src/Types.cs` | the value helpers, the error type, the stable sort |
| `src/Json.cs` | the parser and writer |
| `src/*.cs` | the library, one class per §-area |
| `src/Plugin.cs` | the public surface — forwards, nothing else |
| `test/` | the driver (DOCS.md §4), the corpus runner, `Runner.Main` |

## Using it

```csharp
var retry = new Definition("retry");
retry.Define = i => i.Bind("request", (next, args) => next(args), null);

var host = Plugin.MakeHost(options);
host.Define(retry);
host.Ready("retry$fast");
```

Definitions are **data with delegates in it**, not a class to extend: a
document could produce one, which is the property that makes a catalog a
data structure rather than a compile-time registry. Errors are thrown as
`PluginException`, carrying the §12 `code` the corpus compares by.

## The two decisions that shaped this port

**Every string comparison is `Ordinal`.**
`Comparer<string>.Default` and `StringComparer.CurrentCulture` are
culture-sensitive — on this machine they sort `a, A, b, B` where the corpus
wants `A, B, a, b` — so every map is a
`SortedDictionary<string,object>(StringComparer.Ordinal)` and every sort
says so. `config/normmap#bytewise` catches the alternative immediately;
`Env.EncodeRef` uses `ToUpperInvariant` for the same reason, one dotless-ı
away from a ref that stops matching its own environment variable.

**Every number is a `double`.** `Json` produces nothing else, because a
boxed `int` would compare unequal to the `double` the parser produced for
the same literal, and the corpus would fail on a distinction the model does
not have. What csharp gives for free is the other half:
`true.Equals(1.0)` is false, so the type-strict `match` rule needs no guard
here.

Two smaller ones worth knowing: `List<T>.Sort` is an **introsort and is not
stable**, so ordering goes through `Types.StableSorted` (which decorates
with the original index); and `TreatWarningsAsErrors` is on, which is why
you cannot write `if (false)` here — including in a mutation test, where
four of them had to be rewritten as runtime-false conditions.

## What the corpus cannot see here

Mutation testing: 24 mutations, 21 caught. The three survivors are one
non-mutation — `Types.NewMap`'s comparer, because an output map is compared
key-by-key and never by order, while the map that IS order-sensitive
(`Config`'s entry map) is caught — and the two gaps php, perl, rust, java
and lua each found independently: `ProvidersOf` without `Canon`, and
`Config.Pick` reading an authored null as absence.
