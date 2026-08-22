# Design: voxgig/plugin — one plugin architecture, every language

`voxgig/plugin` is a plugin system defined once and ported faithfully to
the language set the rest of the Voxgig stack already targets, so that a
library — [station](https://github.com/voxgig/station) first, an sdkgen
SDK next, anything after that — can be extended by the developers using
it, in the same way, with the same vocabulary, in whatever language they
happen to be writing.

It is a library, not a framework. A host library declares what it can be
extended at; a plugin binds into those points; the plugin system owns
naming, configuration, lifecycle, ordering and teardown. Nothing about
it is specific to station, to HTTP, or to SDKs.

> **The one-paragraph version.** A **definition** is a plugin kind. An
> **instance** is a live, named, stateful incarnation of a definition —
> `retry$fast` and `retry$slow` are two instances of one definition, in
> one host, at the same time. An instance is **loaded** (configured,
> stateful, inert) or **active** (bound into the host's extension
> points, holding resources). Activation is a separate, reversible,
> runtime-controllable transition, and **it is the only thing that
> captures resources**. Instances come from a static in-code catalog
> everywhere, and from dynamic module loading where the language
> supports it. Configuration is one declarative JSON document and one
> programmatic API over the same normalized model.

- [1. Why this exists](#1-why-this-exists)
- [2. The two inspirations, and what each teaches](#2-the-two-inspirations-and-what-each-teaches)
- [3. The model](#3-the-model)
- [4. Naming and referencing](#4-naming-and-referencing)
- [5. States, transitions and lifecycle](#5-states-transitions-and-lifecycle)
- [6. Extension points](#6-extension-points)
- [7. Ordering](#7-ordering)
- [8. Resource capture](#8-resource-capture)
- [9. Configuration](#9-configuration)
- [10. Loading: dynamic and static](#10-loading-dynamic-and-static)
- [11. Exports and dependencies](#11-exports-and-dependencies)
- [12. Errors](#12-errors)
- [13. Observability](#13-observability)
- [14. Concurrency and async](#14-concurrency-and-async)
- [15. Testing: the omni corpus](#15-testing-the-omni-corpus)
- [16. Repository layout and porting discipline](#16-repository-layout-and-porting-discipline)
- [17. Host adoption](#17-host-adoption)
- [18. Implementation plan](#18-implementation-plan)
- [19. Budgets](#19-budgets)
- [20. Open questions](#20-open-questions)
- [21. Non-goals](#21-non-goals)


## 1. Why this exists

Voxgig already has two plugin systems, and is about to need a third.

The **sdkgen SDK feature system** extends a generated SDK: `retry`,
`cache`, `ratelimit`, `telemetry`, `test`, and now `station` are feature
classes with a fixed hook vocabulary, activated by
`options.feature.<name>.active`. It is ported to ~23 languages already,
which is the single most valuable thing about it — it is proof that a
plugin model *can* be expressed in every target the stack cares about,
including C and Zig.

The **seneca plugin system** extends a microservice mesh: `seneca.use()`
loads a plugin by name or by function, gives it a scoped delegate, its
own options namespace, exports, and a `name$tag` identity that admits
multiple instances of one plugin.

Station now needs a third: its design (§3) already describes a plugin
contract, a registry, wrap ordering, lifecycle, and config precedence —
and every line of that is generic. Writing it a third time, in ~17
languages, to be subtly different from the other two, is the failure
mode this repository exists to prevent.

So: **one plugin architecture, defined once in TypeScript, ported the
way `voxgig/struct` and `voxgig/omni` are ported, proved against
`voxgig/station` and against sdkgen's feature system.** The point is not
novelty. The point is that a developer extending station in Go and a
developer extending an SDK in Python are using the same model, and that
the model was tested by the same JSON corpus in both languages.


## 2. The two inspirations, and what each teaches

### 2.1 sdkgen features

What it gets right, and this design keeps:

- **A fixed, named hook vocabulary** (`PostConstruct`, `PrePoint`,
  `PreRequest`, `PreResponse`, `PreResult`, `PreDone`,
  `PreUnexpected`, …) dispatched by name — `featureHook(ctx, name)`
  walks the feature list and calls the method if present. Cheap,
  obvious, and portable to languages with no closures worth the name.
- **Explicit, inspectable order**: `client._features` is an array, and
  order is the semantics. The ordered-array form of `options.feature`
  makes the developer's intended order the literal order.
- **Ordering controls** (`__before__`, `__after__`, `__replace__`) and a
  deterministic default (test-first, then sorted).
- **Activation as a data flag**: `options.feature.<name>.active`.
- **An extension seam for instances the generated code never knew
  about**: `options.extend`.

What it gets wrong, and this design fixes:

- **`init()` conflates configuration with resource capture.** `RetryFeature.init`
  reads options *and* wraps `utility.fetcher`. There is no way to undo
  it, so there is no deactivation, so `active` is a construction-time
  fact rather than a runtime state.
- **Capture is by host mutation.** A feature *assigns*
  `utility.fetcher = wrapped`, closing over the previous value. That
  composes, but it cannot be unwound: removing the third of five
  wrappers is impossible. This single decision is why sdkgen features
  can never be deactivated, and it is the thing this design changes
  (§6, §8).
- **One instance per name.** `options.feature` is a map keyed by name.
  Two differently-configured retry policies on one client cannot be
  expressed.
- **No dynamic loading, and no seam for one.** `Config.makeFeature(name)`
  reads a generated class registry. Fine for generated code; useless for
  a third-party extension published to npm.
- **Ordering rules are re-derived per problem.** Station needed its
  middleware immediately outside the base transport, and the fix was a
  special case for the literal name `station` inside
  `makeOptions` — beside the existing special case for `test`. A third
  such requirement gets a third special case.

### 2.2 seneca plugins

What it gets right, and this design keeps:

- **`name$tag` identity** (`Common.make_plugin_key`), with a defined
  grammar, parsed out of a single string (`"retry$fast"`), and used as
  the registry key. This is the multi-instance answer, already proven in
  production, already familiar to Voxgig engineers.
- **Options resolution as a documented precedence**, from a namespaced
  config section (`options.plugin[fullname]`), with a schema and
  defaults, and a shortname fallback.
- **Loading by name or by reference.** `seneca.use('foo')`,
  `seneca.use(require('foo'))`, `seneca.use({name, define})` — the same
  path after the first step.
- **A scoped delegate** so a plugin's actions, logs and errors are
  attributed to it.
- **Exports**, keyed by both `fullname/key` and `name/key`.
- **A staged load pipeline** (ordu tasks: args → load → normalize →
  preload → define → options → prepare → complete) that is itself
  inspectable and extensible.

What it gets wrong, and this design fixes:

- **There is no unload, and no deactivate.** A loaded plugin is loaded
  for the life of the process. `ignore_plugins` is a load-time veto, not
  a runtime state.
- **`define` may capture resources** and habitually does (transports
  open ports in `define`/`init`). Same defect as sdkgen's `init`, from
  the opposite direction.
- **The untagged export alias silently overwrites.** Load
  `foo$a` then `foo$b` and `exports['foo/x']` is `foo$b`'s. With
  multi-instance as a first-class requirement, silent last-wins is a
  bug generator (§11).
- **Load is fire-and-forget** (`run()` is deliberately not awaited;
  readiness is a separate `ready()` mechanism). Portable to
  single-threaded JS; not portable to Go or Rust.
- **It is JavaScript-shaped throughout** — dynamic renaming during
  `define`, `options.tag$`, prototype delegates. None of that ports.

### 2.3 The unification

The two systems are the same system with different vocabularies:

| concept | sdkgen | seneca | voxgig/plugin |
|---|---|---|---|
| the kind | feature class | plugin `define` fn | **definition** |
| the live thing | feature instance in `_features` | plugin in `private$.plugins` | **instance** |
| identity | `name` | `name$tag` | **`name$tag`** |
| the extensible thing | the SDK client | the seneca instance | **host** |
| binding | hook method names | `seneca.add()` patterns | **extension points** |
| wrap | `utility.fetcher = f(inner)` | prior chain | **chain point** |
| observe | `PreRequest` etc. | `seneca.sub()` | **hook point** |
| replace | `__replace__` | overriding pattern | **provider point** |
| config | `options.feature.<n>` | `options.plugin.<full>` | **`plugin.instance.<ref>`** |
| on/off | `active: true` at construction | load or don't | **loaded / active states** |

The one genuinely new idea is the last row: separating *loaded* from
*active*, and making activation the sole resource-capturing transition.
Everything else is the intersection of what both systems already do,
named once.


## 3. The model

Three nouns. Everything in this document is one of them.

**Definition** — a plugin kind. Immutable, shareable, has no state. It
carries a name, a version, an options shape (defaults + types, in the
`struct.validate` shape sdkgen already uses), declared dependencies, and
up to four lifecycle callbacks (§5.3). A definition is a *value*: the
same definition object may back many instances, and may be registered in
many hosts.

**Instance** — a live incarnation of a definition inside one host. Has an
identity (§4), resolved options, plugin-owned persistent state, a status
(§5.1), a set of bindings into the host's extension points, and a
resource ledger (§8). An instance is the unit of naming, configuration,
activation and teardown.

**Host** — the library being extended: a station, an SDK client, an
application. It declares extension points (§6), owns the catalog and
resolver (§10), holds the instance registry, and is the only thing that
mutates itself. A host is an ordinary object of the host library; there
is no ambient global. One process may hold many hosts, and an instance
belongs to exactly one.

```
   definition (a kind)                 host (the library being extended)
   ┌──────────────────────┐            ┌───────────────────────────────────┐
   │ name    'retry'      │            │ points:  request (chain)          │
   │ version '1.2.0'      │            │          tick    (hook)           │
   │ options {…defaults}  │            │          store   (provider)       │
   │ requires ['clock']   │            │                                   │
   │ define(inst, opts)   │            │ catalog:  name -> definition      │
   │ activate(inst)       │            │ resolver: name -> definition      │
   │ deactivate(inst)     │            │                                   │
   │ close(inst)          │            │ registry: ref  -> instance        │
   └──────────┬───────────┘            └─────────────────┬─────────────────┘
              │                                          │
              │  load('retry$fast', {retries: 5})        │
              └──────────────────┬───────────────────────┘
                                 ▼
                       instance 'retry$fast'
              ┌────────────────────────────────────────┐
              │ ref/name/tag/id     status: active     │
              │ options  (resolved, §9.3)              │
              │ state    (plugin-owned, persists §5.4) │
              │ bindings (declared in define, §6)      │
              │ releases (captured in activate, §8)    │
              └────────────────────────────────────────┘
```


## 4. Naming and referencing

Multiple instances of one definition is a first-class requirement, so
identity is specified before anything else.

- **name** — the definition name. Grammar (seneca's, unchanged, because
  it already works and half the org already knows it):
  `^[a-zA-Z@][a-zA-Z0-9.~_\-/]*$`, max 1024 chars. `@voxgig/plugin-retry`
  is a legal name; so is `retry`.
- **tag** — the instance discriminator: `^[a-zA-Z0-9.~_-]+$`, max 1024
  chars, or empty.
- **ref** — the canonical instance address: `name` when the tag is
  empty, `name$tag` otherwise. Parsing is the inverse: everything before
  the first `$` is the name, everything after is the tag.
- **id** — `ref#seq`, where `seq` is the host's monotonic load counter.
  Unique across the host's whole lifetime, so events from
  `retry$fast#3` are never confused with events from a later
  `retry$fast#7` after an unload/reload. Debug and trace identity only;
  never an address.

Rules, all pinned by the corpus:

1. **A ref addresses at most one instance in a host.** Loading a ref
   that is already registered is `plugin_ref_duplicate` — not a silent
   overwrite (seneca) and not an impossibility (sdkgen).
2. **The untagged ref is an ordinary ref**, not a wildcard. `retry` and
   `retry$fast` are two different instances of one definition, and both
   may exist.
3. **Auto-tagging is explicit.** `load('retry', {tag: '?'})` assigns the
   lowest unused positive integer tag (`retry$1`, `retry$2`, …). Without
   `'?'`, a collision is an error. Auto-assignment never produces a ref
   that collides with an explicit tag, and the assigned ref is returned.
4. **The definition name is the ref's name** unless the load spec gives
   an explicit `define` (the alias case: instance `cache$hot` from
   definition `memcache`). Aliasing is allowed because the same
   definition genuinely can serve as several conceptually distinct
   extensions; it is *recorded* on the instance (`instance.define`) so
   nothing has to guess.
5. **Refs are canonicalized on the way in.** `"retry$"`, `"retry"` and
   `{name:'retry', tag:''}` all normalize to the ref `retry`. Ports must
   canonicalize before comparison; the corpus's `ref` section is the
   arbiter.

Canonical functions: `parseref(str) -> {name, tag}`, `formatref(name,
tag) -> str`, `checkname`/`checktag`. These are pure, which is why they
are the first thing a new port implements and the first section of the
corpus it passes.


## 5. States, transitions and lifecycle

### 5.1 The state machine

```
                    load()                 activate()
   (absent) ──────────────────► loaded ◄──────────────────► active
       ▲                        │  ▲       deactivate()       │
       │        unload()        │  │                          │
       └────────────────────────┘  └──────────────────────────┘
                                        (state survives)

   any transition may fail:  ─────► failed ─────► (unload only)
```

Five statuses, and no more: `loaded`, `active`, `failed`, plus the two
transient ones `loading` and `closing` that are observable only from
inside a callback or from another thread. A port that adds a sixth is
diverging.

- **`loaded`** — options resolved, state allocated, bindings declared,
  **no resources held, no host participation**. A loaded instance
  receives no hook calls, is not in any chain, and provides no
  providers. It costs memory and nothing else.
- **`active`** — bindings are live, resources are held.
- **`failed`** — a lifecycle callback or a release raised, on any
  transition after `load`. The instance remains registered and
  inspectable (that is the point: a failed plugin must be visible, not
  vanished), participates in nothing, and accepts only `unload`.
  `failed` records the failing transition and the error.

A `define` that raises is the exception, and it is the one case where
nothing is registered — so it needs an explicit cleanup path, or a port
with manual memory leaks on every failed load. The rule: **when `define`
raises, the host runs the definition's `close` on the partially
constructed instance, best-effort, then discards it** and raises
`plugin_define_failed`. `close` must therefore tolerate an instance
whose `define` did not finish: a half-set `state`, no bindings, no
ledger. Bindings declared before the raise are dropped by the host with
the instance; they were never live. An error from that `close` is
attached to the raised error and does not replace it.

### 5.2 Transitions

| call | from | to | on failure |
|---|---|---|---|
| `load(spec)` | absent | `loaded` | `close` runs, nothing registered; error raised |
| `activate(ref)` | `loaded` | `active` | bindings removed, releases run in reverse; → `failed` |
| `deactivate(ref)` | `active` | `loaded` | bindings removed, all releases still run; → `failed` |
| `unload(ref)` | `loaded`, `failed` | absent | error raised; registry entry dropped anyway |
| `unload(ref)` | `active` | absent | deactivate first, then close |

**Any** failure during a transition — a lifecycle callback raising, or a
ledger entry raising (§8) — lands the instance in `failed`. There is no
second, softer failure state for "deactivated, but the release was
messy": the whole point of `failed` is that it is not trustworthy, and a
plugin whose resources may still be held is exactly that. Bindings are
always removed before the status changes, so a `failed` instance never
participates in anything, whatever went wrong.

Every transition is **idempotent in the trivial direction**:
`activate` on an active instance is a no-op returning success, not an
error. This matters more than it looks — it is what lets declarative
config be applied repeatedly (§9.6) without the host tracking what it
already did.

**Transitions are sequential.** A host performs one lifecycle transition
at a time, in call order, and never interleaves two. A transition
triggered from inside a lifecycle callback is `plugin_reentrant`. This
is a hard rule because it is the only way the semantics can be identical
in Go, in Ruby and in single-threaded JavaScript.

### 5.3 The callbacks

```
define(instance, options)     // configure. Allocate memory. Declare bindings.
                              //   MUST NOT capture resources.
activate(instance)            // capture resources. Register releases.
deactivate(instance)          // (host runs the release ledger; hook for extras)
close(instance)               // final teardown before removal. State dies here.
```

Only `define` is required. The split is the central discipline of this
design, and the rule is one sentence:

> **`define` may allocate memory. `activate` may allocate anything.
> Everything `activate` allocates must be registered for release.**

"Resource" means: sockets, files, timers, threads, subscriptions,
watchers, child processes, native handles, host mutations, entries in
anything shared. Memory that the plugin alone can reach is not a
resource.

`define` is also the **only** place bindings may be declared (§6). That
is deliberate: it means the host knows an instance's complete binding
set while the instance is still inert, so `activate` is a pure insertion
and `deactivate` a pure removal, with no discovery in between. It also
means `host.list()` can tell a developer exactly what a loaded-but-
inactive plugin *would* do.

### 5.4 State

`instance.state` is a plugin-owned value the host never reads, writes,
copies or serializes. It is created in `define` and destroyed in
`close`. It **survives deactivate/activate cycles unchanged** — that is
what makes the instance "an active instance with persistent state"
rather than a factory: deactivating a rate limiter and reactivating it
ten seconds later must not reset its window counters unless the plugin
chose to reset them in `deactivate`.

Object identity survives too: `host.instance('retry$fast')` returns the
same instance across any number of activation cycles, and the plugin's
callbacks receive that same instance.

Durable state — surviving process restart — is out of scope for v1
(§21). The seam that would carry it later is the definition-level pair
`snapshot(instance) -> json` / `restore(instance, json)`; naming them
now costs nothing and stops a port inventing something else.


## 6. Extension points

A host declares its extension points; plugins bind into them. **A plugin
never mutates the host.** This is the inversion that makes deactivation
possible: sdkgen's `utility.fetcher = wrapped` is not undoable, but
"this instance holds slot 3 of the `request` chain" is undoable in O(1).

Three kinds, chosen because they are what the two existing systems
actually needed, and no more:

### 6.1 `hook` — fan-out

Many bindings, all called, no composition. The sdkgen hook vocabulary
(`PrePoint`, `PreRequest`, …) is exactly this. The host calls
`host.emit(point, arg)`; every active binding runs, in resolved order
(§7); return values are ignored.

A raising binding does not stop the others by default. Because "reported"
is not a specification — one port collecting errors and another
discarding them would be a genuine cross-port divergence in exactly the
production path nobody tests — the reporting is pinned:

- each error emits a `fail` trace record (§13) carrying the ref, the
  point and the cause, *and* is collected;
- `emit` returns the collected list, empty when every binding was clean.
  A host that ignores the return value has ignored the errors, visibly;
- the collected list is also raised as a single `plugin_hook_failed` when
  the point is declared `{ raise: true }`, for hosts that would rather
  not check a return value;
- `{ strict: true }` on the point declaration stops at the first error
  and propagates it unwrapped — remaining bindings do not run.

`call` on a chain point needs none of this: an error propagates through
the composed chain to the caller, which is what a chain is for.

### 6.2 `chain` — composition

Ordered wrappers around a host-owned base function. This is
`utility.fetcher`, seneca's prior chain, and station's transport
middleware. The host declares the point with a base implementation and
calls `host.call(point, args…)`; the host composes
`b1(b2(b3(base)))` from the active bindings in resolved order, where the
first binding is outermost.

The composition is **recomputed by the host** whenever the active set
changes, and cached between changes. Plugins receive `next` as an
argument; they never see or store the previous value of anything. A
plugin that stashes `next` and calls it after deactivation is a bug the
host cannot prevent, and the corpus says so in a comment rather than
pretending otherwise.

### 6.3 `provider` — exactly one

A named slot with at most one active implementation, and a host-supplied
default. sdkgen's `__replace__` and "the secret store" are this. When
several active instances bind the same provider point, the winner is the
highest `order`, ties broken by ref sort, and **the losers are visible**
(`host.status()` lists them as shadowed) rather than silently ignored.
A point declared `{ exclusive: true }` makes a second binding an error
instead of a shadow.

### 6.4 Declaring and binding

```ts
// host side, once, at host construction
host.point('request', { kind: 'chain', base: rawFetch })
host.point('tick',    { kind: 'hook' })
host.point('store',   { kind: 'provider', base: memStore })

// plugin side, inside define() only
def.define = (inst, options) => {
  inst.state = { hits: 0 }
  inst.chain('request', async (ctx, next) => { inst.state.hits++; return next(ctx) },
             { after: 'test' })
  inst.hook('tick', () => { /* … */ })
}
```

Binding a point the host never declared is `plugin_point_unknown`,
raised at `define` time — i.e. at load, while nothing is running, which
is the whole reason bindings are declared in `define`.

A binding declared with `{ optional: true }` against an undeclared point
is dropped with a warning instead. That exists for one honest reason:
the same plugin should be loadable into a host that is one version
behind.

### 6.5 Position verification

Station's §3.3 found that a plugin can need to *know* it is in the right
place — its middleware must sit immediately outside the base transport
or its "wire truth" events are fiction. So a chain binding may query its
resolved position: `inst.position('request')` returns `{index, count,
innermost, outermost}`, valid while active. A plugin that requires a
position it did not get fails loudly rather than reporting nonsense.
The host does not police this; it just makes the fact available.


## 7. Ordering

One rule, one place — because sdkgen has now grown two special cases in
`makeOptions` (`test`, then `station`) and the third is not far off.

The resolved order of the bindings on a point is computed by a **stable
topological sort**:

1. **Constraints first.** A binding may declare `before: <ref|name>` and
   `after: <ref|name>` (matching by ref, or by name across all that
   definition's instances). Constraints are edges. A cycle is
   `plugin_order_cycle`, reported with the cycle.
2. **Bands second.** A binding may declare an integer `order`
   (default 0). Lower runs first — outermost for a chain, first for a
   hook. Bands break constraint-free ordering globally, which is what
   lets a host say "the base transport wrapper is band 100" once,
   instead of every plugin naming it.
3. **Declaration order last.** Ties break by the instance's load
   sequence, so the array form of the declarative config (§9.1) means
   what it visibly says.

Constraints referring to an absent binding are **satisfied vacuously**
(not an error): a plugin ordered `after: 'test'` must load in a host
with no test plugin. That is the sdkgen `__after__` behaviour, kept.

The resolved order is recomputed on any change to the active set, is
exposed by `host.order(point)`, and is pinned by the corpus's `order`
section — including the awkward cases (a constraint against a
deactivated instance, two instances of one definition ordered relative
to each other by ref, a band that contradicts a constraint — the
constraint wins).


## 8. Resource capture

The requirement is that resource usage is dictated by activation state.
The mechanism is a **release ledger**.

```ts
def.activate = (inst) => {
  const sock = net.connect(inst.options.addr)
  inst.release(() => sock.destroy())          // ledger entry 1

  const timer = setInterval(poll, 1000)
  inst.release(() => clearInterval(timer))    // ledger entry 2
}
```

- The ledger belongs to the instance and is emptied by the host on
  deactivate, running entries **in reverse registration order**.
- `deactivate` on the definition is optional and runs *before* the
  ledger, for anything that must happen while resources still exist
  (draining, flushing, a graceful goodbye).
- **A failing release does not stop the rest.** Every entry runs, in
  reverse order, whatever any of them does; the errors are collected and
  raised as one `plugin_release_failed`.
- **A failed release ends the instance in `failed`**, exactly as a failed
  callback does (§5.2) — a release that raised may have leaked, and an
  instance that may be holding resources it cannot account for must not
  be reactivated. Its bindings are removed either way, so it
  participates in nothing meanwhile. `unload` is the only way out, and
  it still runs `close`.
- If `activate` raises partway, the host runs the entries registered so
  far, in reverse, and the instance goes `failed`.
- `inst.release` outside `activate` is `plugin_release_scope`.

Binding into extension points is **not** a ledger entry; the host
inserts and removes bindings itself as part of the transition. The
ledger is only for things the host cannot see.

The corpus tests this with a synthetic resource: the driver's probe
definitions acquire numbered handles from a counter the driver owns, and
the expected output includes the ledger — so "deactivate released
exactly what activate captured" is a data assertion, in every language,
rather than a property nobody checks.


## 9. Configuration

Two front doors, one normalized model behind them. Neither is the
"real" one: the declarative document is defined as data that produces
exactly the sequence of API calls the programmatic path makes.

### 9.1 The declarative document

```jsonc
{
  "plugin": 1,                       // format version

  // Where dynamically-resolved definitions may come from (§10).
  "source": [
    { "kind": "module", "prefix": ["@voxgig/plugin-", "voxgig-plugin-", ""] },
    { "kind": "path",   "dir": "./plugin" }
  ],

  // Instances, keyed by REF. The key carries the tag, so multi-instance
  // works in the map form too.
  "instance": {
    "retry":       { "active": true,  "options": { "retries": 3 } },
    "retry$slow":  { "active": false, "options": { "retries": 10, "minDelay": 500 } },
    "cache$hot":   { "define": "memcache", "active": true,
                     "order": { "after": "retry" },
                     "options": { "max": 1000 } }
  },

  // Profiles overlay the base. Selected by name at host construction
  // or by VOXGIG_PLUGIN_PROFILE.
  "profile": {
    "dev":  { "instance": { "retry": { "options": { "retries": 0 } } } },
    "prod": { "instance": { "cache$hot": { "options": { "max": 100000 } } } }
  }
}
```

The **array form** is equivalent and carries explicit order — the array
position *is* the load order, exactly as sdkgen's ordered-array feature
form works:

```json
{ "plugin": 1,
  "instance": [
    { "ref": "retry",      "active": true,  "options": { "retries": 3 } },
    { "ref": "cache$hot",  "define": "memcache", "active": true }
  ] }
```

Normalization turns the array into the map plus a load order, and the
map into the same shape with load order = sorted refs. **The
normalization is a pure function of the document**, which is why it is
the second corpus section and why every port gets it right for free.

Sharp edge, stated once: **a partial array is not a filter.** sdkgen
learned this the hard way — deriving order from a partial array silently
dropped config-activated features. Here, an array form lists *every*
instance the host should have; refs present in the base map but absent
from a profile's array are still loaded, in sorted position after the
listed ones. The corpus pins it.

The document may stand alone as `plugin.json`, or be a subtree of a host
library's own config (station's `station.json` would carry the same
shape under a `plugin` key). Hosts choose the file name and the lookup
path; the plugin library only ever sees the parsed subtree, and never
reads a file itself.

### 9.2 The programmatic API

```ts
const host = makeHost({
  point: { request: { kind: 'chain', base: rawFetch }, tick: { kind: 'hook' } },
  config: pluginJson,             // optional; the document above
  profile: 'dev',
})

host.define(RetryPlugin)                            // static catalog
host.resolver(nodeResolver())                       // dynamic loading (§10)

const fast = await host.load('retry$fast', { retries: 5 })
await host.activate('retry$fast')

await host.deactivate('retry$fast')                 // resources released, state kept
await host.activate('retry$fast')                   // same instance, same state
await host.unload('retry$fast')

host.instance('retry$fast')      // -> instance | undefined
host.list()                      // -> [{ref, define, status, options, points, …}]
host.order('request')            // -> ['retry$fast', 'cache$hot']
host.options('retry$fast', {retries: 9})   // patch; see 9.4
host.status()                    // -> the whole picture (§13)
await host.close()               // deactivate + close everything, reverse load order
```

Nothing in the declarative path is unavailable programmatically, and the
declarative loader is implemented *as* calls to this API — a rule, not
an aspiration, so that the two can never drift.

### 9.3 Precedence

One total order, lowest to highest, identical in every port, pinned by
the corpus's `config` section:

1. definition option defaults (the definition's option shape),
2. host defaults for that definition (`makeHost({defaults: …})`),
3. config document base (`instance.<ref>.options`),
4. config document profile overlay,
5. environment (`VOXGIG_PLUGIN_<REF>_<PATH>`, §9.5),
6. host construction options,
7. per-load options (`host.load(ref, options)`),
8. runtime patch (`host.options(ref, patch)`).

Untagged-to-tagged inheritance, seneca's shortname rule, applies at
levels 2–4: options written for `retry` are a base for `retry$fast`,
overlaid by options written for `retry$fast`. It is the behaviour people
expect and it makes "configure the definition, then vary one instance"
one line instead of two copies.

### 9.4 Merge semantics, and the list sharp edge

Merging is `voxgig/struct`'s `merge` (§16 explains why struct is the one
permitted dependency), and validation is `struct.validate` against the
definition's option shape — the same pair sdkgen's `makeOptions`
already uses, so an sdkgen feature's option shape is a plugin option
shape unchanged.

**`struct.merge` merges lists element-wise by index.** For option maps
that is nearly always wrong: overlaying `["a"]` onto `["x","y","z"]`
yields `["a","y","z"]`, not `["a"]`. Station hit exactly this and
carved out `secrets.providers` as replace-wholesale. So this design
states the rule up front rather than per-case:

> **In `plugin` config, a list value REPLACES.** Deep-merge applies to
> maps; a list in a higher-precedence layer replaces the list below it
> entirely. A definition that wants append semantics for one of its
> options says so in its option shape (`{"`$MERGE`": "append"}`), and
> that is a property of the definition, not a special case in the
> library.

`host.options(ref, patch)` is a merge at the top of the precedence
stack, and is re-validated. It applies immediately to a loaded instance
and, for an active one, invokes the optional definition callback
`reconfigure(instance, options, previous)`. A definition without
`reconfigure` that receives a patch while active is deactivated and
reactivated by the host, which is always correct and sometimes
expensive; `reconfigure` exists to make the common case cheap. Whether
that automatic cycle is the right default is §20.

### 9.5 Environment

One prefix, stated as a rule so nothing drifts: `VOXGIG_PLUGIN_*`.

- `VOXGIG_PLUGIN_PROFILE` — the profile name.
- `VOXGIG_PLUGIN_<REF>_<PATH>` — one option. Ref and path are upper-
  snake with `$` → `__` and `.` → `_` (`VOXGIG_PLUGIN_RETRY__FAST_MIN_DELAY`).
  Values parse as JSON, falling back to string.

  **The encoding is lossy, and the design says so rather than pretending
  otherwise.** `_` is legal in a name and in a tag, and the mapping folds
  case, so the refs `retry$fast` and `retry__fast` both encode to
  `RETRY__FAST`, as do `Retry$fast` and `retry$Fast`. Rather than
  restrict a grammar the rest of the stack already uses, the host
  **detects the collision**: it encodes every ref it holds, and a key
  that two refs claim is `plugin_env_ambiguous`, naming both. The
  affected pair is configurable by document and by API, just not by
  environment — which is the honest trade, and is a pure function over
  the ref set, so the corpus pins it.
- `VOXGIG_PLUGIN_ACTIVE` / `VOXGIG_PLUGIN_INACTIVE` — comma-separated
  refs, forced on or off. `INACTIVE` wins. This is the "turn it off in
  production without a deploy" lever, and it is the one thing an
  operator reaches for first.

Env parsing is a pure function over a string map — the corpus tests it
without touching a real environment.

### 9.6 Applying a document

`host.apply(document)` is idempotent and re-runnable: load what is
missing, unload what is gone, patch what changed, and move activation
state to match. It is how a host does config reload, and it is why every
transition is trivially idempotent (§5.2). Ordering: deactivations and
unloads first (reverse dependency order, then reverse load order), then
loads, then activations **in dependency order** (§11), ties broken by
load order. Dependency order governs, not the document's array position:
a document that lists a consumer before the instance satisfying its
requirement is a perfectly ordinary document, and must not fail with
`plugin_dependency_missing` because of how it was written down.


## 10. Loading: dynamic and static

### 10.1 Two paths, one catalog

- **Static registration** — `host.define(definition)` puts a definition
  in the catalog under its name. This works in every language, is the
  only path in some, and is the floor: **every port must implement it,
  and no behaviour in the corpus may depend on anything else.**
- **Dynamic resolution** — a host-installed `resolver` maps a name to a
  definition at load time, typically by importing a module. Optional,
  advertised per port as a capability, and always *replaceable*: the
  resolver is an interface, so a test, a sandbox, or a language without
  module loading supplies its own.

`load(ref)` looks in the catalog first, then asks the resolver, then
fails with `plugin_unknown_definition`. A resolver that raises produces
`plugin_resolve_failed`, carrying the candidates it tried.

### 10.2 The resolution grammar is a pure function

The part of dynamic loading that can differ between ports — and
therefore the part that must not — is *which module ids a name maps
to, in what order*. That is extracted as a pure function,
`resolvecandidates(name, sources) -> [id]`, and lives in the corpus:

```
retry           -> ['@voxgig/plugin-retry', 'voxgig-plugin-retry', 'plugin-retry', 'retry']
@acme/thing     -> ['@acme/thing']                    // scoped: verbatim only
```

Prefixes come from the config `source` list, so a host can add its own
(`@voxgig/station-plugin-`).

**A module path is not a name.** The ref grammar (§4) starts a name with
a letter or `@`, so `./local/thing` is not a ref and never reaches
candidate generation — seneca allows a path where a plugin name goes,
and this design deliberately does not, because a ref is an address
within a host and a path is a location on a disk. Loading from an
explicit location is a separate field on the load spec, which bypasses
candidate generation entirely:

```ts
host.load({ ref: 'thing', from: './local/thing' })
```

and in the document, `{ "thing": { "from": "./local/thing" } }`. `from`
is passed to the resolver verbatim; a resolver that cannot honour a
location raises `plugin_resolve_failed`. *Applying* the ids — `require`,
`importlib`, `ServiceLoader` — is per-port integration-tested, because a
JSON corpus cannot import a Python module in Go. The split is station's
(pure-contract corpus, live integration suites), for the same reason.

### 10.3 Per-language mechanism

| tier | languages | dynamic mechanism |
|---|---|---|
| **D — dynamic by nature** | typescript, javascript, python, ruby, php, perl, lua, elixir, clojure | `require`/`import()`, `importlib`, `require`+const lookup, Composer autoload, `require`+`can`, `require` over `package.path`, `Code.ensure_loaded?`, `requiring-resolve` |
| **D — dynamic by platform** | java, kotlin, scala, csharp | `ServiceLoader`/`Class.forName`; `AssemblyLoadContext` (breaks under AOT/trimming — the port says so) |
| **D — dynamic, opt-in** | ocaml (`Dynlink`, `.cmxs`), c, cpp (`dlopen`/`LoadLibrary`) | real, but ABI-fragile; off unless the host asks for it |
| **S — static only** | go, rust, swift, dart, haskell, zig, lean | package `init()` registration (go — `plugin.Open` exists, but needs cgo, a narrow platform set, and a byte-identical toolchain and dependency graph, so it is not the model); inventory/ctor registration or an explicit registry function elsewhere |

Every tier-S port ships the same ergonomics for registration —
a `Register(def)` called from an `init()`-equivalent, or an explicit
list handed to `makeHost` — so that a Go developer's experience is "add
the import, add one line to the config" rather than "write a factory".

### 10.4 Security posture

Loading a plugin is executing code. The library states the obvious
plainly rather than implying a sandbox it does not have:

- A dynamic resolver runs arbitrary code from the host's module path,
  with the host's privileges. There is no isolation, in any port.
- `source` entries are an *allow-list of shapes*, not a security
  boundary; a host that needs a boundary runs plugins out of process,
  which this library does not do (§21).
- The default resolver is **off**. A host opts in by installing one.
  Static registration is the default because "the developer compiled it
  in" is the only trust statement this library can honestly make.


## 11. Exports and dependencies

**Exports.** An instance may publish values for other plugins and for
the application: `inst.export('client', theClient)` during `define`.
Read with `host.exports('retry$fast/client')`.

The unqualified alias `retry/client` resolves to the **untagged**
instance if one exists. If it does not, and exactly one tagged instance
exports that key, it resolves to that one. If two do, it is
`plugin_export_ambiguous` — deliberately diverging from seneca's silent
last-wins, because with multi-instance as a headline feature, an
ambiguous alias is a defect waiting for production.

Exports of a `loaded` (inactive) instance are **visible**. They are
declared in `define`, they are data, and hiding them would make the
loaded state useless for introspection. An export whose value is only
meaningful while active is the plugin's problem to signal, and the
convention is a getter closing over `inst.state`.

**Dependencies.** A definition may declare `requires: ['clock',
'store']` — definition *names*, not refs, because a dependency is on a
capability, not on someone's configuration.

- At `load`, a missing requirement is a warning, not an error: order of
  loading should not be the developer's problem.
- At `activate`, a missing requirement is `plugin_dependency_missing`,
  and requirements must be `active` — this is the state where
  dependencies genuinely matter, because it is the state where the
  plugin will actually call them.
- `host.apply` and `host.activate(...refs)` order activation by
  dependency, then by the §7 rules. A dependency cycle is
  `plugin_dependency_cycle`.
- **Deactivation runs the dependency graph backwards, and is refused by
  default.** Checking requirements only at activation would leave a
  consumer `active` and calling a provider that has since been
  deactivated or unloaded — active in name, broken in fact. So
  deactivating or unloading an instance that active instances still
  require is `plugin_dependency_held`, naming the holders.
  `deactivate(ref, {cascade: true})` deactivates the dependents first,
  in reverse dependency order, and reports what it touched.
  `host.apply` cascades within its own plan (§9.6), and `host.close()`
  always cascades, since it is tearing everything down anyway.
- A requirement is satisfied by *any* active instance whose definition
  provides that name, so deactivating one of two instances providing
  `clock` is not held — the graph is over capabilities, not refs.

`provides: [...]` lets a definition satisfy a requirement under another
name — one definition supplying `clock` regardless of what it is called.


## 12. Errors

Error codes are API. They are the same string in every port, and so is
the message — omni's lesson, learned by twenty-three runners printing
the same failure differently. So the format is specified here, not left
to each port to guess:

```
plugin/<code>: <text> [<key>=<value> …]
```

- `<code>` is the code from the table below, verbatim.
- `<text>` is one fixed English sentence per code, listed in `DOCS.md`
  and identical in every port. It interpolates only values that also
  appear in the detail fields.
- The bracketed detail carries the fields that apply to the code, in a
  fixed order — `host`, `ref`, `define`, `point`, `key`, `cause` —
  omitting those that do not, and is absent entirely when none do.
  Values are rendered as compact JSON, so a value containing a space or
  a bracket cannot break the parse.
- The cause of a wrapped plugin error is reachable as a field on the
  error object in every port; `cause=` in the text is its message, never
  a replacement for the object.

```
plugin/plugin_ref_duplicate: instance already loaded [host="station" ref="retry$fast"]
plugin/plugin_point_unknown: no such extension point [host="station" ref="retry$fast" point="requst"]
```

The corpus asserts the code on every error entry and the full rendered
message on a representative few — omni's `err` matching is substring by
default, so pinning the meaningful part everywhere and the exact format
in a handful of places is both cheap and sufficient.

| code | when |
|---|---|
| `plugin_bad_name` / `plugin_bad_tag` | grammar violation (§4) |
| `plugin_ref_duplicate` | load onto an occupied ref |
| `plugin_unknown_definition` | not in catalog, no resolver, or resolver found nothing |
| `plugin_resolve_failed` | resolver raised; carries candidates |
| `plugin_dynamic_unsupported` | dynamic load attempted in a static-only port |
| `plugin_not_loaded` | transition or query on an absent ref |
| `plugin_bad_state` | transition illegal from the current status |
| `plugin_reentrant` | transition attempted from inside a lifecycle callback |
| `plugin_option_invalid` | options failed the definition's shape |
| `plugin_point_unknown` | binding to an undeclared point |
| `plugin_point_kind` | binding of the wrong kind for the point |
| `plugin_bind_scope` | binding declared outside `define` |
| `plugin_release_scope` | `release` registered outside `activate` |
| `plugin_order_cycle` | before/after constraints cycle |
| `plugin_dependency_missing` / `plugin_dependency_cycle` | §11 |
| `plugin_dependency_held` | deactivate/unload of an instance active instances require (§11) |
| `plugin_hook_failed` | collected binding errors on a `{raise: true}` hook point (§6.1) |
| `plugin_env_ambiguous` | two refs encode to one environment key (§9.5) |
| `plugin_export_ambiguous` | §11 |
| `plugin_define_failed` / `plugin_activate_failed` / `plugin_deactivate_failed` / `plugin_close_failed` | a callback raised; wraps the cause |
| `plugin_release_failed` | one or more ledger entries raised |
| `plugin_point_exclusive` | second binding on an exclusive provider point |

Every error carries the host name, the ref (where one exists), the code,
and the cause. A plugin's own errors are never rewritten — they are
wrapped, and the cause is reachable.


## 13. Observability

The registry is explicit and queryable, because a plugin system nobody
can see the state of is a plugin system people stop trusting.

- `host.list()` — one row per instance: ref, definition name and
  version, status, load sequence, the points it binds and its resolved
  position in each, its declared requirements and whether they are met,
  its option keys (values redacted by the host's redactor if it has
  one), and the size of its release ledger.
- `host.order(point)` — the resolved order, active bindings only.
- `host.status()` — the whole picture: host name, declared points and
  their kinds, catalog contents, resolver presence, instances, shadowed
  providers, and the last error per failed instance.
- `host.trace(fn)` — a tap over lifecycle events: `load`, `activate`,
  `deactivate`, `unload`, `bind`, `unbind`, `release`, `fail`. `fail`
  covers both a failed transition and a binding that raised during
  `emit`/`call` (§6.1), which is what makes a non-strict hook failure
  observable rather than merely returned. Buffered
  in a bounded ring so it is available after the fact, exactly as
  station's event ring is. Trace records are data (a JSON-shaped map),
  which is what lets the corpus assert on them.

None of this is a logging framework. The library emits records; the host
decides where they go.


## 14. Concurrency and async

- All public host operations are safe to call from any thread. The
  registry and the resolved orders are internally synchronized; each
  port uses its idiom (a mutex in Go/Rust/Java, the GIL where that is
  genuinely sufficient, an actor in Elixir).
- **Lifecycle transitions are serialized** (§5.2). Point invocation is
  not: `emit`/`call` run concurrently with each other and with a
  transition. Consequence, stated because it is the sharp edge: a chain
  invocation that started before a `deactivate` may complete after it,
  running through the deactivated plugin's wrapper. The host guarantees
  *no new invocation* enters a deactivated binding; draining in-flight
  ones is the definition's job, in `deactivate`, before the ledger runs.
- Where a language has async, `load`/`activate`/`deactivate`/
  `unload`/`close` and the lifecycle callbacks may be asynchronous, and
  the host's methods return the idiomatic completion value (a Promise, a
  coroutine, an error return). Where it does not, they are synchronous.
  The *sequence* of operations is identical either way — that is what
  the corpus asserts — and no port may make load fire-and-forget the way
  seneca's `use()` is. A host that wants seneca's ergonomics builds them
  on top; the library's contract is that when `load` returns, the
  instance is loaded.


## 15. Testing: the omni corpus

`spec/plugin.aontu` compiles to `spec/plugin.json`, and every port runs
it through [voxgig/omni](https://github.com/voxgig/omni). Same discipline
as struct, sekreto and station: the corpus is the contract; a port that
disagrees with it is wrong.

### 15.1 The problem, and the shape of the answer

omni entries are one call: arguments in, result out. A plugin system is
a state machine — which is exactly what a naive reading says cannot be
tested this way. The answer is that **an entry is a whole scenario**:
the input is a host configuration plus a script of commands, and the
output is a canonical observable. The subject is a small per-port
**driver** — the same role omni's `fib` library plays — which builds a
host, runs the script, and returns the observable.

```jsonc
{
  "id": "lifecycle#deactivate-keeps-state",
  "in": {
    "host": { "point": { "request": "chain", "tick": "hook" } },
    "script": [
      { "cmd": "load",       "ref": "probe$a", "options": { "n": 1 } },
      { "cmd": "activate",   "ref": "probe$a" },
      { "cmd": "call",       "point": "request", "arg": "x" },
      { "cmd": "deactivate", "ref": "probe$a" },
      { "cmd": "call",       "point": "request", "arg": "y" },
      { "cmd": "activate",   "ref": "probe$a" },
      { "cmd": "call",       "point": "request", "arg": "z" }
    ]
  },
  "out": {
    "instance": [ { "ref": "probe$a", "status": "active", "seen": 2 } ],
    "resource": { "open": 1, "opened": 2, "closed": 1 },
    "result":   [ "probe:x", "y", "probe:z" ]
  }
}
```

`seen: 2` is the persistent-state assertion: the counter in
`instance.state` survived the deactivation. `resource` is the ledger
assertion, and it is worth reading carefully, because the obvious wrong
answer (`opened: 2, closed: 2`) would quietly demand that ports release
resources while the instance is still active: `probe` acquires one
synthetic handle per activation, the deactivation released the first,
and the script *ends active*, so the second is still held. A scenario
that wants the balanced ledger ends with an explicit `deactivate` or
`close`. `result` shows the middle call bypassing the deactivated chain
binding entirely.

### 15.2 The driver

Every port implements the same small driver, and nothing else is
port-specific:

- **A fixed catalog of probe definitions**, defined by the corpus and
  implemented identically per port: `probe` (records calls, wraps a
  chain, holds a counter, acquires one synthetic resource per
  activation), `noisy` (fails on demand at a named callback), `greedy`
  (acquires N resources, releases some), `dep` (declares requirements),
  `provider` (binds a provider point), `slow` (async where the language
  has async). Their behaviour is specified in `DOCS.md` and is as much
  the contract as the runner is.
- **A synthetic resource counter** the driver owns, so "what is open" is
  data.
- **A command interpreter** over the vocabulary: `host`, `define`,
  `load`, `activate`, `deactivate`, `unload`, `apply`, `options`,
  `call`, `emit`, `provider`, `export`, `order`, `list`, `env`, `close`.
- **A canonical observable**: sorted keys, refs not object identities,
  errors as `{code}`.

### 15.3 Sections

| section | what it pins | pure? |
|---|---|---|
| `ref` | name/tag grammar, parse, format, canonicalization, auto-tag | yes |
| `config` | document normalization, array/map forms, profile overlay, precedence, list-replace | yes |
| `env` | `VOXGIG_PLUGIN_*` parsing, ACTIVE/INACTIVE | yes |
| `resolve` | name → candidate module ids | yes |
| `lifecycle` | the state machine, idempotence, illegal transitions, failure paths | driver |
| `state` | persistence across activation cycles, destruction on unload | driver |
| `resource` | the release ledger, reverse order, partial-activate rollback, failing release | driver |
| `order` | topological sort, bands, ties, vacuous constraints, recomputation | driver |
| `point` | the three kinds, fan-out, composition, provider shadowing, exclusivity | driver |
| `export` | keying, aliasing, ambiguity | driver |
| `depend` | requirement checks at load vs activate, activation ordering, cycles | driver |
| `apply` | idempotent document application, add/remove/patch/toggle | driver |
| `error` | every code in §12, and the message format | both |
| `trace` | the lifecycle event records | driver |

### 15.4 What is deliberately not in the corpus

Real dynamic module loading (§10.2), thread-safety under contention,
and anything involving a clock. Those are per-port integration tests,
named as such, so nobody mistakes a green corpus for full coverage —
station's split, for station's reason.


## 16. Repository layout and porting discipline

The layout is `voxgig/struct`'s and `voxgig/omni`'s, because every
Voxgig engineer and agent already navigates it:

```
plugin/
├── README.md               # overview + language-neutral reference
├── DOCS.md                 # the comprehensive guide (incl. probe definitions)
├── AGENTS.md               # agent operating guide (prime directives, workflows)
├── CLAUDE.md               # points at AGENTS.md
├── Makefile                # test/lint/parity/spec aggregate targets
├── docs/design/plugin.md   # this document
├── spec/
│   ├── plugin.aontu        # THE CONTRACT — edit this
│   ├── plugin.json         # generated by `make spec`, committed
│   └── def/plugin-spec.aontu   # the spec-format shape, checked by `make spec-check`
├── tools/
│   ├── build-spec.js       # aontu -> json
│   ├── check_parity.py     # every port defines the canonical API
│   └── check_probes.py     # every port implements every probe definition
├── typescript/             # CANONICAL
└── <lang>/                 # one per port: src, driver, test, Makefile, README, AGENTS
```

Prime directives, inherited wholesale and non-negotiable:

1. **TypeScript is canonical.** Behaviour is defined by the canonical
   source; every other language is a port of it.
2. **The corpus is the contract.** A port that disagrees with
   `spec/plugin.json` is wrong. Never weaken the corpus to make a port
   pass.
3. **Change canonical first, then propagate.** A behaviour change is TS
   + corpus + every port, in one change set.
4. **Parity stays green.** `make parity` checks the canonical API names
   in local casing, and `check_probes.py` checks the driver catalog.
5. **Never hand-edit `spec/*.json`.**

One directive is new, and it is the dependency rule:

> **Zero third-party runtime dependencies. `voxgig/struct` is the single
> permitted Voxgig dependency**, for `merge`, `validate`, `getpath`,
> `setpath`, `clone`, `items` and `walk`.

That is a deliberate divergence from struct's and omni's absolute zero,
and it is worth defending: option merging and option validation must
behave *identically* to sdkgen's `makeOptions`, which is struct's
`merge` + `validate`; struct is already ported to the same language set
including C, C++ and Zig; and re-deriving deep-merge semantics
per-port is precisely the class of bug the corpus exists to catch.
Where struct cannot be linked (a vendored SDK build), a port carries the
same vendored subset the SDKs already carry. The plugin library takes
nothing else, in any port, ever — and, like omni's runner, the plugin
library must never be used to implement its own tests.

Naming and casing follow the house rules: `makehost` / `makeHost` /
`MakeHost` / `make_host` / `plugin_make_host` per language, parity
checked case- and underscore-insensitively. The canonical API surface —
what parity checks — is small on purpose:

```
makehost  parseref  formatref  checkname  checktag
normalizeconfig  resolveoptions  resolveorder  resolvecandidates  applyenv
```

Everything else is methods on the host and instance types.

### 16.1 Port tiers

Rollout follows station's tiering habit rather than pretending 23
languages arrive together:

| tier | ports | what "done" means |
|---|---|---|
| **1 — reference** | typescript | canonical; every section; both integration suites |
| **2 — proving pair** | go, python | one static-only + one dynamic; these two exist to break TypeScript-shaped assumptions before they spread |
| **3 — the rest of A** | javascript, ruby, php, java, csharp, rust, perl, lua, elixir, dart, swift, kotlin, scala, clojure | full corpus; dynamic where the tier-D table says so |
| **4 — constrained** | c, cpp, zig, haskell, ocaml, lean | static-only, full corpus, hand-rolled where needed |

A port is "complete" when it passes every corpus section, implements
every probe, and is green in `make parity`.


## 17. Host adoption

The design is only worth anything if it deletes code from real
libraries. Two candidates, both concrete.

### 17.1 station

Station's design §3 (the plugin contract), §3.2 (registry), §3.3 (wrap
ordering), §3.4 (lifecycle) and §3.5 (config resolution) are all
instances of what is described above:

| station concept | plugin equivalent |
|---|---|
| a bound SDK | an instance |
| `station.plugins()` | `host.list()` |
| the transport middleware wrap, "immediately outside the base transport" | a `chain` binding on the `request` point with a low band, plus `inst.position()` verification (§6.5) |
| the `station` feature ordering special case in `makeOptions` | ordering constraints (§7) — the special case goes away |
| `station.json` `profiles.<p>.plugin.<slug>` | the config document's profile overlay, verbatim |
| §3.5's seven-level precedence | §9.3's eight-level precedence, of which station's is a subset |
| `station.close()` | `host.close()` |
| binding one client twice is an error | `plugin_ref_duplicate` |

Two things station gains that it does not have today: **more than one
binding of the same SDK** (two `solardemo` clients against different
profiles — `solardemo$eu` and `solardemo$us` — which the current
slug-keyed registry cannot express), and **runtime deactivation** (turn
off an integration without tearing down the process, with its
credentials released as part of the ledger).

The migration is not a rewrite: station keeps `connect`/`adopt`/
`options` as its public API and implements them over a host. That is
the proof obligation of phase P3 below.

### 17.2 sdkgen features

An sdkgen SDK becomes a host by declaring its existing vocabulary:

- 13 `hook` points, named exactly as today (`PostConstruct`, `PrePoint`,
  `PreRequest`, …), so a feature's method names are its bindings;
- one `chain` point, `request`, whose base is `utility.fetcher`;
- `provider` points for the seams `__replace__` currently serves.

A `Feature` class is then mechanically a definition: `name`, `version`,
`init(ctx, options)` splits into `define` (read options, declare
bindings) and `activate` (capture), and the transport wrap stops being
an irreversible assignment. `options.feature` (map or array) is a config
document in the SDK's spelling; `options.extend` becomes static
registration.

This is stated as a demonstration, not a commitment: **the deliverable
is a bridge in this repo that runs an unmodified sdkgen feature as a
plugin**, proving the vocabularies map, and leaving whether sdkgen's
generated code adopts it as a separate, sdkgen-side decision with its
own propagation cost across 23 template trees.


## 18. Implementation plan

Sequenced as a tracer bullet: one thin, end-to-end, *working* slice
first, then depth, then breadth. TypeScript is the tracer.

### P0 — Repository skeleton

Layout of §16; `README`, `DOCS`, `AGENTS`, `CLAUDE`, `Makefile`; this
design doc; `spec/def/plugin-spec.aontu` (the spec-format shape);
`tools/build-spec.js` copied from omni's; empty `check_parity.py` with
the canonical name list.

*Exit:* `make spec` and `make spec-check` run on an empty corpus.

### P1 — The tracer bullet (typescript)

The thinnest thing that is genuinely end-to-end, not a subset that
avoids the hard parts:

- ref parsing/formatting; the config document normalizer; static
  catalog; `load` / `activate` / `deactivate` / `unload` / `close`;
  the state machine with its errors; **one point of each kind**
  (`hook`, `chain`, `provider`); the release ledger; the topological
  order resolver; `list`/`order`/`status`/`trace`.
- The driver, the probe catalog, and corpus sections `ref`, `config`,
  `lifecycle`, `state`, `resource`, `point`, `order`, `error`.
- A worked example in `typescript/example/`: a host with a `request`
  chain, two instances of one definition, deactivated and reactivated at
  runtime.

*Exit:* `make test-typescript` green; the §15.1 scenario passes as
written; deactivating a plugin demonstrably closes its handles.

### P2 — Completing the canonical

Dynamic resolution and the resolver interface; `resolvecandidates`;
env application; `apply()`; exports and dependencies; `reconfigure`;
position verification; the remaining corpus sections (`env`, `resolve`,
`export`, `depend`, `apply`, `trace`); the ts integration suite that
does real `require`-based loading.

*Exit:* every section of the corpus exists and is green in TypeScript;
`DOCS.md` complete, including the probe catalog specification.

### P3 — Proof against real hosts

Both, in TypeScript, because a plugin system unvalidated by a real host
is a guess:

1. **station** — reimplement station's TS registry over a host, behind
   its unchanged public API. Station's own conformance corpus and
   integration suites must stay green. Then add what the host makes
   newly possible: two instances of one SDK, and a runtime deactivation
   test that asserts the credential is released.
2. **sdkgen bridge** — a `FeatureHost` that runs an unmodified sdkgen
   feature class as a plugin, exercised against the generated test SDK.

*Exit:* station's suites green on the new implementation; the bridge
runs `RetryFeature` unmodified, and deactivates it — which sdkgen alone
cannot do.

### P4 — The proving pair (go, python)

Go first, because static-only + typed extension points + explicit
errors will find every TypeScript-shaped assumption in the model. Python
second, as the closest dynamic analogue that is not JavaScript.

*Exit:* both pass every corpus section; `make parity` green; any
divergence the model cannot express is fixed **in the canonical**, not
worked around locally. Expect the model to change here — this phase is
scheduled for that.

### P5 — Tier 3 breadth

javascript, ruby, php, java, csharp, rust, perl, lua, elixir, dart,
swift, kotlin, scala, clojure. Ordered by the presence of an existing
station/struct port to copy discipline from. Dynamic loading per the
§10.3 table, with the capability advertised and the integration test
per port.

### P6 — Tier 4 and consolidation

c, cpp, zig, haskell, ocaml, lean — static-only. Then the cross-repo
question: an sdkgen `plugin` feature package, and whether station's
other ports migrate.

### 18.1 Sequencing rules

- **Nothing merges without the corpus.** A behaviour that is not in
  `spec/plugin.aontu` does not exist.
- **P4 may change the canonical**, and that is the point of doing it
  before P5. After P5 begins, a model change costs ~15 ports.
- **Each phase updates the plan register** in the same change that
  lands the work — omni's `doc/plan/` discipline (`adoption.md`,
  `progress.md`, `status.md`, `handover.md`), adopted here for the same
  reason: the register is the one place the whole goal is visible.


## 19. Budgets

Twenty-plus hand-written ports stay sustainable only if each is small,
and they stay small only if the design forbids growth. The rule:

> **The library owns naming, configuration, lifecycle, ordering,
> binding and teardown. Nothing else.** No logging framework, no DI
> container, no scheduler, no IPC, no sandbox, no hot-reload file
> watcher, no service discovery. Anything a plugin needs beyond the
> host's own extension points, it brings itself.

Budget, per port: **~800–1200 lines** for a garbage-collected language,
plus the driver. A port that busts it is a signal the model grew, and
the response is to shrink the model, not to accept the port.


## 20. Open questions

1. **Automatic deactivate/reactivate on a runtime option patch** (§9.4)
   is always correct and sometimes surprising — a rate limiter loses its
   in-flight window. The alternative is to reject a patch on an active
   instance without `reconfigure`. Resolve in P1, with the corpus.
2. **Does `unload` destroy state, or may a host keep it for a later
   reload?** Currently destroyed at `close`. A "detached state" concept
   would serve config reload, at real complexity cost.
3. **Should hook bindings be able to abort the fan-out?** `strict: true`
   at point declaration covers errors; nothing covers "handled, stop".
   Resist until a host needs it.
4. **Per-instance scoping of the host** — seneca's delegate gives each
   plugin a view of the host that attributes its calls automatically. It
   is genuinely useful and genuinely hard to port. Deferred to P2 as a
   possible `inst.host` wrapper.
5. **Does station's proxy need to see plugin state?** If station's
   `station_integrations` MCP tool grows a "deactivate this integration"
   verb, activation state becomes remotely controlled, and the wire
   protocol needs a representation. Station-side question, raised here
   so it is not a surprise.
6. **Versioning between host and plugin.** A definition declares a
   version; nothing yet declares "I need host API >= X". Probably a
   `requires.host` semver range, deferred until the API has moved once.


## 21. Non-goals

- **Isolation or sandboxing.** Plugins run in-process with full host
  privileges (§10.4). Out-of-process plugins are a different design.
- **Hot code reloading.** `unload` + `load` is the mechanism; watching
  the filesystem is the host's business.
- **Durable state.** State lives for the instance's lifetime in the
  process (§5.4). `snapshot`/`restore` is named, not built.
- **A dependency-injection container.** Exports and provider points are
  deliberately dumber than DI.
- **A message bus.** Hook points are fan-out within one host, not
  transport. seneca's action mesh stays seneca's.
- **Distribution, publishing or a registry.** The npm/PyPI/crates
  ecosystem is the registry; this library only resolves names.
- **Replacing sdkgen's feature system.** §17.2 proves the mapping and
  ships a bridge. Whether generated SDKs adopt it is sdkgen's call,
  costed across 23 template trees.
