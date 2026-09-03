# CLAUDE.md

This repository's agent guidance lives in [`AGENTS.md`](./AGENTS.md).
Read it first — it is the single source of truth for how to work here.

Quick reminders (the full rationale is in `AGENTS.md`):

- **TypeScript is canonical**; every other language is a port of it.
- **The corpus is the contract** — `spec/plugin.json`, generated from
  `spec/plugin.aontu`. A port that disagrees with it is the thing that's
  wrong. **Never hand-edit the JSON**, and never weaken the corpus to
  make a port pass.
- **Change canonical first, then propagate** to every port, in one
  change set.
- **Keep `make parity` green** and add **no runtime dependencies** —
  `voxgig/struct` is the only permitted one, and the reason is in
  `AGENTS.md` §1.
- Build and check with `make spec`, `make spec-check`, `make parity`,
  `make check`.

**Status: P5 complete; P6 tier-4 two of six.** The corpus is 572
entries across 19 sections, and **nineteen implementations pass every
one of them** — `typescript/` (canonical), `go/`, `python/`, `javascript/`, `ruby/`, `php/`,
`perl/`, `rust/`, `java/`, `lua/`, `csharp/`, `elixir/`, `clojure/`,
`dart/`, `kotlin/`, `swift/`, `scala/`, `c/` and `cpp/`. `zig`,
`haskell`, `ocaml` and `lean` are what remain of P6.
`AGENTS.md` §6 says what to pick up; the live per-item state is
[`doc/plan/status.md`](./doc/plan/status.md).

The design is [`docs/design/plugin.md`](./docs/design/plugin.md). The
agreement with its first host, and the cross-repo sequencing, live in
station: [`station-and-plugin.md`](https://github.com/voxgig/station/blob/main/docs/design/station-and-plugin.md)
and [`station-and-plugin-plan.md`](https://github.com/voxgig/station/blob/main/docs/design/station-and-plugin-plan.md).
