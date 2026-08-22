# The cross-repo contract register

**Four obligations, and they are the whole cross-repo contract.**
Everything else in either repo's plan is internal. This file exists for
one reason, stated in station's
[station-and-plugin-plan.md](https://github.com/voxgig/station/blob/main/docs/design/station-and-plugin-plan.md)
§8: so that C1 through C4 have somewhere to be **visibly outstanding**,
which is the only property that makes a cross-repo obligation different
from a good intention.

**A row changes in the same commit that changes its state.** `DONE`
means merged, in whichever repo owes it — never "written", never "on a
branch". A row citing another repo is updated when the change merges
there, naming the PR.

States: `NOT STARTED`, `IN PROGRESS` (a PR is open), `DONE` (merged),
`BLOCKED` (waiting on work outside this item, named in the note).


## The register

| # | owed by | to | what | due | state | discharged by |
|---|---|---|---|---|---|---|
| **C1** | plugin | station | `ref` and `config` corpus sections, as pure data | **before station Stage 2** — earlier than P1's exit | IN PROGRESS | `ref` written (93 entries, pure); `config` outstanding |
| **C2** | plugin | station | `lifecycle` and `order` corpus sections **plus** the draft language-neutral driver contract in `DOCS.md` (§15.2 — probes, command vocabulary, canonical observable) | before P1's exit | NOT STARTED | — |
| **C3** | station | plugin | a working Stages 2–**3b** implementation to extract from, and its own suites as the bar | before plugin P3 | NOT STARTED | — |
| **C4a** | station | plugin | conformance on the pure sections: station runs C1's `ref` and `config` against its own implementation and reports divergence as a plugin issue rather than absorbing it | **continuous** from Stage 2 | NOT STARTED | — |
| **C4b** | station | plugin | the same for C2's `lifecycle` and `order` | **continuous** from Stage 3b | NOT STARTED | — |


## What each row is actually for

**C1 is the tightest, and it is the one that goes wrong quietly.**
Station's Stage 1 lands the ref grammar and Stage 2 lands the identity
change. If `ref` arrives after Stage 2, station has already written ref
parsing and the corpus becomes a **retrofit audit rather than a
contract** — it will be read to confirm what was built instead of to
constrain it. Both sections are pure data (§15.3), so the files *are*
the deliverable: this is cheap for plugin, and only cheap if it is
early. That is why C1 is owed before P1's own exit rather than at it.

**C2 cannot ship as corpus files alone.** `lifecycle` and `order` are
driver sections (§15.3), so a port cannot run them without the command
vocabulary they are written against. Adding either without the
`DOCS.md` contract in the same change produces a suite no port but the
canonical can implement.

**C3 is what stops P3 being a thought experiment.** Plugin's extraction
bar is station's own integration test — twenty-plus declared instances
with none constructed at `open()`, two instances of one api with
distinct placeholders, and a fleet-wide feature default reaching an
instance that never mentions it. The last of those is Stage **3b**
work, which is why P3 gates on 3b and not on Stage 3.

**C4 is the one nothing forces.** It is split because its two halves
become runnable at different moments, but the real point is that
**nothing fails when a team stops running another repo's corpus.** The
mitigation is not diligence: it is making plugin's corpus part of
station's own CI from Stage 2, so drift is red rather than unnoticed.
Until that wiring exists, C4 is an intention with a row.


## Standing note

The build-natively decision — station implements plugin's semantics in
its own ports rather than depending on the library — is what makes
these four the entire contract. It also makes them the only thing
preventing the drift that decision buys. A `DONE` on C1 and C2 with
C4 still `NOT STARTED` is the shape of two repos agreeing on paper and
diverging in code.
