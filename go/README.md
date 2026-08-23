# voxgig/plugin — go

The go port of [voxgig/plugin](../README.md). It is a **port**, not an
independent implementation: behaviour is defined by `typescript/`, and
`spec/plugin.json` — the same corpus every port runs — is the arbiter.

```bash
make build     # go build + go vet
make test      # the corpus, all 19 sections
make inspect   # toolchain version
make clean
```

No dependencies. `go.mod` asks for 1.21 and nothing else.

## Layout

| | |
|---|---|
| `plugin/` | the library |
| `test/` | the driver (DOCS.md §4), the corpus runner, and the tests |

## Using it

Go is **tier S** (§10.3): static-only registration. Definitions reach a
host either as an explicit list or through `Catalog.Add` from an
`init()`, and there is no dynamic module loading — `ResolveCandidates`
still answers which module ids a host *would* try, because that is what
the corpus pins and it is the same answer in every language.

```go
catalog, err := plugin.MakeCatalog(plugin.Definition{
    Name: "retry",
    Define: func(i *plugin.Inst) error {
        return i.Bind("request", func(args ...any) any {
            next, _ := args[0].(plugin.BindFn)
            return next(args[1:]...)
        }, 0)
    },
})

host := plugin.MakeHost(plugin.HostOptions{
    Catalog: catalog,
    Points: map[string]plugin.Spec{
        "request": {Kind: plugin.KindChain, Base: transport},
    },
})

_, err = host.Ready("retry$fast")
```

## Two things this port does differently, on purpose

**Errors are returned, not raised.** Every fallible function returns
`error`, and a lifecycle callback returns `error` where the canonical
throws. The corpus compares errors by **code** (§12) and never by
message, so this is invisible to it: `plugin.CodeOf(err)` reads the code
off a `*PluginError`.

The one place it shows through: **a binding cannot raise.** `BindFn`
returns `any`, and a binding that wants to fail returns an `error`
value, which §6.1's collecting hook modes gather.

**One `BindFn` type serves all three point kinds.** A chain's `next` is
simply its first argument, exactly as in the canonical. Three distinct
func types would read better in isolation and cannot be used: the
corpus binds the same probe function to a hook point in one entry and a
provider point in the next.

Both are recorded in [`doc/plan/handover.md`](../doc/plan/handover.md)
§13, along with the three canonical defects writing this port found.
