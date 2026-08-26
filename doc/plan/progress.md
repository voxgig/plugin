# The plan register

Live per-item state of [`adoption.md`](adoption.md). **A row changes in
the same commit that changes its status.** Rows tracking another repo
are updated when the change merges there, citing the PR — so **`DONE`
on an other-repo row means MERGED**, never "written". A row moves to
`IN PROGRESS` when a PR for it is open, which is a claim about work
being underway and not about it having landed.

Statuses: `NOT STARTED`, `IN PROGRESS`, `DONE`, `DECISION NEEDED`
(waiting on a call that is not the implementer's to make), `BLOCKED`
(waiting on work outside this item, named in the note), `DECIDED-NO`
(with a reason).

The four cross-repo obligations have their own register in
[`contracts.md`](contracts.md). What is in flight right now is
[`status.md`](status.md); what a landed item decided is
[`handover.md`](handover.md).


## Phase 0 — the skeleton

| Item | Status | Notes |
|---|---|---|
| 0.1 Layout, `Makefile`, `tools/`, `spec/def/plugin-spec.aontu` | DONE | voxgig/plugin#5. `LANGS`/`PORTS` empty and every target wired, so the first port is built, tested and parity-checked from its first commit. |
| 0.2 `make spec` / `make spec-check` green on an empty corpus | DONE | voxgig/plugin#5. The empty corpus is the exit criterion, not a gap. |
| 0.3 CI | DONE | voxgig/plugin#5 (`62e29cf`). Two jobs: spec freshness and api parity. Added because every sibling repo gates on its own checks and plugin had none, so the guards were enforced by nobody. |
| 0.4 Design on `main` | DONE | voxgig/plugin#4. Prerequisite for 0.1 rather than a tidy-up — P0 builds a skeleton around a document the mainline had never seen. |

## Phase 1 — the tracer bullet

| Item | Status | Notes |
|---|---|---|
| 1.0 The plan register | DONE | This file and its four companions. §18.1 requires each phase to update the register in the same change that lands the work, so it exists before the work does. |
| 1.1 `ref` corpus section (**C1**) | DONE | 97 entries, 9 groups, no host. Covers exactly what the four pure functions reach — grammar, parse, format, canonicalization, both predicates, the 1024 bound through all four. §15.3's extra assignments were moved out by 1.7. |
| 1.2 `config` corpus section (**C1**) | DONE | 84 entries, 13 groups, no host. All four pinned items, the partial-array rule, host key renaming, and the `optionlayers` split (see [`handover.md`](handover.md) §9). |
| 1.3 Draft driver contract in `DOCS.md` (**C2**) | DONE | `DOCS.md` §4: how an entry runs, 17 verbs, the 6-probe catalog, the ordering block, the observable, and what a port must not do. Landed *with* 1.4. |
| 1.4 `lifecycle` and `order` corpus sections (**C2**) | DONE | 31 + 28 entries (`order` grew from 22 when the `order/list` set landed - six entries pinning list-valued `before`/`after`, which every port had silently dropped). Corpus 527 → 533.  Driver sections, landed in the same change as the contract that makes them runnable. |
| 1.5 `typescript/` — the canonical | DONE | All 11 canonical names. All four corpus sections green: `ref` 97, `config` 86, `lifecycle` 32, `order` 28. Written to the portability budget — no reflection, no `Proxy`, no decorators, eager reconciliation. |
| 1.6 `tools/check_probes.py` | DONE | Checks presence of all six probes per port; behaviour is the corpus's job. `make probes` no longer reports its own absence. |
| 1.7 Relocate auto-tag and `pos`/`seq`, and correct §15.3 | DONE | §15.3 corrected: `pos` to `config` (pure), `seq` and auto-tag to `declare` (driver), `pos`-stability to `order`'s tie group. `pos` is now pinned by two `config` entries — the map form's sorted index and the array form's positional index, which disagree by construction. `seq` and auto-tag have nowhere to run until `declare` exists (P2) and are tracked as **2.4**. |

## Phase 2 — the canonical completed

| Item | Status | Notes |
|---|---|---|
| 2.1 Dynamic resolution, `apply()`, exports, position verification | DONE | Scoped names resolve verbatim (they did not); `from` bypasses candidate generation; `position()` returns §6.6's record with `outermost`/`innermost` pinned against a chain whose composition is asserted the other way in the same group. |
| 2.2a Remaining PURE corpus sections | DONE | `env` 30, `version` 29, `capability` 16, `graph` 10, `resolve` 8 — 93 entries, all running green against the canonical. Nine sections total, 330 entries. |
| 2.2b DRIVER sections: point, export, depend | DONE | 37 entries. Twelve sections, 367 total. Points (three kinds, four hook modes, composition, shadowing, exclusivity), export aliasing and ambiguity, and the reactive half of dependencies. |
| 2.2c DRIVER sections: declare, state, resource, apply, nest, trace, error | DONE | 50 entries. **All 19 sections §15.3 names now exist** — none missing, none extra — 417 entries total. Includes item 2.4's `seq` and auto-tag. |
| 2.3 `DOCS.md` completed from P1's draft | DONE | Tutorial, how-to, reference and explanation written; 517 lines. §4 stays a draft in COVERAGE, not stability. |
| 2.4 `declare` section: `seq` and auto-tag | DONE | The gap 1.7 moved rather than closed is now closed. Auto-tag pins LOWEST-UNUSED including the fills-a-gap case a counter-based implementation fails; `seq` pins that a re-declared instance gets a fresh one while `pos` does not move. |

## Phase 3 — proof, and the bridge

| Item | Status | Notes |
|---|---|---|
| 3.1 Extraction against a working station | NOT STARTED | C3 is discharged: station's Stages 2, 3 and 3b merged in voxgig/station#9 (`f7656aa`; review follow-ups in #10, `2036cd6`). What P3 extracts now exists on station `main`: `feature.ts` carries the constraint-and-band resolver written to plugin's §7 semantics, deliberately so this extraction is a move rather than a rewrite. The extraction itself has not run — that is this item. |
| 3.2 The `FeatureHost` bridge | DONE (ts) | `FeatureHost.ts` runs an unmodified sdkgen feature class as a plugin: hook methods become hook bindings, and an assignment to `ctx.utility.fetcher` becomes a `request` chain binding instead of an irreversible overwrite. That last is the whole point — the bridge DEACTIVATES a feature, which sdkgen alone cannot, because it assigns the slot and has nowhere to put the old value back. Six mutations, six caught. Not yet exercised against the generated test SDK (no checkout here), which is the half 3.1 carries. Found the §17.2 hook-count discrepancy — handover.md §11. **Codex review found eight things, seven of them real** (handover.md §14): the portability-budget exemption was unstated, `init`'s §17.2 split into define AND activate was not implemented, `__replace__` seams were not given the provider points §17.2 names, the synthetic ctx replaced the SDK's real `client` and `utility`, a repeated hook name bound twice, a mismatched feature name was accepted silently, and the live status file was left stale. Seven mutations, seven caught. The eighth — a shared `next` slot across concurrently in-flight async wraps — is real and is stated as a bounded limit rather than fixed, because fixing it needs either a modified feature or async-context storage the budget forbids. |
| 3.3 P3b — capabilities (§11) | DONE | Brought forward while 3.1 waits on C3, since nothing blocks it. §11.1 ranking and §11.2 versions landed in P2; §11.4's `resolve()` already carried all four `Why` kinds. This item closed §11.3: the four-cell cardinality/policy matrix read PER REQUIREMENT, the consumers-first cascade, `plugin_dependency_cycle` over restart-causing edges, and `dependency: 'hold'` with its coordinated-teardown suspension. New `Depend.ts`; corpus `depend` grew 12 → 32 across four new groups. Nine mutations, nine caught. |

## Phase 4 — go and python

Go first, because static-only + typed extension points + explicit
errors find every TypeScript-shaped assumption in the model (§18, P4).
It did: see 4.1's note and [`handover.md`](handover.md) §13.

| Item | Status | Notes |
|---|---|---|
| 4.1 `go/` | DONE | 3733 lines of library across 15 files plus a 1235-line driver and runner; all 19 corpus sections green (469 entries). **It changed the canonical four times, which is what P4 is for** — and no design section, because all four were the canonical failing to implement the design. (a) §11.1's `match` is a partial match that recurses; the canonical compared `attrs[k] !== req.match[k]`, which for any compound value is JavaScript reference identity, so `match: {limits:{max:5}}` matched *nothing*. (b) §8.3's reverse unwind was normative and unpinned — an acquired handle is an idempotent decrement, so a port unwinding forwards passed every entry. (c) `inst.release` incremented the open count and never decremented it, so `close()` on a plugin using it could never reach `open: 0`. (d) `unload` on a live instance whose `deactivate` raised let the raise straight out: instance still `live`, scope never unwound, bindings never removed — §5.2 says `failed` and a full unwind. Corpus grew 446 → 469: new `capability/nested` and `lifecycle/faildown` groups, `graph/blocked#match-nested`, four `resource/scope` entries. Eleven mutations, eleven caught. |
| 4.2 `python/` | DONE | 2401 lines of library plus a 723-line driver and runner; all 19 corpus sections green. Closest port to the canonical — it raises rather than returning, so the interesting differences are where JavaScript's coercion rules and Python's disagree. **Two more corpus gaps, both of the loose-equality class the corpus exists to catch:** (a) `match` compares by JSON TYPE as well as value, and half the ports are written in languages whose default `==` says `true == 1` — four new `capability/match` entries; (b) §6.3's provider tie at equal bands breaks by REF SORT, not declaration order, and nothing pinned it — two new `point/provider` entries with the higher ref declared first, so a port using declaration order fails. Eleven mutations, eleven caught (after fixing the harness: a stale `__pycache__` makes a mutation run test nothing, so the cache is cleared around every run). |

## Review rounds

| Item | Status | Notes |
|---|---|---|
| R1 The bridge round (8 findings) | DONE | Seven fixed, one stated as a bounded limit. The one that mattered was an **unstated exemption** in the portability budget — see [`handover.md`](handover.md) §14. |
| R2 The ports round (24 findings) | DONE | **Eight were canonical defects with explicit design backing**, fixed and propagated to all five ports: `apply` never unloaded what §9.6 says is gone and ran one interleaved loop rather than its four phases; `deactivate` fell through on `failed`; the cascade discarded failures; §12's `plugin_*_failed` codes wrapped nothing; `acquire`/`release` were admitted outside `activate` (a permanent leak, since a `define`-registered scope entry is never unwound); a failing release did nothing §8.3 promises; and reservation left the host unable to declare its own reserved refs. Plus one corpus row (`stray`) that had been asserting nothing in every port. Corpus 476 → 498; three probe options added, because five of the eight were unreachable from the catalog as it stood. Thirty-two mutations, thirty-two caught. [`handover.md`](handover.md) §16. |
| R2b The port-local half (8 findings) | DONE | Five landed as ordinary corpus work — a bounded version component (2^31-1, the smallest every target holds exactly), an empty `options` map that must CLEAR rather than be ignored, `NaN`/`Infinity` refused by python's `json.loads`, sorted pin keys, and a `seq` tie-break for a shared `pos`. **Three could not**: two Go rules the corpus has no word for (numbers across Go's twelve spellings; transitions across goroutines) now live in `go/test/golocal_test.go` with the rule that keeps that honest, and the bridge's `featureof` read a `failed` instance's feature through `exports`, which §11 hides — so `close` was skipped in exactly the case that needs it. Corpus 498 → 527. Fourteen mutations, fourteen caught; two survivors were a finding about what the corpus can see, not a gap. [`handover.md`](handover.md) §17. |
| R2c Two the same round found were not port-local | DONE | **`bail` needed a rule JavaScript had made for it.** §6.1 said "stops at the first binding that returns a value" and left null unsaid; the canonical and javascript stopped on `null` while go, python and ruby declined on it — three of five had silently implemented the other reading. §18's budget settles it (JavaScript can tell `null` from `undefined`; almost nothing else in the target set can), so **null declines** is now stated, with `point/bail#null-declines` and a `false`-is-a-value companion. **And the `slow` probe asserted nothing in any port**: DOCS.md said it yields to prove eager settling, no port implemented it, and no entry had ever loaded it. Implemented literally it cannot work — a sync host drops the promise, and python runs no coroutine at all — so DOCS.md now says what `slow` is, `lifecycle/slow` loads it, and whether a host should ever await is recorded as open. [`handover.md`](handover.md) §17. |
| R2d Two rules the design stated and nothing implemented | DONE | **`plugin_bind_scope` had been in §12's table since before anything raised it** — §8.1 splits binding declaration (`define`) from insertion (a successful activate), and the guard was the half nobody wrote, in all five ports: a binding added from `activate` went live without being part of the loaded definition and every cycle appended another copy. **And `active: false` barred nothing past the apply that set it** — §9.6 says `activate` and `ready` on it fail, but `wantlive` was a local in `apply`, so a later direct `ready` brought the instance live and §17.1's config switch could be turned back on by anything. The bar is now on the instance, reasserted every apply in both directions; `plugin_inactive` is new in §12 because the design settled the behaviour and left the code unnamed. `declare/free#barred`'s comment had described the whole rule while the entry checked half — the third green row this round that turned out to be describing rather than checking. Corpus 516 → 527. Sixteen mutations, sixteen caught. [`handover.md`](handover.md) §17. |
| R2e `hold` was asking the cascade's question | DONE | §11.3's strict policy read its holders from `consumersof` — the set the CASCADE walks, which is the edges that RESTART. `hold`'s word is `required`, which is cardinality. The sets differ in **both** directions: a mandatory-**dynamic** consumer was excluded, so the strictest policy let a provider go that a live consumer could not do without; an **optional**-static one was included, so `hold` refused a deactivation on behalf of an instance that had said in writing it does not need the thing. `holdersof` is now its own function in all five ports, with §11.3 saying which set is which. Also found: **go's test cache hid a corpus change** — `spec/plugin.json` is outside the module so it is not in the cache key, and `go test` replayed stale results as `ok (cached)`; `make test` passes `-count=1` now. Corpus 522 → 527. [`handover.md`](handover.md) §17. |
| R2f Reluctance was a re-computation | DONE | §11.4 takes "always-reluctant: a satisfied requirement is not re-bound while it stays satisfied", and every port implemented it as `providersof(req)[0]`, re-ranked on every question — which is **greedy** wearing reluctance's name. A better-ranked provider arriving later silently became "the bound one", so deactivating the provider the consumer was actually activated against restarted nothing. The selection is now made once at activate, recorded per requirement, and dropped on leaving `live`; `chosen` is the only place a provider is picked, and questions asked ABOUT an instance cannot create a binding. **The statuses are identical under both readings**, so `depend/select#reluctant` asserts on the LOG; two more pin it through `hold`. Corpus 524 → 527. Fifteen mutations, fifteen caught. [`handover.md`](handover.md) §17. |

## Phases 5 and 6 — tiers 3 and 4

| Item | Status | Notes |
|---|---|---|
| 5.1 Fourteen tier-3 ports | IN PROGRESS (2/14) | **ruby** landed: 2420 lines, all 19 sections green, and it found **three more corpus gaps and one live bug in a shipped port** (handover.md §15). (a) Ruby's `^`/`$` are LINE anchors, so writing `\A`/`\z` deliberately raised the question — and the PYTHON port turned out to have the same class of hole, because Python's `$` also matches before a trailing newline: `check_name("abc\n")` returned True. Four new `#trailing-newline` entries; python fixed in `ref.py` and `version.py`. (b) `match` compares `1` and `"1"` as different, which php, perl and lua all get wrong — two new entries. (c) `Array#sort` is not stable, so every sort goes through a decorate-with-index helper. Fourteen mutations; two were NON-mutations (guards ruby makes unreachable) and the dead guard was deleted rather than kept as false protection. **javascript** landed: the canonical with the types stripped, all 19 sections green, twelve mutations twelve caught. It found nothing, which is the expected and correct result for the one port that shares a language and every coercion rule with the thing it ports — recorded in its AGENTS.md as the reason a corpus failure THERE is a transcription error rather than a model question. **Only six of P5's fourteen have a toolchain in this environment** (javascript, ruby, php, java, rust, perl); lua, csharp, swift, kotlin, scala, clojure, dart and elixir are absent, and porting a language nobody can execute is the thing the corpus exists to prevent. |
| 5.2 Does station take the library as a dependency? | DECISION NEEDED | Deferred here **by design**, and non-blocking for station's native rollout. Decides only whether station's ports later *replace* their native implementation, and the +800-lines-per-port trade. |
| 5.3 Does station hold Stage 5 after ts/js until P4? | SETTLED | **Moot: P4 merged, so the hold expired rather than being decided.** The question was whether station should port fourteen languages before P4 settled the canonical, making later model changes expensive in the other repo. P4 completed 2026-08-23, so station's remaining Stage 5 work carries no divergence risk from this repo and needs no decision here. |
| 6.1 Six tier-4 ports | NOT STARTED | |
| 6.2 Does sdkgen adopt plugin? (§17.2) | DECISION NEEDED | Open, uncommitted, and carries a propagation cost across 23 template trees. Gates nested hosts *natively*, deletion of `transport`, and the seventeen-model change. |
