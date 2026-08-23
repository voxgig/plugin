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

Last updated: 2026-08-22.


## 1. What has landed

| Where | What |
|---|---|
| voxgig/plugin#4 | The design on `main`. |
| voxgig/plugin#5 | P0: the skeleton — `Makefile`, `spec/` with the empty corpus and its aontu format shape, `tools/`, CI. Three review rounds, all of them the same defect class. |
| voxgig/plugin#6 | The `active` overload settled: the lifecycle status is `live`, the config key stays `active`. |
| voxgig/omni#36 | Two tooling bugs found while copying omni's `build-spec.js` into this repo, fixed upstream where they also lived. |


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

Doing that properly means editing the design, which is a larger change
than the corpus section it blocks; the section ships pure and correct
in the meantime, and this row is the reason it looks incomplete against
§15.3.


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


## 10. Open, and deliberately so

| | |
|---|---|
| **Station's Stage 5 hold** | Whether station stops after ts/js until P4 settles the canonical, or accepts divergence and budgets a migration across sixteen ports. A recommendation with a real cost either way; not plugin's call. |
| **sdkgen adoption** (§17.2) | Uncommitted. The risk that invalidates the plan rather than delaying it: with no second consumer, station carries a generic abstraction for one. |
| **The dependency decision** | Deferred to P5 by design, and non-blocking for station's native rollout. Keep it deferred rather than assuming it. |
