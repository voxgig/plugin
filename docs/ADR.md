# Architecture Decision Records

One record per architectural decision that is **expensive to reverse**
and **not obvious from the code**. A record says what was decided, what
it costs, and what would make us revisit it — so that a future reader
finds the reasoning rather than re-deriving it, and so that changing the
decision is a deliberate act rather than a drift.

The full design is [`docs/design/plugin.md`](./design/plugin.md); §
references below are to it. A record does not restate the design, it
records the *choice* the design made and why the alternative lost.

**Format.** Each record has a status, the context that forced a choice,
the decision, its consequences (including the ones we do not like), and
the conditions under which it should be reopened. A record is never
edited to change its decision — it is superseded by a later record, and
the old one is marked so.

| # | Decision | Status |
|---|---|---|
| [1](#adr-1--static-loading-is-preferred-dynamic-only-when-cheap) | Static loading is preferred; dynamic only when cheap | Accepted |


## ADR-1 — Static loading is preferred; dynamic only when cheap

**Status:** Accepted. Design §10; security posture §10.4; non-goals §21.

### Context

A plugin system has to answer "where does a definition come from?" Two
answers are available, and most systems pick one and build the whole
architecture around it.

**Dynamic loading** — resolve a name to a module at run time and import
it — is what seneca, sdkgen and OSGi do, and it is what people expect a
plugin system to mean. It is also the answer that decides an enormous
amount downstream: isolation, versioning, class/module identity,
teardown, and the security boundary.

**Static registration** — the definition is compiled in and handed to
the host by name — is available in every language without exception, and
asks nothing of the runtime.

The forcing question for this library is that it must behave
**identically in 23 languages**. Seven of them (go, rust, swift, dart,
haskell, zig, lean) have no practical runtime code loading at all, and
three more (c, cpp, ocaml) have one that is real but ABI-fragile. A
contract whose behaviour depended on dynamic loading would be a contract
those ten could not implement, and the corpus — the only thing keeping
the implementations honest — could not cover it.

### Decision

**Static registration is the floor and the default. Dynamic resolution
is an optional, host-installed capability, offered where the language
makes it cheap, and no corpus behaviour may depend on it.**

Concretely:

1. `host.define(definition)` works in every port, is the only path in
   some, and **no behaviour in the corpus may depend on anything else**
   (§10.1).
2. Dynamic resolution is a **resolver the host installs**. The default
   resolver is **off**. `load(ref)` looks in the catalog first, then
   asks the resolver, then fails `plugin_unknown_definition`.
3. The part of dynamic loading that *could* differ per port — which
   module ids a name maps to, in what order — is extracted as a **pure
   function**, `resolvecandidates(name, sources)`, and pinned by the
   corpus in every port including the ones that can never import
   anything (§10.2, 13 entries).
4. *Applying* those ids — `require`, `importlib`, `ServiceLoader` — is
   per-port integration-tested, "because a JSON corpus cannot import a
   Python module in Go" (§10.2).
5. Whatever path a definition arrives by, **its `name` must equal the
   ref's name**, or it is `plugin_definition_name` — otherwise a
   resolver could hand back a `memcache` definition for `cache$hot` and
   reinstate the aliasing §4 removed.

"Cheap" is the operative word in the title, and §10.3's tier table is
what it means in practice — mechanism by language, from `import()` at
the top to "static only" at the bottom.

### Why the alternative lost

Not because the static languages "cannot". **OSGi is the most thoroughly
dynamic plugin system ever built and it is written in Java** — a static,
compiled, statically-typed language. Bundles install, update and
uninstall at runtime with multiple versions of a package live at once.

Dynamism was never a property of the language. It was a property of the
*container*, and OSGi bought it with a classloader-per-bundle
architecture that is also the direct cause of every "classloader hell"
story the platform is known for: reflection across bundle boundaries,
thread-context classloaders and `ServiceLoader` all break on it (§23).

So the decision is a **cost decision**: the price of dynamism in these
languages is an isolation architecture this library has declared a
non-goal (§21). A host that genuinely needs runtime code loading can
have it, at that price, in its own resolver.

### Consequences

**Good.**

- One contract, 23 implementations, no capability tiers in the corpus. A
  behaviour is either in `spec/plugin.json` and true everywhere, or it
  is not a behaviour of this library.
- The security posture can be stated honestly rather than implied
  (§10.4): loading a plugin is executing code, there is no isolation in
  any port, `source` entries are an allow-list of *shapes* and not a
  boundary, and the default is off — because "the developer compiled it
  in" is the only trust statement this library can make.
- Lazy `declared` instances stay useful, because the catalog carries the
  option **shape** at registration time. A host can validate twenty
  declared instances without constructing one.

**Bad, and accepted.**

- The headline feature people expect from a plugin system is opt-in and
  off by default. That is a documentation burden forever.
- **As the code stands today, no port ships a live resolver at all.**
  `Host` never calls `resolvecandidates`; only the pure grammar is
  implemented and tested. Every port is static-only *in practice*,
  whatever tier §10.3 puts it in, and the integration suites §10.2
  promises do not exist yet. This is a real gap between the design and
  the code, and naming it here is the point of the record.
- A host wanting dynamic loading writes the resolver itself, and gets no
  help with the hard parts (versioning, unload, identity).

### Revisit if

- A host adopts the library and its integrators are writing the same
  resolver repeatedly. That is the signal to ship a reference resolver
  per tier-D language — still off by default.
- Isolation stops being a non-goal (§21). The whole calculation changes
  if out-of-process plugins are on the table, because then dynamism is
  bought with a process boundary rather than a classloader.
- A tier-S language grows practical runtime loading. The table is a
  snapshot of what the toolchains do, not a claim about the languages.
