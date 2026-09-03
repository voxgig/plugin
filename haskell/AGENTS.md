# The haskell port — agent notes

Haskell is tier-4 by the LOADER (design §10.3): no dynamic plugin
discovery. Everything else about it is unlike `c` — closures,
exceptions, garbage collection — so it uses all three and none of `c`'s
scaffolding.

## Everything that can raise is IO, and that is the one big decision

Haskell *can* `throw` from pure code. **It must not here.** An
imprecise exception fires when the thunk is FORCED, and the corpus does
not merely assert that a call raises — it asserts **what survived a
raise mid-sequence** (`resource/unwind`, `lifecycle/fail`). A raise
that happens whenever the consumer happens to look is a different
semantics from one that happens at the call, and laziness would let a
port pass the "does it raise" entries while getting every ordering
entry wrong for reasons no reader could see.

So the split is not pure-vs-impure by taste: **a function is `IO`
exactly when it can raise.** `checkname` is pure because it answers
`Bool`; `parseRef` is `IO` because it raises. `Resolve` is pure
throughout because nothing in it can fail.

## The mutability is on the instance, not inside the Value

`Value` is an immutable ADT. Every field a transition changes is an
`IORef` on `Inst` or `Host`.

That is why **this port needs no in-place `refill`**. The other ports
must empty an options map and fill it again so callbacks that closed
over it see new values; here a callback reads `iOptions` through the
ref each time, so `writeIORef` is the same observation. The rule is
still written down in `hostDeclare`, because the ports should read
alike.

## Defs.hs exists because Haskell modules cannot be mutually recursive

Without `.hs-boot` files, the definition/instance/host cycle has to live
in one module — the same cycle `c` opens with a forward `typedef` and
`ocaml` gathers into `defs.ml`. Only the **declarations** are there; the
functions stay in `Catalog` and `Host`.

## No cabal file, no stack project

`make build` is `ghc --make` against the boot libraries alone, which is
the only way to be sure nothing was pulled in. `-Wall -Werror`.

## What the corpus caught

- **The `provider` probe was carrying dead code, in four ports.** `c`
  synthesized a capability record from `options.capability`, `version`
  and `priority` and then dropped it on the floor; `cpp` and `ocaml`
  copied it, and this port nearly registered it — which would have been
  a real divergence. The canonical `provider` reads none of those three
  keys and no corpus entry sets them. Deleted everywhere. **The lesson
  is the porting one: check the canonical, not the nearest port.**
- **A bad number must be an error, not a crash.** GHC's `read` throws;
  `Value.pNumber` uses `reads` and reports `"bad number"`, because
  §9.5's env values "parse as JSON, falling back to string" and the
  fallback can only catch a reported failure. The `ocaml` port hit this
  first with `float_of_string`.
- **No regex engine in the boot libraries**, and §16 permits no second
  dependency to supply one. `Corpus.regexLite` is the same
  literal-with-anchors matcher `lua` has, which **errors** on any
  metacharacter it cannot evaluate rather than quietly reporting a
  mismatch.
