# The lean port — agent notes

Lean 4 is tier-S in §10.3's table: static registration only. It is also
the only port whose **type theory refused the shape every other port
uses**, and that is the thing to read before changing anything here.

## Lean will not let a definition hold a function of the instance

Every other port gives a callback the instance itself. `define(inst)`,
and the instance points back at its host, and the host holds a catalog
of definitions. `c` opens that cycle with a forward `typedef`, `ocaml`
gathers it into `defs.ml`, `haskell` into `Defs.hs`.

**The kernel refuses it:**

```
(kernel) arg #1 of '_nested.Option_2.some' has a non positive
occurrence of the datatypes being declared
```

A `Definition` holding `Inst → PluginM Unit` puts `Inst` in a *negative*
position and `Inst` holds the `Definition` back. That is not a quirk to
route around — it is the logic refusing a type whose inhabitants could
encode a fixed point of `X → X`. `unsafe` or an opaque cast would throw
away the one thing this language is for.

**So the instance api is an explicit record of closures** (`InstApi` in
`Defs.lean`), and the cycle never forms:

```
HostApi   ← mentions nothing recursive
InstApi   ← mentions HostApi, String, Value, PluginM
Definition← mentions InstApi
InstState ← mentions HostApi (for a nested host)
HostState ← mentions Definition and InstState
```

**And the shape is not a compromise.** §6 says a plugin never mutates
the host; it declares bindings and captures resources through a small
API. `InstApi` *is* that API, written down. Lean made explicit what the
other ports leave implicit in a pointer.

One consequence shows: `nest` takes no options and returns a `HostApi`,
so the inner host shares the outer's catalog and points. §10.1 already
permits a shared catalog, and the driver's nested host wants exactly the
outer's probes, so the corpus cannot tell the difference.

## What is `partial`, and why

Lean asks every recursive function for a termination argument. Most of
this port is structural and needs none. The `mutual` block in
`Machine.lean` is `partial` because:

- **`reconcile`** settles by reaching a fixed point, bounded by an
  explicit round cap. Termination is a SEMANTIC property of the state
  machine, not a structural one.
- **`cascade`** recurses over the consumer graph, guarded by a `seen`
  set. It terminates because the graph is finite and the guard is
  honoured; proving that means carrying the invariant in the type.
- everything else in the block is mutually recursive with those two.

`partial` says exactly that: the proof is not free, and the corpus is
what checks them instead. `HostApi` and `InstApi` derive `Inhabited`
solely because Lean will only compile a `partial` definition whose
result type it knows is non-empty.

## The build trap, and it cost fifteen modules

**Lake builds only what a target's import graph reaches.** A module no
target imports is not compiled, so it reports no errors — and reads
exactly like a module that compiled cleanly. Fifteen modules in this
port sat "green" that way while every one of them had a syntax error
Lean would have rejected instantly.

The guards are all three of: both libraries `@[default_target]`,
`roots` naming every test module, and `src/Plugin.lean` importing the
whole library. **Do not remove any of them.** The Makefile also fails
the build if no binary appears.

## Other things Lean does not have

- **`String.toFloat?`** — the JSON reader parses the number grammar
  itself (sign, integer part, fraction, exponent, nothing left over),
  and answers `none` rather than dying, which is what §9.5's
  parse-or-string fallback needs.
- **`List.zipIdx`** — `Value.indexed`, because `List.enum` yields
  `(index, value)` and every call site here wants `(value, index)`.
- **A regex engine** — `Corpus.regexLite`, the same
  literal-with-anchors matcher `lua` has, which *errors* on any
  metacharacter it cannot evaluate rather than quietly reporting a
  mismatch.
- **`Float.toString` that agrees with anyone** — it is fixed to six
  decimals, so `1.5` rendered as `1.500000`. `Value.numStr` trims the
  trailing zeros; a value needing more than six decimals would be lossy
  in Lean's own `toString` before it reached us.

`at`, `prefix`, `from` and `instance` are all keywords, so the
accessors and locals that would use those names are spelled `idx`,
`pfx`, `froms` and `instMap`.
