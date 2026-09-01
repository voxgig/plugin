# plugin

`voxgig/plugin` — one plugin architecture, every language.

A plugin system defined once in TypeScript and ported faithfully to the
language set the rest of the Voxgig stack targets, so that a library —
[station](https://github.com/voxgig/station) first, an
[sdkgen](https://github.com/voxgig/sdkgen) SDK next, anything after that —
can be extended by the developers using it, in the same way, with the
same vocabulary, in whatever language they are writing.

A **definition** is a plugin kind. An **instance** is a concrete, stateful
incarnation of one, addressed by **name+tag** — `stripe` and
`stripe$test`, or `retry$fast` and `retry$slow`, coexisting in one host
and individually addressable. The name is always the definition; the tag
says which instance. An instance is **declared** (a name and its config, nothing executed),
**loaded** (defined, stateful, inert) or **live** (bound into the
host's extension points, holding resources). Activation is a separate,
reversible, runtime-controllable transition, and it is the only thing
that captures resources. Definitions come from a static in-code catalog
in every language, and from dynamic module loading where the language
supports it. Configuration is one declarative JSON document and one
programmatic API over the same normalized model.

## Status

**P5 tier-3 complete — fourteen of fourteen.** The design is complete
and agreed with its first host, the contract is complete (all 19 corpus
sections, 539 entries), and there are **sixteen implementations**:
`typescript/` the canonical, plus `go/`, `python/`, `javascript/`,
`ruby/`, `php/`, `perl/`, `rust/`, `java/`, `lua/`, `csharp/`,
`elixir/`, `clojure/`, `dart/`, `kotlin/`, `swift/` and `scala/`. **All
sixteen pass every section**, and none of them carries a runtime
dependency: every one writes its own JSON parser and its own test
runner, because §16 permits exactly one dependency and no port of it
exists in those languages.

The pair went before the other fourteen ports on purpose — go for
static-only registration, typed extension points and explicit errors;
python as the closest dynamic analogue that is not JavaScript — because
a model change costs two ports now and sixteen later.

Between them they found **six defects in the canonical**, every one of
them the canonical failing to implement its own design rather than the
design being wrong: a `match` that could not match a nested requirement,
an unwind direction the design mandated and no entry could distinguish,
a resource counter `release` leaked, an `unload` that leaked when
`deactivate` failed, a `match` a loose-equality language would satisfy
with `1` for `true`, and a provider tie nothing pinned.

P5's ruby port then found the sharpest example yet: **`^` and `$` are
not string anchors in every language**, and the python port had shipped
accepting `"abc\n"` as a plugin name. Three ports rejected it, one
accepted it, and no corpus entry distinguished them. All of it is fixed
in the canonical and pinned by new entries — see
[`doc/plan/handover.md`](./doc/plan/handover.md) §13 and §15.

Twelve more ports since then found **no further defect in the
canonical**, which is the result a settled contract should produce. What
they did find is three places where two implementations could disagree
and **the corpus would not notice** — mutation-tested independently in
every language, and the same three every time: shape validation at
catalog *registration* is pinned by nothing (no corpus definition
carries a `shape` at all), `providersof` comparing refs uncanonicalized
changes no observed answer, and whether a nested host counts as an open
resource is a free choice. §18 of the handover records them, and the
remedy is the usual one: an entry each, in the canonical first.

| | |
|---|---|
| design | complete — [`docs/design/plugin.md`](./docs/design/plugin.md) |
| agreement with station | [reconciled](https://github.com/voxgig/station/blob/main/docs/design/station-and-plugin.md), and [sequenced](https://github.com/voxgig/station/blob/main/docs/design/station-and-plugin-plan.md) |
| corpus | **539 entries across all 19 sections** — the contract is complete |
| driver contract | [`DOCS.md`](./DOCS.md) §4 |
| ports | **sixteen, all passing every section** — `typescript/` (canonical), `go/`, `python/`, `javascript/`, `ruby/`, `php/`, `perl/`, `rust/`, `java/`, `lua/`, `csharp/`, `elixir/`, `clojure/`, `dart/`, `kotlin/`, `swift/` and `scala/`. Next: P3.1's extraction (unblocked — station's Stages 2–3b merged) and P6's six tier-4 ports. |

Live per-item state is [`doc/plan/status.md`](./doc/plan/status.md);
what this repo owes station, and what has actually landed, is
[`doc/plan/contracts.md`](./doc/plan/contracts.md).

Next are two parallel tracks: **P3.1**, the extraction against
station's merged Stages 2–3b (unblocked by C3, and the proof that P3
is not a thought experiment), and **P6**'s six tier-4 ports — see
[`AGENTS.md`](./AGENTS.md) §6. Read
[`doc/plan/handover.md`](./doc/plan/handover.md) §13 before writing one:
the six defects the proving pair found were all of two kinds, and both
are found by making another implementation decide from the same text.

The initial use case is [station](https://github.com/voxgig/station)
loading generated SDKs as plugins: twenty-plus SDK instances declared in
one config file, constructed lazily at the point of use, each managing
its own SDK features. That use case set most of the model's harder
requirements — see the design's §17.1.

- [`docs/design/plugin.md`](./docs/design/plugin.md) — the design and the
  implementation plan: the model, naming, the state machine, extension
  points, ordering, resource capture, configuration, dynamic vs static
  loading, errors, the [omni](https://github.com/voxgig/omni) conformance
  corpus, the port layout, host adoption for station and sdkgen, and the
  phased delivery plan.

## Structure

The multi-port layout of [`voxgig/struct`](https://github.com/voxgig/struct)
and [`voxgig/omni`](https://github.com/voxgig/omni): `typescript/` is
canonical, one directory per port, the shared corpus in `spec/` run by
every port through omni, and `tools/` for the spec build and the parity
checks. See the design's §16.

## License

MIT
