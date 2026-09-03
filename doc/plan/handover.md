# Handover — what the work decided, and what it cost

The durable residue: decisions that stay true after an item lands, and
things a landed change taught that a register row is too short to
carry. Companion to [`adoption.md`](adoption.md) (the plan),
[`progress.md`](progress.md) (the register) and
[`contracts.md`](contracts.md) (what is owed across repos).

**This is not the live snapshot.** What is in flight, what is blocked
on a human, and what to pick up first is [`status.md`](status.md) —
read that first. Delete a section here once its lesson has been
absorbed somewhere better.

Last updated: 2026-09-01.


## 1. What has landed

| Where | What |
|---|---|
| voxgig/plugin#4 | The design on `main`. |
| voxgig/plugin#5 | P0: the skeleton — `Makefile`, `spec/` with the empty corpus and its aontu format shape, `tools/`, CI. Three review rounds, all of them the same defect class. |
| voxgig/plugin#6 | The `active` overload settled: the lifecycle status is `live`, the config key stays `active`. |
| voxgig/omni#36 | Two tooling bugs found while copying omni's `build-spec.js` into this repo, fixed upstream where they also lived. |
| voxgig/plugin, P4 (go, python) | The proving pair. All 19 corpus sections green in three languages, and six canonical defects fixed on the way — §13. |


## 2. `active` vs `live`, and why the framing was the hard part

Both designs recorded a **three-way** collision. It was two. Station's
`active: false` (*barred from running*) and plugin's document key
`active` (*may this run*) are **one predicate stated in two
polarities** — and deliberately so, since station's document *is*
plugin's document under C1. Counting them separately made the problem
look harder than it was and hid which way the fix ran.

The genuine clash was that key against the runtime **status**, and it
was substantive: `active: true` with `start: "lazy"` sits at `declared`
indefinitely, so one word answered two questions whose answers
routinely differ.

It resolved on **cost, not taste**, once the two sides were costed
separately — which the earlier "left as-is, renaming costs more churn
than the ambiguity" conclusion had never done:

| | shipped where |
|---|---|
| `active` as a key | station's 17 ports, its spec corpus, `sdkgen-station`, sdkgen's `options.feature.<name>.active` in ~23 template trees, every `station.json` in the field |
| `active` as the status | nothing — no code in any language, no `lifecycle` corpus section |

**The lesson worth keeping:** when a naming collision looks
unresolvable, check whether the count is right before accepting the
cost. And cost the sides *separately* — a single "renaming is churn"
judgement hid a 20:0 asymmetry for as long as it went unexamined.

### The trap it left behind

`live` also means "real" in ordinary English, so a sentence can be
unremarkable prose and a specific falsehood at once. **Five** sentences
needed fixing; the first pass found three and review found two —
including §5.4's "what makes the instance *a live instance* with
persistent state", in a paragraph whose entire subject is state
surviving while the instance is *not* live.

`AGENTS.md` carries the standing warning. The check that would have
caught them: **read any sentence containing `live` against the
`declared` and `loaded` cases specifically.**


## 3. Cross-repo pins rot, and the discipline did not catch it

station's `station-and-plugin.md` pins every `P§n` reference to a
plugin commit, and instructs re-pinning whenever plugin's design
advances. The `live` rename made station assert `live` while the pin
still pointed at a revision saying `active` — **the exact failure the
pin exists to prevent, produced by the change that introduced the
claim**, and caught in review rather than by the discipline.

Two things came out of it:

1. The pin's own step in the joint plan had been written as **done** —
   a completed one-time action. It is a standing obligation, and now
   reads as one.
2. A PR head is an acceptable pin when the merge commit does not exist
   yet. The property that matters is that the reference does not
   *move*; the original defect was tracking a *branch*, which does. A
   SHA does not, merged or otherwise.


## 4. Three ways a contract can pass while broken

All three were found reviewing P0's skeleton, all three exit 0 on
failure, and all three are cheap now and expensive once ports exist.

- **A misspelled top-level corpus key builds cleanly.** `primray:` for
  `primary:` emits the misspelled tree, keeps the version marker, and
  passes the shape check — while every runner reads `primary`, finds
  nothing, and reports **zero tests as a pass**. Not catchable by
  unification: the shape is imported *into* the generated check, so
  closing that file's root conflicts with the shape's own definitions,
  and aontu has no way to apply a closed template to a file's root
  (`$.Root` and `*: $.Root` are parse errors, `&: $.Root` is a path
  cycle). Checked in `build-spec.js` against the built artifact.

- **A tolerantly-invoked port target swallows compiler errors.**
  `|| echo "(no build target)"` cannot distinguish an absent optional
  target from a build exiting 7. Fixed by **removing the optional-target
  concept** — every port defines all four of `test`, `build`, `inspect`
  and `clean` — rather than adding machinery to detect it. `inspect`
  stays tolerant and says so where it is written.

- **"Non-mutating by cleanup" is not non-mutating.** `--check` restored
  the artifact on every exit path, which a SIGINT mid-write bypasses
  entirely — and signal handlers still leave SIGKILL, OOM kills and
  power cuts. It now builds into a throwaway mirror, so the committed
  file is never opened for writing.

The general shape: **a guard that reports success when it cannot do its
job is worse than no guard**, because it also removes the suspicion
that would have found the gap.


## 5. `ref` is marked pure but two of its listed behaviours are not

Found writing the section. §15.3's table marks `ref` **pure**, and lists
it as pinning "name/tag grammar, parse, format, canonicalization,
**auto-tag**, and **`pos` vs `seq` across a redeclaration**".

The last two are not reachable from the pure surface:

| | why not |
|---|---|
| **auto-tag** | reached only through `declare(name, {tag: '?'})`, a host operation. There is no `autotag` in the canonical API — `parseref`, `formatref`, `checkname`, `checktag` is the whole pure surface. |
| **`seq`** | defined as "a monotonic counter **from the host**". It is host state by construction; no pure function can observe it. |
| **`pos`** | "the document's array index, or the sorted-ref index for the map form" — assigned by document normalization, so it belongs to `config`, not `ref`. |

**Why this is not cosmetic.** C1 must be dischargeable *before* C2,
because C2 is what brings the driver contract and station needs `ref`
before its Stage 2. If `ref` requires a driver to run, C1 lands behind
C2 and the ordering the whole contract rests on inverts. A section
marked `pure` that needs a driver is also exactly the defect AGENTS.md
warns about from the other direction.

**What the section does.** It pins the genuinely pure part — grammar,
parse, format, canonicalization, both predicates, and the 1024-character
bound — 93 entries, no host. The three behaviours above are left out
and the omission is documented in the corpus header rather than left to
be noticed.

**What is still owed.** A decision, not a fix:

- `pos` assignment moves to the `config` section, where normalization
  already lives. Cheap and non-controversial.
- auto-tag and `seq` move to a driver section — `declare` is the
  natural home, since both are declaration behaviour.
- §15.3's `ref` row is corrected to match.

**RESOLVED.** §15.3 now reads:

| behaviour | section | pure? |
|---|---|---|
| `pos` assignment | `config` | yes |
| `seq` | `declare` | driver |
| auto-tag | `declare` | driver |
| `pos` stability across a redeclaration | `order`'s tie group | driver |

`ref` keeps grammar, parse, format and canonicalization — exactly what
the four pure functions can reach. §4 rule 4 now says where each half
is pinned, so the next reader does not have to rediscover that the
table and the surface disagreed.

**What is still owed:** `seq` and auto-tag have nowhere to be *run*
until the `declare` driver section exists, which is P2. `pos` is
covered now. The corpus header records the split.


## 6. The driver vocabulary was missing a verb it requires

Found writing the contract. §15.2 lists the command vocabulary as
sixteen verbs — `host`, `define`, `load`, `activate`, `deactivate`,
`unload`, `apply`, `options`, `call`, `emit`, `provider`, `export`,
`order`, `list`, `env`, `close` — and omits **`ready`**.

But §5.1 defines `ready(ref)` as running the whole forward path in one
call, §9.1 makes it the thing that walks a `lazy` instance up, and
§15.3's own `declare` row requires the corpus to pin "`ready` walking
the staircase". A driver that cannot issue `ready` cannot run a section
the same table demands.

So the list is **incomplete against the design's own section table**
rather than deliberately excluding it. `DOCS.md` §4.2 carries seventeen
verbs and says why; §15.2 is owed the same correction.

Two smaller gaps in the same list, both added and both flagged there:
`load` needs a `definition` key (a ref whose name differs from its
catalog entry — required to test `plugin_ref_duplicate` at all, since
loading the *same* definition twice is a documented no-op), and `host`
needs `points` (declaring a point's `kind` and `pin`, without which
§7's pin rules are untestable).

**The pattern worth noting** — this is the second finding of the same
shape as §5's. A list written in prose drifts from the table beside it,
and neither is wrong on its own; the disagreement only surfaces when
something tries to *use* both. Writing the corpus is what uses both.


## 7. One ambiguity the corpus had to settle

§7 describes "an integer `order`" for a band. §9.1's document shows
`"order": {"after": "retry"}` — a map. Both cannot be the spelling.

The corpus is the arbiter (as §4 rule 5 already makes it for
canonicalization), and it pins **one map**:

```json
{ "order": { "before": "...", "after": "...", "band": 0 } }
```

`band` rather than a nested `order`, because `order.order` needs
explaining every time it is read. Recorded in `DOCS.md` §4.4.

The alternative — accepting either an integer or a map — was rejected
on the standing rule: two spellings for one behaviour is the defect
class this repo exists to avoid, and it is the same argument that
rejected `{"deep": 0}` in §9.4.


## 8. What review found that writing did not

Fifteen findings across two rounds on the C1/C2 PR, all fifteen
genuine. Three are worth keeping beyond the fixes.

**A chain of adjacent comparisons does not pin a total order.** The
ten-level ladder was tested one step at a time — level 2 beats 1, 3
beats 2, and so on. That constrains the whole order only if the
relation is already known transitive, and a resolver applying layers in
the wrong sequence can satisfy every adjacent pair while inverting a
non-adjacent one. The case that actually bit: nothing required
environment options to beat the *selected profile's* values, because
level 7 was only ever compared with level 4. The group now carries
sparse non-adjacent pairs and an all-ten-at-once case.

**A corpus written in one alphabet pins one alphabet.** The load-order
cases used only lowercase refs, for which bytewise, locale-aware and
case-folded comparators all agree. Refs admit uppercase and `@`, which
is exactly where the three diverge: bytewise gives
`@scope/x, A, B, a, b` and case-folding gives `@scope/x, a, A, B, b`.
The all-lowercase cases were unfalsifiable.

**A pure group cannot pin when something happens.** The `$MERGE` domain
entries call `resolveoptions` with the shape already in hand, so they
prove *which* values are rejected and nothing about §9.4's requirement
that the raise happen at **catalog insertion**. A port accepting an
invalid shape and raising only at resolution time passed all of them.
That is the same shape as §5's finding — the group now says what it
does not cover instead of claiming coverage it cannot have.

The general lesson, and it is the one to carry into `typescript/`:
**a corpus entry is only worth what it can falsify.** Each of these
passed for every implementation, correct or not, which makes them
documentation rather than contract.


## 9. Normalization does not merge options, and that is forced

One contract decision came out of the same round. `normalizeconfig`
merges the *entry* keys (`active`, `start`, `order`) across base and
profile — §9.3's defaults-after-merge rule is about those — but leaves
option data as **`optionlayers`**, the levels 3-6 that are present, in
ladder order.

The split is forced rather than chosen. §9.4 makes merge behaviour a
property of the definition's option **shape**, which normalization has
never seen. A normalizer that flattened the layers would make
`$MERGE: append` unimplementable at load time: the layers it needed to
concatenate are already collapsed. Preserving them is what keeps
normalize-then-resolve equivalent to resolve-on-raw, and the corpus
header now states it.


## 10. What writing the canonical found

The corpus caught four defects in the implementation and two in itself.
That ratio is the argument for writing the contract first.

**In the implementation:**

- **The array form lost its positional order.** I built the load order
  from the profile overlay and then re-sorted the remainder, which is
  right for a map-form base and destroys the one thing an array
  document exists to express. Caught by `normarray#order` on the first
  run.
- **A pin rejected instead of placing.** §7 says a pin *fixes* where a
  binding sits and an ordering that would move it is the error. I had
  implemented "raise if it is not already there", which makes every pin
  either redundant or fatal.
- **The driver dropped the ordering block.** `ready` took only a ref, so
  every `order` entry ran against unordered bindings and four groups
  failed at once. The fix is that `ready` walks the staircase and does
  not carry configuration — the declaration does.
- **`acquire` could not be released early.** `greedy` exists to acquire
  N and release some, and the difference is what the scope must unwind;
  with no handle to release, the difference was always zero.

**In the corpus:**

- **A `normdefaults` entry asserted one option layer where there are
  two.** When `optionlayers` replaced the merged view I converted that
  entry mechanically and kept the base layer only. What it should
  assert — and now does — is that BOTH survive in ladder order, which
  is precisely the information a nested host needs to apply the
  defaults-after-merge rule one level down.
- **The `fail` group was unwritable as specified.** §5.2's claim is that
  a failed instance *remains registered and inspectable*, and a driver
  that stops at the first raise can never observe it. The contract
  gained `catch: true` (DOCS.md §4.1): the corpus could pin that
  activation raises, or that the instance survives, but not both — and
  it is the pair that matters.


## 11. §17.2 says thirteen hook points; the model declares eleven

Found by building the bridge, which needs the list to declare points
before any feature can bind to one.

§17.2 says the SDK "becomes a host by declaring its existing
vocabulary: **13 `hook` points**, named exactly as today
(`PostConstruct`, `PrePoint`, `PreRequest`, …)". sdkgen's
`model/sdkgen.aontu` declares **eleven** under `main.kit.feature.&.hook`:
`PostConstruct`, `PostConstructEntity`, `SetData`, `GetData`,
`GetMatch`, `PreTarget`, `PreSpec`, `PreRequest`, `PreResponse`,
`PreResult`, `PostOperation`.

Two of the three names §17.2 uses as examples are in that list. The
third, `PrePoint`, is **not** — it is declared by sdkgen-station's own
feature (`.sdk/model/feature/station.aontu`), along with `PreDone` and
`PreUnexpected`, because `hook: &:` admits any name a feature cares to
declare.

**So the count is not a property of the SDK; it is a property of which
features are installed.** Eleven plus station's three is fourteen, not
thirteen, and a different feature set gives a different number. The
bridge therefore takes the extra names as an argument rather than
carrying a list that pretends to be closed — `featurepoints(fetcher,
extra?)` — and `SDK_HOOKS` is documented as the core eleven rather than
as "the vocabulary".

Nothing is broken by this: a fixed thirteen would have been wrong in the
other direction, silently refusing to declare a point some feature
needs. But §17.2's sentence should say "the hooks the SDK and its
installed features declare" rather than naming a count, and the count
should come out.


## 13. What the proving pair found, and why a second implementation found it

P4 is a PAIR — go, "because static-only + typed extension points and
explicit errors will find every TypeScript-shaped assumption in the
model", then python, "the closest dynamic analogue that is not
JavaScript". Six defects landed between them, four from go and two from
python, and the shape of each is worth keeping: **none of them was a Go
or a Python problem.** All six were defects in the canonical — the
canonical failing to implement its own design, not the design being
wrong. **No design section changed.**

**1. `match` did not match (§11.1).** The design says `match` is "a
partial match against `attrs`, with exactly the semantics voxgig/struct
and the omni corpus already define for `match` — every leaf in the
requirement must be present and equal in the capability". The canonical
implemented `attrs[k] !== req.match[k]`. For a scalar that is the rule;
for a map or a list it is JavaScript **reference identity**, and a
requirement and a capability are written in different places and are
never the same object. So `match: { limits: { max: 5 } }` was satisfied
by no provider at all — including one declaring exactly that.

The reason it survived P2 is the reason it is written down here: **every
corpus entry was scalar**, and the two readings agree on every scalar.
Writing the port meant writing `want == got` in a language where that
does not compile for a map, which is the moment the question gets asked.
Fixed in the canonical (`matchvalue`, recursing), pinned by
`capability/nested` and `graph/blocked#match-nested`.

**2. The unwind direction was normative and unpinned (§8.3).** "unwound
by the host on deactivate, **in reverse registration order**, whether an
entry came from a host call or from `release`". A mutation reversing the
loop passed the whole suite. The cause is that `greedy` acquired
handles, and an acquired handle's release is an idempotent counter
decrement: run them in any order and `open` lands on the same number.
The direction was unobservable, so nothing observed it.

The fix is a probe change, not just an entry: `greedy` gained
`options.mark`, which registers that many **foreign** releases that each
record their own index as they run. `resource/scope#reverse` pins
`[2, 1, 0]`.

**3. `release` leaked the open count.** Registering a foreign release
did `open += 1` and nothing ever decremented it. `acquire` was already
symmetric; `release` was not. A plugin that used `release` could never
reach `open: 0`, so `close()` could not be asserted clean. Invisible
because **no corpus entry used `release` at all** — the driver's `stray`
method is a deliberate no-op, and nothing else reached it. Adding
`mark` was what first exercised the path, and the defect fell out
immediately.

**4. `unload` on a live instance leaked when `deactivate` failed.**
§5.2: `unload` from `live` is "deactivate first, then close", and "**any**
failure during a transition — a lifecycle callback raising, or a ledger
entry raising — lands the instance in `failed`", with the scope still
fully unwound. The canonical let the raise propagate straight out of
`unload`: the instance stayed `live`, its scope was never unwound and
its bindings were never removed. It reported a failure while leaking
exactly the resources the failure was about, and left a still-live
instance participating in every point.

The same path through `deactivate` was already correct, which is what
made this survivable: the two paths share a rule and only one
implemented it. Nothing exercised **either** — a failing `deactivate`
had no corpus entry at all. Pinned by a new `lifecycle/faildown` group,
including the case that distinguishes it from the `unload`-from-`failed`
row, where §5.2 says the entry is dropped anyway.

**5. `match` compared by value and not by type.** Python's `==` says
`True == 1`. The canonical uses `===`, under which they are different,
and JSON gives them distinct types — so a requirement for
`transactional: true` must not be satisfied by a provider advertising
`transactional: 1`. Nothing in the corpus said so, and half the ports
are written in languages whose default comparison agrees with Python's:
php's `==`, perl, lua. A port taking its language's default passes every
other entry in `capability/match` and silently satisfies a requirement
nobody asked for.

Found by a mutation deleting the port's `isinstance(x, bool)` guard,
which survived the whole suite. Four entries now pin it, including the
`false`/`0` half — a port that special-cased only `true` still gets that
one wrong — and a matching pair, so the guard cannot be written as
"compound values never match".

**6. §6.3's provider tie at equal bands.** The winner is "the highest
band, ties broken by ref sort", and no entry had two provider bindings
at the same band. Ref sort is the one place §6.3 does not fall through
to `pos`, because a provider is picked from a set rather than composed
into a sequence and "whichever loaded first wins" is not a rule anyone
can reason about across twenty ports. Two entries now pin it, with the
*higher* ref declared first, so a port breaking the tie by declaration
order fails rather than coincidentally agreeing.

### The pattern, and what it tells the next fourteen ports

The transferable lesson is about *coverage of the mechanism*, not about
either language. Every one of the six was one of two kinds:

- **a rule the design states, that no corpus entry can distinguish** —
  the unwind direction, the nested `match`, the type-strict `match`, the
  provider tie;
- **a code path no corpus entry enters** — `release`'s counter, and
  `unload`'s failing `deactivate`.

Neither is found by reading the canonical. Both are found the moment a
second implementation has to make the same decision from the same text —
which is the entire argument for running the proving pair before P5's
fourteen, and for reading this section before writing the fifteenth.

### What the ports changed about the model, and what they did not

Go **returns** errors where the canonical throws. That is a signature
change in every fallible function and it changes nothing else: the
corpus compares by `code` (§12), so a port that returns a `*PluginError`
and one that throws a `PluginError` are indistinguishable to it. §12's
choice to compare by code and not by message paid for itself here.

One thing genuinely does not port, and is stated rather than papered
over: **a binding cannot raise in Go**. `BindFn` returns `any`, and a
binding that wants to fail returns an `error` value, which §6.1's
collecting modes gather. No corpus entry exercises a raising binding, so
this is a difference in the port's *surface*, not in its behaviour — but
it is the one place a Go author writes something a TypeScript author
does not.

`BindFn` is also **one variadic type for all three point kinds**, where
a typed port would prefer three. It has to be: the `provider` probe
binds the same function to a hook point in `point/bail` and a provider
point in `point/provider`, and three distinct func types make that
unwritable. Recorded because the next static port (rust, swift) will
reach the same fork and should not re-litigate it.

**Python changed nothing at all**, which is the other half of the
result: it raises where the canonical raises, has ordered dicts, stable
sorts and first-class closures, so the translation is close to
line-for-line. That is also why it is the more dangerous port to write —
no compiler stops you, and every remaining difference is silent. The
four that bit are in `python/AGENTS.md`: `True == 1`,
`isinstance(True, int)`, late binding in closures, and `dict.get`
collapsing absent into `None` where JavaScript has both `undefined` and
`null`.

One process note that cost a whole mutation batch: **a stale
`__pycache__` makes a mutation run test nothing.** Bytecode is keyed on
source mtime and size, so restoring a mutated file can land on the same
pair and re-execute the old `.pyc` — a "caught" that is a mismatch
artifact, and a "survived" that never saw the mutation. The first batch
reported one false survivor and one false result and had to be redone
with the cache cleared around every run.


## 14. The bridge's review round: an exemption nobody wrote down

Codex reviewed P3.2 and raised eight things. **Seven were real**, and
one of them is worth more than the other six put together.

**The portability budget had an exemption nobody had written down.**
`typescript/AGENTS.md` forbids dynamic property interception. The
bridge's `utility.fetcher` getter/setter pair is exactly that — and
`Config.ts` cites the same budget, two files away, as the reason `apply`
refills an options map instead of installing a getter. Both cannot be
right without a stated scope, and there was none.

The scope is real and it is defensible: **a bridge to sdkgen cannot be
ported and is not meant to be.** sdkgen generates SDKs in 23 languages,
each feature written in that language's idiom; a Go SDK's feature does
not assign `ctx.utility.fetcher`, so a Go translation of `FeatureHost`
would have nothing to intercept. Each language that wants the bridge
writes its own against its own generated code, and what they share is
the plugin model underneath, not this mechanism.

The lesson is not "the budget was wrong". It is that **an unstated
exemption is indistinguishable from a violation**, and the next person
to want one will cite this file. It is now written down in
`typescript/AGENTS.md`, naming the one file it covers and saying that
the reasoning does not extend.

The other six, briefly, all now fixed and mutation-checked:

- §17.2 says `init` "splits into `define` (read options, declare
  bindings) and `activate` (capture)", and only `define` was
  implemented. An unmodified feature has no such split — which is
  exactly why the bridge's claim had to be narrowed from "deactivates
  the feature" to **"makes the feature's bindings reversible"** — but a
  feature that carries `activate`/`deactivate`/`close` now gets them
  called in the phase the model puts them in.
- §17.2 also says "`provider` points for the seams `__replace__`
  currently serves", and `featurepoints` returned only hooks and the
  chain. A replacement is a provider and not a chain: at most one wins,
  the losers are visible, the host keeps a default.
- The synthetic ctx replaced the SDK's real `client` and `utility`, so a
  feature reading `ctx.utility.log` broke and one reading `ctx.client`
  got the plugin instance. The trap now layers onto the SDK's own ctx.
- A hook name repeated between the core list and an SDK's extras bound
  the same method twice, and one `emit` fired it twice.
- A feature whose own `name` differed from the definition it was
  registered as was accepted silently, leaving configuration addressed
  by the SDK's feature name unable to resolve it.
- The live status file was left describing the previous commit — which
  `AGENTS.md` explicitly forbids, and which the register's own rule is
  supposed to prevent.

### The one that is stated rather than fixed

The bridge holds ONE shared `next` slot per feature instance, because
an sdkgen feature stashes `inner` once at init. §6.2 already names that
pattern: "a plugin that stashes `next` and calls it after deactivation
is a bug the host cannot prevent, and this says so rather than
pretending otherwise."

Every synchronous and nested path is correct — the binding sets the slot
immediately before the wrap runs, and a test pins it. The residual is an
**awaiting** wrap overtaken by a second request: both share the slot, and
the resumed wrap calls through the second request's chain.

Restoring the previous value in a `finally` makes it strictly worse: the
finally runs when the wrap returns its promise, before the feature ever
calls `inner`. A real fix needs either a per-invocation channel the
feature would have to be modified to accept — which is the thing the
bridge exists to prove unnecessary — or async-context storage, which the
portability budget forbids and which does not exist in most of the 23
languages. So it is bounded, tested where it can be, and written down in
the file.


## 15. P5's first two ports, and the bug a shipped port was hiding

**javascript found nothing**, which is the expected result: it is the
canonical with the types stripped, so a disagreement could only be
carelessness. Recorded in its `AGENTS.md` as the reason a corpus failure
*there* is a transcription error rather than a model question — the
opposite of the standing advice for every other port.

**ruby found four things, and one of them was a live bug in python.**

### The one that matters: `^` and `$` are not string anchors

Ruby's `^`/`$` match at every LINE boundary, so `/^[a-z]+$/` accepts
`"abc\ndef"`. Writing `\A`/`\z` deliberately is what raised the
question of what the design's grammar means by those characters — and
checking the other ports found that **the python port had shipped with
the same class of hole**: Python's `$` also matches *before a trailing
newline*, so `check_name("abc\n")` returned `True`, and so did
`check_tag` and `parse_range`.

Three ports rejected it, one accepted it, and **no corpus entry
distinguished them.** The grammar in §4 is written `^...$` because that
is how a regex is conventionally written down; what it means is STRING
start and end, and four languages spell that differently. Four entries
now pin it — name, tag, the public `parse_ref` path, and the version
grammar, which is the only other regex in the library and which a port
fixing `ref` alone would leave broken.

That is the sharpest example so far of the pattern §13 names: *a rule
the design states, that no corpus entry can distinguish.* It survived
two ports and a review round.

### `1` is not `"1"`

The type-strict `match` rule (§13's finding 5) was pinned for
booleans-versus-integers. A ruby mutation comparing `to_s` survived,
which is the string-versus-number half — and that one is what php's
`==`, perl's `==`/`eq` split and lua's coercion each get wrong in their
own way. Two more entries.

### Two NON-mutations, and why they are worth recording

Ruby makes two guards unreachable: `true == 1` is false, and
`true.is_a?(Integer)` is false. So the explicit boolean guard the python
port needs in `matchvalue` **cannot fire here**, and a mutation deleting
it survived the whole corpus.

A guard that cannot fire is dead code that reads as protection. It was
deleted, with the reasoning moved into a comment — and
`ruby/AGENTS.md` now says "do not re-add defensive code the language
already makes unreachable". The same call went the other way for
`JSON.parse(..., quirks_mode: true)`, which is also a no-op on ruby 3.x
but is kept because json 1.x genuinely rejected bare scalars; the
comment now says that accurately instead of claiming a protection it is
not currently providing.

**A surviving mutation is not always a corpus gap.** Sometimes it is the
language telling you the line does nothing.

### Scope: only six of P5's fourteen are verifiable here

`javascript`, `ruby`, `php`, `java`, `rust` and `perl` have toolchains
in this environment. `lua`, `csharp`, `swift`, `kotlin`, `scala`,
`clojure`, `dart` and `elixir` do not. Porting a language nobody can
execute ships an implementation nobody has run, which is the thing the
corpus exists to prevent — the same call station's Stage 5 made about
its own five gated ports.


## 16. Review round two: eight canonical defects the PORTS' review found

Codex reviewed the go and python ports and raised twenty-four things.
**Eight were canonical defects with explicit design backing** — the
design said one thing and the canonical did another, in every port at
once, since every port is a faithful translation of the canonical. All
eight are fixed, pinned and propagated.

The pattern is the one §13 named, at a larger scale: *a rule the design
states that no corpus entry can distinguish*, and *a code path no corpus
entry enters*. Reviewing a PORT surfaced them because a reviewer reading
a second implementation of the same rules asks "why does this do X?"
where a reviewer reading the original asks "does this do what it says?"

**1. `apply` never unloaded what the document dropped.** §9.6's first
sentence is "load what is missing, **unload what is gone**, patch what
changed". `apply` walked only the document's own refs, so an integration
REMOVED from a config reload stayed live, with its bindings in every
chain and its resources held. That is the case the method exists for.

**2. `apply` ran one interleaved loop, not §9.6's phases.** "Ordering:
deactivations and unloads first (reverse load order), then loads, then
activations in load order." It declared, loaded and activated each ref
before touching the next, so a plugin's `define` could see a
half-declared registry. Now four phases, and the log pins them.

**3. `deactivate` fell through on a `failed` instance.** §5.2 makes
`unload` the only transition out of `failed`. `deactivate` ran the
definition's callback on an instance that never completed activation
and, if that callback happened to succeed, returned it to `loaded` —
from where it could be activated again.

**4. The cascade discarded failures.** A consumer whose own `deactivate`
raised during a provider cascade was marked `pending`, which handed it
straight back to `reconcile`: the moment the provider returned, an
instance whose teardown had failed was activated again.

**5. Callback errors were not wrapped.** §12 defines
`plugin_define_failed` and its three siblings as "a callback raised;
wraps the cause", and nothing wrapped anything. An ordinary library
error escaping a callback reached the caller with **no code at all**, so
it took part in no cross-port error contract. Invisible because every
probe raise carried a code of its own. An error that already has a code
keeps it — the code is the error's identity.

**6. `acquire` and `release` were admitted outside `activate`.** The
guard tested "a callback is running", not "activate is running", while
§8.1 puts capture in `activate` and §8.3 names the error. A scope entry
registered in `define` is **never unwound** — `unload` on a merely
`loaded` instance does not call `unwind` — so this was a permanent leak
reachable from ordinary plugin code.

**7. A failing release did nothing at all.** §8.3 promises that every
entry still runs, that the errors are collected and raised as one
`plugin_release_failed`, and that the instance ends in `failed`. None of
it was implemented; `unwind` swallowed. The host reported a clean
`loaded` for an instance that had failed to give back what it held.
Invisible because **every release in the probe catalog was infallible**.

**8. Reservation made its own purpose impossible.** §9.1: "The host
declares those instances itself, after the user merge, and always wins."
Every path to `declare` was barred, including the embedding host's — so
`reserved: ['station']` meant station could never install the adapter it
had reserved the name for. `hostdeclare` is the host-owned path, and its
boundary is **by method, not by caller**: no language here can tell the
embedding host from a plugin holding the same host object, and one that
does can already call `close()`. What reservation protects is
configuration, which is exactly what §9.1 lists.

### And one row that had been asserting nothing

`resource/scope`'s `stray` entry claimed to call `release` outside a
lifecycle callback. **Every port's `stray` command was a no-op with a
comment saying it did**, so the row stayed green whatever the guard did.
The probe now exports its own instance api and `stray` calls through it.

That is worth more than its size: a corpus row that tests nothing is
worse than a missing one, because it reads as coverage.

### What the round cost, and what it says about reviewing ports

Three probe options (`greedy.early`, `greedy.markfail`, `noisy.bare`) and
one export (`probe`'s `inst`) had to be added, because **five of the
eight defects were unreachable from the probe catalog as it stood**. A
probe catalog is not a fixture; it is the surface through which the
corpus can see the library at all, and a rule it cannot reach is a rule
nothing checks.

Thirty-two mutations across the five ports, thirty-two caught. Two of
the canonical's own mutations came back as NON-mutations first — a
redundant `want.indexOf` clause that `wantlive` already covered, and a
corpus entry of mine that used an unreserved name to test a reservation
bypass — and both were fixed rather than counted.


## 17. Review round two, part two: what the corpus cannot see

Round two's other half was eight PORT-LOCAL fixes — not the canonical
being wrong, but one port disagreeing with a canonical that was right.
Five landed as ordinary corpus work. **Three could not, and those are
the ones worth reading.**

### The corpus cannot see a rule about a language it has no word for

Two Go fixes have no expressible corpus entry, in any port:

- **Numbers.** The model has one number type; Go has twelve. Corpus JSON
  decodes every number to `float64`, so both sides of every comparison
  arrive the same and the corpus cannot ask what happens when a Go
  EMBEDDING HOST writes `Attrs{"max": 5}` — an `int`, which
  `any(5) == any(5.0)` says is not `5.0`. The capability silently missed.
- **Goroutines.** §5.2 makes transitions sequential; `intransition` is
  set inside `run`, so two goroutines both passed the guard and
  `Declare` handed out a shared `Seq` and `Pos`. The corpus is
  single-threaded and always will be.

Both now live in `go/test/golocal_test.go`, and the file's header says
what it is for, because "the corpus is the contract" makes a port-local
test look like cheating. The rule that keeps it honest: **a port-local
test may pin a model rule in a dimension the port has and the corpus
does not; it may never state a rule of its own.**

`make test` in `go/` now runs `-race`, since a data race is exactly the
failure the concurrency test exists to catch and is silent without it.

### Two entries that only bite where maps have no order

`order/pinorder` and `order/seqtie` are real entries that catch a real
bug — in go. They cannot catch it anywhere else, and this took a
mutation run to notice rather than reasoning:

- `make spec` emits `spec/plugin.json` with **sorted keys**. Every
  decoder that preserves file order therefore hands JavaScript, Python
  and Ruby a pin map that is already sorted, so "sorted" and "insertion
  order" coincide and no entry can separate them.
- A delete-then-insert moves a key to the END of an insertion-ordered
  map, which is also where its new `seq` puts it — so registry order and
  `seq` order coincide there too.

The fixes are still right in all five ports: **an embedding host builds
its pin map in code, in whatever order it likes**, and the corpus only
ever sees the generator's normalised form. What is wrong is reading the
green as coverage, which is why both entries now say so in
`spec/plugin.aontu` and why the surviving mutations were investigated
instead of being patched away.

### The bridge lost a failed feature

`featureof` read the feature back through `host.exports(...)`. §11 hides
a `failed` instance's exports; §5.2 says `unload` is the only exit from
`failed` and still runs `close`. So the one case where a feature holding
a connection most needs its `close` was the exact case where the bridge
handed the callback `undefined`. It reads from the instance's own
`state` now, which survives every status.

Its test asserts on the FEATURE'S OWN LOG rather than on the host's
status map — the earlier draft asserted the instance was gone, which
stayed green with the bug still in.

### The tally

Fourteen mutations this round, fourteen caught. Three came back as
NON-mutations first (a `componentMax` guard rewritten against text that
no longer existed, a removed sort that Go's map randomisation hid, an
`if false` that fell through to the same lock) and were re-run rather
than counted — and two SURVIVORS were the finding above, not a gap to
paper over.


### Two more the same round, both cross-cutting rather than port-local

**`bail` needed a rule JavaScript had made for it.** §6.1 said "stops at
the first binding that returns a value" and left null unsaid. The
canonical and javascript stopped on `null`; go, python and ruby treated
it as a decline — **three of five ports had already, silently,
implemented the other reading.** The budget settles it rather than a
vote: JavaScript can tell `null` from `undefined` and almost nothing else
in the target set can, so making the distinction load-bearing costs every
other port a wrapper type carried through the whole dispatch path, to
express a difference their plugin authors cannot write. **Null declines**
is now in §6.1, and `point/bail#null-declines` makes the two readings
disagree out loud, with a second entry pinning `false` as a value so a
port reaching for its own truthiness lands somewhere visible.

**The `slow` probe asserted nothing, in all five ports.** DOCS.md §4.3
said it yields once per callback where the language has async, to prove
eager settling. No port implemented it — every one registers a plain
`record` — and **no corpus entry had ever instantiated it**, so a port
could ship a `slow` that raised on activate and stay green.
`check_probes.py` checked the definition existed, which is not the same
question.

Implemented literally it does not work, and that is the finding rather
than the fix: §18 makes the host synchronous, so an `async` callback
hands back a promise the host drops and everything past the first `await`
never runs — in python a coroutine called from a sync host executes
nothing at all. Yielding cannot demonstrate eager settling; it can only
demonstrate a truncated callback. So DOCS.md now says what `slow` is,
`lifecycle/slow` loads it, and **whether a host should ever await a
callback is written down as open** rather than guessed at.


### Two rules the design stated and nothing implemented

Both came in as go findings and neither was go's:

**`plugin_bind_scope` had been in §12's table since before anything
raised it.** §8.1 splits binding DECLARATION (in `define`) from
INSERTION (at a successful activate); the guard was the half nobody
wrote, in all five ports. A binding added from `activate` went live
without being part of the loaded definition, and each
deactivate/activate cycle appended another copy. `greedy.bind` is
`early`'s counterpart — it names the callback, because the guard is on
the phase and an entry exercising only `activate` leaves `deactivate`'s
mutation alive.

**`active: false` barred nothing past the apply that set it.** §9.6 is
explicit — "`activate` and `ready` on it fail rather than quietly doing
nothing" — and `wantlive` was a local in `apply`, so a later direct
`ready` brought the instance live. The config switch §17.1 exists for
(`stripe$test` off in prod) could be turned back on by anything.

The bar is now a field on the instance, reasserted on every apply in
both directions. `plugin_inactive` is new in §12: the design settled the
behaviour and left the code unnamed, and `plugin_bad_state` would have
been a lie — the status is `declared` and activating from `declared` is
perfectly legal; it is the bar that refuses.

**The old entry is the lesson.** `declare/free#barred`'s comment said
"`ready` on it fails rather than quietly doing nothing" and the entry
only ever called `apply`. The comment described the rule; the assertion
covered the first half of it. Third time this round that a green row
turned out to be describing rather than checking — after `stray` and
`slow`.


### `hold` was asking the cascade's question

§11.3's strict policy computed its holders from `consumersof` — the set
the CASCADE walks, which is the edges that RESTART. `hold`'s own word is
`required`, and required is cardinality, not policy. The two sets differ
in **both** directions, and each difference was a bug:

- a **mandatory-dynamic** consumer was excluded, so the strictest policy
  let a provider go that a live consumer could not do without. `dynamic`
  promises the consumer survives a *swap*; under `hold` there is no
  swap, so it falls back to `pending` — which is the exact outcome the
  policy exists to prevent.
- an **optional-static** consumer was included, so `hold` refused a
  deactivation on behalf of an instance that had said in writing it does
  not need the thing. Disruptive (it restarts), but the design's word is
  `required`, and optional is the plugin declaring the provider is not.

`holdersof` is now its own function beside `consumersof`, in all five
ports, and §11.3 says which set is which and why. Both directions have
an entry; both failed four ports before the fix.

**And the go test cache hid it for a while.** `spec/plugin.json` lives
outside the go module, so it is not part of go's cache key: a corpus
change with no `.go` change replays the previous result and reports
`ok (cached)` for entries it never ran. `make test` passes `-count=1`
now. Same trap as python's stale `__pycache__`, one directory over.


### Reluctance is a remembered choice, not a re-computation

§11.4 takes "always-reluctant: a satisfied requirement is not re-bound
while it stays satisfied", and every port implemented it as
`providersof(req)[0]` — re-ranked on every question. That is *greedy*
wearing reluctance's name: a better-ranked provider arriving later
silently becomes "the bound one", so deactivating the provider the
consumer was actually activated against restarts nothing, and the
consumer keeps using a reference nobody told it to drop.

The selection is now made once, at activate, recorded per requirement,
and dropped when the instance leaves `live` — one function, `chosen`,
is the only place a provider is picked, and the questions asked ABOUT an
instance pass `remember: false` so introspection cannot create a
binding.

**The statuses are identical under both readings**, which is why no
existing entry caught it. `depend/select#reluctant` asserts on the
LOG — under reluctance, deactivating the low-ranked provider produces
`dep$c:deactivate … dep$c:activate`; under re-ranking the log simply
ends. Two more pin it through `hold`, which names the holder, and one
pins that the selection does not survive the consumer's own restart.


## 18. What twelve more ports found, and the three gaps — all now closed

P5's fourteen tier-3 ports are complete: `php`, `perl`, `rust`, `java`,
`lua`, `csharp`, `elixir`, `clojure`, `dart`, `kotlin`, `swift` and
`scala` joined `javascript` and `ruby`, and **all seventeen
implementations pass all 572 entries**. Each port's own `AGENTS.md`
carries its language-specific traps; this section carries only what is
the CORPUS's business rather than a port's.

### The three gaps every port finds — all now closed

Mutation testing each port against the whole corpus produced the same
three survivors, in every language and independently. **All three are
now closed**, and the sizing was wrong in both directions: gap 1 cost
seventeen driver implementations and turned up a canonical bug, while
gaps 2 and 3 cost nine corpus entries between them and no port change.

**1. Shape validation at catalog REGISTRATION was pinned by nothing.
CLOSED — `declare/shape`, seven entries, plus `declare/register`.**
§10.1 puts `check_shape` in `catalog.add` so that a malformed shape
"fails once, and in the same place everywhere". No corpus definition
carried a `shape` at all, so the check was reachable only through
`resolve_options` and every port could defer it to resolution time and
stay green.

The reason nothing carried one turned out to be the whole of the gap,
and it was not what "no definition carries a shape" suggests: **the
driver's `define` command was a NO-OP in all seventeen ports.** DOCS.md
§4.2 documents it as `name`, `probe?`, `shape?` — "register a definition
in the catalog" — and every port's implementation was `break`, with a
comment explaining that the catalog is pre-seeded so the command only
*names* an entry. So `catalog.add`'s shape check was unreachable by
construction, and the `probe` key was ignored in the ten entries that
passed it. A corpus entry carrying a shape had nowhere to put it.

Closing the gap therefore meant implementing `define` in every port
first — all three keys, `probe` defaulting to `name` (not to the literal
`probe`, which DOCS.md said and which would have re-backed every `dep`,
`noisy` and `greedy` definition with the wrong probe). `declare/shape`
then pins the TIMING that `config/optmergebad` says in its own comment it
cannot: every entry stops at `define`, with no load and no document, so a
port that defers raises nothing and fails. Two of its entries also pin
that a valid shape is KEPT rather than validated and dropped, and one
that a rejected registration leaves nothing behind.

**Implementing it found a canonical bug of exactly the class §17
describes.** `apply` resolved an instance's options, handed the map to
`declare` — which ADOPTS it as the instance's own for a ref declared for
the first time — and then refilled that same map from itself, clearing
its own source. **A first-time `apply` gave the instance no options at
all**; applying the identical document a second time filled them in,
because by then `declare` returned the existing entry and the two maps
were distinct. Every `apply` entry in the corpus asserted status, log or
open, and not one asserted a value the options decide, so 539 entries and
seventeen implementations never saw it. `apply/idempotent` now carries
three entries that do. Present in canonical, go, javascript, python,
ruby, perl, lua and dart; absent from php, java, csharp, kotlin, rust,
swift, scala, elixir and clojure, whose `declare` copies the map or whose
values are immutable — a fifty-fifty split that is itself the argument
for the entry.

Lua additionally failed the new group for a driver reason worth
recording: its `probes()` returns PLAIN tables, and `T.getv` answers nil
for anything without the map metatable, so the lookup missed every time
and `define` replaced the probe with a definition that had no callbacks.
Five unrelated groups went red at once, which is what a driver bug looks
like and what a library bug does not.

**2. `providersof` comparing refs uncanonicalized. CLOSED —
`depend/byref`, five entries.** Found by php first and by every port
since.

**The gap was wider than its name, and §11.1 did not say what this
section claimed it said.** The claim was that "§11.1 lets a REF satisfy
a requirement" and only the canonicalization was unpinned. In fact
§11.1 said the opposite — "a dependency is on a capability, not on a
ref" — and the exception lived nowhere but a comment in the canonical's
`unmetof`: *"A ref satisfies too, because a host that genuinely needs a
specific instance should not have to invent a capability for it."*
Replacing the whole branch with `if (false)` passed all 552 entries.
Seventeen ports carried the behaviour because they copied the
canonical, not because anything checked it.

So closing it meant stating the rule in the design first (§11.1 now
carries it, narrow and with the reason), then pinning both halves: that
a live ref satisfies at all, that `loaded` and `declared` do not, that
losing it cascades like any other requirement — and the canonicalizing
comparison, which `dep$` against `dep` is the only way to reach, since
a trailing `$` parsing to the empty tag is the sole way two spellings
of one ref can differ (§4).

**3. A nested host counted as an open resource. CLOSED — `nest/open`,
four entries.** §6.5 registers the inner host's teardown in the outer
instance's scope; whether that also increments `open` was free, because
the three `nest` entries asserted `result` and `status` and never
`open`. It counts nothing: the scope entry is a teardown, not an
acquisition, and the inner host keeps its own counter. The entries pin
that a nested outer reports the same `open` as an unnested one, that
the count does not scale with the inner host's contents (two inner
instances, still 1), and that it unwinds to zero.

None of the three was a defect in any port — every port implemented the
design, and all seventeen passed the new entries unchanged apart from
gap 1's driver work. They were places where **two implementations could
disagree and the corpus would not notice**, which is the same category
§17 records.

**"Cheap" was wrong about gap 1, and the reason generalizes.** A gap
described as "no entry carries X" deserves one question before it is
sized: *can* an entry carry X? For gap 1 it could not — the command
that would have carried it did nothing — and the fix was seventeen
driver implementations plus a canonical bug fix, not a handful of
corpus rows. Gaps 2 and 3 were exactly what all three were advertised
as, which is how the mis-sizing went unnoticed.

**And a gap's NAME can be narrower than the gap.** "`providersof`
without `canon`" named one mutation; the branch that mutation lived in
was itself unreached, and the rule it implemented was not in the design
at all. Before writing the entry that kills the named mutant, delete
the whole construct and see what else survives.

### The gap-2 close was premature, and review caught it

Codex reviewed the PR that closed gaps 2 and 3 and said the second one
was not closed. It was right, for a reason bigger than the finding —
and the lesson is the most reusable thing in this section.

**A rule is implemented once per place that asks the question, not once
per codebase.** §11.1's "a ref satisfies a requirement" is read in
THREE places: runtime `providersof`, load-time `dependencycycle`, and
whole-graph `resolve`. Only the first had it. Pinning the runtime half
and declaring the rule closed left two implementations of the same
sentence disagreeing with it, and the corpus entry that proved the
runtime half said nothing about either.

Four defects came out of chasing it, and none of them is exotic:

- **`providersof` canonicalized EVERY requirement name.** §4's grammar
  is on plugin *names*; the design puts none on capability names, so
  `2fa` and `my cap` are legal capabilities that no ref could be
  called — and `canonref` RAISES on those. A legal document killed the
  host at its first such requirement. **Nine ports had independently
  worked around it** with a `try/except` or a tolerant `canon`, so the
  CANONICAL was the outlier; the corpus could not see it because every
  capability name in it happened to be a well-formed ref. A workaround
  that reads as defensive rather than as the rule is how this stays
  invisible: it fixes one call site and teaches the next reader nothing.
- **`dependencycycle` indexed by canonical ref and looked up raw.** The
  same cycle spelled `dep$`/`other$` produced no edges and evaded the
  load-time check outright — a guarantee about non-terminating
  reconciles that a spelling could switch off.
- **`graph.candidates` never considered node refs at all**, so
  `resolve()` reported `absent` about a provider the runtime binds. In
  the canonical spelling, too: this was not a canonicalization bug but
  a rule that had never been implemented there.
- **The design text overstated ref loss**, saying it always sends the
  consumer to `pending`. It follows the ordinary cardinality and policy
  rules (§11.3) like any requirement, so mandatory-`dynamic` stays live
  and optional never gated. A sentence that is true of the default and
  stated as universal is a contract two ports can implement
  differently while both reading it carefully.

Eleven entries pin the lot, across `depend/byref`, `depend/cycle` and
`graph/resolve`/`graph/blocked`; each targeted mutant fails its group
and no other. The canonical gained a tolerant `tryref`; the ports use
whatever tolerant spelling they already had.

**What to take from it.** When a rule is stated in one place and read in
several, grep for the other readers before calling it pinned. And when a
port has a workaround the canonical lacks, that asymmetry is a finding,
not a style difference — nine of them had one here, and it went
unremarked through P4 and P5.

### One gap that is a SCALE gap rather than a coverage gap

The dart port's `stableSortBy` survives having its index tiebreak
removed. Dart's `List.sort` is genuinely unstable — two hundred elements
sorted by a two-valued key come back reordered — but it uses an
insertion sort below 32 elements, and **no corpus entry sorts more than
a handful of bindings**. A host with 32 live bindings on one point would
see it and the corpus never will. Recorded rather than fixed by a
32-instance entry, because the fix belongs in the ports (all of which do
decorate) rather than in a corpus row that exists only to be slow.

### What the ports found that the corpus DID catch

Two bugs, both in ports rather than in the canonical, and both worth
knowing because the entry that caught each is not the obvious one:

- **`Host.instance` must canonicalize with the VALIDATING spelling.**
  Rust and swift both wrote it with the forgiving `canon`, and
  `declare/lookup#malformed` failed: a lookup with a malformed ref is
  `plugin_bad_name`, not a miss.
- **`declare`/`load` must test PRESENT AND NOT NULL, not merely
  present.** Every port's driver builds its command spec with all four
  keys and a null for each absent one, so a presence test reads an
  omitted `options` as an authored empty and wipes the real ones.
  `declare/clear` catches it.

### Two non-mutations worth not re-deriving

Recorded so the next port does not spend an afternoon on them:

- **Anchors in the ref grammar are load-bearing in some languages and
  decorative in others.** Ruby's `^`/`$` are LINE anchors (§15), java's
  and dart's `$` matches before a final newline — but clojure's
  `re-matches` and kotlin's `Regex.matches` already require a
  whole-input match, and swift and scala use character loops with no
  search at all. In those four the anchors cannot be got wrong, and the
  four `#trailing-newline` entries pass either way. They still catch a
  port that reaches for `re-find`/`containsMatchIn`.
- **An empty `after: []` reading as a stated constraint changes
  nothing**, because `order_targets` yields no targets for it. The guard
  documents the intent; it does not change an answer.


## 19. P6's six tier-4 ports: what a language actually costs

P6 is complete: `c`, `cpp`, `ocaml`, `haskell`, `zig` and `lean`, and
**twenty-three implementations now pass all 572 entries.** The durable
finding is that the six **are not one port six times.** The tier-4 label
("static-only", §10.3) describes the **loader**, not the language: it
says nothing about whether the language has closures, exceptions or a
garbage collector, and those three are what a port actually costs.

| | closures | exceptions | GC | what the port had to build |
|---|---|---|---|---|
| `c` | no | no | no | arena; `setjmp`/`longjmp`; `volatile` discipline |
| `cpp` | yes | yes | yes | nothing — `shared_ptr`, `throw`, `std::function` |
| `ocaml` | yes | yes | yes | nothing, but a **mutable** Value (below) |
| `haskell` | yes | yes | yes | nothing; everything raising is `IO` (below) |
| `zig` | no | no | no | arena; error unions **with the payload beside** |
| `lean` | yes | yes | yes | an **explicit instance api** (below) |

Read the first two rows against each other:

| | `c` | `cpp` |
|---|---|---|
| values | one arena, nothing freed | `shared_ptr`, destructors |
| raises | `setjmp` / `longjmp` | `throw` / `catch` |
| closures | function pointer + `void *ctx` | `std::function`, capturing |
| locals across a try | **`volatile`, or undefined** | nothing |

**In `c` the three decisions hold each other up, and that is the part
worth carrying forward.** The arena is not a shortcut: `longjmp` past a
frame leaks whatever that frame owned, and nothing here owns anything,
so there is nothing to leak. Take the arena away and `longjmp` becomes
unsafe; take `longjmp` away and an error-return discipline lets a missed
check continue silently past a failure — the one thing the corpus cannot
see and the one thing it exists to pin.

**`volatile` on every local that straddles a try is a correctness
requirement, not a warning to silence.** C guarantees only that
`volatile` locals keep their value across a `longjmp`. `-Wclobbered`
(on, through `-Werror`) found **seven** while the port was written, in
`reconcile`, `cascade` and `drive` — every one a flag or an index set
before a raise and read after it. A reader would have missed all seven.

`cpp` needs none of that, and writing it as a syntax edit of `c` would
have been the mistake. `std::function` is what makes a chain binding
read like the canonical — it receives `next` as a callable and writes
`next(arg)`, where `c` walks an explicit `Chain *` by index.

### The two shortcuts `c` and `cpp` took, and the corpus refused

- **`point/bail#null-declines`** — the `provider` probe must test its
  `value` option for **presence**, not for non-null. An authored `null`
  *is* a value, and in `bail` mode a null **declines** so the next
  binding answers. Reading it as "no value given" and substituting the
  ref made the probe answer where the contract says it stands aside.
- **`resource/scope#difference`** and **`lifecycle/resource#unwind`** —
  `acquire` must return a handle a plugin can hand back early, with the
  scope keeping the entry so unwinding it twice is a no-op. Stubbing the
  release count out left `open` high by exactly the number handed back.

### The other four, and the two that refused the shape

**`ocaml` — a MUTABLE value, which is not the obvious choice in ML, and
the corpus forces it.** §9.4's `refill` empties an options map and
refills it **in place**, precisely so a definition's callbacks — which
closed over that map at `define` — read the new values. With an
immutable map, `refill` is a rebinding the callbacks never see and
`apply/idempotent` fails. The persistence ML would prefer is spent in
`clone` instead. `defs.ml` exists because OCaml modules cannot be
mutually recursive across compilation units.

**`haskell` — everything that can raise is `IO`, and that is the whole
port.** Haskell *can* `throw` from pure code; it must not here. An
imprecise exception fires when the thunk is FORCED, and the corpus does
not merely assert that a call raises — it asserts **what survived a
raise mid-sequence**. A raise that happens whenever the consumer happens
to look is a different semantics from one that happens at the call, and
laziness would let a port pass the "does it raise" entries while getting
every ordering entry wrong for reasons no reader could see. So the split
is not taste: **a function is `IO` exactly when it can raise.** The
mutability sits on the instance (`IORef`), not inside the Value — which
is the opposite of `ocaml` and equally forced.

**`zig` — errors are values without payloads.** No `throw` carrying an
object, no `setjmp`; `error.Plugin` and an explicit `try` at every call.
So the diagnostic **travels beside the error**: `fail` parks a
`PluginError` and every handler calls `take()` as its FIRST act.
`pending` holds one error, and a handler that calls something fallible
before reading it gets the second error's payload with the first error's
control flow. What it buys over `c`: an explicit `try` means the
compiler will not let a fallible call be ignored, so the "missed check
continues silently past a failure" mode `c`'s `longjmp` exists to
prevent **cannot happen at all** — and there is no `volatile`
discipline, because there is no `longjmp`.

**`lean` — the kernel rejected the shape every other port uses.** A
`Definition` holding `Inst → PluginM Unit` puts `Inst` in a negative
position, and `Inst` holds the `Definition` back:

    (kernel) arg #1 of '_nested.Option_2.some' has a non positive
    occurrence of the datatypes being declared

That is not a quirk to route around; it is the logic refusing a type
whose inhabitants could encode a fixed point of `X → X`. So the instance
api became an **explicit record of closures** — and **that is not a
compromise**: §6 says a plugin never mutates the host, it declares
bindings and captures resources through a small API. Lean made explicit
what the other five leave implicit in a pointer.

### What the corpus caught, across all six

Beyond the two shortcuts above:

- **The regex dialect, in `cpp`.** The corpus's `match` patterns are
  JavaScript `/.../` literals. POSIX ERE leaves `\/` undefined — glibc
  tolerates it, so `c` passes with `REG_EXTENDED`; libstdc++ does not.
  Four entries failed on messages that plainly matched. `ocaml`, `zig`,
  `haskell` and `lean` all use a **`regexlite`** instead — the
  literal-with-anchors matcher `lua` already had, which *errors* on any
  metacharacter it cannot evaluate.
- **A bad number must be a reported error, not a crash**, first hit in
  `ocaml` with `float_of_string`. §9.5's env values "parse as JSON,
  falling back to string", and the fallback can only catch a *reported*
  failure. Every later port used the option-returning parse.

### And three it could NOT catch

Each is a checker or a copy rather than a behaviour, and each is the
kind of thing a corpus is structurally unable to see:

1. **`check_probes.py` had no `c` row.** `make probes` reported `c`
   green without opening a file in `c/test`. The probes existed — the
   row was the gap. **Adding a port means three registrations**:
   `LANGS`, `check_parity.py`, `check_probes.py`.
2. **The `provider` probe carried dead code in three ports.** `c`
   synthesized a capability record from `options.capability`, `version`
   and `priority` and dropped it on the floor; `cpp` and `ocaml` copied
   it. Writing it in Haskell, the natural reading was to **register**
   that record — a real divergence. The canonical reads none of those
   three keys and no corpus entry sets them. **Check the canonical, not
   the nearest port.**
3. **Lake builds only what a target's import graph reaches.** Fifteen
   Lean modules sat "green" while every one had a syntax error — they
   were never compiled, and a module that is not compiled reads exactly
   like one that compiled cleanly. Both libraries are now
   `@[default_target]`, `roots` names every module, `src/Plugin.lean`
   imports the lot, and the Makefile fails if no binary appears.

**Two ports passed 572/572 on the first run** — `zig` and `lean` — which
is the fifth and sixth port's dividend rather than luck: every mistake
had already been made and written down. Both were mutation-checked
rather than trusted (breaking `tagly`'s empty-tag case fails 125 entries
in each), because "passed first time" is exactly when a runner deserves
to be doubted.


## 12. Open, and deliberately so

| | |
|---|---|
| **Station's Stage 5 hold** | Whether station stops after ts/js until P4 settles the canonical, or accepts divergence and budgets a migration across sixteen ports. A recommendation with a real cost either way; not plugin's call. |
| **sdkgen adoption** (§17.2) | Uncommitted. The risk that invalidates the plan rather than delaying it: with no second consumer, station carries a generic abstraction for one. |
| **The dependency decision** | Deferred to P5 by design, and non-blocking for station's native rollout. Keep it deferred rather than assuming it. |
