# AGENTS.md — the rust port

Read [`../AGENTS.md`](../AGENTS.md) first. The prime directives there are
not negotiable here: **TypeScript is canonical**, **the corpus is the
contract**, **change canonical first then propagate**, and **never weaken
the corpus to make this port pass**.

## The rule that matters most here

**A disagreement with the corpus is this port's bug — until you have
established it is the canonical's.** Both happen;
[`../doc/plan/handover.md`](../doc/plan/handover.md) §13 has the running
list.

## Rust-specific traps

**Never hold a `RefCell` borrow across a callback.** This is the whole
shape of `host.rs`: read what you need, drop the borrow, then run plugin
code. `unwind` takes the scope out with `mem::take` for exactly this
reason. A held borrow PANICS, and a panic is the one failure a conformance
suite reports as "the process died" rather than "this entry disagrees".

**`Value::get` collapses absent and null.** Where the canonical tests
`undefined !== x`, use `has`. `config_pick` and `load`'s options clearing
both turn on it, and `declare/clear#empty-options` catches the second.

**`as_int` is Num-and-integral on purpose.** §7's band is an integer a
document wrote as one; `true` is a `Bool` and `"2"` a `Str`, and neither is
a band. Do not "helpfully" coerce.

**No crate may be added.** `[dependencies]` is empty and §16 says it stays
empty. If something needs JSON, it is in `value.rs`; if something needs a
regex, look again at whether it needs a regex (`regex_lite` handles every
pattern the corpus writes, and panics rather than guessing on any it does
not).

**`Value::Opaque` is the escape hatch, and it is only for exports.** §11
lets a plugin publish "a client" — a thing the library never inspects. It
is never produced by the parser and never compared as data.

## What the corpus cannot currently distinguish

Three mutations survive, and none is a licence to relax the code:

- `order_declared` returning true for an ABSENT constraint, and for an
  EMPTY LIST. **DOCS.md §4.4 predicts both in writing**: neither yields an
  edge, so the sort cannot see the difference. Where they ARE observable is
  the normalized document, which `config/normorder` pins.
- `providersof` without `canon`: no requirement in the corpus names an
  uncanonical ref.

## Local shape

- One module per §-area, `Result<_, PluginError>` on everything fallible.
- `Host` is `Rc<HostInner>` with `RefCell` fields; `Entry` lives behind
  `Rc<RefCell<_>>` so the registry, the `Inst` a callback holds, and any
  closure that captured it all see one set of values.
- The driver's probe closures capture the `Inst` that owns them — an `Rc`
  cycle that is never collected. Deliberate, bounded (539 entries and the
  process exits), and said out loud in `tests/support/driver.rs`.
- `make build` is a real compile, so a type error in a file no test
  exercises still fails.

## Adding a corpus section

Dispatch it explicitly in `tests/corpus.rs`. The runner fails on a *group*
with no subject, and its coverage block fails if a whole SECTION exists in
the corpus and nothing runs it. A section or group silently not run is
worse than a failing one.
