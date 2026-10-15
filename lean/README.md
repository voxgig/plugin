# voxgig/plugin — lean

The lean port of [voxgig/plugin](../README.md). It is a **port**, not
an independent implementation: behaviour is defined by `typescript/`,
and `spec/plugin.json` — the same corpus every port runs — is the
arbiter.

```bash
make build     # lake build, failing on lake's own status
make test      # the corpus, all 19 sections
make inspect   # toolchain version
make clean
```

**No dependencies.** `lakefile.lean` declares no `require`, so `lake build`
never touches the network. §16 permits one runtime dependency,
`voxgig/struct`, which has no Lean port, so `src/Plugin/Value.lean` is
the JSON reader. The toolchain is pinned in `lean-toolchain`, and the
port's `Makefile` puts `~/.elan/bin` on `PATH` for a shell that does
not.

## Layout

| | |
|---|---|
| `src/Plugin.lean` | imports every library module, so `lake build` compiles all of them |
| `src/Plugin/Value.lean` | the JSON value, and the only parser this port has |
| `src/Plugin/Defs.lean` | `Definition`, `InstApi`, `HostApi` and the host state |
| `src/Plugin/Machine.lean` | the lifecycle state machine |
| `src/Plugin/*.lean` | the rest of the library, one module per §-area |
| `test/Driver.lean` | the driver (DOCS.md §4) and the probe catalog |
| `test/Corpus.lean`, `test/Run.lean` | the runner, which counts entries and failures |

## Using it

Everything is in `namespace Plugin`. The canonical names are
camel-cased: `makeHost`, `makeCatalog`, `parseRef`, `formatRef`,
`normalizeConfig`, `resolveOptions`, `resolveOrder`,
`resolveCandidates`, `applyEnv`. The two predicates keep their canonical
spelling, `checkname` and `checktag`. Anything that can fail runs in
`PluginM`, which is `ExceptT PluginError IO`.

```lean
import Plugin
open Plugin

def retry : Definition :=
  { name := "retry"
    define := some fun i => i.bindChain "request" (fun next arg => next arg) .null }

def start : PluginM Unit := do
  let catalog ← makeCatalog
  let host ← makeHost
    { catalog := some catalog
      points := Value.vmap.set "request" (Value.vmap.set "kind" (.str "chain"))
      bases := [("request", fun a => pure a)] }
  hostDefine host retry
  let _ ← hostReady host "retry$fast"

def main : IO Unit := do
  match ← start.run with
  | .ok () => pure ()
  | .error e => IO.println e.code
```

A chain base is a function, which a `Value` cannot hold, so it rides
beside the point map in `bases`, keyed by point name.

## A definition gets an `InstApi`, not the instance

Every other port hands a callback the instance itself: the instance
points back at its host, and the host holds a catalog of definitions.
Lean's kernel refuses that cycle. A `Definition` holding
`Inst → PluginM Unit` puts `Inst` in a negative position while `Inst`
holds the `Definition` back, and the kernel rejects the type with *"has
a non positive occurrence of the datatypes being declared"*. That is the
logic refusing a type whose inhabitants could encode a fixed point, not
a quirk to route around with `unsafe`.

So a callback receives `InstApi`, an explicit record of closures, and
the cycle never forms. The shape is not a compromise: §6 says a plugin
never mutates the host but declares bindings and captures resources
through a small API, and `InstApi` is that API written down.

One consequence shows. `nest` takes no options and returns a `HostApi`,
so the inner host shares the outer host's catalog and points. §10.1 already
permits a shared catalog, and the driver's nested host wants the outer
host's probes, so the corpus cannot tell the difference.

## What is `partial`, and why

Most of the port is structural recursion and needs no termination
argument. The `mutual` block in `Machine.lean` is `partial`:
`reconcile` settles by reaching a fixed point under an explicit round
cap, and `cascade` walks the consumer graph recursively behind a
`seen` set. Both terminate for semantic reasons rather than structural ones,
and the corpus checks them instead of a proof. `HostApi` and `InstApi`
derive `Inhabited` because Lean compiles a `partial` definition only
when it knows the result type is non-empty.

## The build trap

Lake builds only what a target's import graph reaches. A module no
target imports is never compiled, so it reports no errors and reads
exactly like a module that compiled cleanly; fifteen modules here once
sat green that way with syntax errors in every one. Three guards close
it, and each one matters: both libraries are `@[default_target]`, the
test library's `roots` names its modules, and `src/Plugin.lean` imports
the whole library. `make build` also tests lake's exit status directly,
since a pipeline through `grep` once hid a failed build and ran a stale
binary.

## What Lean does not have

- **`String.toFloat?`.** The JSON reader parses the number grammar
  itself and answers `none` on a bad number, which is what §9.5's
  parse-or-string fallback needs.
- **A regex engine.** `Corpus.regexLite` is a literal matcher with
  optional anchors that **errors** on any metacharacter it cannot
  evaluate, rather than reporting a mismatch it never checked.
- **A `Float.toString` that agrees with the other ports.** It prints six
  decimals, so `1.5` renders as `1.500000`; `Value.numStr` trims the
  trailing zeros.

`at`, `prefix`, `from` and `instance` are keywords, so the names that
would use them are spelled `idx`, `pfx`, `froms` and `instMap`.
