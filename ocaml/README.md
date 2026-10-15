# voxgig/plugin — ocaml

The ocaml port of [voxgig/plugin](../README.md). It is a **port**, not
an independent implementation: behaviour is defined by `typescript/`,
and `spec/plugin.json` — the same corpus every port runs — is the
arbiter.

```bash
make build     # ocamlopt over the module list, warnings as errors
make test      # the corpus, all 19 sections
make inspect   # compiler version
make clean
```

**No dependencies, and no `ocamlfind`, `dune` or `opam`.** §16 permits
one runtime dependency, `voxgig/struct`, which has no ocaml port, so
`src/value.ml` is the JSON reader. The build runs the compiler alone and
links nothing outside the distribution, not even `Str`. The module list
in the port's `Makefile` is the dependency order, written down, because
nothing else sorts it.

## Layout

| | |
|---|---|
| `src/value.ml` | the JSON value, and the only parser this port has |
| `src/types.ml` | `Plugin_error`, `fail` and the §12 message format |
| `src/defs.ml` | the definition, instance, and host types, in one module |
| `src/*.ml` | the rest of the library, one module per §-area |
| `test/driver.ml` | the driver (DOCS.md §4) and the probe catalog |
| `test/corpus.ml`, `test/run.ml` | the runner, which counts entries and failures |

## Using it

The canonical names keep their canonical spelling: `Host.makehost`,
`Catalog.makecatalog`, `Ref.parseref`, `Config.normalizeconfig`,
`Env.applyenv` and the rest. Host and instance operations are functions
in `Host`, such as `Host.ready` and `Host.bindchain`. A failure raises
`Types.Plugin_error`, carrying the §12 `code`.

```ocaml
open Defs

let retry =
  { dname = "retry"; shape = Value.vnull;
    define = Some (fun i ->
      Host.bindchain i "request" (fun next arg -> next arg) Value.vnull);
    activate = None; deactivate = None; close = None; reconfigure = None }

let () =
  let catalog = Catalog.makecatalog () in
  Catalog.add catalog retry;

  let request = Value.vmap () in
  Value.set request "kind" (Value.vstr "chain");
  let points = Value.vmap () in
  Value.set points "request" request;

  let host =
    Host.makehost
      { nohostoptions with
        ocatalog = Some catalog; opoints = points;
        obases = [ ("request", fun arg -> arg) ] }
  in
  try ignore (Host.ready host "retry$fast")
  with Types.Plugin_error e -> print_endline e.Types.code
```

A chain base is a function, which a `Value.t` cannot hold, so it rides
beside the point map in `obases`, keyed by point name.

## A mutable value, which is not the obvious choice in ML

`Value.t` holds `ref` cells for its lists and maps, and the instance and
host are mutable records. The corpus forces it: §9.4's refill empties an
options map and fills it again **in place**, so that a definition's
callbacks, which closed over that map at `define`, read the new values.
With an immutable map the refill is a rebinding the callbacks never see,
and `apply/idempotent` fails. The persistence ML would prefer is spent
where it belongs, in `clone`.

`defs.ml` holds the definition, instance, and host types together
because ocaml modules cannot be mutually recursive across compilation
units, and a definition's callbacks take an instance, which points at
its host, which holds a catalog of definitions. Only the declarations
live there; the functions stay in `catalog.ml` and `host.ml`.

## What the corpus caught

- **`Str` is a third regex dialect, so the port does not use it.** The
  corpus's `match` patterns are JavaScript `/.../` literals, and `Str`
  spells groups `\(` and has its own anchor rules. `test/corpus.ml`
  carries `regexlite`, a literal matcher with optional anchors that
  **errors** on any metacharacter it cannot evaluate, rather than
  reporting a mismatch it never checked.
- **`float_of_string` raising is not a parse error.** §9.5's environment
  values parse as JSON and fall back to a string, and the fallback can
  only catch a `Parse_error`. A bare `-`, or a truncated `1e`, reached
  the number branch and ended the run with `Failure "float_of_string"`.
  `Value.parse` uses `float_of_string_opt` and reports a bad number the
  way it reports every other malformation.
