# voxgig/plugin — haskell

The haskell port of [voxgig/plugin](../README.md). It is a **port**, not
an independent implementation: behaviour is defined by `typescript/`,
and `spec/plugin.json` — the same corpus every port runs — is the
arbiter.

```bash
make build     # ghc --make, -Wall -Werror
make test      # the corpus, all 19 sections
make inspect   # compiler version
make clean
```

**No dependencies, and no cabal file or stack project.** §16 permits
one runtime dependency, `voxgig/struct`, which has no Haskell port, so
`src/Value.hs` is the JSON reader. `make build` is `ghc --make` against
the boot libraries alone, which is the only way to be sure nothing was
pulled in.

**The port is written against GHC 9.4** (base 4.17), and it does not
build clean on 9.8 or later: `-Wx-partial` joins `-Wall` there and
rejects six uses of `head` and `tail`, and base 4.20 exports `foldl'`
from `Prelude`, which makes one import redundant. Under `-Werror` both
fail the build. CI pins the compiler for that reason.

## Layout

| | |
|---|---|
| `src/Value.hs` | the JSON value, and the only parser this port has |
| `src/Defs.hs` | the definition, instance, and host declarations, in one module |
| `src/Types.hs` | `PluginError`, `raise` and the §12 message format |
| `src/*.hs` | the library, one module per §-area |
| `test/Driver.hs` | the driver (DOCS.md §4) and the probe catalog |
| `test/Corpus.hs`, `test/Main.hs` | the runner, which counts entries and failures |

## Using it

The canonical names are camel-cased: `makeHost`, `makeCatalog`,
`parseRef`, `formatRef`, `normalizeConfig`, `resolveOptions`,
`resolveOrder`, `resolveCandidates`, `applyEnv`. The two predicates keep
their canonical spelling, `checkname` and `checktag`. Host and instance
operations are functions over a `Host` or an `Inst`, such as
`hostReady` and `instBindChain`.

```haskell
import Control.Exception (try)
import Catalog
import Defs
import Host
import Types
import Value

main :: IO ()
main = do
  let retry =
        Definition
          { dName = "retry"
          , dShape = VNull
          , dDefine = Just (\i -> instBindChain i "request" (\next arg -> next arg) VNull)
          , dActivate = Nothing
          , dDeactivate = Nothing
          , dClose = Nothing
          , dReconfigure = Nothing
          }
  catalog <- makeCatalog
  catalogAdd catalog retry

  host <-
    makeHost
      noHostOptions
        { oCatalog = Just catalog
        , oPoints = VMap [("request", VMap [("kind", VStr "chain")])]
        , oBases = [("request", return)]
        }

  result <- try (hostReady host "retry$fast")
  case result of
    Right _ -> return ()
    Left err -> putStrLn (peCode err)
```

A chain base is a function, which a `Value` cannot hold, so it rides
beside the point map in `oBases`, keyed by point name.

## Everything that can raise is `IO`

Haskell can throw from pure code, and this port must not. An imprecise
exception fires when its thunk is forced, and the corpus does not merely
assert that a call raises: it asserts what survived a raise
mid-sequence (`resource/unwind`, `lifecycle/fail`). A raise that happens
whenever a consumer happens to look is a different semantics from one
that happens at the call, and laziness would let a port pass the "does
it raise" entries while getting every ordering entry wrong.

So the split is not pure against impure by taste: **a function is `IO`
exactly when it can raise.** `checkname` is pure because it answers a
`Bool`; `parseRef` is `IO` because it raises a `PluginError`.
`resolveCandidates` is pure because nothing in it can fail.

## The mutability is on the instance, not in the value

`Value` is an immutable algebraic type. Every field a transition changes
is an `IORef` on `Inst` or `Host`, so a callback reads its options
through the reference each time. That is why this port needs no
in-place refill of an options map, which the ports with mutable maps
must do so that callbacks closing over the map see new values.

`Defs.hs` holds the definition, instance, and host declarations together
because Haskell modules cannot be mutually recursive without boot files.
Only the declarations live there; the functions stay in `Catalog` and
`Host`.

## What the corpus caught

- **A bad number has to be an error, not a crash.** The Prelude's `read` throws;
  `Value` uses `reads` and reports `bad number`, because §9.5's
  environment values parse as JSON and fall back to a string, and the
  fallback can only catch a reported failure.
- **No regex engine ships with the boot libraries**, and §16 permits no
  second dependency to supply one. `Corpus.regexLite` is a literal
  matcher with optional anchors that **errors** on any metacharacter it
  cannot evaluate, rather than reporting a mismatch it never checked.
- **The `provider` probe carried dead code in the `c/`, `cpp/`, and
  `ocaml/` ports.** It built a capability record from `options.capability`,
  `version`, and `priority` and then dropped it; the canonical
  `provider` reads none of those keys. Checking the canonical rather
  than the nearest port is what kept this one from shipping it, and the
  code is gone from all three.
