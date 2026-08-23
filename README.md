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

**P4 — the first port.** The design is complete and agreed with its
first host, the contract is complete (all 19 corpus sections, 463
entries), `typescript/` is the canonical, and `go/` is the first port.
**Both pass every section.**

Go went first on purpose: static-only registration, typed extension
points and explicit errors find every TypeScript-shaped assumption in
the model, and running that before fourteen more ports exist is what
makes fixing one cheap. It found three defects in the canonical — a
`match` that could not match a nested requirement, an unwind direction
the design mandated and no entry could distinguish, and a resource
counter `release` leaked — all fixed in the canonical and pinned by new
corpus entries. See [`doc/plan/handover.md`](./doc/plan/handover.md)
§13.

| | |
|---|---|
| design | complete — [`docs/design/plugin.md`](./docs/design/plugin.md) |
| agreement with station | [reconciled](https://github.com/voxgig/station/blob/main/docs/design/station-and-plugin.md), and [sequenced](https://github.com/voxgig/station/blob/main/docs/design/station-and-plugin-plan.md) |
| corpus | **463 entries across all 19 sections** — the contract is complete |
| driver contract | [`DOCS.md`](./DOCS.md) §4 |
| ports | `typescript/` (canonical) and `go/` — both pass every section. `python/` is next. |

Live per-item state is [`doc/plan/status.md`](./doc/plan/status.md);
what this repo owes station, and what has actually landed, is
[`doc/plan/contracts.md`](./doc/plan/contracts.md).

Next is the second half of P4, the Python port — see
[`AGENTS.md`](./AGENTS.md) §6. Go went first because static-only, typed
extension points and explicit errors find TypeScript-shaped assumptions
in the model, and it found three; what they were is
[`doc/plan/handover.md`](./doc/plan/handover.md) §13.

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

## Structure (planned)

The multi-port layout of [`voxgig/struct`](https://github.com/voxgig/struct)
and [`voxgig/omni`](https://github.com/voxgig/omni): `typescript/` is
canonical, one directory per port, the shared corpus in `spec/` run by
every port through omni, and `tools/` for the spec build and the parity
checks. See the design's §16.

## License

MIT
