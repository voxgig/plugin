# Voxgig Plugin — Comprehensive Guide

> One plugin architecture, defined once and ported to every language.

This is the in-depth, language-neutral companion to the
[`README.md`](./README.md) overview, and it is **also the driver
contract**: the probe behaviours it specifies are as much a part of the
conformance corpus as the runner is (design §15.2).

---

## Status: P2 — complete

Every section is written. The driver contract (§4) is the one still
called a draft, and draft here means COVERAGE rather than stability: it
specifies what the nineteen corpus sections need and is meant to be
relied on. A future phase extends it; it does not rewrite it.

| section | state |
|---|---|
| 1. Tutorial | written |
| 2. How-to guides | written |
| 3. Reference — the canonical API | written, extended per phase |
| 4. The driver contract | written (draft coverage) |
| 5. Explanation | written |

[`docs/design/plugin.md`](./docs/design/plugin.md) remains the authority
on anything these disagree about, and the corpus is the authority on
anything the design leaves open.

---

## 1. Tutorial

A first plugin, end to end.

```ts
import { makehost, makecatalog } from '@voxgig/plugin'

// 1. The host declares its extension points. A PLUGIN NEVER MUTATES
//    THE HOST — that inversion is what makes deactivation possible.
const host = makehost({
  catalog: makecatalog([{
    name: 'retry',
    define: (inst) => {
      inst.state.attempts = 0
      inst.bind('request', (next, req) => {
        inst.state.attempts += 1
        return next(req)
      })
      inst.export('attempts', () => inst.state.attempts)
    },
    activate: (inst) => {
      // Anything acquired here is released automatically on deactivate,
      // in reverse. You do not keep a ledger.
      inst.acquire()
    },
  }]),
  points: { request: { kind: 'chain', base: (req) => req } },
})

// 2. Declaring costs nothing — no module loads, no callback runs.
host.declare('retry$fast')
host.list()                      // { 'retry$fast': 'declared' }

// 3. `ready` walks the whole staircase in one call.
host.ready('retry$fast')
host.list()                      // { 'retry$fast': 'live' }

// 4. The binding is now in the chain.
host.call('request', 'hello')
host.order('request')            // ['retry$fast']

// 5. And away again. The binding is removed and the resource released;
//    the plugin's STATE survives, because a rate limiter reactivated
//    ten seconds later must not have forgotten its window.
host.deactivate('retry$fast')
host.order('request')            // []
host.list()                      // { 'retry$fast': 'loaded' }
```

**Two instances of one definition** is the headline feature, and costs
nothing extra:

```ts
host.ready('retry$fast')
host.ready('retry$slow')
host.order('request')            // ['retry$fast', 'retry$slow']
```

The name is always the definition and the tag says which one, so a
registry groups by the part before the `$` and a config file's key is
its own documentation.


## 2. How-to guides

### Order two plugins relative to each other

Prefer a **constraint**, which says what you mean:

```json
{ "instance": { "audit": { "order": { "after": "auth" } } } }
```

Reach for a **band** only for a genuine cross-cutting layer — "the base
transport wrapper is band 100" — said once by the host instead of by
every plugin. Constraints beat bands in the sort precisely so the
correct tool wins when both are present.

> **A band chosen by trial and error to fix an ordering bug is a bug
> wearing a number.** Bands are OSGi start levels and carry the same
> hazard: bump the number until it works, ship it, and leave a system
> whose startup order is a pile of magic constants nobody can safely
> change.

### Depend on something

Depend on a **capability**, not a ref — you need something that can do
the job, and which instance is doing it is exactly the configuration
detail your plugin must not care about.

```ts
inst.provides({ name: 'store', version: '2.3', attrs: { durable: true } })
```
```json
{ "requires": [{ "name": "store", "range": "2.1", "match": { "durable": true } }] }
```

If no provider is live yet your instance sits in `pending`, and the host
activates it the moment one arrives. **Activation is a standing request,
not a one-shot event**, so you never poll and never retry.

Write `range: '2.1'` if you merely *call* the store. Write `~2.1` if you
*implement* it for someone else to call — adding a method to an
interface is a minor bump that breaks every provider and no consumer.

### Hold a resource

Acquire in `activate` and forget about it:

```ts
activate: (inst) => {
  const sock = net.connect(inst.options.addr)
  inst.release(() => sock.destroy())
}
```

The scope unwinds in reverse on `deactivate`, on a failed partial
activation, and on host close. **You cannot forget to release what you
never registered.**

### Substitute rather than wrap

Bind innermost and do not call `next`:

```ts
inst.bind('request', (next, req) => myOwnTransport(req))
```

The host's base stays reachable, the substitution is visible in
`host.order(point)` like every other link, and nothing needs a declared
"this one is a base" role.

### Turn something off in production without a deploy

```
VOXGIG_PLUGIN_INACTIVE=stripe$test
```

`INACTIVE` wins over everything. If the ref collides with another in the
environment encoding the host names both — at startup, not when the
variable is first read.

### Port to a new language

1. `parseref`, `formatref`, `checkname`, `checktag` — pass `ref`. It is
   the first section a port passes and needs no host.
2. `normalizeconfig`, `resolveoptions` — pass `config`.
3. The other pure sections: `env`, `version`, `capability`, `graph`,
   `resolve`. Still no host.
4. The driver (§4), then the driver sections.

**Do not skip an entry you cannot pass.** A divergence is a thing to
report, not a case to filter — filtering inverts the one mechanism
keeping twenty implementations honest.


## 3. Reference

The canonical surface `make parity` checks. Everything else is a method
on the host or the instance — small on purpose (§19), because a library
that grows a public entry point per feature is one twenty ports pay for
twice.

| | |
|---|---|
| `parseref(str)` | `stripe$test` → `{name, tag}`. Canonicalizing; splits on the FIRST `$`. |
| `formatref(name, tag)` | The pair → the written form. An empty tag never writes the separator. |
| `checkname(str)` | `^[a-zA-Z@][a-zA-Z0-9.~_\-/]*$`, max 1024. |
| `checktag(str)` | `^[a-zA-Z0-9.~_-]+$`, max 1024, or empty. A tag may start with a digit; a name may not. |
| `normalizeconfig({doc, profile?, keys?, reserved?})` | Structure and entry keys. **Does not merge options.** |
| `resolveoptions({ref, shape?, …})` | §9.3's ten levels, honouring the shape's `$MERGE`. |
| `resolveorder(bindings, pin?)` | Constraints, then bands, then `pos`. |
| `resolvecandidates(name, sources?)` | Name → module ids, in order. A scoped name resolves verbatim only. |
| `applyenv({env, refs, reserved?})` | `VOXGIG_PLUGIN_*`. Needs the ref set: the encoding is lossy. |
| `makehost(options?)` | The host. |
| `makecatalog(defs?)` | The definition registry. Option shapes are validated **here**. |

**`normalizeconfig` does not merge options, and cannot.** It merges the
entry keys (`active`, `start`, `order`) and leaves option data as
`optionlayers` — levels 3–6 present, in ladder order. §9.4 makes merge
behaviour a property of the definition's option *shape*, which
normalization has never seen; flattening the layers would make
`$MERGE: append` unimplementable at load time.

### The host

`declare` `load` `activate` `deactivate` `unload` `ready` `apply`
`options` `close` — the lifecycle. `emit` `call` `provider` `shadowed`
`order` — the points. `list` `instance` `exports` `capability` `trace` —
observation, and **none of it advances the state**.

### The instance

`bind(point, fn)` `export(key, value)` `provides(cap)` `acquire()`
`release(fn)` `position(point)` `nest(options?)`, plus `ref` `name`
`tag` `options` `state`.

### Errors

```
plugin/<code>: <text> [<key>=<value> …]
```

Fields appear in a fixed order — `host`, `ref`, `name`, `tag`, `point`,
`key`, `capability`, `range`, `version`, `match`, `candidates`, `cycle`,
`holders`, `refs`, `path`, `cause` — omitting those that do not apply,
and rendered as compact JSON so a value containing a space or a bracket
cannot break a parser.

**Compare by code, never by wording.** A port's language is its own
business; pinning the words would make every translation a corpus
change. The *format* is what makes a log searchable across twenty
languages.


## 4. The driver contract

**P1, in draft. This one has a consumer waiting.**

Design §15.3 marks `lifecycle`, `order` and eleven other sections as
*driver* rather than pure data. A port cannot run them from corpus files
alone: it needs the probe catalog, the command vocabulary and the
canonical observable, and none of those belong in the corpus. They are
here.

voxgig/station is owed `lifecycle` and `order` before P1 exits
([the plan](https://github.com/voxgig/station/blob/main/docs/design/station-and-plugin-plan.md)
§3, C2), and shipping them without this contract would hand its other
fifteen ports two suites they could each implement differently — which
is precisely the drift an early corpus exists to prevent.

**Draft status is about coverage, not stability.** What is written below
is what `lifecycle` and `order` need, and it is meant to be relied on.
P2 extends it for the remaining driver sections; it does not rewrite it.

### 4.1 How a driver entry runs

A driver entry carries **`cmd`**, a list of commands, in place of the
`in`/`args` a pure entry uses. The driver:

1. builds a fresh host,
2. runs each command in order,
3. stops at the first command that raises, and
4. returns **one observable map** (§4.4).

`out` compares against that whole map; `match` asserts on part of it;
`err` matches the code of the raise that stopped the run. `err` beside
`out` is invalid, exactly as for a pure entry.

**A command may carry `catch: true`, and §5.2 forces it.** That section's
central claim is that a failed instance *remains registered and
inspectable* — "the point is that a failed plugin must be visible, not
vanished" — and a run that stops at the raise can never observe it. A
command marked `catch` records its raise and the run continues, so the
observable afterwards shows `failed` in `status` and whatever the scope
unwound in `open`. Without it the corpus could pin that activation
raises, or that the instance survives, but never both.

A command is a **map with a `do` key** naming the verb, plus that verb's
own keys:

```json
{ "cmd": [
    { "do": "define", "name": "probe" },
    { "do": "load",   "ref": "probe$a" },
    { "do": "activate", "ref": "probe$a" }
] }
```

A map rather than a positional list, because the verbs do not share an
argument shape and a positional form would make every optional argument
a counting exercise in twenty languages.

### 4.2 The command vocabulary

**Seventeen verbs.** Design §15.2 lists sixteen and omits `ready`,
which §5.1 defines and §15.3 explicitly requires the `declare` section
to pin ("`ready` walking the staircase"). The list is incomplete
against the design's own section table rather than deliberately
excluding it, so the vocabulary carries it and
[`doc/plan/handover.md`](./doc/plan/handover.md) §6 records the
correction owed to §15.2.

Every port implements all of them; a section that never uses one still
needs it present, because the next section will.

| `do` | keys | effect |
|---|---|---|
| `host` | `reserved?`, `keys?`, `defaults?`, `profile?`, `points?` | rebuild the host with these construction options, discarding the current one. `points` declares extension points and their `kind`/`pin` (§7). Only valid as the **first** command. |
| `define` | `name`, `probe?`, `shape?` | register a definition in the catalog. `probe` names the catalog entry (§4.3); default is `probe`. |
| `load` | `ref`, `options?`, `order?`, `definition?` | declare if absent, then load. `order` is the instance's ordering block (§4.4); `definition` names the catalog entry when it differs from the ref's name. |
| `ready` | `ref` | run the whole forward path in one call (§5.1) |
| `activate` | `ref` | `loaded` → `live`, or `pending` |
| `deactivate` | `ref` | → `loaded` |
| `unload` | `ref` | → absent |
| `apply` | `doc`, `profile?` | apply a declarative document (§9.6) |
| `options` | `ref`, `patch` | runtime patch at the top of the ladder |
| `call` | `ref`, `method?`, `args?` | invoke a probe's own method; the value becomes `result` |
| `emit` | `point`, `arg?` | fire a hook point; every live binding runs in resolved order |
| `provider` | `point`, `arg?` | invoke a provider point; the winner's value becomes `result` |
| `export` | `key?` | read the export map, or one key |
| `order` | `point?` | the resolved order; the value becomes `result` |
| `list` | — | the status map; the value becomes `result` |
| `env` | `vars` | set `VOXGIG_PLUGIN_*` for subsequent commands |
| `close` | — | tear the host down, unwinding every instance |

Any command may additionally carry **`catch: true`** (§4.1): its raise
is recorded and the run continues, which is the only way to observe a
`failed` instance at all.

A command naming a ref that does not exist, or a verb that does not
apply in the instance's current state, raises the §12 code for that
case. It does **not** silently no-op — except where §5.2 makes a
transition explicitly idempotent, and those cases are pinned in
`lifecycle` rather than left to the reader.

### 4.3 The probe catalog

Six definitions, implemented identically in every port. **Their
behaviour is as much the contract as the runner is**, and this is where
twenty implementations of `noisy` are made to fail at the same callback
in the same way.

| probe | behaviour |
|---|---|
| `probe` | The workhorse. Records every callback it receives into the log, binds one hook point (`p`), wraps one chain point (`c`), holds an integer counter in its state, and **acquires exactly one synthetic resource per activation**. |
| `noisy` | Fails on demand. `options.fail` names the callback that raises — `define`, `activate`, `deactivate` or `close` — and `options.code` the error code. Everything else is `probe`. |
| `greedy` | Acquires `options.acquire` resources on activation and releases `options.release` of them explicitly, so the difference is what the instance scope must unwind (§8.3). |
| `dep` | Declares requirements. `options.requires` is a list of refs or capability names, `options.optional` those that are optional rather than mandatory. |
| `provider` | Binds a provider point named by `options.point`, returning `options.value`. `options.version` and `options.priority` feed the selection rank. |
| `slow` | Where the language has async, every callback yields once before completing; where it does not, it is `probe`. Exists to prove the lifecycle settles **eagerly** — a transition runs the state machine to a fixed point rather than suspending on a promise (§18's portability budget). |

Every probe records its callbacks into the shared log, so a `lifecycle`
entry asserts the *sequence* of callbacks and not merely the end state.

### 4.4 The ordering block

§7 describes "an integer `order`" for a band while §9.1's document shows
`"order": {"after": "retry"}` — a map. Both cannot be the spelling, and
two spellings for one thing is the defect class this repo exists to
avoid, so the corpus is the arbiter (as it is for §4 rule 5) and pins
**one map**:

```json
{ "order": { "before": "<ref|name>", "after": "<ref|name>", "band": 0 } }
```

`band` rather than a nested `order`, because `order.order` is a name
that has to be explained every time it is read. Every key is optional;
absent `band` is `0`.

Matching is **by ref, or by name across all of that definition's
instances** (§7) — so `after: "retry"` orders behind every instance of
`retry`, and `after: "retry$fast"` behind exactly one.

### 4.5 The canonical observable

The driver returns exactly this map. **Sorted keys, refs rather than
object identities, errors as `{code}`** — the three properties that make
one expected value work in twenty languages.

```json
{
  "status": { "probe$a": "live", "probe$b": "loaded" },
  "open":   1,
  "log":    ["probe$a:define", "probe$a:activate"],
  "result": null
}
```

- **`status`** — every declared instance, ref → status (§5.1's seven).
  Sorted by ref, so output does not depend on a map's iteration order.
  An instance that was never declared is absent, not `null`.
- **`open`** — synthetic resources currently held, counted by the
  driver. This is what makes "what is open" **data** rather than an
  assertion each port words differently, and it is the whole test for
  §8.3's unwind.
- **`log`** — the ordered record of probe callbacks, each
  `"<ref>:<callback>"`. Order is the assertion; a set would pass a port
  that unwinds in the wrong direction.
- **`result`** — the value of the last command that produces one
  (`call`, `provider`, `export`, `order`, `list`), else `null`.

Object identity is never observable. Where §5.4 requires that
`host.instance(ref)` returns the same object across activation cycles,
the corpus pins it through the probe's **counter surviving** rather than
through identity, because a port whose language has no stable identity
would otherwise fail a test about something else.

### 4.6 What a port must NOT do

- **No clock.** No entry may depend on elapsed time; `slow` yields, it
  does not sleep.
- **No parallelism inside a run.** Commands are sequential, so a port
  may not reorder them for speed.
- **No error text matching.** Errors compare by `code` (§12). Message
  wording is a port's own business, and pinning it would make every
  translation a corpus change.
- **No port-local skips.** A driver section entry that a port cannot
  run is a divergence to report, not a case to filter — that inverts
  the one mechanism keeping the ports honest (AGENTS.md §1).

## 5. Explanation

### Why identity is `name$tag`

Because an instance *is* "the `test` one of `stripe`", and `stripe$test`
says exactly that in one token. **The name is always the definition** —
the invariant that makes everything downstream cheap: a registry groups
by the part before the `$`, a config file's key is its own
documentation, and nothing has to be told twice what a thing is an
instance of.

Two earlier drafts carried more machinery than the job needs. The
free-form form let a config write `stripe-test` and say `api: stripe`
separately, which reads well and costs a second name to keep consistent,
a field that can disagree with it, and an "is this the instance or the
definition?" question at every use site. The one real forfeit is
aliasing — an instance of `memcache` called `cache$hot` must be
`memcache$hot` — a cosmetic loss against a load-bearing invariant.

### Why `declared` costs nothing

Because a host with twenty integrations should not import twenty
packages to render a status page. `declared` means the ref exists and
its configuration is collected, and *nothing else has happened*: no
module resolved, no callback run.

That is also why **introspection never advances the state**. A status
endpoint that quietly loaded what it listed would be a denial of service
with a friendly name.

### Why resource capture is a scope, not a ledger

Because the alternative asks every plugin author to remember something,
in twenty languages, forever. `init()` conflating configuration with
capture is what makes sdkgen's features un-deactivatable:
`RetryFeature.init` reads options *and* wraps `utility.fetcher`, and
there is no way to undo it.

An instance scope inverts that. The host records what it hands out, the
plugin registers what it acquired elsewhere, and teardown unwinds in
reverse. **You cannot forget to release what you never registered.**

The honest limit, stated because a green suite must not be read as
claiming more: the corpus proves the host stopped routing to a
deactivated instance and unwound what it registered. **It cannot prove
the instance stopped running.** A plugin that squirrels a reference into
a global would pass every entry. That is a limit of the architecture,
not a gap in the tests.

### Why a plugin never mutates the host

`utility.fetcher = wrapped` is not undoable. "This instance holds slot 3
of the `request` chain" is undoable in O(1).

The idea is not new and should not pretend to be: OSGi named it the
**whiteboard pattern** in 2004, in a paper called *Listeners Considered
Harmful*, and gave exactly this reason — an extension that calls
`addListener` has created a cleanup obligation something must remember,
while one that merely registers and waits to be discovered has not.

### Why the corpus is the contract

Because twenty implementations of one idea drift, and nothing in a code
review catches it. The corpus is the only artefact that says the same
thing to all of them.

Two rules follow, and both are prime directives. **Never weaken the
corpus to make a port pass** — that inverts the mechanism. And **an
entry is worth exactly what it can falsify**: one that passes for every
implementation, correct or not, is documentation wearing a contract's
clothes.

Writing this corpus produced several, and review found them — adjacent
comparisons that pin a total order only under an unstated transitivity
assumption, all-lowercase sort cases that agree under every comparator,
and a pure group claiming to pin *when* a raise happens rather than
which values are rejected. Each looked like a test and tested nothing.


## Per-language documentation

Each port carries its own `DOCS.md` with the exact local spelling. None
exist yet; P1 adds `typescript/`.
