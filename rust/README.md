# voxgig/plugin — rust

The rust port of [voxgig/plugin](../README.md). It is a **port**, not an
independent implementation: behaviour is defined by `typescript/`, and
`spec/plugin.json` — the same corpus every port runs — is the arbiter.

```bash
make build     # compile the library
make test      # the corpus, all 19 sections
make inspect   # toolchain version
make clean
```

**No dependencies. Not one.** §16 permits a single runtime dependency,
`voxgig/struct`, which has no rust port — so `[dependencies]` is empty and
stays empty. That decision costs about 250 lines (a JSON parser and a
literal matcher) and buys a library with no crate graph to audit.

## Layout

| | |
|---|---|
| `src/value.rs` | the JSON value, and the only parser this port has |
| `src/*.rs` | the library, one module per §-area |
| `tests/support/` | the corpus runner and the driver (DOCS.md §4) |
| `tests/corpus.rs` | the suite: one `#[test]`, 539 entries |

## Using it

```rust
use std::rc::Rc;
use voxgig_plugin::catalog::Definition;
use voxgig_plugin::host::make_host;
use voxgig_plugin::value::Value;

let mut retry = Definition::named("retry");
retry.define = Some(Rc::new(|i| {
    i.bind("request", Rc::new(|next, args| next.unwrap()(args)), &Value::Null)
}));

let host = make_host(&points);
host.define(retry)?;
host.ready(&Value::str("retry$fast"))?;
```

Errors are **returned**, not raised — go's one deliberate change (§18, P4),
kept for the same reason: `PluginError` carries the §12 `code` the corpus
compares by, so the change survives the corpus intact.

## The three decisions that shaped this port

**`Value` is a JSON enum, and `Map` is a `BTreeMap`.** Every port has to
sort its keys before iterating — status maps, export lookups, registry
walks — and a sorted map makes that the default rather than a discipline to
remember. `Num` is `f64` because JSON has one number type and the canonical
is javascript; splitting int from float would disagree with the corpus
about which spelling a document used. Type-strict `match` (`1` is not
`true`, `"1"` is not `1`) falls out of the enum, so this port needs none of
the guards php, perl and lua each carry.

**Never hold a borrow across a callback.** A definition's `define` calls
back into the host — `bind`, `export`, `acquire`, `nest` — so every method
reads what it needs out of a `RefCell`, **drops** the borrow, and only then
runs anything a plugin wrote. `unwind` is the sharp case: it `mem::take`s
the scope under a short borrow, because a foreign release records its index
into the same entry's `state` as it runs. A held borrow does not produce a
wrong answer, it panics — the one failure mode a conformance suite cannot
report as a divergence.

**A literal matcher, not a regex engine.** The corpus writes ten `/re/`
expectations and every one is a literal, optionally `^`-anchored. So
`regex_lite` unescapes and compares — and **panics** on any unescaped
metacharacter, because the one thing a hand-rolled matcher must never do is
quietly report a mismatch it could not evaluate.

## What the corpus cannot see here

Mutation testing: 18 mutations, 15 caught. Of the three survivors, **two
are ones DOCS.md §4.4 predicts in writing** — an ordering constraint that
is absent and one that is an empty list are both invisible to the sort "by
construction", because neither yields an edge — and the third (dropping
`canon` in `providersof`) needs a requirement that names an uncanonical
ref, which no entry writes.
