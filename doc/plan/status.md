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

**Two PRs open.**

- **voxgig/station#8** — Stage 1, the config grammar as data. CI green,
  11/11 ports. Awaiting review.
- **voxgig/plugin** — P3b, this change.

plugin `main` was `ebb54ee`; station `main` is `088f204`. **C1 and C2
are both discharged** — voxgig/plugin#7, 234 entries across four
sections plus the driver contract.


## Pick this up first

**Station's track, still.** P3 remains gated on **C3** — station's
Stages 2–3b — because P3's acceptance bar *is* station's own
integration test: twenty-plus declared instances with none constructed
at `open()`, two instances of one api with distinct placeholders, and a
fleet-wide feature default reaching an instance that never mentions it.

Stage 1 has now landed, so the next station work is **Stage 2**
(instances — the identity change), which consumes C1 and is delivered.
Then Stage 3 and 3b, at which point C3 is discharged and plugin's P3
unblocks.

**P3b is done** and no longer the answer to "what can plugin do while it
waits". §11 is complete: 11.1 ranking and 11.2 versions from P2, 11.3
from this change, and 11.4's `resolve()` already carried all four `Why`
kinds. What is left in plugin before P4 is 3.1 and 3.2, and both are
blocked.

**Station also owes itself a port sweep.** Stage 1 crossed ts, js and py
over the `plugin` → `sdk` rename; thirteen ports have not crossed, and
the corpus carries both grammars until they do (station
`spec/README.md`). That is mechanical and unblocked, and it is the
cheapest thing available to anyone with capacity.


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
