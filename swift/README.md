# voxgig/plugin — swift

The swift port of [voxgig/plugin](../README.md). It is a **port**, not an
independent implementation: behaviour is defined by `typescript/`, and
`spec/plugin.json` — the same corpus every port runs — is the arbiter.

```bash
make build     # swiftc, warnings as errors, library then suite
make test      # the corpus, all 19 sections
make inspect   # swiftc --version
make clean
```

Swift 5.10 on Linux. **No `Package.swift` and no dependencies**: §16 permits
one runtime dependency and swift has no port of it, so `swiftc` is the whole
build system — which also keeps `swift build` from wanting a network it does
not need.

## Layout

| | |
|---|---|
| `src/Value.swift` | the value model — an enum, not `Any` |
| `src/Json.swift` | the parser |
| `src/Types.swift` | the error type, the sort key, the stable sort |
| `src/*.swift` | the library, one file per §-area |
| `src/Host.swift` | the state machine, `Entry`, `Inst`, `HostOptions`, `PointSpec` |
| `test/` | the driver (DOCS.md §4), the corpus runner, and `main.swift` |

## Using it

```swift
import VoxgigPlugin

let host = makeHost(HostOptions(
    catalog: try makeCatalog([
        Definition(name: "retry", define: { i in
            try i.bind("request") { next, req in try next!(req) }
        })
    ]),
    points: ["request": PointSpec(kind: "chain", base: transport)]
))

try host.ready(.str("retry$fast"))
```

## The three decisions swift forces

**`Value` is an enum, not `Any`.** Swift can express the JSON model exactly,
and `[String: Any]` would throw away the guarantees the language is for —
`dict["k"] = nil` REMOVES the key rather than storing a null, so an authored
null and an absent key could not be told apart at all. That is the distinction
`__NULL__` and `__UNDEF__` pin, and here it is the difference between `.null`
and a `nil` optional, checked by the compiler at every read.

**Everything that can fail is `throws`.** Rust returns a `Result` and the other
ports raise; swift makes the possibility part of the signature, so `try`
appears at every call from `Host.ready` down to `Refs.parseRef`. It is verbose
and it is honest: a reader can see from a signature alone whether a call can
produce a §12 error.

**`Definition`, `HostOptions` and `PointSpec` are structs, not `Value` maps.**
Every other port passes a definition as a plain map with function values,
because its maps hold closures. Swift's cannot — the JSON enum has no case for
one — and an `.opaque` per callback with a cast at every call would be a worse
lie than a type. So the shape every port has (a name, four lifecycle callbacks,
`reconfigure`, an option shape) is written in the type system rather than in a
comment. The corpus does not notice: the driver builds the structs from the
same command data every other driver reads.

**Nothing is `async`.** Swift invites an actor or an `async` transition at
every turn, and either would make §5.2's "one at a time, in call order" a claim
about a cooperative executor rather than about the code. Reconciliation is
eager (§18) and §6.1's four fan-out modes stay *data* rather than becoming a
`TaskGroup`.

## No Foundation, anywhere

`NSRegularExpression`, `JSONSerialization` and `String.replacingOccurrences`
all live in Foundation, and this port imports it in neither the library nor the
suite. What that costs, and what it buys:

- **The ref grammar is a character loop.** Which removes the whole
  `^`/`$`-versus-`\A`/`\z` trap that ruby, java and dart each document from a
  different side: there is no anchor to get wrong, because there is no search,
  and `"abc\n"` fails on the newline like any other character outside the class.
- **The corpus runner has `Rex`**, a matcher for the subset the corpus actually
  uses — a literal with backslash escapes and at most a leading `^`, which is
  all ten `/re/` expectations are. It **traps on any metacharacter it does not
  implement**, so the day the corpus adds a real pattern this port fails loudly
  instead of quietly matching the wrong thing.
- **Reading the corpus file goes through `Glibc`.**

## What the corpus cannot see here

Mutation testing: 24 mutations, **21 caught**. The three survivors are exactly
the ones every other port also finds:

- **Shape validation skipped at catalog registration.** §10.1 puts it there so
  a malformed shape "fails once, and in the same place everywhere", but no
  corpus definition carries a `shape`.
- **`providersOf` comparing refs uncanonicalized.**
- **A nested host counted as an open resource.** Nothing in `nest` asserts
  `open` while an inner host is live.

Worth noting what the corpus DOES catch here that it catches nowhere else: a
version component parsed without its `componentMax` bound fails
`version/rangebad`, because this port's components are `Double` and would
otherwise sail past 2**31-1 without complaint.
