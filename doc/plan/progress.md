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
| 1.4 `lifecycle` and `order` corpus sections (**C2**) | DONE | 31 + 22 entries. Driver sections, landed in the same change as the contract that makes them runnable. |
| 1.5 `typescript/` — the canonical | DONE | All 11 canonical names. All four corpus sections green: `ref` 97, `config` 86, `lifecycle` 32, `order` 22. Written to the portability budget — no reflection, no `Proxy`, no decorators, eager reconciliation. |
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
| 3.1 Extraction against a working station | READY WHEN C3 MERGES | station's Stages 2, 3 and 3b are implemented and green in voxgig/station#9. What P3 extracts now exists: `feature.ts` carries the constraint-and-band resolver written to plugin's §7 semantics, deliberately so this extraction is a move rather than a rewrite. |
| 3.2 The `FeatureHost` bridge | BLOCKED | On 3.1. |
| 3.3 P3b — capabilities (§11) | DONE | Brought forward while 3.1 waits on C3, since nothing blocks it. §11.1 ranking and §11.2 versions landed in P2; §11.4's `resolve()` already carried all four `Why` kinds. This item closed §11.3: the four-cell cardinality/policy matrix read PER REQUIREMENT, the consumers-first cascade, `plugin_dependency_cycle` over restart-causing edges, and `dependency: 'hold'` with its coordinated-teardown suspension. New `Depend.ts`; corpus `depend` grew 12 → 32 across four new groups. Nine mutations, nine caught. |

## Phase 4 — go and python

| Item | Status | Notes |
|---|---|---|
| 4.1 `go/` | NOT STARTED | Expected to change the canonical. That is the point of running it before P5. |
| 4.2 `python/` | NOT STARTED | Pair with station's Stage 5 `py`/`go` tranche. |

## Phases 5 and 6 — tiers 3 and 4

| Item | Status | Notes |
|---|---|---|
| 5.1 Fourteen tier-3 ports | NOT STARTED | A model change costs ~15 ports from here. |
| 5.2 Does station take the library as a dependency? | DECISION NEEDED | Deferred here **by design**, and non-blocking for station's native rollout. Decides only whether station's ports later *replace* their native implementation, and the +800-lines-per-port trade. |
| 5.3 Does station hold Stage 5 after ts/js until P4? | DECISION NEEDED | **station's call, not this repo's** — recorded here because P4 is what it waits on. P4 is scheduled early to make model changes cheap; station porting fourteen languages first makes them expensive again, in the other repo. The alternative is to accept divergence and budget a migration pass, said out loud rather than discovered. |
| 6.1 Six tier-4 ports | NOT STARTED | |
| 6.2 Does sdkgen adopt plugin? (§17.2) | DECISION NEEDED | Open, uncommitted, and carries a propagation cost across 23 template trees. Gates nested hosts *natively*, deletion of `transport`, and the seventeen-model change. |
