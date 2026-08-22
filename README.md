# plugin

`voxgig/plugin` — one plugin architecture, every language.

A plugin system defined once in TypeScript and ported faithfully to the
language set the rest of the Voxgig stack targets, so that a library —
[station](https://github.com/voxgig/station) first, an
[sdkgen](https://github.com/voxgig/sdkgen) SDK next, anything after that —
can be extended by the developers using it, in the same way, with the
same vocabulary, in whatever language they are writing.

A **definition** is a plugin kind. An **instance** is a live, stateful
incarnation of one, addressed by **name+tag** — `stripe` and
`stripe$test`, or `retry$fast` and `retry$slow`, coexisting in one host
and individually addressable. The name is always the definition; the tag
says which instance. An instance is **declared** (a name and its config, nothing executed),
**loaded** (defined, stateful, inert) or **active** (bound into the
host's extension points, holding resources). Activation is a separate,
reversible, runtime-controllable transition, and it is the only thing
that captures resources. Definitions come from a static in-code catalog
in every language, and from dynamic module loading where the language
supports it. Configuration is one declarative JSON document and one
programmatic API over the same normalized model.

## Status

Design only. Nothing is implemented yet.

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
