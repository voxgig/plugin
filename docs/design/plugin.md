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
> **instance** is a concrete, stateful incarnation of a definition,
> addressed by **name+tag** — `retry$fast` and `retry$slow` are two
> instances of one definition, in one host, at the same time; the name
> is always the definition, the tag says which one. An instance is **loaded** (configured,
> stateful, inert) or **live** (bound into the host's extension
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
- [22. Prior art: Cordis](#22-prior-art-cordis)
- [23. Prior art: OSGi](#23-prior-art-osgi)


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
| the runtime thing | feature instance in `_features` | plugin in `private$.plugins` | **instance** |
| identity | `name` | `name$tag` | **`name$tag`** |
| the extensible thing | the SDK client | the seneca instance | **host** |
| binding | hook method names | `seneca.add()` patterns | **extension points** |
| wrap | `utility.fetcher = f(inner)` | prior chain | **chain point** |
| observe | `PreRequest` etc. | `seneca.sub()` | **hook point** |
| replace | `__replace__` | overriding pattern | **provider point** |
| config | `options.feature.<n>` | `options.plugin.<full>` | **`plugin.instance.<ref>`** |
| on/off | `active: true` at construction | load or don't | **loaded / live states** |

The one genuinely new idea is the last row: separating *loaded* from
*live*, and making activation the sole resource-capturing transition.
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

**Instance** — one concrete incarnation of a definition inside one host,
addressed by name+tag (§4). Has resolved options, plugin-owned persistent state, a status
(§5.1), a set of bindings into the host's extension points, and a
resource scope (§8). An instance is the unit of naming, configuration,
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
              │ ref/name/tag/id     status: live        │
              │ options  (resolved, §9.3)              │
              │ state    (plugin-owned, persists §5.4) │
              │ bindings (declared in define, §6)      │
              │ releases (captured in activate, §8)    │
              └────────────────────────────────────────┘
```


## 4. Naming and referencing

**One identity, two parts.**

- **name** — the definition. `^[a-zA-Z@][a-zA-Z0-9.~_\-/]*$`, max 1024
  chars. `retry`, `stripe`, `@voxgig/plugin-retry`.
- **tag** — which instance of it. `^[a-zA-Z0-9.~_-]+$`, max 1024 chars,
  or empty.

Written `name$tag`, or just `name` when the tag is empty. That written
form is called a **ref**, and it is a spelling of the pair rather than a
third thing: `parseref` and `formatref` convert between them, and every
public API takes either.

That is the whole model. An instance *is* "the `test` one of `stripe`",
and `stripe$test` says exactly that in one token. There is no separate
instance name, no alias field pointing at a definition, and no
incarnation suffix — **the name is always the definition name**, which
is the invariant that makes everything downstream cheap: a registry
groups by the part before the `$`, a config file's key is its own
documentation, and nothing has to be told twice what a thing is an
instance of.

Rules, all pinned by the corpus:

1. **A name+tag pair addresses at most one instance in a host.**
   Declaring a pair that is already registered is `plugin_ref_duplicate`
   — not a silent overwrite (seneca) and not an impossibility (sdkgen).
2. **The empty tag is an ordinary tag.** `stripe` and `stripe$test` are
   two different instances of one definition, and both may exist. The
   single-instance case writes no tag and never learns tags exist.
3. **Auto-tagging is explicit.** `declare('stripe', {tag: '?'})` assigns
   the lowest unused positive integer tag — `stripe$1`, `stripe$2`, … —
   and returns the assigned pair. Without `'?'`, a collision is an
   error. This is also the answer for a host handing out uncached
   instances from one declared name (a per-request credential scope,
   station's `create()`): they are ordinary tagged instances, not a
   parallel identity scheme.
4. **Two numbers, and they are not the same number.** Each instance
   carries **`pos`**, its position in the declaration order — the
   document's array index, or the sorted-ref index for the map form —
   and **`seq`**, a monotonic counter from the host incremented on
   every declaration. `pos` is *stable across a redeclaration*: an
   instance unloaded and declared again by `apply` (§9.6) keeps the
   position its document gives it, while `seq` advances. So `pos`
   decides ordering ties (§7) and `seq` distinguishes one incarnation
   of `stripe$test` from the next in a trace. Collapsing them would
   let a re-applied document silently reorder a chain: toggle an early
   instance and its fresh `seq` would sort it behind everything that
   never moved. Neither is part of the address.

   **They are pinned in three different sections, and that is not an
   accident.** `pos` is assigned by document normalization, so it is
   `config`'s and stays pure. `seq` is a counter the host holds, and
   auto-tagging (rule 3) needs to know what is already declared — both
   are host state, so both belong to the `declare` driver section.
   `pos` *stability across a redeclaration* is `apply` behaviour and is
   pinned by `order`'s tie group, which is where getting it wrong
   actually shows. An earlier draft of §15.3 assigned all of this to
   `ref` and marked that section pure; nothing in the pure surface —
   `parseref`, `formatref`, `checkname`, `checktag` — can reach any of
   it.
5. **Refs are canonicalized on the way in.** `"stripe$"`, `"stripe"` and
   `{name: 'stripe', tag: ''}` all normalize to `stripe`. Ports must
   canonicalize before comparison; the corpus's `ref` section is the
   arbiter.

Canonical functions: `parseref(str) -> {name, tag}`, `formatref(name,
tag) -> str`, `checkname`/`checktag`. Pure, which is why they are the
first thing a new port implements and the first section of the corpus
it passes.

**What this replaced.** Two earlier drafts of this section carried more
machinery than the job needs: first a `$tag` identity with an
`define`/alias escape hatch, then — on station's evidence (§17.1) — a
free-form instance name *plus* a `define` field naming the definition,
*plus* `ref#n` for derived incarnations. Four concepts where two do the
work. The free-form form let station write `stripe-test` and say
`api: stripe` separately, which reads well in a config file and costs a
second name to keep consistent, a field that can disagree with it, and
an "is this the instance or the definition?" question at every use
site. `stripe$test` answers that question in the token itself. The one
real forfeit is **aliasing** — an instance of `memcache` called
`cache$hot` — which now has to be `memcache$hot`. That is a cosmetic
loss and the invariant is worth more than the cosmetics.


## 5. States, transitions and lifecycle

### 5.1 The state machine

```
   forward, and each step implies the ones before it:

              declare()         load()         activate()     requirements met
   (absent) ───────────► declared ─────► loaded ─────────► pending ──────────► live
                                                              ▲                  │
                                                              └──────────────────┘
                                                                requirements lost

   back:   deactivate()   any of pending/live    ─────────►  loaded
           unload()       any state              ─────────►  (absent)
           ready(ref)     runs the whole forward path in one call

   a failure in any transition  ─────►  failed  ─────►  (unload only)

   plugin state survives every backward step except unload
```

Seven statuses, and no more: `declared`, `loaded`, `pending`, `live`,
`failed`, plus the two transient ones `loading` and `closing` that are
observable only from inside a callback or from another thread. A port
that adds an eighth is diverging.

- **`declared`** — the ref exists, its **configuration layers are
  collected and normalized but not yet merged**, and nothing else has
  happened: the definition has not been resolved, no module has been
  imported, no plugin code has run. It is a row in the registry and a
  list of layers, and it costs a map entry.

  Layers, not a merged value, and the distinction is load-bearing
  rather than pedantic — twice over. §9.3's precedence starts at the
  *definition's* option defaults and §9.4 validates against the
  *definition's* option shape, neither of which exists until the
  definition is resolved, which this state forbids. **And the shape
  decides how the merge behaves**: a definition may mark an option
  `` {"`$MERGE`": "append"} `` (§9.4), which turns list replacement
  into list append. Merging before that is known would discard
  lower-precedence elements irrecoverably — a base list overlaid by a
  profile list, flattened at declaration, cannot be un-flattened at
  load.

  So a `declared` instance holds the ordered layers as data; **the
  merge, the resolution and the validation all happen at `load`**, in
  that order, which is also the first moment a bad option value can be
  reported in ordinary operation. (`host.check()` deliberately reads
  the same shape earlier, from the catalog and without loading, to
  report what `load` would say — §9.6. It is a pre-flight, not a second
  path: nothing it does changes where the ordinary path validates.) A port that merged or resolved here would have to import
  plugin code to do it correctly, which is the one thing this state
  exists to avoid.

  This state is here because the first real consumer cannot work
  without it. Station (§17.1) declares twenty-plus SDK instances in one
  config file — `stripe`, `stripe$test`, `github$ent`, … — and
  constructs each on first use — and the *reason* it is
  built that way is that resolving twenty SDK packages at startup,
  whether or not the process touches them, is the specific defect its
  declarative design set out to remove. A model whose cheapest state
  still runs `define` would have reproduced that defect exactly, and
  handed station a reason not to adopt it. Declaration must be free, or
  scale is a lie.

- **`loaded`** — definition resolved (this is where a dynamic import
  happens), `define` run, options resolved, state allocated, bindings
  declared, **no resources held, no host participation**. A loaded
  instance receives no hook calls, is not in any chain, and provides no
  providers. This is the *deliberate* off state: it is ready and nobody
  has asked it to run.
- **`pending`** — activation *has* been asked for, and cannot happen yet:
  a declared requirement (§11) is not live. Observably identical to
  `loaded` — nothing held, nothing bound — but it means something
  entirely different to whoever is reading `host.list()`, which is why
  it is a state and not a flag. The host activates it the moment the
  requirement arrives, without being asked again.
- **`live`** — bindings are installed and running, resources are held.
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
| `declare(spec)` | absent | `declared` | nothing registered; error raised |
| `load(ref)` | `declared` | `loaded` | `close` runs, entry stays `declared`; error raised |
| `load(spec)` | absent | `loaded` | declare, then load; `close` runs, nothing registered |
| `activate(ref)` | `loaded` | `live`, or `pending` if a requirement is unmet | bindings removed, scope unwound in reverse; → `failed` |
| *(automatic)* | `pending` | `live` | as `activate` |
| *(automatic)* | `live` | `pending` | a requirement was lost (§11) |
| `deactivate(ref)` | `live` | `loaded` | bindings removed, scope still fully unwound; → `failed` |
| `deactivate(ref)` | `pending` | `loaded` | — (nothing to undo; see below) |
| `unload(ref)` | `declared`, `loaded`, `pending`, `failed` | absent | error raised; registry entry dropped anyway |
| `unload(ref)` | `live` | absent | deactivate first, then close |

**Every transition implies the ones before it.** `activate` on a
`declared` instance loads it first; `load` on an absent ref declares it
first. So a host that wants the whole staircase in one call writes
`host.ready(ref)` — declare if needed, load if needed, activate, return
the instance — and a host that wants to inspect without executing
anything calls `host.instance(ref)`, which **never** advances the state.
That distinction is the whole point of the state: introspection has to
stay free, or a status page becomes a way to accidentally import twenty
packages.

The two automatic rows are the reactive half of §11, and they are the
reason `pending` exists: activation is a *standing request*, not a
one-shot event. Asking for an instance to be live means it is live
whenever it can be, and `deactivate` — an operator withdrawing the
request — is the only thing that returns it to `loaded`.

**Deactivating a `pending` instance runs no callback.** It never
reached `activate`, so it holds no scope and no live bindings, and
there is nothing for `deactivate` to undo — running the definition's
`deactivate` there would be teardown without matching setup, which
plugins are not written to survive and which could fail an instance
that had done nothing wrong. It is a callback-free withdrawal of the
standing request, and it cannot fail.

**Any** failure during a transition — a lifecycle callback raising, or a
ledger entry raising (§8) — lands the instance in `failed`. There is no
second, softer failure state for "deactivated, but the release was
messy": the whole point of `failed` is that it is not trustworthy, and a
plugin whose resources may still be held is exactly that. Bindings are
always removed before the status changes, so a `failed` instance never
participates in anything, whatever went wrong.

Every transition is **idempotent in the trivial direction**:
`activate` on a live instance is a no-op returning success, not an
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
activate(instance)            // capture resources, through the instance scope (§8)
deactivate(instance)          // (host unwinds the scope; hook for extras)
close(instance)               // final teardown before removal. State dies here.
```

Only `define` is required. The split is the central discipline of this
design, and the rule is one sentence:

> **`define` may allocate memory. `activate` may allocate anything.
> Everything `activate` allocates is unwound on deactivate — recorded
> automatically when it went through the instance, explicitly via
> `release` when it did not (§8).**

"Resource" means: sockets, files, timers, threads, subscriptions,
watchers, child processes, native handles, host mutations, entries in
anything shared. Memory that the plugin alone can reach is not a
resource.

`define` is also the **only** place bindings may be declared (§6). That
is deliberate: it means the host knows an instance's complete binding
set while the instance is still inert, so `activate` is a pure insertion
and `deactivate` a pure removal, with no discovery in between. It also
means `host.list()` can tell a developer exactly what a loaded-but-not-
live plugin *would* do.

### 5.4 State

`instance.state` is a plugin-owned value the host never reads, writes,
copies or serializes. It is created in `define` and destroyed in
`close`. It **survives deactivate/activate cycles unchanged** — that is
what makes the instance "a concrete instance with persistent state"
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

The idea is not new and should not pretend to be: OSGi named it the
**whiteboard pattern** in 2004, in a paper called *Listeners Considered
Harmful* (§23), and gave exactly this reason — an extension that calls
`addListener` on the host has created a cleanup obligation that
something now has to remember, while an extension that merely registers
and waits to be discovered has not.

Three kinds, chosen because they are what the two existing systems
actually needed, and no more:

### 6.1 `hook` — fan-out

Many bindings, all called, no composition. The sdkgen hook vocabulary
(`PrePoint`, `PreRequest`, …) is exactly this. The host calls
`host.emit(point, arg)`; every live binding runs, in resolved order
(§7); return values are ignored.

**A hook point declares its dispatch mode, and "fan-out" is not one
answer but four.** In a language with asynchrony, "call every binding"
hides a decision — start them all and wait for all, await each in turn,
or do not wait at all — and a design that leaves it unsaid gets four
different answers from four ports, in the concurrency behaviour of
production code that no corpus entry happens to cover. So the mode is
part of the point declaration:

| mode | dispatch | returns |
|---|---|---|
| `emit` | every binding, no waiting (the default) | errors raised *synchronously*; a later async failure is trace-only |
| `parallel` | every binding, started together, all awaited | the collected errors, once all settle |
| `serial` | every binding, awaited one at a time in resolved order | the collected errors |
| `bail` | in resolved order, **stops at the first binding that returns a value** | that value, or absent |

**Null declines.** "Returns a value" means a value, and a null — `nil`, `None`, `null`, `undefined`, whatever the port spells it — is the absence of one. JavaScript can tell `null` from `undefined` and almost nothing else in the target set can: Go, Python, Ruby, PHP, Lua, Java and C# each have exactly one way to say nothing. Making the distinction load-bearing would cost every one of them a wrapper type carried through the whole dispatch path, to express a difference a plugin author in those languages cannot even write. §18's budget settles it: a binding that returns null has declined, and the next one gets its turn.

`bail` is the "handled — stop" case, and it earns its place: it is how a
plugin overrides a default without replacing the whole implementation
the way a `provider` point does. Cordis ships the same four (plus
`waterfall`, which is this design's `chain`), which is a fair sign the
set is neither too small nor invented.

In a port with no asynchrony, `emit`, `parallel` and `serial` collapse
into the same loop, and the mode is then purely documentation — but it
is documentation the *other* ports are bound by, so it is declared
everywhere.

A raising binding does not stop the others by default. Because "reported"
is not a specification — one port collecting errors and another
discarding them would be a genuine cross-port divergence in exactly the
production path nobody tests — the reporting is pinned:

- each error emits a `fail` trace record (§13) carrying the ref, the
  point and the cause. **That is the only report `emit` can make for a
  binding that fails after it returns** — a fire-and-forget dispatch
  has, by construction, no result left to put a late rejection in, and
  a mode that promised to collect them would be promising something no
  async port can deliver. `emit` returns the errors its bindings raised
  *before it returned*; anything later is trace-only, and a host that
  needs every failure in hand declares the point `parallel` instead —
  which is the same fan-out, awaited;
- `parallel` and `serial` return the collected list, empty when every
  binding was clean. A host that ignores the return value has ignored
  the errors, visibly;
- the collected list is also raised as a single `plugin_hook_failed` when
  the point is declared `{ raise: true }`, for hosts that would rather
  not check a return value;
- `{ strict: true }` on the point declaration stops at the first error
  and propagates it unwrapped — remaining bindings do not run. **It
  therefore forces `serial` dispatch**, whatever mode the point
  otherwise declares: "stop before the next one runs" is only
  meaningful if each binding has settled before the next starts, and
  on a fire-and-forget `emit` every binding would already have been
  launched before the first rejection arrived. Declaring `strict` is
  declaring an ordered, awaited fan-out; the mode field records that
  rather than contradicting it.

`call` on a chain point needs none of this: an error propagates through
the composed chain to the caller, which is what a chain is for.

### 6.2 `chain` — composition

Ordered wrappers around a host-owned base function. This is
`utility.fetcher`, seneca's prior chain, and station's transport
middleware. The host declares the point with a base implementation and
calls `host.call(point, args…)`; the host composes
`b1(b2(b3(base)))` from the live bindings in resolved order, where the
first binding is outermost.

**A plugin cannot replace the base, and does not need to.** The base
belongs to the host, so a plugin whose job is to *substitute* the
transport rather than wrap it — sdkgen's `test` feature, which assigns
`ctx.utility.fetcher` outright — binds as the innermost link and simply
does not call `next`. The effect is identical and the ownership is
not: the host's base stays reachable, the substitution is visible in
`host.order(point)` like every other link, and nothing needs a
declared "this one is a base" role. Station had proposed exactly such a
role — `transport: 'base' | 'wrap' | 'none'` across seventeen feature
models — and it disappears here, along with the seventeen-model change,
because position already carries it. A host that wants the invariant
enforced pins the innermost slot (§7) rather than trusting a
self-declared role.

The composition is **recomputed by the host** whenever the live set
changes, and cached between changes. Plugins receive `next` as an
argument; they never see or store the previous value of anything. A
plugin that stashes `next` and calls it after deactivation is a bug the
host cannot prevent, and the corpus says so in a comment rather than
pretending otherwise.

### 6.3 `provider` — exactly one

A named slot with at most one live implementation, and a host-supplied
default. sdkgen's `__replace__` and "the secret store" are this. When
several live instances bind the same provider point, the winner is the
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

### 6.5 An instance may itself be a host

The model as far as §6.4 has hosts and plugins and no way for one to be
the other. The first real consumer will need exactly that, so it is in
the model rather than discovered later.

Station (§17.1) declares SDK instances as plugins — and every generated
SDK carries **its own** plugin system, sdkgen's features (`retry`,
`cache`, `debug`, `proxy`, `test`…), which station also configures
fleet-wide from the same document. So a station plugin instance would
itself be a host of feature plugins. Two levels, and the outer one owns
the inner one's lifetime.

**A generated SDK is not natively a host, and the bridge is how this
is reached before it becomes one.** Today an SDK has `options.feature`
(map or ordered array) and a `FEATURE_CLASS` table, and station
configures features by composing that array (§17.1). Wrapping one in
`inst.host(...)` *directly* would be a host-shaped object around a
non-host, and §17.2 declines to commit sdkgen to changing that.

What closes the gap is **P3's `FeatureHost` bridge** (§17.2, §18),
which runs an unmodified sdkgen feature class as a plugin. The inner
host is the bridge, not the SDK: it populates its catalog from the
SDK's `FEATURE_CLASS` table, maps the SDK's 13 hook points and its
`request` chain onto plugin points, and composes the SDK's own feature
array from its live set. A fleet-wide default therefore reaches an
instance through a nested host **with the generated SDK unmodified**,
which is the form P3's bar is written against.

So the sequence is: the bridge makes the mapping reachable at P3;
sdkgen adopting later would *delete* the bridge rather than enable the
model. The model is specified now because carrying it from the start is
far cheaper than retrofitting it onto a shipped lifecycle.

```ts
def.activate = (inst) => {
  const sdk = inst.host({ point: { request: { kind: 'chain', base: rawFetch } } })
  // ... declare/activate the SDK's own features into `sdk`
}
```

`inst.host(spec)` creates a host **owned by the instance**, and it is
an ordinary scope entry (§8): deactivating the outer instance closes
the inner host, which deactivates and closes everything in it, in
order. There is no separate teardown path and no way to forget one.

Three rules keep this from becoming a graph:

- **Ownership is a tree, never a mesh.** An inner host belongs to one
  instance. It does not inherit the outer host's points, catalog or
  registry — if it did, a ref would stop addressing one instance
  (§4 rule 1), and `host.list()` would have to mean two things.
- **Capabilities do not cross the boundary** by default. An inner
  plugin requiring `clock` is asking its own host, not its
  grandparent's. A host that genuinely wants to share passes the
  capability down explicitly, `inst.host({ inherit: ['clock'] })`,
  which is a decision written in one place rather than an ambient rule.

  **An inherited capability stays live across the boundary.** It is a
  *view* of the outer host's capability, not a copy taken at creation:
  when the outer provider leaves `live`, §11's reactive deactivation
  fires inside the child exactly as it would for a native one, and the
  child's consumers return to `pending` until it comes back. Anything
  else would leave an inner plugin `live` against a dead provider —
  the precise failure §11 exists to prevent — reintroduced by the
  nesting. The inner host's `resolve()` (§11.4) therefore includes
  inherited capabilities and reports their outer provider by its full
  path.
- **Trace records carry the ancestry as a list of refs**, `["stripe$test",
  "retry"]`, not a joined string. A `/` is legal inside a definition
  name (§4), so `stripe/retry` is ambiguous between a top-level
  instance called `stripe/retry` and the `retry` child of `stripe` —
  and a status tool that merged those two would be doing the opposite
  of what the path is for. Rendering for humans joins with `/`;
  the *record* stays structured.

The nesting is not recursive by ambition; nothing stops a third level,
and nothing in the design encourages one.

### 6.6 Position verification

Station's §3.3 found that a plugin can need to *know* it is in the right
place — its middleware must sit immediately outside the base transport
or its "wire truth" events are fiction. So a chain binding may query its
resolved position: `inst.position('request')` returns `{index, count,
innermost, outermost}`, valid while live. A plugin that requires a
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
3. **Declaration order last.** Ties break by the instance's `pos`
   (§4 rule 4) — its position in the declaration order, not the order
   in which instances happened to load and not its incarnation `seq`.
   Both distinctions are load-bearing: with lazy instances (§5.1)
   twenty declared in document order may load in whatever order their
   first `ready()` calls arrive, and with `apply` redeclaring a
   toggled instance (§9.6) a counter-based tie-break would sort it
   behind everything that never moved. `pos` is the order the document
   visibly states, and it is the one that must decide.

**Bands are OSGi start levels, and they carry the same hazard** (§23).
A global integer ordering is the thing people reach for when they have
a dependency they have not declared: bump the number until it works,
ship it, and leave a system whose startup order is a pile of magic
constants nobody can safely change. The rule, stated so the review has
something to point at: **a band expresses a genuine cross-cutting layer
("the base transport wrapper"), a constraint expresses a relationship
between two specific things, and a band that was chosen by trial and
error to fix an ordering bug is a bug wearing a number.** Constraints
beat bands in the sort precisely so that the correct tool wins when
both are present.

Constraints referring to an absent binding are **satisfied vacuously**
(not an error): a plugin ordered `after: 'test'` must load in a host
with no test plugin. That is the sdkgen `__after__` behaviour, kept.

**A host may pin a binding's position, and a pin is not a constraint.**
`host.point('request', {kind: 'chain', pin: {station: 'innermost'}})`
fixes where a named instance's binding sits, and an ordering that would
move it is `plugin_order_pinned` — rejected, not honoured.

**A pin names an end of the chain, not a sort position, and the two
read in opposite directions.** §6.2 composes `b1(b2(b3(base)))` with the
*first* binding outermost, so "first" and "innermost" are opposites; a
pin spelled in sort terms would be read backwards by exactly the people
it exists to protect. The vocabulary is therefore positional:
`outermost` and `innermost` for a `chain`, `first` and `last` for a
`hook`. Station's adapter must sit *immediately outside the base
transport*, so it pins `innermost` — a `first` pin would place every
other wrapper between the adapter and the base and make its wire-truth
events observe the wrong boundary, which is the failure the pin exists
to prevent. Constraints
and bands are negotiable by definition: they are what plugins and
documents say they want, and the sort's job is to satisfy them all. A
pin is the host stating a structural invariant of its own architecture,
which is a different kind of claim and must not lose a tie to a
document.

Station is again the case that shows the need: its transport adapter
must sit immediately outside the base transport, `station.md` §3.3
pins that mechanism, and an `order` list that moves it has to be an
error rather than a preference honoured into a broken wrap. §6.6's
`inst.position()` is the *plugin*-side counterpart — a binding
verifying after the fact where it landed — and the two are not
substitutes: verification tells a plugin it was misplaced, a pin stops
the misplacement from being expressible.

The resolved order is recomputed on any change to the live set, is
exposed by `host.order(point)`, and is pinned by the corpus's `order`
section — including the awkward cases (a constraint against a
deactivated instance, two instances of one definition ordered relative
to each other by ref, a band that contradicts a constraint — the
constraint wins).


## 8. Resource capture

The requirement is that resource usage is dictated by activation state.
The mechanism is a **scope**: everything an instance does through its
handle is recorded against that instance and undone on deactivate,
automatically.

```ts
def.define = (inst, options) => {
  inst.state = { hits: 0 }
  inst.chain('request', wrap)                 // DECLARED here, never in activate
  inst.provide('store', myStore)              // (§5.3, §6.4)
}

def.activate = (inst) => {
  // the bindings declared above are NOT live yet: the host inserts them
  // only once this function has returned successfully (§8.1). Nothing
  // here re-declares them.

  inst.timer(1000, poll)                      // recorded: the host owns the undo
  const conn = inst.connect(inst.options.addr)// recorded, where the host offers it

  const sock = net.connect(inst.options.addr) // FOREIGN: the host cannot see this
  inst.release(() => sock.destroy())          // so it is registered explicitly
}
```

### 8.1 Bindings go live only when activation succeeds

The host inserts an instance's declared bindings **after `activate`
returns successfully**, never before. §14 permits point invocation
concurrently with a lifecycle transition, so inserting first would let
a request enter a chain wrapper whose connection, timer or cache the
plugin is still in the middle of acquiring — and, worse, let traffic
run through a plugin whose activation then failed and which the host is
about to unwind. Insertion is atomic with success: the instance is
either not participating, or participating with everything it declared
it needed.

The symmetric rule already holds on the way down: bindings are removed
*before* the status changes (§5.2), so nothing new enters while
teardown runs.

Two things are then unwound on deactivate, from two different places,
and conflating them is a mistake this document made in an earlier
draft:

- **bindings**, declared in `define` and inserted by the host at
  activation — the host removes them itself, and they are not scope
  entries. Calling `inst.chain` inside `activate` is
  `plugin_bind_scope` (§12), not a shortcut;
- **resources**, acquired during `activate` — the scope's actual job.

The rule that matters:

> **Anything reached through `inst` during `activate` records its own
> undo. `release` is only for what the host cannot see.**

A per-resource ledger the plugin author maintains by hand is a list
every author can forget an entry in, silently, forever — and a plugin
that forgot one looks identical to a plugin that had nothing to
release. Making the handle itself the ledger removes the whole class:
the author cannot forget to register what they never registered. This
is Cordis's model (§8.3), and it is a straight improvement over what
was here before.

- The scope belongs to the instance and is unwound by the host on
  deactivate, **in reverse registration order**, whether an entry came
  from a host call or from `release`.
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
- If `activate` raises partway, the host unwinds the entries registered
  so far, in reverse, and the instance goes `failed`.
- `inst.release` outside `activate` is `plugin_release_scope`.

### 8.2 What the host can actually promise

Before the mechanism, its limit — because OSGi (§23) has had total
lifecycle control since 1999 and *still* cannot deliver clean teardown,
and a design that implied otherwise would be selling something no
runtime has ever shipped. A stale reference in a static field, a
`ThreadLocal`, a thread nobody stopped, a callback handed to a library
that outlives you: any one of them keeps a "deactivated" plugin working
long after the host stopped talking to it.

So the guarantee is stated narrowly and honestly:

> **The host guarantees it stops routing to a deactivated instance and
> unwinds every resource that instance registered. It cannot guarantee
> the instance stopped running.**

Everything the host can see, it undoes. What a plugin handed to a third
party, stored in a global, or closed over and passed outward is beyond
any mechanism available in any of these languages. The corpus can only
test the first half — and §15.4 says so, rather than letting a green
suite imply the second.

This is not a reason to weaken the mechanism; it is the reason the
mechanism has to be the *default path* rather than an opt-in discipline.
The less a plugin author has to do by hand, the smaller the surface on
which they can defeat it.

**Reverse order is a guarantee about registration, not about
completion.** Where releases are asynchronous, the host starts them in
reverse order but does not serialize them — awaiting each in turn turns
a deactivation into a sum of timeouts, and no port should pay that for
a guarantee almost nothing needs. A plugin whose teardown genuinely is
order-dependent consolidates it into **one** release that does the
whole sequence itself. Cordis, which has run this in production for
years, documents exactly the same caveat, and a design that promised
strict ordering here would be promising something its ports would each
quietly break.

The corpus tests this with a synthetic resource: the driver's probe
definitions acquire numbered handles from a counter the driver owns, and
the expected output includes the ledger — so "deactivate released
exactly what activate captured" is a data assertion, in every language,
rather than a property nobody checks.

### 8.3 Why the scope, and not the ledger

The mechanism has two independent precedents, twenty years apart, which
is about as good as design evidence gets.

OSGi's `BundleContext` (§23) has, since 1999, automatically unregistered
everything a bundle registered through it when that bundle stops. The
context *is* the bundle's scope, and a bundle that only ever touched the
framework through it needs no teardown code at all.

Cordis (§22) makes every registration made through a plugin's context
inherently disposable and owned by that plugin's fiber — `ctx.on()`,
a service registration, or `ctx.effect()` for anything foreign — and
unwinds the lot when the plugin unloads. It is the same insight as this
design's "a plugin never mutates the host" (§6), pushed one step
further: not only does the plugin not mutate the host, it cannot even
*reach* the host except through a handle that is keeping score.

The practical consequence for a twenty-port library is larger than it
looks. A manual ledger has to be got right by every plugin author in
every language. A scope has to be got right once per port, and the
corpus can prove it: any host call made during `activate` must leave
the resource counter at zero after `deactivate`, and a port that
forgets to record one of its own seams fails that assertion.


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
    { "kind": "module", "prefix": ["@voxgig/plugin-", "voxgig-plugin-", "plugin-", ""] },
    { "kind": "path",   "dir": "./plugin" }
  ],

  // Per-definition defaults, keyed by NAME — never a ref. A base for
  // every instance of that definition; declares nothing itself (§9.3).
  "default": {
    "stripe": { "options": { "timeout": 5000 } }
  },

  // Instances, keyed by REF. The key carries the tag, so multi-instance
  // works in the map form too.
  "instance": {
    "retry":       { "active": true,  "options": { "retries": 3 } },
    "retry$slow":  { "active": false, "options": { "retries": 10, "minDelay": 500 } },
    "memcache$hot":  { "active": true,
                       "order": { "after": "retry" },
                       "options": { "max": 1000 } },
    "stripe$test":   { "active": true, "start": "lazy",
                       "options": { "base": "https://api.stripe.test" } }
  },

  // Profiles overlay the base. Selected by name at host construction
  // or by VOXGIG_PLUGIN_PROFILE.
  "profile": {
    "dev":  { "instance": { "retry": { "options": { "retries": 0 } } } },
    "prod": { "default":  { "stripe": { "options": { "timeout": 20000 } } },
              "instance": { "memcache$hot": { "options": { "max": 100000 } } } }
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
    { "ref": "memcache$hot", "active": true }
  ] }
```

Two keys decide how far `apply` takes each instance, and they are not
the same question:

- **`active`** (default `true`) — *may* this instance run at all?
  `false` declares it and bars it: it appears in `host.list()`, and
  `activate` and `ready` on it fail with `plugin_inactive` rather than
  quietly doing nothing. **The bar lives on the instance, not on the
  apply that set it** — a host that only skipped the barred ref while
  `apply` ran would let the next direct `ready` bring it live, which is
  the config switch being silently ignored. Every apply reasserts it in
  both directions, so a document that turns the instance back on clears
  it.
  That is how a profile switches an integration off without deleting
  its configuration (§17.1's `stripe$test` in prod).
- **`start`** (default `"eager"`) — *when* does it run? `eager` means
  `apply` activates it. `"lazy"` means `apply` leaves it `declared` and
  the first `ready(ref)` walks it up. A host whose instances are
  expensive to construct sets `lazy` and pays only for what is asked
  for; a host with five cheap plugins leaves the default alone and
  never learns the key exists.

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
library's own config. Hosts choose the file name and the lookup path;
the plugin library only ever sees the parsed subtree, and never reads a
file itself.

**A host may also rename these keys.** `makeHost({ keys: { instance:
'sdk', default: 'api' } })` maps a host's own vocabulary onto the
generic one before normalization. That is not a concession, it is the
point: `sdk` and `api` are the right words in `station.json` (§17.1),
and `instance` and `default` are the right words in a library that
knows nothing about SDKs. A generic library that forces its vocabulary into every
host's config file has mistaken uniformity for design.

The renaming is a pure map applied at **two places and no others: the
document root, and every `profile.<name>` overlay root.** Both are
needed and neither recurses. A profile overlay carries the same
`default` and `instance` keys the root does — that is what §9.3's
precedence levels 5 and 6 overlay — so a rename applied only at the
root would leave station's `profile.prod.api` and `profile.prod.sdk`
untranslated and silently drop every environment override the host
depends on. Recursing further would be worse: option data is the
definition's, and a host's key map has no business rewriting keys
inside it. The *shape* underneath is identical either way, so the
corpus tests the mapping once and every host gets it.

**A host may also reserve refs, and a host that embeds this library in
its own config file needs to.** `makeHost({ reserved: ['station'] })`
makes every key under a reserved name — `station`, `station$anything` —
`plugin_ref_reserved`. The host declares those instances itself, after
the user merge, and always wins.

**The reservation covers every input layer, not just the document.** A
reserved ref is rejected in the base document, in a profile overlay, in
`VOXGIG_PLUGIN_<REF>_<PATH>`, in `VOXGIG_PLUGIN_ACTIVE` and
`VOXGIG_PLUGIN_INACTIVE` (§9.5), in host construction options, and in
`load`/`options` calls made by anything other than the host itself.
Stating it for documents alone would have left the guarantee trivially
bypassable: `VOXGIG_PLUGIN_INACTIVE=station` is *easier* to set than
editing a config file, and §9.5 gives `INACTIVE` the final word, so the
one lever this mechanism exists to deny would have been the one lever
left open. "The host declaration always wins" is only true if it wins
against every layer.

This exists because of a trap station identified and closed in its own
design (`station-declarative-config.md` §8.4). Station's adapter is a
plugin like any other, so a generic document surface would let a config
file write `active: false` against it — switching off the component
that is reading the file — or re-point it at a different identity, and
§9.3's precedence puts a document value *above* what the host passes at
construction. A configuration surface that can disable the thing
reading it is not a surface, it is a trap. Any host embedding this
library has the same exposure the moment its own machinery is a plugin,
so the guard belongs here rather than being re-derived per host.

Reserved is deliberately all-or-nothing per name in v1: opening a
specific key later is safe, and discovering that a half-open one was
settable is not.

### 9.2 The programmatic API

```ts
const host = makeHost({
  point: { request: { kind: 'chain', base: rawFetch }, tick: { kind: 'hook' } },
  config: pluginJson,             // optional; the document above
  profile: 'dev',
})

host.define(RetryPlugin)                            // static catalog
host.resolver(nodeResolver())                       // dynamic loading (§10)

host.declare('retry$fast', { retries: 5 })
                                 // free: nothing resolved, nothing run
const fast = await host.load('retry$fast')   // resolve + define
await host.activate('retry$fast')

const live = await host.ready('stripe$test') // declare→load→activate→return

await host.deactivate('retry$fast')                 // resources released, state kept
await host.activate('retry$fast')                   // same instance, same state
                                                    // (and a standing request: §5.2)
await host.unload('retry$fast')

host.instance('retry$fast')      // -> instance | undefined; NEVER advances state
host.list()                      // -> [{ref, name, tag, status, seq, points, …}]
                                 //    includes `declared` rows
host.order('request')            // -> ['retry$fast', 'memcache$hot']
host.options('retry$fast', {retries: 9})   // patch; see 9.4
host.status()                    // -> the whole picture (§13)
await host.close()               // deactivate + close everything, reverse load order
```

Nothing in the declarative path is unavailable programmatically, and the
declarative loader is implemented *as* calls to this API — a rule, not
an aspiration, so that the two can never drift.

Cordis makes that rule structural rather than clerical: **its loader is
itself a plugin**, mounted on the root context, which then reads the
config file and mounts everything else. A loader that is a plugin
cannot reach past the public API, because it does not have anything
else to reach with. This design adopts the same shape — `apply` is
built on `load`/`activate`/`options` and ships as an ordinary
definition — which also means a host that wants a different
configuration format writes a different loader rather than patching
this one.

### 9.3 Precedence

One total order, lowest to highest, identical in every port, pinned by
the corpus's `config` section:

1. definition option defaults (the definition's option shape),
2. host defaults for that definition (`makeHost({defaults: …})`),
3. document base — `default.<name>`,
4. document base — `instance.<ref>`,
5. profile overlay — `default.<name>`,
6. profile overlay — `instance.<ref>`,
7. environment (`VOXGIG_PLUGIN_<REF>_<PATH>`, §9.5),
8. host construction options,
9. per-load options (`host.load(ref, options)`),
10. runtime patch (`host.options(ref, patch)`).

Levels 3–6 are one ordered merge, and the order is the point:
**profile specificity outranks definition specificity.** A `prod`
per-definition default beats a base-profile instance value, because
that is what an environment overlay is for; within one profile the
instance beats the definition default, because that is what an instance
is for. With no `default` entries it degenerates to base ⊕ overlay.

**`default` is keyed by name and declares nothing.** `default.stripe`
is a base for `stripe`, `stripe$test` and `stripe$eu` alike; it does
not create an instance, does not appear in `host.list()`, and a
`default` entry for a name with no instances is inert rather than an
error. That last point is what makes a shared library of defaults
shippable.

**This replaces seneca's shortname rule, and the replacement is
deliberate.** Earlier drafts sourced per-definition inheritance from
the *untagged instance's* options, so `instance.stripe.options` was a
base for `stripe$test`. That overloads one key with two jobs, and a
host wanting `stripe$live`/`stripe$test`/`stripe$eu` and no untagged
instance had to declare `{"stripe": {"active": false, "options": {…}}}`
— a defaults carrier masquerading as an instance, visible as one in
`host.list()` and in every status row built from it. Station hit this
immediately (§17.1). So: **the untagged instance is an ordinary
instance and its options apply only to itself.** Shared configuration
has exactly one home.

**The two maps are separate namespaces, not separate spellings.** An
untagged ref *is* a bare name — §4 rule 5 canonicalizes `"stripe$"` and
`"stripe"` to the same thing — so `default.stripe` and
`instance.stripe` are the same key string in two maps, and a normalizer
that tried to tell them apart lexically would reject the ordinary
single-instance case. The map decides the meaning: `default.stripe`
configures every instance of `stripe` and declares none;
`instance.stripe` declares the untagged one and configures only it.
Disambiguation is structural, so a reader never has to ask which of two
places a value came from, and the corpus pins the case where both
entries exist for one name.

The forfeit is familiarity for seneca users; the gain is that this repo
does not ship the same rule written twice, which is the defect class it
exists to avoid.

**Document defaults are applied after the merge, never before it.**
`active` (default `true`) and `start` (default `"eager"`) are filled in
on the *fully merged* entry, not on each layer as it is read. This is a
safety rule, not a tidiness one, and station supplied the case that
shows why (`station-declarative-config.md` §3.3). Take a base that bars
an instance and an overlay that only moves a URL:

```json
"instance": { "pad$a": { "active": false } },
"profile": { "prod": { "instance": { "pad$a": { "options": { "base": "https://prod.example" } } } } }
```

If the overlay entry had its defaults filled in before merging, it
would carry a synthesized `active: true` and overwrite the base's
`false` — and a one-key environment override would silently re-enable a
deliberately disabled integration in production. So: **merge the
entries as authored, then apply defaults to the result.** The same rule
holds one level down for any host that nests an instance map inside an
option (§6.5), where the identical defect reappears with a different
key. The `config` corpus section carries both cases.

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

**Map depth is declarable the same way, and it has to be.** Deep-merge
is the right default for an option map, but it is the wrong default for
any option whose value is a *set of permissions* rather than a bag of
settings. Station's `policy: {hosts: [...]}` is the worked case: an
egress allowlist that silently widens because two precedence levels
merged is precisely the failure worth designing against, and station's
own rule (`station-declarative-config.md` §3.3) is therefore that a
block merges shallow, per key, with `policy` replacing wholesale.

Those two rules — this library's deep-merge and station's shallow —
cannot both be global, and a host cannot be asked to give up an
allowlist guarantee to adopt a plugin library. So neither is global:

> **The option shape declares the merge behaviour of each key.** The
> library default is deep for maps and replace for lists. A key whose
> shape carries `{"$MERGE": "replace"}` replaces wholesale at every
> precedence level; `"append"` concatenates a list; `{"$MERGE":
> {"deep": N}}` merges N levels below that key and replaces below
> that. The shape is the one place the question is answered, and it
> travels with the definition rather than living as a table in the
> host.

**`N` is an integer of at least 1, and everything else is an error.**
`{"deep": 0}` is rejected despite having an obvious reading — "replace
at this key" already has a spelling, and two spellings for one
behaviour is the defect class this repo exists to avoid. A zero, a
negative, a fraction, a non-number, or an unrecognised `$MERGE` value
is `plugin_shape_invalid`, naming the key and the directive, and it is
raised **when the shape enters the catalog** (§10.1) rather than when a
document happens to exercise that key — so a malformed shape fails once
and in the same place everywhere.

Stating the domain is not pedantry: without it each port picks its own
reading of `{"deep": 0}` or `{"deep": -1}` — reject, replace, unlimited
merge, or clamp to 1 — and the same document resolves to different
effective configuration in different languages. That is precisely the
class of divergence the corpus exists to make impossible, and it cannot
pin what the contract does not state.

The depth form is not a generalization for its own sake — station's
feature map needs exactly it. §8.3 of its design merges `feature` **by
feature name, then by option key**, and replaces below that, so a
map-valued feature option like `headers` must replace wholesale rather
than merge key-by-key with the fleet default underneath it. Marking the
top-level `feature` key `replace` would destroy the composition that is
the point of a fleet default; leaving it deep would silently retain
base keys inside an option an overlay meant to replace. `{"deep": 2}`
on `feature` says the rule once, where per-option `replace` markers
would say it once per feature per option and be wrong the first time
someone adds a feature.

Station declares `policy` and `options` as `replace` in its SDK
definition shape and keeps its §3.3 guarantee unchanged; a definition
that says nothing gets deep-for-maps and never learns the key exists.
The `config` corpus section pins all three behaviours against the same
document.

`host.options(ref, patch)` is a merge at the top of the precedence
stack, and is re-validated. It applies immediately to a loaded instance
and, for a live one, invokes the optional definition callback
`reconfigure(instance, options, previous)`. A definition without
`reconfigure` that receives a patch while live is deactivated and
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
unloads first (reverse load order), then loads, then activations in load
order.

Activation order does not have to be dependency-sorted, because under
§11 activation is a standing request: a consumer activated before its
provider simply sits in `pending` until the provider arrives, a few
lines later in the same plan. The document's array position therefore
cannot make a valid configuration fail — which was the point of
sorting, obtained without the sort.

`apply` **declares everything and activates only what asked for it**:
every instance in the document reaches `declared`, and those with
`start: "eager"` and `active: true` go on to `live`. A document of
twenty lazy instances is therefore twenty map entries and no executed
code, which is the property station needs and the reason §5.1's
`declared` state exists.

**Toggling an instance back to lazy or inactive returns it to
`declared`, by unloading it.** There is no `loaded → declared`
transition and there should not be one: going back to `declared` means
"as if never loaded", and an instance that has run `define` has
allocated state and declared bindings that only `close` can properly
undo. So when a re-applied document flips `start` to `"lazy"` or
`active` to `false` on an instance that is currently `loaded` or
beyond, `apply` **unloads it and declares it again**, at its document `pos`
(§4 rule 4) so ordering is untouched — its plugin state is destroyed,
which is the honest meaning of the change. Without this
the same document would yield `declared` on a first apply and `loaded`
after a toggle, and "re-runnable" would be false. `apply` reports these
in its plan, because silently destroying an instance's state on a
config reload is not something to do quietly.

`apply` runs `host.resolve()` (§11.4) over the **eager** set before it
activates anything, and returns its answer alongside the plan. A
document that cannot fully come up says so once, naming the one missing
capability — rather than coming up nineteen-twentieths of the way and
leaving an operator to infer the cause from a screen of `pending`. Lazy
instances cannot be resolved in advance (their definitions are not
loaded, so their requirements are not yet known), and `host.check()` —
the CI counterpart — is the call that reports what breaks.

**`check()` has two halves, and only one of them moves an instance.**
The distinction matters because the two questions have different
answers about what must run first:

- **Options are checked from the catalog, without loading.** The
  definition's option shape is catalog metadata (§10.1), so `check()`
  validates every *declared* instance's merged layers against it and
  changes no state. This is the half that lets twenty lazy instances be
  checked without constructing one, which is the property station needs
  and the reason `declared` costs nothing.
- **Requirements are learned by loading.** A definition declares its
  requirements inside `define`, which only runs at `load`, so there is
  no metadata to read and `check()` **does** force declared instances up
  for this half — and says so in its report, because a CI verb that
  quietly allocates state would be a surprise.

Neither half changes §5.1's rule for the ordinary path: a `declared`
instance still merges, resolves and validates at `load`, and that is
still where a bad option is first reported in normal operation.
`check()` is a pre-flight that reads the same shape early and reports
what `load` *would* say. Where a dynamically-resolved definition's
resolver cannot supply a shape, its options cannot be checked without
loading either, and `check()` reports that per instance rather than
silently downgrading.


## 10. Loading: dynamic and static

### 10.1 Two paths, one catalog

- **Static registration** — `host.define(definition)` puts a definition
  in the catalog under its name. This works in every language, is the
  only path in some, and is the floor: **every port must implement it,
  and no behaviour in the corpus may depend on anything else.**

  **A catalog entry carries the definition's option shape, and it is
  readable before the definition is loaded.** This is the one piece of
  metadata that must be available at registration time rather than at
  `load`, because the questions a host asks *before* running anything
  depend on it: validating a declared instance's options, composing an
  ordered array for a constructor that has not been called yet, and
  reporting on twenty declared instances without constructing one.

  Station identified this as a hole in its own first draft and fixed
  it — its factory table registers `{construct, config}` rather than a
  bare constructor, precisely so that `station.check()` can validate
  every instance's configuration with no construction at all
  (`station-declarative-config.md` §6.2). A catalog that yields the
  shape only after `load` reintroduces that hole one layer down: a
  document of twenty lazy instances could not be validated without
  defeating the laziness that is the reason `declared` exists (§5.1).

  So `define` takes the shape alongside the definition, and a dynamic
  resolver may return it without instantiating. What `host.check()`
  then does with it — options from the catalog without loading,
  requirements only by loading — is stated once in §9.6 rather than
  twice here.

- **A catalog may be shared between hosts.** `makeCatalog()` produces
  one that `makeHost({catalog})` takes, so a process running several
  hosts registers a definition once. Station's factory table is
  explicitly process-global, station-independent and populated before
  any `Station.open()`, and two stations in one process must not need
  two registrations; without a shared catalog, adoption would either
  regress that or push hosts into a module-level singleton this
  library does not define. The default remains a private per-host
  catalog — sharing is a host's decision, and a shared catalog is
  still only a map from name to definition, holding no configuration
  and no instances.
- **Dynamic resolution** — a host-installed `resolver` maps a name to a
  definition at load time, typically by importing a module. Optional,
  advertised per port as a capability, and always *replaceable*: the
  resolver is an interface, so a test, a sandbox, or a language without
  module loading supplies its own.

`load(ref)` looks in the catalog first, then asks the resolver, then
fails with `plugin_unknown_definition`. A resolver that raises produces
`plugin_resolve_failed`, carrying the candidates it tried.

**The definition that comes back must be named what was asked for.**
Whether it arrived from the catalog, from a resolver, or through an
explicit `from` (§10.2), its `name` must equal the ref's name, and a
mismatch is `plugin_definition_name`. Without that check a resolver
could hand back a `memcache` definition for `cache$hot` and quietly
reinstate the aliasing §4 removed — registry identity saying one thing
and definition metadata another, which is the exact ambiguity
canonicalizing on name+tag was meant to end.

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

**Read that table as a cost decision, not a language limitation.** OSGi
(§23) is the most thoroughly dynamic plugin system ever built, and it is
built in Java — a static, compiled, statically-typed language. Bundles
install, update and uninstall at runtime, with multiple versions of the
same package live simultaneously. Dynamism was never a property of the
language; it was a property of the container, and OSGi bought it with a
classloader-per-bundle architecture that is also the direct cause of
every "classloader hell" story the platform is known for — reflection
across bundle boundaries, thread-context classloaders and `ServiceLoader`
all break on it.

So tier S is not "these languages cannot"; it is **"the price of
dynamism in these languages is an isolation architecture we have
declared a non-goal" (§21)**. A Go host that genuinely needs runtime
code loading can have it, at that price, in its own resolver. What the
tier table promises is that no *corpus behaviour* depends on anyone
paying it.

**The choice itself, and what it costs, is recorded once in
[`docs/ADR.md`](../ADR.md) ADR-1** — including the part this section
does not say, which is that no port ships a live resolver yet.

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

Exports of a `loaded` (not live) instance are **visible**. They are
declared in `define`, they are data, and hiding them would make the
loaded state useless for introspection. An export whose value is only
meaningful while live is the plugin's problem to signal, and the
convention is a getter closing over `inst.state`.

### 11.1 Capabilities

**A dependency is on a capability, not on a ref**, because it is a
dependency on *something that can do the job*, and which instance is
doing it is exactly the configuration detail a plugin must not care
about.

A definition declares what it provides and what it needs:

```ts
provides: ['clock']                                  // shorthand
provides: [{ name: 'store', version: '2.3',
             attrs: { transactional: true, durable: true } }]

requires: ['clock']                                  // shorthand
requires: [{ name: 'store', range: '2.1',
             match: { transactional: true } }]
```

- **`name`** — the capability. Any live instance providing it
  satisfies a requirement for it, so deactivating one of two `clock`
  providers moves nobody.

  **When several match, one is selected, deterministically.** Rank the
  matching live providers by: highest `version` first, then lowest
  **`priority`** — an integer on the `provides` entry, default 0 —
  then declaration position `pos` (§4 rule 4) ascending. The first is
  bound, and `inst.capability(name)` returns it.

  `priority` is a field on the capability rather than §7's `order`
  band, because bands live on *point bindings*: a provider may have
  several bindings with different bands, or none at all, so a rank
  that reached for one would be undefined in the common case. Without
  a total rank, "any provider satisfies" is true of the *graph* and
  useless to the *plugin* — two ports could bind different `store`
  instances, both resolve green, and behave differently, which is
  precisely the divergence a shared corpus exists to catch.

  **A binding is to an instance, not to a capability**, and that
  decides what happens when the bound provider leaves while another
  match remains. Rebinding stays reluctant (§11.3) — a bound provider
  is not swapped for a better one while it remains live — but when
  *the selected one* deactivates, a `static` consumer is deactivated
  to `pending` and reactivated against the new winner, exactly as if
  no provider remained. It is not silently re-pointed: `static` is the
  plugin saying in writing that it cannot survive a provider swap, and
  a survivor being available does not make the swap survivable. A
  `dynamic` consumer is re-pointed in place and notified, which is
  what it signed up for.
- **`attrs`** — what this provider is like. Free-form JSON.
- **`match`** — what the consumer needs it to be like: a **partial
  match against `attrs`**, with exactly the semantics `voxgig/struct`
  and the omni corpus already define for `match` — every leaf in the
  requirement must be present and equal in the capability, keys not
  mentioned are not checked. This is deliberately not a filter
  language. OSGi (§23) reaches for LDAP filters here; we already have a
  partial-match operator, ported to every language, corpus-tested, that
  our engineers read every day. Inventing a second one to express
  `transactional: true` would be indefensible.
- **`version` / `range`** — §11.2.

**A REF SATISFIES TOO**, and this is the one exception to the sentence
this section opens with. A requirement naming a live instance's ref is
met by that instance, because a host that genuinely needs a *specific*
instance should not have to invent a capability for it to depend on.
The exception is narrow on purpose: it is met only while that instance
is `live`, exactly as a capability is. Everything else about depending
on a ref is worse than depending on a capability, and nothing here
recommends it.

**It is not a third axis.** A ref requirement is a requirement, so
cardinality and policy (§11.3) decide what its loss does, exactly as
for a capability: mandatory-`static` goes back to `pending`,
mandatory-`dynamic` is re-pointed in place and stays live, and an
optional one never gated activation and so changes nothing. Stating it
as "losing the ref sends the consumer to `pending`" is true only of the
default and would make ports that read it literally disagree with ports
that routed it through the ordinary rules.

**The comparison is on the CANONICAL ref** (§4 rule 5). `dep$` and
`dep` are the same instance, so a requirement written either way is met
by it — a port comparing the requirement string against the registry
key without canonicalizing first answers differently, which is the
divergence rule 5 exists to prevent.

**And a requirement name need not be a ref at all.** §4's grammar is on
plugin *names*; this design puts no grammar on capability names, so
`2fa` and `my cap` are perfectly good capabilities and no ref could be
called either. The ref comparison must therefore be able to answer *not
a ref* rather than failing: canonicalizing every requirement name
unconditionally raises `plugin_bad_name` on a legal document, which is
what the canonical did until `depend/byref` pinned it.

**The rule holds wherever the graph is examined, not only at
activation.** Load-time cycle detection (§11.3) and whole-graph
resolution (§11.4) answer questions about the same graph, so a ref edge
is an edge in both: a cycle expressed through refs is
`plugin_dependency_cycle`, and `resolve()` must not report `absent` for
a provider the runtime would bind. All three read the requirement name
the same way, and the corpus pins each — `depend/byref`,
`depend/cycle#through-refs-noncanonical`, `graph/resolve#byref`.

This rule lived only in the canonical's source comments until those
groups were written; the whole ref branch was dead code as far as the
corpus was concerned, and deleting it outright passed every entry —
which is why the two places that never implemented it at all went
unnoticed for as long as they did.

Unsatisfiable is not an error at declaration time. It is a *fact about
the current registry*, and §11.4 is how you ask for it.

### 11.2 Versions, and the asymmetry nobody expects

A capability carries a version; a requirement carries a range. The
grammar is two forms, and no more:

**Two fields, and one predicate.** A capability declares `version`, a
concrete version. A requirement declares `range`. A requirement is
satisfied by a provider when the names match, the `match` passes
(§11.1), and:

> **the provider's `version` falls inside the requirement's `range`.**

That is the whole rule. There is no third field and no second
comparison — an earlier draft added a provider-side `compat` range,
which left three values and no statement of how they combine: with
`range: '2.1'`, `version: '2.3'` and `compat: '~2.1'`, matching on
version accepts, checking version against compat rejects, and
intersecting the ranges accepts again. Three defensible readings of one
declaration is worse than the ambiguity it was introduced to fix.

```ts
provides: [{ name: 'store', version: '2.3' }]
requires: [{ name: 'store', range: '2.1' }]
```

Ranges have two forms and no more:

| form | means |
|---|---|
| `'2.1'` | `>= 2.1.0` and `< 3.0.0` |
| `'~2.1'` | `>= 2.1.0` and `< 2.2.0` |

**The asymmetry lives in which range a requirer writes**, and that is
the part worth importing wholesale from OSGi's semantic-versioning
work, because it is genuinely counter-intuitive and it is right: **two
plugins requiring the same capability do not tolerate the same range,
depending on what they do with it.** Add one method to an
interface and that is a *minor* bump — every existing consumer still
works, and every existing provider is now broken, because it does not
implement the new method. So a plugin that merely calls `store` requires `range: '2.1'`; a plugin
that *implements* the `store` interface for someone else to call —
and therefore has to implement every method in it — requires
`range: '~2.1'` and is updated deliberately. Same field, same grammar,
different width, chosen by the requirer who knows which kind it is.
This is guidance the corpus can only partly pin: it can prove `'~2.1'`
excludes `2.2.0` and `'2.1'` admits it, but not that a given plugin
picked the right one.

Getting this wrong is not a subtle degradation — it is a provider that
silently satisfies a requirement it cannot actually meet, failing at
the first call to the method it never implemented. A malformed range is
`plugin_bad_range`, at load. Range parsing and matching are pure
functions, and the corpus's `version` section pins them, including the
asymmetry.

### 11.3 Cardinality and policy

Two axes, both declared by the definition that has the requirement,
because only it knows what it can cope with:

| | **`static`** (default) | **`dynamic`** |
|---|---|---|
| **mandatory** (default) | unmet → `pending`; lost → back to `pending`, recursively | unmet → `pending`; lost → **stays `live`**, notified, must cope |
| **`optional: true`** | never gates activation; a change deactivates and reactivates | never gates activation; a change is a notification, nothing else |

- **Optional requirements** are the case this design could not express
  at all before, and they are common: a plugin that works without
  metrics and uses metrics when it is there. `inst.capability('metrics')`
  returns the provider or absent; the host emits a `capability` trace
  record when that changes.
- **`dynamic`** means the plugin has said, in writing, that it can
  survive its provider being swapped underneath it. It is not the
  default because most plugins cannot, and the cost of wrongly assuming
  they can is a live instance holding a dead reference.
- The **rebinding-preference axis is deliberately omitted.** OSGi has
  `reluctant` vs `greedy` — whether an already-bound reference should be
  swapped when something better appears — and it is a knob every author
  must understand to read anyone else's component. We take always-
  reluctant: a satisfied requirement is not re-bound while it stays
  satisfied. Three axes were more than the model can carry across
  twenty ports; two are the ones that change what a plugin must be
  written to survive.

  **Reluctance is a REMEMBERED choice, not a re-computation.** The
  selection is made once, when the consumer activates, and recorded per
  requirement; every later question — the cascade, `hold`, `unmet` —
  reads it back. A host that instead re-ranks the candidates each time
  it is asked has implemented *greedy* while appearing to implement
  neither: a better-ranked provider arriving later silently becomes
  "the bound one", so deactivating the provider the consumer was
  actually activated against restarts nothing, and the consumer keeps
  using a reference it was never told to stop using. The selection
  belongs to one activation and is dropped when the instance leaves
  `live`, so the next activation ranks afresh.

**Requirements are live, not checked once.** A check at the activation
instant guarantees nothing about the moment that matters, which is the
arbitrary later moment the consumer actually calls the thing.

- At `load`, an unmet requirement is neither error nor warning. Load
  order is not the developer's problem.
- At `activate` with a mandatory requirement unmet, the instance goes
  `pending` (§5.1) and **waits**. Not an error: a document listing a
  consumer before its provider is fine, and a provider arriving thirty
  seconds later is fine.
- When the last provider of a capability leaves `live`, its `static`
  mandatory consumers are **deactivated back to `pending`** — scope
  unwound, bindings removed, state kept — and reactivated when a
  provider returns, recursively.

  **Consumers go down first, not afterwards.** The cascade is part of
  the provider's own deactivation, run *before* the provider's
  `deactivate` callback and scope unwind, so a consumer's teardown can
  still call the thing it depends on — flushing a buffer to the store
  it is about to lose is exactly what a `deactivate` callback is for,
  and a cascade that fired after the provider was already gone would
  make that impossible. Order: consumers deepest-first, then the
  provider. `unload` and `close` inherit it — **under either
  dependency policy** — which is what makes `apply`'s
  reverse-load-order teardown (§9.6) safe even when a document happens
  to list a consumer before its provider.
- A cycle through **restart-causing** requirements is
  `plugin_dependency_cycle`, detected at load. Those are the mandatory
  ones *and the `static` optional ones*, because both make a
  capability change deactivate and reactivate the consumer — and a
  cycle of restarts does not settle: A comes up, B restarts, which
  changes B's capability, which restarts A, indefinitely.

  **Only `dynamic` optional edges are excluded**, and they are the ones
  the exclusion was for: two plugins that optionally and dynamically
  consume each other's capabilities both activate happily, neither
  gates on the other, and each is merely *notified* when the other
  appears. Nothing restarts, so nothing oscillates. An earlier draft
  excluded every optional edge and thereby admitted the
  non-terminating case it was trying to permit.

This is provider replacement as an ordinary runtime operation rather
than a restart: deactivate the old secret store, activate the new one,
and everything that depended on it rides through, having released the
old one's resources in between. It is Cordis's behaviour (§22) and
OSGi Declarative Services' `static` reference policy (§23) — the same
answer, reached twice, fifteen years apart.

For a host that wants the strict reading, `makeHost({dependency:
'hold'})` restores it: deactivating a required instance is then
`plugin_dependency_held`, naming the holders. Not the default, because
a station that cannot swap a provider without a restart has lost the
argument for having a plugin system.

**A holder is a MANDATORY consumer, and that is a different set from
the one the cascade walks.** The cascade follows the edges that
*restart* — mandatory-static and optional-static — because a restart is
what it has to perform. `hold` asks whether the instance is *required*,
and required is cardinality: a mandatory-**dynamic** consumer holds,
because `dynamic` promises it survives a *swap* and under `hold` there
is no swap — the provider goes and the consumer falls back to
`pending`, which is what the policy exists to prevent. An **optional**
consumer does not hold whatever its policy, because it has said in
writing that it does not need the thing, and a policy that refuses a
deactivation on its behalf is speaking for a plugin against that
plugin's own declaration. Reading the holders off the cascade's set gets
both of these wrong, in opposite directions.

**The hold check is a guard on ad-hoc deactivation, not on coordinated
teardown.** In a bulk operation that is removing the holders too —
`host.close()`, or an `apply` plan whose own steps deactivate them —
it is suspended for exactly those holders, and the teardown still runs
consumers before providers. Otherwise `close()` under `hold` would
raise on the first provider it reached whenever a document happened to
list a consumer after it, which is the policy refusing to allow the
one teardown it has no reason to object to.

### 11.4 Resolution is a phase, not a discovery

The rule above — activate, and wait in `pending` if you must — is
correct and, on its own, produces a terrible experience. Apply a
document with twenty instances against a registry missing one thing and
you get *nineteen* pending rows and no statement of what is actually
wrong. OSGi resolves the entire constraint graph before starting
anything, and gets to answer the question once; we should too.

```ts
host.resolve()          // -> { resolved: [...refs], blocked: [{ ref, unmet, why }] }
```

`resolve()` is a **pure function of the registry and the intended
activation set**: no callbacks run, no state changes, nothing is
touched. It answers, for the whole graph at once, which instances can
be live and which cannot — and for each blocked one, the specific
requirement that is unmet, and why: no provider at all, a provider at
an incompatible version (with both the range and the version found), a
provider whose attributes fail the `match` (with the failing leaf), or
a provider that is itself blocked (with the chain).

Two things follow. `host.apply()` (§9.6) runs `resolve()` first and
reports one coherent result instead of a scatter of pending rows. And
because it is pure over JSON-shaped input, `resolve` is a **corpus
section like `ref` and `config` are** — the hardest logic in the
library, tested as data, in every port, with no driver.

That matters more than it sounds, because the failure mode being
designed against is a famous one. OSGi's resolver is correct and its
diagnostics are legendarily unusable — `Unresolved constraint in bundle
X: missing requirement osgi.wiring.package=…` is a sentence that has
cost the industry entire days. The lesson is not "resolve better"; it
is that **the explanation is a deliverable, not a by-product**, and one
that a JSON corpus can hold to a fixed standard in twenty languages.

`provides: [...]` also lets one definition satisfy a requirement under
another name — one definition supplying `clock` regardless of what it
is called.


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
- The bracketed detail carries the fields that apply to the code, in
  this fixed order, omitting those that do not, and is absent entirely
  when none do:

  `host`, `ref`, `name`, `tag`, `point`, `key`, `capability`,
  `range`, `version`, `match`, `candidates`, `cycle`, `holders`,
  `refs`, `path`, `cause`

  The list is exactly what the error table below needs — the resolver's
  tried `candidates`, the ordering or dependency `cycle`, the
  `holders` of a held instance, the `refs` of an ambiguous export, the
  `range`/`version`/`match` of a capability that did not satisfy, and
  the `path` of an error inside a nested host (§6.5). An earlier draft
  named six fields while other sections promised diagnostics that had
  nowhere to go, which would have left each port inventing its own
  order and breaking message parity. Values are rendered as compact
  JSON, so a value containing a space or a bracket cannot break the
  parse, and a list field renders as a JSON array.
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
| `plugin_definition_name` | resolved definition's name is not the ref's name (§10.1) |
| `plugin_dynamic_unsupported` | dynamic load attempted in a static-only port |
| `plugin_not_loaded` | transition or query on an absent ref |
| `plugin_bad_state` | transition illegal from the current status |
| `plugin_inactive` | `activate` or `ready` on an instance a document barred with `active: false` (§9.6) |
| `plugin_reentrant` | transition attempted from inside a lifecycle callback |
| `plugin_option_invalid` | options failed the definition's shape |
| `plugin_point_unknown` | binding to an undeclared point |
| `plugin_point_kind` | binding of the wrong kind for the point |
| `plugin_bind_scope` | binding declared outside `define` |
| `plugin_release_scope` | `release` registered outside `activate` |
| `plugin_order_cycle` | before/after constraints cycle |
| `plugin_dependency_cycle` | requirements cycle, detected at load (§11) |
| `plugin_bad_range` | malformed version range or capability version (§11.2) |
| `plugin_dependency_held` | deactivate of a required instance, under `dependency: 'hold'` only (§11) |
| `plugin_hook_failed` | collected binding errors on a `{raise: true}` hook point (§6.1) |
| `plugin_env_ambiguous` | two refs encode to one environment key (§9.5) |
| `plugin_export_ambiguous` | §11 |
| `plugin_define_failed` / `plugin_activate_failed` / `plugin_deactivate_failed` / `plugin_close_failed` | a callback raised; wraps the cause |
| `plugin_release_failed` | one or more ledger entries raised |
| `plugin_point_exclusive` | second binding on an exclusive provider point |
| `plugin_ref_reserved` | any input layer names a host-reserved ref (§9.1) |
| `plugin_shape_invalid` | a malformed `$MERGE` directive in an option shape (§9.4) |
| `plugin_order_pinned` | an ordering would move a host-pinned binding (§7) |

Every error carries the host name, the ref (where one exists), the code,
and the cause. A plugin's own errors are never rewritten — they are
wrapped, and the cause is reachable.


## 13. Observability

The registry is explicit and queryable, because a plugin system nobody
can see the state of is a plugin system people stop trusting.

- `host.list()` — one row per instance, **including `declared` ones,
  and without loading them**: ref, definition version (absent until
  loaded — it is the definition's, and the definition has not been
  resolved), status, `seq`, the points it binds and its resolved
  position in each, its declared requirements and whether they are met,
  its option keys (values redacted by the host's redactor if it has
  one), and the size of its scope. A `pending` row names **which**
  requirement it is waiting on, because "pending" without that is a
  shrug, and this is the row an operator stares at when an integration
  did not come up.
- `host.order(point)` — the resolved order, live bindings only.
- `host.status()` — the whole picture: host name, declared points and
  their kinds, catalog contents, resolver presence, instances, shadowed
  providers, the last error per failed instance, and the current
  `resolve()` answer (§11.4) — the capability graph as it stands, with
  each blocked instance's specific unmet requirement.
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

> **This section is the aspiration; the state is
> [`docs/ADR.md`](../ADR.md) ADR-2.** Thread safety is a **per-port
> property**, claimed in a port's own `AGENTS.md`, and only `go` and
> `elixir` claim it today. §15.4 keeps thread-safety-under-contention
> out of the corpus deliberately, so nothing here is checked the way the
> rest of this document is — read the first bullet as what a port that
> claims it must deliver, not as what every port does.
>
> Reentrancy is the exception and is not per-port: `plugin_reentrant` is
> a corpus behaviour that every port implements.

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
  ones is the definition's job, in `deactivate`, before the scope unwinds.
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

`spec/plugin.aon` compiles to `spec/plugin.json`, and every port runs
it through [voxgig/omni](https://github.com/voxgig/omni). Same discipline
as struct, sekreto and station: the corpus is the contract; a port that
disagrees with it is wrong.

> **The corpus is in omni's format; the runners are not omni yet.** The
> entry fields, the `set` groups and the sentinels here are omni's, and
> `make omni-check` proves the committed corpus runs green under omni's
> own runner — 572 entries, 19 sections. But every port still ships a
> hand-written runner for it. [`docs/ADR.md`](../ADR.md) ADR-3 records
> what moved, what did not, and the dependency question the migration has
> to answer first.

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
    "instance": [ { "ref": "probe$a", "status": "live", "seen": 2 } ],
    "resource": { "open": 1, "opened": 2, "closed": 1 },
    "result":   [ "probe:x", "y", "probe:z" ]
  }
}
```

`seen: 2` is the persistent-state assertion: the counter in
`instance.state` survived the deactivation. `resource` is the ledger
assertion, and it is worth reading carefully, because the obvious wrong
answer (`opened: 2, closed: 2`) would quietly demand that ports release
resources while the instance is still live: `probe` acquires one
synthetic handle per activation, the deactivation released the first,
and the script *ends live*, so the second is still held. A scenario
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
| `ref` | name/tag grammar, parse, format, canonicalization | yes |
| `config` | document normalization, array/map forms, profile overlay, precedence, list-replace, and **`pos` assignment** — the array index or the sorted-ref index | yes |
| `env` | `VOXGIG_PLUGIN_*` parsing, ACTIVE/INACTIVE | yes |
| `resolve` | name → candidate module ids | yes |
| `capability` | provides/requires matching: name, `match` against `attrs`, the selection rank (version, `priority`, `pos`), and a `static` consumer restarting when its *selected* provider leaves though another matches (§11.1) | yes |
| `version` | range grammar, the one satisfaction predicate (provider `version` inside requirer `range`), boundary cases, `plugin_bad_range` | yes |
| `graph` | whole-graph resolution (§11.4): resolved/blocked sets, and the *explanation* for each blocked instance | yes |
| `lifecycle` | the state machine, idempotence, illegal transitions, failure paths | driver |
| `declare` | `declared` costs nothing: introspection without loading, raw-vs-resolved options, `start` eager vs lazy, `ready` walking the staircase, `active: false` barring, callback-free `deactivate(pending)`, and `apply` unloading a toggled instance back to `declared` (§5.1, §9.1, §9.6). Also **auto-tag** and **`seq`** — both need a host, so neither can live in a pure section (§4 rule 4) — and **catalog registration** (§10.1): a definition named independently of what backs it, and an option shape validated WHEN IT ENTERS THE CATALOG rather than when a document exercises the key, which `config`'s pure entries cannot observe | driver |
| `nest` | an instance that is a host (§6.5): inner lifetime owned by the outer, teardown order, structured trace ancestry, capability isolation, and an inherited capability's loss reaching inner consumers | driver |
| `state` | persistence across activation cycles, destruction on unload | driver |
| `resource` | the instance scope: automatic recording of host calls, `release` for foreign ones, reverse unwind, partial-activate rollback, failing release | driver |
| `order` | topological sort, bands, ties, vacuous constraints, recomputation | driver |
| `point` | the three kinds, the four hook dispatch modes incl. `bail`, composition, provider shadowing, exclusivity | driver |
| `export` | keying, aliasing, ambiguity | driver |
| `depend` | `pending` on an unmet requirement, automatic activation on arrival, reactive deactivation and recovery, recursion through consumers, optional vs mandatory, static vs dynamic policy, capability-not-ref satisfaction, cycles | driver |
| `apply` | idempotent document application, add/remove/patch/toggle | driver |
| `error` | every code in §12, and the message format | both |
| `trace` | the lifecycle event records | driver |

### 15.4 What is deliberately not in the corpus

Real dynamic module loading (§10.2), thread-safety under contention,
and anything involving a clock. Those are per-port integration tests,
named as such, so nobody mistakes a green corpus for full coverage —
station's split, for station's reason.

And one thing that is not testable anywhere, stated so a green suite
cannot be read as claiming it: **the corpus proves the host stopped
routing to a deactivated instance and unwound what it registered. It
cannot prove the instance stopped running** (§8.2). A probe that
squirrels a reference away in a global and keeps using it after
deactivation would pass every entry in this file. That is a limit of
the architecture, not a gap in the corpus, and no amount of test design
closes it.


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
│   ├── plugin.aon        # THE CONTRACT — edit this
│   ├── plugin.json         # generated by `make spec`, committed
│   └── def/plugin-spec.aon   # the spec-format shape, checked by `make spec-check`
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

**The canonical is written to the portability budget in §18's P1** — no
reflection-backed API, no decorators, eager lifecycle reconciliation, no
meta-level interception. A canonical that reaches for a JavaScript
convenience is not clever, it is a bill the other twenty ports pay.

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

Station is the initial use case, and it is a much more demanding one
than "station.md §3, generalized" — which is what this section claimed
before reading what station is actually building. Station's
[declarative-config design](https://github.com/voxgig/station/blob/claude/voxgig-station-sdk-design-8ayy9d/docs/design/station-declarative-config.md)
sets the bar: **a fully declarative `station.json` declaring at least
twenty SDKs and twenty-six instances, with SDK instances fetched by
name, lazily, at the point of use.** Four properties of that document
are requirements on this one, and two of them changed this design:

| station needs | plugin provides |
|---|---|
| `sdk` blocks declaring named instances | the config document's `instance` map, keyed by ref (§9.1) |
| `api.<slug>` blocks, inherited by every instance of an api | the `default` map, keyed by name (§9.1, §9.3) — settled by station's review |
| `stripe-test`, an instance of api `stripe` | `stripe$test` — name is the api, tag is the instance (§4) |
| twenty declared, constructed on first `sdk(name)` | `declared` state + `start: "lazy"` + `ready(ref)` (§5.1) — **the reason `declared` exists** |
| `instances()` (declared) vs `plugins()` (live) | `host.list()` over all states vs the `live` rows of it |
| `active: false` in a profile overlay | `active: false` in the document (§9.1) |
| `create()` returning uncached clients | auto-tagged instances, `tag: '?'` → `stripe$1` (§4 rule 3) |
| SDK features managed fleet-wide, per instance | an instance that is itself a host (§6.5) — **the reason nested hosts are in the model**, and contingent on §17.2 (see below) |
| the transport wrap "immediately outside the base transport" | a `chain` binding with a low band, pinned by the host (§7), verified by `inst.position()` (§6.6) |
| `feature.station` reserved, so a config cannot disable the adapter | `makeHost({reserved})` and `plugin_ref_reserved` (§9.1) |
| `test` replacing the transport rather than wrapping it | the innermost `chain` link, declining to call `next` (§6.2) — the proposed `transport` role is unnecessary |
| feature config validated with no construction | the catalog carries the option shape at registration (§10.1) |
| `policy` replacing wholesale, never widening by merge | `{"$MERGE": "replace"}` in the option shape (§9.4) |
| a process-global factory table, shared by every station | a shared catalog, `makeHost({catalog})` (§10.1) |
| the `station` ordering special case in `makeOptions` | ordering constraints (§7) — the special case goes away |
| explicit feature wrap `order` at profile level | the same constraints, one level down, in the inner host |
| struct-validated config | §9.4's option shapes, same `struct.validate` — but see the credential note below |
| `station.close()` | `host.close()` |
| binding one name twice is an error | `plugin_ref_duplicate` |

What station gains that it cannot do today: **more than one binding of
one api** (its own §1 records `station_bound_twice` as a *prohibition*,
not a gap), **runtime deactivation** with credentials released as part
of the instance scope, and one instance model shared with every other
voxgig library instead of a station-shaped one.

**Two rows of that table need qualifying, both raised by station's own
review of this document.**

*Validation is not closed-by-construction, and cannot be.* Station's
guarantee (its §5.2) is that its **grammar** cannot express a
credential: eight known block keys, closed maps, and no key that holds
a value. This library validates an instance's `options` against **the
definition's** option shape — and for an SDK definition that shape is
the SDK's own options, in which `apikey` is a declared key
(sdkgen's `MakeOptionsUtility.ts` `optspec`). So

```json
"stripe$test": { "options": { "apikey": "sk-live-abc123" } }
```

is *grammatically valid* here, where in station's own grammar it is a
hard error. The property does not weaken, it inverts: a closed grammar
that omits the credential key becomes an open one that includes it by
definition. That is not a defect in this design — a generic plugin
library cannot know which of a definition's options is a credential —
but it means **the guarantee is the host's to keep, not this library's
to supply**, and station keeps it with a scan layered over these
option shapes. Said here so neither repo believes the other is
providing it.

*Nested hosts are the right model for station's feature management and
are reached over the bridge, not natively.* §6.5 is justified by
station configuring each SDK's features fleet-wide, and a generated SDK
is not itself a host: it has `options.feature` (map or ordered array)
and a `FEATURE_CLASS` table, and station configures features by
composing that array, which is what its §8 describes and what already
works. Wrapping *that* in `inst.host(...)` would be a host-shaped
object around a non-host, and §17.2 declines to commit sdkgen to
changing it.

P3's `FeatureHost` bridge is what makes the row real in the meantime:
the inner host is the bridge rather than the SDK, and the generated
code stays unmodified. So the row is a **present fit over the bridge
and a future fit natively** — sdkgen adopting would delete the bridge,
not enable the model. §6.5 says "will need" and carries the same
caveat inline rather than only here.

**Where the two designs still disagree, and who moves.** Station's
document is further along and names things in its own domain; this
library is generic. The reconciliation is that station's grammar stays
station's — `sdk`, `api`, `feature`, `order`, `secret`, `policy` are
its keys and should be — and plugin's document keys (§9.1) are the
*generic* form a host may rename when it embeds the subtree. §9.1
already says a host chooses the file and the lookup path; it now also
says a host may map its own key names onto the generic ones, because
`sdk` reads better in `station.json` than `instance` ever would, and a
generic library that forces its vocabulary into a specific host's
config file has mistaken uniformity for design.

**One consequence station has to absorb, and it is a real one.** §4
canonicalizes identity on name+tag, where the name is *always* the
definition — so station's instance keys become `stripe$test`,
`github$ent`, `slack$ops`, and its `api` field disappears because the
name already carries it. That is a change to station's config grammar,
not a translation layer over it: `sdk` keys are refs, and a key with no
`$` is simply the untagged instance of that api. In exchange station
loses a field that could disagree with its own key, and gains the
property that any log line, event or status row naming an instance also
names its api. Instance names get longer where the api slug is long
(`voxgig-solardemo$eu`, not `solar-eu`); that is the visible cost and it
is worth paying for one identity instead of two.

One smaller collision, settled here so neither repo hits it in code.
Station's `active: false` means *barred from running* and §9.1's
document key `active` means *may this run* — that is **one predicate
stated in two polarities, not two meanings**, and it was miscounted as
a three-way clash for as long as the two were listed separately.

The genuine clash is between that document key and the runtime
**status**, and it is real: `active: true` with `start: "lazy"` sits at
`declared` indefinitely, so the same word answers two questions whose
answers legitimately differ.

**It is resolved in favour of the key.** The status is named `live`
(§5.1); the document key keeps `active` in both repos. The asymmetry is
one of cost, not taste: `active` as a config key was already shipped
across station's ports, its `station.json` documents, and sdkgen's
`options.feature.<name>.active` in ~23 languages, while the status was
unshipped when this was decided — no code, and no `lifecycle` corpus
section yet. Renaming the unshipped one costs a documentation pass;
renaming the shipped one is a breaking change to a user-facing file.

The word was not invented for the occasion. This design already defined
the status as "bindings are live" (§5.1), and station's `instances()`
already reported `{active, live}` for exactly this distinction — both
repos reached for the same second word independently, which is the
strongest evidence available that it is the right one. Station's
boolean `live` is now precisely `status == "live"`, so the two
vocabularies agree rather than merely coexisting.

**The sequencing, stated plainly because it is a real cost.** An
earlier version of this section discussed sequencing entirely in
TypeScript: station's Stage 2 (the identity change) and Stage 3 (the
declarative front door) behind plugin's P1 and P2. That is the small
version of the problem, and station's review supplied the large one.

**Station has sixteen written ports** — `c`, `cpp`, `csharp`, `dart`,
`elixir`, `go`, `java`, `javascript`, `lua`, `perl`, `php`, `python`,
`ruby`, `rust`, `swift`, `typescript` — eleven of them running a full
suite in CI. This library has **none**, and §16.1 rolls out in four
tiers. A station port cannot depend on a plugin library that does not
exist in its language, so adopting this library as a *dependency* means,
for each of those sixteen: wait for that language's plugin port (tier 3
for most, tier 4 for `c` and `cpp`), or keep a native implementation
and carry two instance models in one repo — the exact outcome this
section exists to avoid.

The budget compounds it. §19 puts a port's core at ~1200 lines against
station's own 1–2k for an entire tier-A port (`station.md` §10.1), and
plugin absorbs perhaps 300–400 lines of what a station port already
does. Net, roughly **+800 lines per language in sixteen languages**,
carried by the only consumer that exists.

**So the order is the other one.** Station builds Stages 2 and 3
natively, to the semantics in this document — the ref grammar, the
`declared`/`loaded`/`live` states, §9.3's precedence,
list-replaces-on-merge, vacuous constraint satisfaction — and this
library extracts them afterwards. Same destination; station's sixteen
ports stay green throughout; and plugin's P3 becomes an extraction from
working code rather than a construction against a design, which is an
easier proof obligation to discharge, not a harder one.

Four things follow, and they are obligations on *this* repo:

1. **P1 and P2 ship the core only** — §11's capability system is P3b
   (§18) precisely so it is not on station's critical path.
2. **P3 is station**, and it is a proof obligation on plugin, not a
   migration burden on station: station keeps `connect`/`adopt`/
   `options`/`sdk`/`create` as its public API, and plugin has to fit
   underneath it unchanged. If it does not fit, plugin is wrong.
3. **Station's Stage 1 does not wait.** Its grammar, shape file,
   normalizer and corpus sections are station's own data and depend on
   nothing here.
4. **Ship the corpus sections early, even in draft** — and the driver
   contract with them. `ref` and `config` are pure data (§15.3): the
   files are the whole deliverable. `lifecycle` and `order` are
   *driver* sections, so executing them also takes §15.2's driver
   contract — the probe catalog, the command interpreter and the
   canonical observable — and shipping the four without it would hand
   station two contracts it cannot run. Ordering and lifecycle are
   exactly where two independent implementations drift furthest, so
   the answer is to bring the driver contract forward in draft, not to
   narrow the promise to the pure pair. Station has said it will hold
   itself to them; this repo owes them sooner than P1's exit.

The dependency question reopens when this library reaches tier 3 — at
which point most of station's ports have something to depend on, and
sdkgen (§17.2) is likelier to be a second consumer, so the per-port
trade is being made for two libraries rather than one. That is a
decision to make on a date, not on principle.

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

> **Cross-repo sequencing lives in station's
> [`station-and-plugin-plan.md`](https://github.com/voxgig/station/blob/main/docs/design/station-and-plugin-plan.md)**,
> beside the reconciliation it accompanies. The phases below stay
> authoritative for their own contents; what they cannot state from
> inside this repo is what this repo owes station and when. Two of the
> four cross-repo obligations fall on P1 and are easy to read as
> internal when they are not: the `ref` and `config` corpus sections
> are owed **before station's Stage 2**, earlier than P1's own exit,
> and `lifecycle`, `order` and the draft driver contract before P1
> exits. P0 has an entry condition that plan also names — **this
> design is not yet on `main`**, and P0 builds a repository skeleton
> around it.

### P0 — Repository skeleton

Layout of §16; `README`, `DOCS`, `AGENTS`, `CLAUDE`, `Makefile`; this
design doc; `spec/def/plugin-spec.aon` (the spec-format shape);
`tools/build-spec.js` copied from omni's; empty `check_parity.py` with
the canonical name list.

*Exit:* `make spec` and `make spec-check` run on an empty corpus.

### P1 — The tracer bullet (typescript)

The thinnest thing that is genuinely end-to-end, not a subset that
avoids the hard parts.

**The canonical must be written to a portability budget from line one**,
and §22.2 supplies it for free: `cordis-rs` is a Rust port of this same
model, and its documented divergences are a list of the JavaScript
shapes that do not survive contact with a static language. So P1 is
constrained, not merely reviewed later:

- **no reflection-backed API** — no `Proxy`, no dynamic property
  interception, no "the context magically has a field named after the
  service". Typed accessors and explicit registration only.
- **no decorators**, and nothing else that needs a language feature
  half the target set lacks.
- **eager lifecycle reconciliation** — a transition settles by running
  the state machine to a fixed point, not by suspending on a promise.
  Ports that have no executor must be able to ask "what is the state
  now?" and get an answer. This is also the honest form of §14's
  async rule.
- **no meta-level interception** of the host's own operations. A plugin
  extends the host through declared points; it does not hook the act of
  getting a service or setting an option.

Every one of these is cheaper to obey in P1 than to remove in P4.

The work itself:

- ref parsing/formatting; the config document normalizer; static
  catalog; `load` / `activate` / `deactivate` / `unload` / `close`;
  the state machine with its errors; **one point of each kind**
  (`hook`, `chain`, `provider`) with all four hook dispatch modes; the
  instance scope and its automatic recording; the topological
  order resolver; `list`/`order`/`status`/`trace`.
- The driver, the probe catalog, and corpus sections `ref`, `config`,
  `lifecycle`, `state`, `resource`, `point`, `order`, `error`.
- **The driver contract in `DOCS.md`, in draft** — the probe
  behaviours, the command vocabulary and the canonical observable
  (§15.2), written language-neutrally rather than as a description of
  the TypeScript implementation. §17.1 owes station the `lifecycle` and
  `order` corpus sections before this phase exits, and those are
  *driver* sections (§15.3): a port cannot run them from corpus files
  alone. Shipping the data without the contract would hand station's
  other fifteen ports two suites they cannot implement consistently —
  the drift the early corpus exists to prevent. P2 completes the
  document; P1 owes the part station consumes.
- A worked example in `typescript/example/`: a host with a `request`
  chain, two instances of one definition, deactivated and reactivated at
  runtime.

*Exit:* `make test-typescript` green; the §15.1 scenario passes as
written; deactivating a plugin demonstrably closes its handles.

### P2 — Completing the canonical

Dynamic resolution and the resolver interface; `resolvecandidates`;
env application; `apply()`; exports; `reconfigure`; position
verification; the remaining corpus sections (`env`, `resolve`,
`export`, `apply`, `trace`); the ts integration suite that does real
`require`-based loading.

**The capability system is deliberately NOT in this phase** — see P3b.

*Exit:* every section of the corpus except the four capability ones
exists and is green in TypeScript; `DOCS.md` complete, including the
probe catalog specification — completing the draft P1 shipped, not
starting it.

### P3 — Proof against real hosts

Both, in TypeScript, because a plugin system unvalidated by a real host
is a guess:

1. **station** — implement station's declarative front door over a host
   (its Stages 2 and 3), behind its unchanged public API:
   `connect`/`adopt`/`options` as today, plus `sdk(name)`,
   `create(name)`, `instances()` and `check()`. Station's own
   conformance corpus and integration suites must stay green. The bar
   is station's own integration test, not a plugin-flavoured version of
   it: **twenty-plus declared instances, none constructed at `open()`,
   two instances of one api live at once with distinct placeholders,
   and a fleet-wide feature default reaching an instance that never
   mentions it** — that last one through a nested host (§6.5), built
   over item 2's bridge rather than over a natively host-shaped SDK,
   which is what makes the bar reachable without sdkgen having adopted
   anything.
2. **sdkgen bridge** — a `FeatureHost` that runs an unmodified sdkgen
   feature class as a plugin, exercised against the generated test SDK.

*Exit:* station's suites green on the new implementation; `open()` with
twenty declared instances imports no SDK package, asserted; the bridge
runs `RetryFeature` unmodified, and deactivates it — which sdkgen alone
cannot do.

### P3b — The capability system

Capabilities and `match` (§11.1), version ranges and the
consumer/provider asymmetry (§11.2), cardinality and policy (§11.3),
and the whole-graph resolver with its explanations (§11.4) — plus the
four corpus sections that pin them (`capability`, `version`, `graph`,
`depend`). Build them in that order: a resolver written before the
matching rules are pinned will encode them twice.

**It sits after the station proof on purpose, and the reason is
evidence.** §11 is the largest single tranche in the library — most of
the jump in §19's per-port budget — and the first real consumer does not
use one line of it. Station declares no `requires` and no `provides`;
its twenty-six SDK instances are independent of each other, and its
ordering needs are §7's, not §11's. Shipping a capability graph, a
version-range grammar and a constraint resolver to twenty ports before
anything in the building needs them would be the most expensive
possible way to find out we designed it wrong.

So it lands where the evidence is: after P3 has put the core through a
real host, and ideally alongside the second consumer — a third-party
extension ecosystem, where "this plugin needs a store, version 2 or
better" is the case that actually exists. If P3 turns up a station
requirement that wants it sooner, it moves; that is a decision made on
a finding rather than on a plan.

The three pure sections (`capability`, `version`, `graph`) are worth
writing as corpus entries *before* the code either way — they are cheap
as data and they are what stops the resolver encoding the matching
rules a second time.

*Exit:* the four capability sections green in TypeScript; a blocked
instance's explanation asserted, not just its blocked-ness.

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
  `spec/plugin.aon` does not exist.
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

Budget, per port: **~1200 lines for the core, plus ~500 for the
capability system (§11)** — so ~1700 for a complete port — plus the
driver. The split is deliberate and load-bearing: P3b (§18) ships the
second half only once something needs it, and a port that has the core
is a *useful* port, not a partial one. Station's initial use needs the
core alone. The total is up from the ~800–1200 this document first claimed, and the
increase is honest bookkeeping rather than scope creep discovered late:
§11's capability matching, version ranges and whole-graph resolver are
real code in every port, and quoting the old number while shipping the
new model would make the budget decorative. The rule it enforces is unchanged — a port that busts its
budget is a signal the model grew, and the response is to shrink the
model, not to accept the port.

Two things keep that number from being paid twice. Capability matching
is `struct`'s `match`, not a filter language of our own (§11.1), and
the resolver is pure over JSON, so it is corpus-tested rather than
integration-tested in every port (§11.4).


## 20. Open questions

1. **Automatic deactivate/reactivate on a runtime option patch** (§9.4)
   is always correct and sometimes surprising — a rate limiter loses its
   in-flight window. The alternative is to reject a patch on a live
   instance without `reconfigure`. Resolve in P1, with the corpus.
2. **Does `unload` destroy state, or may a host keep it for a later
   reload?** Currently destroyed at `close`. A "detached state" concept
   would serve config reload, at real complexity cost.
3. ~~**Should hook bindings be able to abort the fan-out?**~~
   *Settled* — the `bail` dispatch mode (§6.1). The instinct to resist
   it was wrong: Cordis has carried the same mode for years, which is
   better evidence than an argument from parsimony.
4. ~~**Where do per-definition defaults live in the document?**~~
   *Settled* — the name-keyed `default` map (§9.1, §9.3), at precedence
   levels 3 and 5. Raised by station's review: its `api.<slug>` block
   writes a policy or a package name once for every instance of an api,
   and §17.1's "the `api` field disappears" is true of the *field* and
   not of the *block*. The alternative shapes — a `defaults: true`
   marker on an instance entry, or keeping the untagged instance as the
   carrier — both leave one key doing two jobs, and the untagged-carrier
   form shows up as a real instance in `host.list()` and in every status
   row built from it.

   Settled here rather than deferred because P1 ships the document
   normalizer and requires the `config` corpus green at its exit: a
   `default` map introduced after that would not extend the canonical
   API and its fixtures, it would invalidate them. The cost is that
   seneca's shortname inheritance goes with it — §9.3 says why that
   forfeit is the right way round.
5. **Per-instance scoping of the host** — seneca's delegate gives each
   plugin a view of the host that attributes its calls automatically. It
   is genuinely useful and genuinely hard to port. Deferred to P2 as a
   possible `inst.host` wrapper.
6. **Does station's proxy need to see plugin state?** If station's
   `station_integrations` MCP tool grows a "deactivate this integration"
   verb, activation state becomes remotely controlled, and the wire
   protocol needs a representation. Station-side question, raised here
   so it is not a surprise.
7. **Versioning between host and plugin.** *Partly settled* —
   capability versions and consumer/provider ranges are §11.2. What
   remains is the *host's own* API version: nothing yet declares "I
   need host API >= X". The mechanism is now obvious (the host provides
   a capability like any other, and a plugin requires it with a range),
   so this is a decision about what the host's capability is called and
   when it bumps, deferred until the API has moved once.


## 21. Non-goals

- **Isolation or sandboxing.** Plugins run in-process with full host
  privileges (§10.4). Out-of-process plugins are a different design.
  OSGi (§23) is the cautionary evidence rather than a missed
  opportunity: its classloader-per-bundle isolation is what allows two
  versions of one package to coexist, *and* what breaks reflection,
  thread-context classloaders and `ServiceLoader` across bundle
  boundaries — the single largest source of the platform's reputation
  for difficulty. Isolation is not a feature that was too much work
  here; it is a feature whose cost lands on every plugin author whether
  or not they wanted it.
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


## 22. Prior art: Cordis

[Cordis](https://github.com/cordiverse/cordis) is a context-based plugin
kernel: four years in production under the Koishi chatbot framework, and
now the kernel of [DeepSeek Harness](https://deepseek.com/harness/en/),
where models, tools, skills, sessions, sandboxes, storage, the agent
loop and the UI are all plugins. It is the closest thing to this design
that already exists, it is further along, and several of its answers are
better than the ones this document started with. Four of them have been
taken into the sections above; they are collected here so the debt is
legible and so the two places we deliberately diverge are on the record.

### 22.1 What we took

- **The scope, not the ledger** (§8.3). Every registration made through
  a plugin's context is inherently disposable and owned by that
  plugin's fiber; `ctx.effect()` covers anything foreign. This design's
  first draft made the plugin author keep the list by hand.
- **`PENDING` as a state** (§5.1). Cordis's fiber runs
  `PENDING → LOADING → ACTIVE | FAILED` and
  `ACTIVE → UNLOADING → DISPOSED`. "Declared but its dependencies are
  not available" is a different fact from "switched off", and this
  design had one state for both.
- **Live requirements** (§11). A plugin with `inject` waits for its
  services, and if a service disappears — during provider replacement,
  say — it unloads and comes back when the service returns. That is a
  better answer than refusing the deactivation.
- **Dispatch modes** (§6.1). `emit`, `parallel`, `serial`, `bail` and
  `waterfall` (this design's `chain`). Our `hook` was one word standing
  in for four different concurrency behaviours.

And one caveat, taken as stated: disposers run in reverse registration
order, but **async disposers are not serialized**, so order-dependent
teardown belongs in a single effect (§8).

### 22.2 The port that already ran our P4

[`cordis-rs`](https://github.com/dshbox/cordis-rs) is a runtime-agnostic
Rust port with zero dependencies — the same model, in the language this
design's plan schedules as its hardest early port. Its `Fiber` /
`FiberState`, its "single-shot and fiber-owned" effects with an
`EffectHandle` for early disposal, and its object-safe `Plugin` trait
are worth reading before writing our own.

Its **documented divergences** are worth more still, because they are
the list of things that did not survive the crossing: no Proxy-backed
reflection, no decorator syntax, eager lifecycle reconciliation instead
of promise-based suspension ("deterministic without requiring a specific
executor"), and no meta-event interception. That list is the
portability budget in §18's P1, obtained without our having to spend a
port to discover it.

### 22.3 Where we diverge, and why

- **Named instances.** Cordis makes multi-instance opt-in per plugin
  (`reusable: true`) and instances are anonymous **forks**, disposed by
  holding the fork handle: `fork.dispose()`. That is fine in-process
  and no use at all from a configuration file, a CLI, or an agent tool
  — you cannot write "the slow retry instance" in a document and later
  deactivate *that one* by name. Our `name$tag` (§4) makes every
  instance addressable from outside the process, which is precisely the
  requirement station has, and multi-instance is a property of the
  system rather than a permission each definition grants.

  This one is not a judgement call, and the evidence is OSGi's (§23).
  Configuration Admin's factory configurations originally got
  **auto-generated PIDs** — anonymous instance identity, the same
  choice Cordis makes. In R7 the specification added the form
  `factoryPid~name` — `my.factory.component~foo`,
  `my.factory.component~bar` — for the stated reason that a generated
  PID "has no meaning" and makes identifying a particular instance
  later much harder. That is our `name$tag`, separator and all, arrived
  at independently by the one ecosystem that shipped the anonymous
  version first, lived with it for a decade, and migrated away. When
  the two prior systems disagree and one of them has already been both
  things, its second answer is the one to take.
- **Host-declared points.** In Cordis a plugin can introduce a new
  service key on the context; that open-endedness is what lets
  "everything is a plugin" be true. We require the host to declare its
  points (§6.4), so an unknown binding fails at `define` time and the
  extension surface of a library is a knowable, auditable list. The
  cost is real and worth stating: a voxgig/plugin host cannot be
  extended in a direction it did not anticipate. For station — where
  the question "what can a plugin do to my outbound traffic?" has to
  have an answer — that is the right trade. For a harness whose entire
  architecture is plugins, it would be the wrong one.

The honest summary: on lifetime and disposal Cordis is ahead of where
this document started, and we should follow it. On addressing and on
the size of the extension surface we are solving a different problem,
and should not.


## 23. Prior art: OSGi

[OSGi](https://docs.osgi.org/specification/) has been solving this exact
problem in Java since 1999: bundles with a real lifecycle, a service
registry whose contents come and go at runtime, versioned dependency
resolution, and configuration-driven instantiation. It is the deepest
prior art available and the only one with twenty-five years of evidence
about which parts were mistakes. Both halves are useful.

Its core shape will look familiar, because much of this design
converges on it independently: bundle states `INSTALLED` (not resolved)
/ `RESOLVED` (wired, not running) / `ACTIVE` are our `pending` /
`loaded` / `live`; `BundleContext` is the instance scope (§8.3); the
**whiteboard pattern** is §6's inversion, named in 2004 in a paper
called *Listeners Considered Harmful*; and Declarative Services'
`static` reference policy — deactivate the component when a mandatory
reference goes, reactivate when it returns — is §11.3, reached again by
Cordis fifteen years later.

### 23.1 What we took

- **Named factory instances** (§22.3). The `factoryPid~name` form, and
  more importantly the documented reason it replaced generated PIDs.
- **Cardinality and policy** (§11.3). Optional requirements — a plugin
  that runs without metrics and uses them when present — had no
  expression here at all before. Static vs dynamic policy came with it;
  `reluctant`/`greedy` deliberately did not (§11.3).
- **Versioned capabilities and the consumer/provider asymmetry**
  (§11.2). The single most counter-intuitive correct idea in the whole
  survey.
- **Attributed capabilities with a match filter** (§11.1) — as
  `struct`'s partial match rather than OSGi's LDAP filters, because we
  already have one and porting a second to twenty languages would be
  indefensible.
- **Resolution as a phase with a whole-graph answer** (§11.4), and its
  corollary that the *explanation* is a deliverable.

### 23.2 What it warns us about

The failures are worth more than the features.

- **Teardown is approachable, never achievable** (§8.2). OSGi has total
  lifecycle control and bundles still leak — a static field, a
  `ThreadLocal`, an unstopped thread. The lesson is not to try harder;
  it is to state the guarantee narrowly and make the safe path the
  default one.
- **Diagnostics are the product.** `Unresolved constraint in bundle X:
  missing requirement osgi.wiring.package=…` is a correct answer that
  has cost the industry days. §11.4 treats the explanation as
  corpus-tested output for this reason.
- **Start levels are how ordering goes wrong** (§7). A global integer
  ordering becomes the thing people bump until it works, in place of
  declaring the dependency they actually have. Our bands are the same
  mechanism and need the same warning label.
- **Isolation is where the complexity came from** (§21, §10.3).
  Classloader-per-bundle buys simultaneous versions and costs
  reflection, thread-context classloaders and `ServiceLoader` across
  boundaries. It is the reason tier S is a cost decision rather than a
  language limitation — and the reason we are not buying it.
- **The dynamic story is mostly unused, and everyone pays anyway.**
  Most OSGi deployments restart rather than update a bundle in place.
  The complexity is universal, the benefit rare. Runtime activation is
  a stated requirement here, so it is load-bearing — but the cost must
  land on the hosts that use it, not on every plugin author in every
  language. That is the argument for the automatic scope being the
  default path (§8.2), and against importing every knob OSGi offers
  just because it exists.

### 23.3 The shape of the disagreement

OSGi's model is that **configuration creates instances**: a Managed
Service Factory plus a configuration record with a factory PID is what
brings a component into being, and removing the record removes it. Ours
is that a document is *applied* to a host that also has a programmatic
API, and `apply` (§9.6) reconciles. The two end up in nearly the same
place, and OSGi's is arguably purer — but it presumes a container that
owns the process, and this is a library that a host library embeds. A
station cannot cede "which plugins exist" to a config file it does not
control.

The larger disagreement is scope, and it is worth saying plainly: OSGi
is a *module system* — it resolves and isolates code, not just
extensions. That is why it can do multi-version and hot update, and why
it costs what it costs. This design is a plugin system with a
dependency model borrowed from a module system, which is a smaller
thing on purpose.
