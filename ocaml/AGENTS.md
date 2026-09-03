# The ocaml port — agent notes

OCaml is a tier-4 language by the LOADER (design §10.3): no dynamic
plugin discovery. It is nothing like `c` in any other respect — it has
closures, exceptions and a garbage collector, so it uses all three and
none of `c`'s scaffolding.

## A MUTABLE value, which is not the obvious choice in ML

`Value.t` holds `ref` cells for lists and maps, and `inst`/`host` are
mutable records. That is deliberate and the corpus forces it: §9.4's
`refill` empties an options map and refills it **in place**, precisely
so a definition's callbacks — which closed over that map at `define` —
read the new values. With an immutable map `refill` is a rebinding the
callbacks never see, and `apply/idempotent` fails.

The persistence ML would prefer is spent where it belongs: in `clone`.

## defs.ml exists because OCaml modules cannot be mutually recursive

A definition's callbacks take an `inst`, an `inst` points at its
`host`, and a `host` holds a `catalog` of definitions. That cycle is
real — it is the same one `c` opens with a forward `typedef struct Inst
Inst;` — and OCaml has no way to spread it across compilation units. So
`defs.ml` holds **only the declarations**, and the functions over them
stay in `catalog.ml` and `host.ml`.

## No ocamlfind, no dune, no opam

`make build` runs `ocamlopt` over an explicit module list. **That list
is the dependency order**, written down, because there is no separate
link step to sort it out. Warnings are errors (`-warn-error +a`).

Nothing outside the compiler distribution is linked — not even `Str`,
and see below for why.

## What the corpus caught

- **`Str` is a third regex dialect, so the port does not use it.** The
  corpus's `match` patterns are JavaScript `/.../` literals; `Str`
  spells groups `\(` and has its own anchor rules. `cpp` was bitten by
  exactly this class of assumption — it copied `c`'s POSIX-ERE call and
  four entries failed on messages that plainly matched. `test/corpus.ml`
  uses a `regexlite`, the same literal-with-anchors matcher
  `lua/test/corpus.lua` has, which **errors** on any metacharacter it
  cannot evaluate rather than quietly reporting a mismatch.
- **`float_of_string` raising is not the same as a parse error.**
  §9.5's env values "parse as JSON, falling back to string", and the
  fallback can only catch a `Parse_error`. A bare `-`, or a truncated
  `1e`, reached the number branch and killed the run with
  `Failure "float_of_string"`. `Value.parse` now uses
  `float_of_string_opt` and reports a bad number the way it reports
  every other malformation.
