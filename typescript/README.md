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
| `src/Ref.ts` | `parseref`, `formatref`, `checkname`, `checktag`, `canonref` — §4 |
| `src/Config.ts` | `normalizeconfig`, `resolveoptions`, `checkshape` — §9 |
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

P1. The two **pure** sections run green — `ref` (97 entries) and
`config` (86). `lifecycle` and `order` are driver sections and need the
host, which is the next piece.
