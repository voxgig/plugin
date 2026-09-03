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
| [2](#adr-2--thread-safety-is-a-per-port-property-not-a-corpus-behaviour) | Thread safety is a per-port property, not a corpus behaviour | Accepted |
| [3](#adr-3--the-corpus-is-in-omnis-format-the-runners-are-not-omni-yet) | The corpus is in omni's format; the runners are not omni yet | Accepted |
| [4](#adr-4--one-version-line-and-the-tag-is-the-release-for-twenty-one-ports) | One version line, and the tag is the release for twenty-one ports | Accepted |


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


## ADR-2 — Thread safety is a per-port property, not a corpus behaviour

**Status:** Accepted. Design §14; the corpus exclusion is §15.4.

### Context

§14 opens with a flat promise: *"All public host operations are safe to
call from any thread. The registry and the resolved orders are
internally synchronized; each port uses its idiom (a mutex in
Go/Rust/Java, the GIL where that is genuinely sufficient, an actor in
Elixir)."*

That sentence is a contract-shaped statement, and this repository has
exactly one mechanism for holding an implementation to a
contract-shaped statement: the corpus. §15.4 puts thread safety
explicitly **outside** it — "Real dynamic module loading (§10.2),
thread-safety under contention, and anything involving a clock" are
named as per-port integration tests — for the good reason that a
deterministic JSON corpus cannot express a race.

So the promise is made repo-wide and checked nowhere. Counting what the
code actually does, across all 23 ports:

- **`go`** synchronizes properly. A non-reentrant `sync.Mutex` is taken
  once at the public door and never below it; `TryLock` is what turns a
  transition attempted from inside a lifecycle callback into
  `plugin_reentrant` without ever blocking.
- **`elixir`** gets it structurally: host state lives in an `Agent`, so
  the BEAM serializes every read and write, and the port is careful that
  `activate` is never invoked from inside `Agent.update`.
- **The other 21 ports have no synchronization at all.** Not the
  compiled ones, not the tier-3 ones. Six of them (`typescript`,
  `javascript`, `python`, `ruby`, `php`, `perl`) are on runtimes where
  that ranges from *fine* to *fine today*; the rest —
  `rust`, `java`, `csharp`, `kotlin`, `scala`, `swift`, `dart`,
  `clojure`, `go`'s compiled peers `c`, `cpp`, `zig`, and the functional
  four — would data-race under the concurrency §14 promises.

The forcing question is what to do about a promise 21 implementations
do not keep and nothing detects.

### Decision

**§14's guarantee is a per-port property. It is claimed only by the
ports that implement it, and no port may be assumed thread-safe merely
because §14 says so.**

Concretely:

1. The library's baseline contract is **single-threaded**. A host that
   drives one `Host` from several threads must either use a port that
   claims thread safety, or serialize the calls itself.
2. A port claims thread safety in its own `AGENTS.md`, and claiming it
   means the whole public transition is the locked unit (§5.2's
   sequencing), not each field access. Today only `go` and `elixir`
   claim it.
3. **Reentrancy is not thread safety and is NOT per-port.**
   `plugin_reentrant` — a transition attempted from inside a lifecycle
   callback — is a corpus behaviour, every port implements it, and it is
   what `intransition` is for. A mutex is not required to get it right,
   which is exactly why the two are separated here.
4. §15.4 stands: thread safety under contention stays out of the
   corpus. A port that adds synchronization owns an integration test for
   it, in its own suite, named as such.

### Why the alternative lost

The obvious alternative is to close the gap: add the language's mutex to
each of the 21 ports and keep §14 as written.

It lost on **verification, not effort**. The lock is easy; a lock that
is *correct* is a different claim, and this repo would have no way to
tell the two apart. `go`'s implementation is the evidence — getting it
right meant a non-reentrant lock taken exactly once at the door, unlocked
bodies underneath because the public transitions call each other, and
`TryLock` to keep `plugin_reentrant` non-blocking. Three design
decisions, none of them visible to a single corpus entry.

Bolting `pthread_mutex_t` onto `c` and `std.Thread.Mutex` onto `zig`
would have produced 572 identical passes either way, and the repo would
then be asserting thread safety in 23 ports on the strength of one
reviewed implementation and twenty-two unreviewed ones. **A promise
nothing checks is worse than an honest limit**, and it is worse in the
specific way this library cares about: it is the kind of claim a host
builds on and finds out about in production.

The narrower alternative — quietly leave §14 as aspirational — lost
because that is the state that produced this record. The gap was found
by review, not by the repo, after twenty-three ports had shipped.

### Consequences

**Good.**

- What the code does and what the documents say agree, and the
  disagreement that existed is written down rather than carried.
- A host reads one line per port and knows what it is getting.
- Ports stay comparable. A `c` port with a mutex and a `zig` port with
  one would still not be *the same* under contention, and the corpus
  could not tell; leaving both out keeps the 23 implementations
  behaviourally identical everywhere the corpus can see, which is the
  property the whole repository is built on.

**Bad, and accepted.**

- §14 as written is now the *aspiration* and this record is the *state*.
  Two places to read instead of one, until §14 is rewritten.
- A host on `rust` or `java` — languages whose users reasonably expect
  a library to be thread-safe, and which §14 names by name as taking a
  mutex — gets a single-threaded library. That is the sharpest edge
  here, and it is the reason this record exists rather than a comment.
- "Serialize the calls yourself" is real work pushed onto the host,
  and the library gives no help with it.

### Revisit if

- A host drives a `Host` concurrently in a port that does not claim
  thread safety. That is the signal to implement it *there*, to `go`'s
  shape, with the integration test point 4 requires — not everywhere at
  once.
- Someone builds a way to test it. A deterministic scheduler, a race
  detector in CI (`-race`, TSan, `cargo miri`) over a concurrent
  integration suite, or a model checker would move thread safety from
  "claimed" to "checked", and the calculation changes the moment it can
  be verified rather than asserted.
- §14 is rewritten to state the per-port position directly. Then this
  record is superseded rather than merely descriptive.


## ADR-3 — The corpus is in omni's format; the runners are not omni yet

**Status:** Accepted. Design §15; the format is
[voxgig/omni](https://github.com/voxgig/omni)'s `DOCS.md`.

### Context

Design §15 says, in these words, that `spec/plugin.json` "compiles from
`spec/plugin.aon`, and **every port runs it through
[voxgig/omni](https://github.com/voxgig/omni)**".

No port did. All twenty-three shipped a **hand-written corpus runner** —
the same algorithm re-implemented twenty-three times, each with its own
`deepequal`, its own `__EXISTS__`/`__UNDEF__`/`__NULL__` handling, its
own `/regex/` matcher. Five of them (`lua`, `rust`, `zig`, `ocaml`,
`haskell`) had to invent a `regexlite` because their standard library
has no regex engine — which omni already ships, in those exact five
languages.

The cost is not duplication for its own sake. It is that **a runner
defect is twenty-three separate defects**, and this repository has
already paid for that: six ports shipped without the section-coverage
assertion `AGENTS.md` requires, because there is no one runner to put it
in. The corpus catches a port that disagrees about *behaviour*; nothing
catches a port that disagrees about *how to read the corpus*.

Against that, the corpus was not actually in omni's format. Three things
kept it out:

1. **`cmd`.** The twelve driver sections carried the command list in a
   field omni does not define — and omni's version-1 validation rejects
   an unrecognised entry field, because an unrecognised field is almost
   always an assertion that stopped asserting.
2. **`err` as a code.** 119 entries wrote `err: 'plugin_not_loaded'`.
   omni matches an `err` string as a **case-insensitive substring of the
   message**, and its error base carried only `{name, message}` — so the
   assertion plugin actually makes, *the raised error's `code` equals
   this exactly*, could not be expressed at all.
3. **No `OMNI` block**, so omni would have run the corpus in its lenient
   version-0 mode with strict entry validation off.

### Decision

**Move the corpus to omni's format now; move the runners later, and keep
the format claim checked in the meantime.**

Concretely, and all of it landed:

1. **`cmd` is now `in`** — which is what it always was: the single
   argument the driver subject is called with. The corpus uses omni's
   nine entry fields and no others, and `spec/def/plugin-spec.aon` now
   says so rather than carving out a field of plugin's own.
2. **`err: '<code>'` is now `err: true` with
   `match: {err: {code: '<code>'}}`** — an exact assertion on a
   structured field instead of a substring of prose. This works in every
   existing port unchanged, because each already builds
   `{code, message, name}` as its match base.
3. **`OMNI: version: 1`** sits beside `PLUGIN: version: 1`. Two markers
   on purpose: `PLUGIN.version` gates plugin's own runners,
   `OMNI.version` gates omni's strict validation, and neither should
   stand in for the other.
4. **omni gained `Provider.errify`**
   ([voxgig/omni#58](https://github.com/voxgig/omni/pull/58)), because
   point 2 is unreachable without it — omni's default error base has no
   `code`, and seven of its ports report a failure as a message string
   with nothing else to offer. plugin was the forcing case; the hook is
   general.
5. **`make omni-check`** loads the committed corpus with omni's own
   runner and drives the `javascript` port through all nineteen
   sections. It is the check that keeps §15's claim honest.

### Why the runners did not move too

Because it is a different change, and a much larger one: twenty-three
test layers rewritten at once, in twenty-three languages, against a
corpus that is currently green in all of them. Doing it in the same
change set as the format move would mean a failure could be either the
format or the migration, with no way to tell which.

There is also a real question the migration has to answer first, and it
is a prime-directive question: **§16 permits exactly one dependency, and
omni would be a second.** The honest reading is that omni is a *test*
dependency rather than a runtime one — nothing it provides is reachable
from `src/` — and that prime directive 6 is about what a **consumer**
inherits. But that is a decision to take deliberately, per port, with
the vendoring shape settled (omni ships as source in most of its
twenty-four ports, not as a package), not as a side effect of a corpus
change.

### Consequences

**Good.**

- The corpus is genuinely portable: **572 entries across 19 sections run
  green under omni's runner today**, which `make omni-check` proves on
  demand rather than asserting.
- The error assertions got *stronger*, not weaker. `err: 'plugin_x'` was
  compared by code in plugin's own runners but would have been a message
  substring anywhere else; `match: {err: {code: 'plugin_x'}}` is exact
  and says what it means.
- A corpus change that drifts out of omni's format now fails a named
  check, instead of being discovered whenever the migration is attempted.

**Bad, and accepted.**

- §15's claim is still ahead of the code, and this record is the only
  thing saying so. Twenty-three hand-written runners remain, with the
  duplication and the per-port drift risk they carry.
- The check covers one port. `make omni-check` proves the CORPUS is
  omni-readable; it says nothing about the other twenty-two runners.
- `null: false` is now load-bearing and easy to lose. plugin's corpus is
  written in literal nulls — `point/bail#null-declines` asserts that an
  authored null IS a value — so omni must run it with null-normalisation
  off. That is a documented omni flag, not a workaround, but a migration
  that forgets it fails in one entry and looks like a behaviour bug.

### Revisit if

- A port's runner and another port's disagree about how to read an
  entry. That is the defect this ADR is deferring, and its first
  appearance is the signal to stop deferring.
- The dependency question is settled. Once §16's reading is agreed for
  test dependencies, the migration can start — canonical first, then
  propagate, exactly as every other change here.
- omni gains what the migration still needs. Section-coverage assertion
  and the probe-catalog contract are plugin's own additions today; if
  omni grows an equivalent, the per-port test layer shrinks to almost
  nothing.


---

## ADR-4 — One version line, and the tag is the release for twenty-one ports

**Status:** Accepted. Supersedes nothing; the per-port versions it
replaces were never written down as a decision.

### Context

Twenty-three ports, and only two of them are packages anyone can
install. `typescript` is `@voxgig/plugin` and `javascript` is
`@voxgig/plugin-js`, both on npm through `publish.yml` and npm trusted
publishing. The other twenty-one publish to no registry at all: `go`,
`rust`, `dart` and `lean` are consumed by git ref, and the remaining
seventeen are consumed by vendoring a source directory.

That left two questions the repository had answered only by accident.

**What version is a port at?** Four manifests state a version
(`typescript/package.json`, `javascript/package.json`,
`python/pyproject.toml`, `rust/Cargo.toml`) and nineteen ports state
none anywhere. The four had drifted to three different numbers — 0.1.6,
0.1.1 and 0.1.0 twice — none of which meant anything, because the
corpus they all pass is the same corpus. A consumer asking "which
version of the ruby port matches `@voxgig/plugin` 0.1.6?" had no way to
answer, and neither did we.

**How does a port without a registry get released?** It did not. Six
releases of the canonical port had happened and no other port had ever
carried a tag, so the only way to pin the go port was a SHA — and a SHA
does not tell you which corpus it passes.

### Decision

**`VERSION` at the repository root is the one version line.** It holds
plain semver and nothing else. `0.1.6` means *all twenty-three ports are
at that corpus* — not that each port changed, but that this commit is
the release point for every one of them.

**Every manifest that states a version must equal it.**
`tools/check_versions.py` enforces that, over the four manifests and
their lockfiles, and runs as part of `make check`. A port that states no
version is not required to invent one: for it the tag IS the version.

**Every port is tagged `<port>/vX.Y.Z`, at one commit, by `tag.yml`.**
Twenty-three tags per release, written atomically.

**The separator is a slash because Go says so.**
`github.com/voxgig/plugin/go` is a subdirectory module: the go command
resolves v0.1.6 of it from the tag `go/v0.1.6` and ignores every tag
without that exact prefix. One repository cannot sensibly run two tag
conventions, so the npm ports took go's — which is also
[voxgig/omni](https://github.com/voxgig/omni)'s shape, so the two
repositories now read the same way.

### Why the alternatives lost

**Per-port version lines** — each port versioning on its own changes.
This is what npm, cargo and pub all assume, and it is the right answer
for a repository whose parts change independently. This one's do not:
every port implements the same 572-entry corpus, and a corpus change
propagates to all twenty-three in one change set (AGENTS.md §1). Ports
here move together by construction, so twenty-three independent version
lines would encode a variation the repository does not have, and would
leave the "which ruby matches which typescript" question unanswered in
exactly the way it already was.

**A dash separator, `<port>-vX.Y.Z`** — what `publish.yml` used for its
first six releases. Go makes it unusable: a tag `go-v0.1.6` is invisible
to the go command, so the go port could never be released under it. A
slash for go and a dash for everything else is two conventions and a
footnote; one convention and six historical tags left alone is cheaper.

**Deriving `tag.yml`'s port list from the Makefile** — no duplication,
no drift. Rejected because that file writes tags that cannot be taken
back, and a regex over a Makefile is not what should decide which. The
list is literal and `check_versions.py` holds the two in agreement
instead, which fails on a developer's machine rather than in a release.

### Consequences

**Good.**

- A version number now means something across the whole repository. "The
  ruby port at 0.1.6" resolves to a tag, and that tag is a commit whose
  full CI matrix went green.
- Twenty-one ports became pinnable. `go get
  github.com/voxgig/plugin/go@v0.1.6` works; so does vendoring
  `ruby/v0.1.6`.
- A bump is a one-line reviewable diff, and `make check` refuses a tree
  whose manifests disagree with it — including lockfiles, which
  otherwise fail later and less clearly at `npm ci`.

**Bad, and accepted.**

- **A port with no change still gets a new version.** Release 0.1.7 will
  tag `lua/v0.1.7` whether or not the lua port was touched. That is the
  cost of a shared line, and it is the honest reading: what changed is
  the corpus the port passes.
- **Adding a port is now a five-place change**, not four — the Makefile,
  `check_parity.py`, `check_probes.py`, the CI matrix, and `tag.yml`.
  The drift check makes forgetting the fifth a failure rather than a
  silently unreleasable port.
- **The go tag is irreversible.** proxy.golang.org and sum.golang.org
  cache a version permanently: moving or deleting a tag reaches users as
  a security error, and the only withdrawal is `retract` in a new
  version. Every guard in `tag.yml` exists because of this, and a
  mistaken release cannot be undone, only superseded.
- **Two tag conventions are visible in the history.**
  `typescript-v0.1.0` through `typescript-v0.1.6` and
  `javascript-v0.1.1` are the old shape. They are not rewritten — a
  published tag is history.

### Revisit if

- **A port genuinely diverges.** If one port needs a release the others
  do not — a language-specific packaging fix, say — the shared line
  becomes a lie rather than a simplification, and per-port versions with
  a recorded corpus level would be the answer.
- **A registry gains automation.** PyPI for `python`, crates.io for
  `rust`, NuGet for `csharp`: each would publish under this same version,
  and each needs its own trusted-publisher registration. Nothing here
  blocks that; the version line is what those publishes would read.
- **The tag count becomes the cost.** Twenty-three tags per release is
  already enough that `git tag -l` needs a filter. If ports reach fifty,
  a single `vX.Y.Z` tag plus a manifest mapping ports to it may beat
  one tag each — at the price of go, which would then need its own.
