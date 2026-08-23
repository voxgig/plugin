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

**Nothing open, in either repo.** plugin `main` is `56f48e1` (every PR
through #6 merged); station `main` is `088f204`, which carries station's
half of the `active`/`live` decision and pins `P§n` to plugin's
`56f48e1`.

The only work in flight is P1's first corpus sections.


## Pick this up first

**P1 item 1.5 — `typescript/`, the canonical.** Everything owed
outward is now written: C1 (`ref` + `config`) and C2 (`lifecycle` +
`order` + the driver contract), 204 entries across four sections. The
canonical is the phase's third deliverable by design, and it is next.

Write it to the portability budget (AGENTS.md §5): no reflection-backed
APIs, no `Proxy`, no decorators, no meta-level interception, and eager
lifecycle reconciliation. Every one of those is cheaper to obey now
than to remove at P4.

**1.6 `tools/check_probes.py` is also unblocked** — the probe catalog
now exists to check against — and is the cheaper of the two.

Both halves of C1 and all of C2 are written and **awaiting merge**;
neither row is `DONE` until it lands.

The reason for that ordering is not politeness. Station's Stage 1 lands
the ref grammar and Stage 2 lands the identity re-key; if `ref` arrives
after Stage 2, station has already written ref parsing and the corpus
becomes a retrofit audit rather than a contract. Both sections are pure
data (§15.3) — the files *are* the deliverable — so this is cheap for
plugin and only cheap if it is early.

Do **not** start `typescript/` (1.5) first because it feels like the
real work. It is the phase's third deliverable by design.


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
