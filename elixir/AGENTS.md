# AGENTS.md — the elixir port

Read [`../AGENTS.md`](../AGENTS.md) first. The prime directives there are
not negotiable here: **TypeScript is canonical**, **the corpus is the
contract**, **change canonical first then propagate**, and **never weaken
the corpus to make this port pass**.

**THIS PORT CLAIMS THREAD SAFETY** — one of two that do (`go` is the
other), per [`../docs/ADR.md`](../docs/ADR.md) ADR-2. It gets it
structurally rather than by locking: host state lives in an `Agent`, so
the BEAM serialises every read and write. The care needed is that a
definition's `activate` is never invoked from inside `Agent.update` —
`host.ex` says why. §14's guarantee is a per-port property rather than a
repo-wide one, so a claim here is a commitment this port keeps and not
an inherited default.

## The rule that matters most here

**A disagreement with the corpus is this port's bug — until you have
established it is the canonical's.** Both happen;
[`../doc/plan/handover.md`](../doc/plan/handover.md) §13 has the running
list.

## Elixir-specific traps

**The host is an `Agent`, and callbacks MUST run outside it.** Every
`Host` function runs in the caller's process and reaches the agent only
through `read/2`, `write/2` and `swap/2`. Never call a definition's
callback from inside `Agent.get_and_update` — §5.2 requires a re-entrant
transition to raise `plugin_reentrant`, and a process waiting on itself
raises nothing.

**Never write back a whole snapshot.** A callback mutates the registry
while it runs (`Inst.export`, `Inst.bind`, `Inst.state_put`), so the entry
you read before running one is stale afterwards. Every internal function
here takes a **ref**, not an entry, and every write is targeted
(`entry_update/3`, `setfield/4`). Reintroducing a read-modify-write over
the whole state would silently drop whatever the callback wrote.

**An exception raised inside an agent function kills the agent AND the
linked caller.** So validation happens before the write, not inside it —
see `catalog_add/2`, which calls `Catalog.add/2` in the caller and stores
the result.

**Scope entries carry an id and an `open` delta.** Releasing pops by id, so
an early release and the unwind that follows it cannot double-count; and a
nested host is registered with `open: 0`, because creating one must leave
`open` where it found it.

**`Catalog` is a value, not an object.** `add/2` returns the new catalog.
`Host.catalog_add/2` is the only path that mutates one, and it exists
because the driver's §6.5 nest case extends a live host's catalog.

**Bindings are arity two, `(next, arg)`, hook and chain alike.** Elixir has
no optional arguments on anonymous functions and no variadic call, so a
port that gave hooks arity one would need `Point` to know which kind of
point it is holding — and the kind is the HOST's property. `next` is nil
for a hook.

**`fn` is a reserved word but a valid map key.** Bindings are
`%{ref:, point:, fn:, band:}` and `b.fn.(next, arg)` is how they are
called. It parses; it just reads oddly the first time.

What elixir gives free, and what the other ports pay for: `%{}` is not
`[]`; `Map.has_key?/2` separates an authored null from absence with no
sentinel; `true == 1` and `"1" == 1` are both false, so `match` needs no
type guard; `Enum.sort_by/2` is stable for the `<=` comparator a key
function builds, so `Types.stable_sort_by/2` can delegate to it — the name
is kept so one place states that stability is required.

## What the corpus cannot currently distinguish

> **Three of the mutations listed below are no longer survivors.** Shape
> validation at catalog registration (`declare/shape`, `declare/register`),
> `providersof` comparing refs uncanonicalized (`depend/byref`,
> `depend/cycle#through-refs-noncanonical`, `graph/resolve#byref`) and a
> nested host counted as an open resource (`nest/open`) are all pinned now,
> and each mutation fails its group. Anything else in this list still
> stands. `doc/plan/handover.md` §18 has the account — including that
> closing them turned up four defects the corpus could not previously see.

Three mutations survive:

- **`Inst.nest/2` counting the inner host as an open resource.** Nothing in
  `nest` asserts `open` while an inner host is live.
- **`providersof` without `canon`** — the same gap php, perl, rust, java,
  lua and csharp each found independently.
- **`Catalog.add/2` skipping `check_shape`.** §10.1 puts shape validation
  at REGISTRATION so a malformed shape fails once and in the same place
  everywhere, but no corpus definition carries a `shape` — so the check
  is reachable only through `resolve_options`, and every port could defer
  it and stay green. This one is new here; the register has it.

Two more turned out to be **non-mutations**, and are worth knowing so
nobody re-derives them: an empty `after: []` reading as a stated constraint
changes nothing (`order_targets/2` yields no targets either way), and
swapping `reconcile`'s loss and gain passes converges identically on every
corpus entry.

None is a licence to relax the code.

## Local shape

- One module per §-area under `lib/voxgig_plugin/`; `lib/voxgig_plugin.ex`
  delegates so the canonical surface is visible in one place.
- `Host` is the agent; `Inst` is a `{host, ref}` handle; an `entry` is a
  plain string-keyed map (never a corpus value).
- Internal shapes use ATOM keys and say so in their docs — `Order`'s
  `%{ref:, pos:, order:}`, `Point`'s bindings, `Export`'s `%{ref:, key:,
  value:}`, `Depend`'s nodes. `Capability`'s candidates use string keys,
  because `provides` is corpus data.
- `make build` is `elixirc --warnings-as-errors`. That is the point of it:
  elixir warns rather than fails on an unused variable, an unreachable
  clause, or a call to a function that does not exist.

## Adding a corpus section

Add it to `sections/0` in `test/run.exs`. The runner fails on a *group*
with no subject, and its coverage block fails if a whole SECTION exists in
the corpus and nothing runs it. A section or group silently not run is
worse than a failing one.
