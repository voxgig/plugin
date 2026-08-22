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

**P0 — the repository skeleton.** The design is complete and agreed with
its first host; the build machinery exists and turns over; there is no
code in any language yet, and the corpus is empty.

That last part is deliberate rather than a gap: `make spec` and
`make spec-check` are proven against an empty corpus *before* there is
anything to compile, so that when the first sections land, a failure is
about the data rather than about the pipeline.

| | |
|---|---|
| design | complete — [`docs/design/plugin.md`](./docs/design/plugin.md) |
| agreement with station | [reconciled](https://github.com/voxgig/station/blob/main/docs/design/station-and-plugin.md), and [sequenced](https://github.com/voxgig/station/blob/main/docs/design/station-and-plugin-plan.md) |
| corpus | empty — `ref` and `config` land first, in P1 |
| ports | none — `typescript/` is canonical and arrives with P1 |

Next is P1, the TypeScript tracer bullet. Its first deliverables are the
two corpus sections owed to station, not its last — see
[`AGENTS.md`](./AGENTS.md) §6.

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
