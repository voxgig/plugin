# Status — where the next session starts

Live snapshot, **2026-08-22**. The register in
[`progress.md`](progress.md) is the per-item authority,
[`contracts.md`](contracts.md) tracks what is owed across repos, and
[`handover.md`](handover.md) is the durable record. This file says what
is in flight *right now*, what is blocked on a human, and what to pick
up first.

**Update it at the end of a session, or delete it once it goes stale —
a wrong status file is worse than none.**


## In flight

**voxgig/station#9** — Stages 2, 3 and 3b, 11/11 CI ports green, awaiting
review. **It discharges C3.**

plugin `main` is `8804f82` (P3b merged); station `main` is `600fdfe`
(Stage 1 merged). C1 and C2 were discharged by voxgig/plugin#7.


## Pick this up first

**P3, as soon as station#9 merges.** Its acceptance bar is station's own
integration test, and the three stages that bar needs are now
implemented: twenty-plus declared instances with none constructed at
`open()` (Stage 3), two instances of one api with distinct placeholders
(Stage 2), and a fleet-wide feature default reaching an instance that
never mentions it (Stage 3b).

What P3 extracts already exists in the shape it needs to be in:
station's `typescript/src/feature.ts` carries the constraint-and-band
resolver **written to plugin's §7 semantics** — constraints beating
bands, vacuous satisfaction of an absent name, ties by declaration
position rather than alphabet, and the innermost pin. That was
deliberate, and it makes P3 a move rather than a rewrite.

**§11 is complete** (P3b): 11.1 ranking and 11.2 versions from P2, 11.3
from voxgig/plugin#13, and 11.4's `resolve()` already carried all four
`Why` kinds. Nothing else in plugin is unblocked before P3.

**Station's remaining tail**, for anyone with capacity: Stage 4 (the
generator side) and Stage 5 (the thirteen ports that have not crossed
the `plugin` -> `sdk` rename — the corpus carries both grammars until
they do, see station `spec/README.md`).


## Blocked on a human

Two decisions, neither the implementer's to make. Both are recorded in
[`progress.md`](progress.md) and neither blocks P1.

**Three**, and each has a row in [`progress.md`](progress.md) — this
table is the summary, that file is the authority. None blocks P1.

| Decision | Register row | Gates |
|---|---|---|
| **Does station hold Stage 5 after ts/js until P4?** | 5.3 | station's fourteen remaining ports. P4 is scheduled early to make model changes cheap; porting first makes them expensive again, in the other repo. The alternative is to accept divergence and budget a migration pass — said out loud rather than discovered. |
| **Does station take the library as a dependency?** | 5.2 | Only whether station's ports later *replace* their native implementation, and the +800-lines-per-port trade. Deferred to P5 by design and **non-blocking** for the native rollout. |
| **Does sdkgen adopt plugin?** (§17.2) | 6.2 | Nested hosts natively, `transport`'s deletion, the seventeen-model change. Uncommitted. If it never adopts, station is a sixteen-language library carrying a generic abstraction for a single consumer — the risk that invalidates the plan rather than delaying it. |


## Recently settled

- **`active` vs `live`** — settled before P1 wrote a fixture, which was
  the point of dating it. voxgig/plugin#6. See
  [`handover.md`](handover.md) §1.
