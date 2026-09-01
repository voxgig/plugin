# voxgig/plugin — elixir

The elixir port of [voxgig/plugin](../README.md). It is a **port**, not an
independent implementation: behaviour is defined by `typescript/`, and
`spec/plugin.json` — the same corpus every port runs — is the arbiter.

```bash
make build     # elixirc --warnings-as-errors
make test      # the corpus, all 19 sections
make inspect   # elixir --version
make clean
```

Elixir 1.14 on OTP 25. **No mix project and no `deps` list**: §16 permits
one runtime dependency and elixir has no port of it, so the JSON parser is
`lib/voxgig_plugin/json.ex` and the suite is a plain script rather than
ExUnit. A `mix.exs` would be a dependency file every embedding host
inherits, for a library that needs nothing.

## Layout

| | |
|---|---|
| `lib/voxgig_plugin/types.ex` | the value model, the error type, the JSON writer |
| `lib/voxgig_plugin/json.ex` | the parser |
| `lib/voxgig_plugin/*.ex` | the library, one module per §-area |
| `lib/voxgig_plugin/host.ex` | the state machine — the one mutable thing here |
| `lib/voxgig_plugin.ex` | the public surface — eleven delegations, nothing else |
| `test/` | the driver (DOCS.md §4), the corpus runner, and `run.exs` |

## Using it

```elixir
alias Voxgig.Plugin
alias Voxgig.Plugin.Host
alias Voxgig.Plugin.Inst

host =
  Plugin.make_host(%{
    "catalog" =>
      Plugin.make_catalog([
        %{"name" => "retry",
          "define" => fn i -> Inst.bind(i, "request", fn next, req -> next.(req) end) end}
      ]),
    "points" => %{"request" => %{"kind" => "chain", "base" => transport}}
  })

Host.ready(host, "retry$fast")
```

Definitions are plain maps with function values, which is what makes a
catalog a data structure a document could produce. Errors are a
`Voxgig.Plugin.Error` exception carrying the §12 `code` the corpus compares
by, whose `message` is the pinned `plugin/<code>: <text> [k=v]` format.

## What elixir makes easy, and the one thing it does not

Almost every trap the dynamic ports document is absent here. `%{}` and `[]`
are different types, so the empty-map-versus-empty-list distinction php
cannot draw is free. Maps hold `nil` as a value, so `Map.has_key?/2`
separates an authored null from an absent key without a sentinel — lua
needs one and perl needs another. `true == 1` and `"1" == 1` are both
false, so the type-strict `match` rule needs no guard. `Enum.sort_by/2` is
stable for the `<=` comparator a key function builds, so §7's fall-through
to `pos` lands where the canonical's does.

The one thing elixir does not give is **mutation**, and the host is a state
machine. So the host is an `Agent`, and two properties of that choice are
worth stating because neither is visible from a green corpus:

**Callbacks run outside the agent.** Every function in `Host` executes in
the CALLER's process and touches the agent only for short reads and
targeted writes; a definition's `activate` is never invoked from inside
`Agent.update`. Running one there would deadlock the moment it called back
into its own host — which §5.2 requires to answer `plugin_reentrant`, an
answer a process waiting on itself cannot give.

**The agent is not a concurrency boundary.** It serializes individual reads
and writes and nothing larger. Two processes calling `activate` at once
would interleave transitions, which §5.2 forbids and which no process
discipline here would fix, because the interleaving is in the caller's
control flow. The contract is sequential use; the agent supplies the
mutable cell, not the ordering.

One happy consequence: the canonical's **"REFILL rather than REBIND"**
(§9.6) is a problem this port does not have. The canonical must empty and
refill the options map because a definition closes over the object it was
handed at `define`; here `Inst` is a `{host, ref}` handle and
`Inst.options/1` reads the entry, so `apply` simply replaces the map.

## What the corpus cannot see here

> **Three of these are no longer invisible.** Shape validation at catalog
> registration, `providersof` comparing refs uncanonicalized, and a nested
> host counted as an open resource are now pinned by `declare/shape`,
> `declare/register`, `depend/byref`, `depend/cycle`, `graph/resolve` and
> `nest/open`. Anything else below still stands.

Mutation testing: 22 mutations, **20 caught**. The survivors:

- **A nested host counted as an open resource.** `Inst.nest/2` registers
  the inner host's teardown in the outer instance's scope but does NOT
  increment `open`, and nothing in `nest` asserts `open` while an inner
  host is live. Every port has the same free choice.
- **`providersof` comparing refs uncanonicalized** — the same gap php,
  perl, rust, java, lua and csharp each found independently.
- **Shape validation skipped at catalog registration.** §10.1 puts it
  there so a malformed shape "fails once, and in the same place
  everywhere", but no corpus definition carries a `shape`, so every port
  could defer it to `resolve_options` and stay green.

None is a licence to relax the code. Two further mutations turned out to be
**non-mutations** and are recorded as such: an empty `after: []` reading as
a stated constraint changes nothing, because `order_targets/2` returns no
targets for it either way; and swapping `reconcile`'s two passes converges
to the same fixed point on every entry the corpus has.
