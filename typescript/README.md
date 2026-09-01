# plugin — TypeScript (canonical)

**This is the canonical implementation.** Behaviour is defined here;
every other language is a port of it (AGENTS.md §1). A behaviour change
is TypeScript + corpus + every port, in one change set.

## Run

```bash
make test      # build, then run the corpus suites
make build
make inspect
make clean
```

## What is here

| | |
|---|---|
| `src/Host.ts` | the host: `define`, `load`, `activate`, `ready`, `nest` — §6–§8 |
| `src/Ref.ts` | `parseref`, `formatref`, `checkname`, `checktag`, `canonref` — §4 |
| `src/Config.ts` | `normalizeconfig`, `resolveoptions`, `checkshape` — §9 |
| `src/Catalog.ts` | definition registration and shape validation — §10 |
| `src/Depend.ts`, `src/Graph.ts`, `src/Resolve.ts` | requirements, candidates, selection — §11 |
| `src/Point.ts`, `src/Order.ts` | extension points and ordering — §7 |
| `src/Capability.ts`, `src/Version.ts` | `match` and version ranges — §11.1 |
| `src/Env.ts`, `src/Export.ts`, `src/FeatureHost.ts` | `applyenv`, exports, the feature bridge |
| `src/Types.ts` | the shared types, and `PluginError` |
| `test/corpus.ts` | the runner: reads `spec/plugin.json` and dispatches by group |

`test/corpus.ts` reads the **committed artifact**, not the aontu source
— exactly as every other port's runner does. The canonical does not get
a private door into the spec.

## The portability budget

The canonical may not use reflection-backed APIs, `Proxy`, dynamic
property interception, decorators, or meta-level interception of the
host's own operations, and its lifecycle reconciliation must be eager
(AGENTS.md §5). **A canonical that reaches for a JavaScript convenience
is a bill twenty ports pay.**

Nothing here uses any of them. When adding to it, keep it that way: the
cost of removing one at P4 is fourteen ports rewriting around it.

## Status

**All 561 corpus entries pass, across all 19 sections** — `apply`,
`capability`, `config`, `declare`, `depend`, `env`, `error`, `export`,
`graph`, `lifecycle`, `nest`, `order`, `point`, `ref`, `resolve`,
`resource`, `state`, `trace` and `version`.

Sixteen other implementations pass the same corpus: `go`, `python`,
`javascript`, `ruby`, `php`, `perl`, `rust`, `java`, `lua`, `csharp`,
`elixir`, `clojure`, `dart`, `kotlin`, `swift` and `scala`. That is the
point of the corpus — the contract is the same in every language, and
this package is the one it is defined by.

## Install

```bash
npm install @voxgig/plugin
```

**No runtime dependencies.** `voxgig/struct` is the single permitted one
and is not yet needed.
