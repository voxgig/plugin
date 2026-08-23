# The adoption plan

plugin's goal: be the **plugin architecture for the voxgig stack** —
one model of naming, configuration, lifecycle, ordering, binding and
teardown, expressed in every language the stack targets.

[station](https://github.com/voxgig/station) is the first host and the
reason the library exists in a usable form rather than a general one;
[sdkgen](https://github.com/voxgig/sdkgen) is the possible second, and
**is not committed** (§17.2). This document is the plan. The live
per-item state is [`progress.md`](progress.md), which changes in the
same commit as the work it records; the cross-repo obligations are in
[`contracts.md`](contracts.md); what is in flight right now is
[`status.md`](status.md).

The phase definitions are §18 of [the design](../../docs/design/plugin.md).
The sequencing against station's own stages is station's
[station-and-plugin-plan.md](https://github.com/voxgig/station/blob/main/docs/design/station-and-plugin-plan.md).


## Standing decisions

Four, and they frame everything below.

- **Station builds natively; plugin extracts.** Station implements
  plugin's semantics in its own sixteen ports rather than taking the
  library as a dependency. Plugin is then extracted from a working
  implementation instead of being written against a hypothesis. The
  dependency question — whether station's ports later *replace* their
  native implementation with the library — is deliberately deferred to
  **P5**, and is explicitly **non-blocking** for the native rollout.

- **Canonical-first, always.** TypeScript defines behaviour; every
  other language is a port of it. A behaviour change is TypeScript +
  corpus + every port, in one change set. The repo's prime directives
  apply to plan work exactly as to bug fixes.

- **Nothing merges without the corpus.** A behaviour not in
  `spec/plugin.aontu` does not exist (§18.1).

- **The portability budget binds the canonical, not the review.** No
  reflection-backed APIs, no `Proxy`, no decorators, no meta-level
  interception, and eager lifecycle reconciliation. Every one of those
  is cheaper to obey now than to remove at P4. A canonical that reaches
  for a JavaScript convenience is a bill twenty ports pay.


## Phase 0 — the skeleton

Build the machinery that guards the contract, and prove it turns over
before there is anything to compile. A corpus pipeline first exercised
on real data is one whose failures arrive mixed up with the data's.

1. Layout, `Makefile`, `spec/def/plugin-spec.aontu`, `tools/`, CI.
2. `make spec` and `make spec-check` green **on an empty corpus** —
   that is the exit criterion, not a placeholder for one.


## Phase 1 — the tracer bullet

The first phase whose deliverables are owed outward, and they come
first rather than last.

1. **C1** — `ref` and `config` corpus sections. Pure data; owed to
   station before its Stage 2, which is *earlier than this phase's own
   exit*. See [`contracts.md`](contracts.md).
2. **C2** — the draft driver contract in `DOCS.md` (§15.2), then the
   `lifecycle` and `order` corpus sections it makes runnable.
3. `typescript/` — the canonical, written to the portability budget.
4. The four configuration items the reconciliation pinned to P1: the
   `default` map, the ten-level precedence ladder, defaults-after-merge,
   and shape-declared merge depth including `{"deep": N}`.


## Phase 2 — the canonical completed

Dynamic resolution, `apply()`, exports, position verification, and the
remaining corpus sections. `DOCS.md` completed from P1's draft.


## Phase 3 — proof, and the bridge

Extraction against a **working station**, plus the `FeatureHost`
bridge. Gated on station's Stage **3b** rather than Stage 3: the bar
includes a fleet-wide feature default reaching an instance that never
mentions it, and that is 3b's deliverable. Gating on Stage 3 would
start this phase with its own acceptance test unavailable.

**P3b — capabilities.** Deliberately after the station proof, because
station uses none of §11 and it is the largest single tranche in the
library.


## Phase 4 — go and python

**Expected to change the canonical, and scheduled early for exactly
that reason.** Go and Python are where a TypeScript-shaped model
breaks. Fix what they find *in the canonical*, never locally in the
port.

Station's Stage 5 should pair its `py` and `go` ports with this phase —
the same two languages for the same reason, with the corpus between
them as the arbiter. Running them apart means finding each divergence
twice, months apart.


## Phase 5 — tier 3, and Phase 6 — tier 4

Fourteen languages, then six. A model change now costs ~15 ports, which
is what P4 exists to prevent. The dependency decision reopens at P5;
the sdkgen `plugin` feature-package question is P6's.
