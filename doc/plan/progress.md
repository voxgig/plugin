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
| 1.1 `ref` corpus section (**C1**) | DONE | 93 entries, 9 groups, no host. **Covers the pure surface only** — grammar, parse, format, canonicalization, both predicates, the 1024 bound. It does **not** cover auto-tag or `pos`/`seq`, which §15.3 also lists under `ref`; that gap is item **1.7**, not a footnote here. |
| 1.2 `config` corpus section (**C1**) | DONE | 84 entries, 13 groups, no host. All four pinned items, the partial-array rule, host key renaming, and the `optionlayers` split (see [`handover.md`](handover.md) §9). |
| 1.3 Draft driver contract in `DOCS.md` (**C2**) | DONE | `DOCS.md` §4: how an entry runs, 17 verbs, the 6-probe catalog, the ordering block, the observable, and what a port must not do. Landed *with* 1.4. |
| 1.4 `lifecycle` and `order` corpus sections (**C2**) | DONE | 31 + 22 entries. Driver sections, landed in the same change as the contract that makes them runnable. |
| 1.5 `typescript/` — the canonical | NOT STARTED | Written to the portability budget (§18, and AGENTS.md "Sharp edges"). |
| 1.6 `tools/check_probes.py` | NOT STARTED | **Unblocked** — 1.3 landed the probe catalog to check against. `make probes` still reports its own absence rather than passing silently. |
| 1.7 Relocate auto-tag and `pos`/`seq`, and correct §15.3 | NOT STARTED | §15.3 marks `ref` pure while assigning it auto-tag and `pos`/`seq`, neither of which the pure surface can reach. `pos` belongs to `config`, auto-tag and `seq` to a driver section (`declare`). **Until this lands, those three identity behaviours are pinned by nothing**, so ports can diverge on them while passing a green `ref`. See [`handover.md`](handover.md) §5. |

## Phase 2 — the canonical completed

| Item | Status | Notes |
|---|---|---|
| 2.1 Dynamic resolution, `apply()`, exports, position verification | NOT STARTED | |
| 2.2 Remaining corpus sections | NOT STARTED | env, resolve, capability, version, graph, declare, nest, state, resource, point, export, depend, apply, error, trace. |
| 2.3 `DOCS.md` completed from P1's draft | NOT STARTED | |

## Phase 3 — proof, and the bridge

| Item | Status | Notes |
|---|---|---|
| 3.1 Extraction against a working station | BLOCKED | On **C3** — station's Stages 2–3b. |
| 3.2 The `FeatureHost` bridge | BLOCKED | On 3.1. |
| 3.3 P3b — capabilities (§11) | NOT STARTED | Deliberately after the station proof; station uses none of §11. |

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
