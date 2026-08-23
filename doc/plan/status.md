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

**Nothing open.** plugin `main` is `e8ca92c`; station `main` is
`088f204`. **C1 and C2 are both discharged** — voxgig/plugin#7, 234
entries across four sections plus the driver contract.


## Pick this up first

**P3 — extraction against a working station, and the `FeatureHost`
bridge.** P2 is complete: nineteen corpus sections, 400+ entries, the
canonical passing all of them, and `DOCS.md` written.

**P3 IS BLOCKED, AND NOT ON THIS REPO.** It is gated on **C3** —
station's Stages 2–3b — because P3's acceptance bar *is* station's own
integration test: twenty-plus declared instances with none constructed
at `open()`, two instances of one api with distinct placeholders, and a
fleet-wide feature default reaching an instance that never mentions it.
Station is still at Stage 0.

So the next work is **station's track**, not plugin's. Stage 1 (the
grammar) is independent of plugin entirely and can start immediately;
Stage 2 consumes C1, which is delivered.

**P3b (capabilities, §11)** could be brought forward — it is
deliberately scheduled after the station proof because station uses none
of §11, but nothing blocks it. It is the largest single tranche in the
library, so doing it while P3 waits is a real option rather than
make-work.


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
