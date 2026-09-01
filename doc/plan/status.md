# Status — where the next session starts

Live snapshot, **2026-09-01**. The register in
[`progress.md`](progress.md) is the per-item authority,
[`contracts.md`](contracts.md) tracks what is owed across repos, and
[`handover.md`](handover.md) is the durable record. This file says what
is in flight *right now*, what is blocked on a human, and what to pick
up first.

**Update it at the end of a session, or delete it once it goes stale —
a wrong status file is worse than none.**


## In flight

**P5's fourteen tier-3 ports are complete.** Twelve landed in this
session — `php`, `perl`, `rust`, `java`, `lua`, `csharp`, `elixir`,
`clojure`, `dart`, `kotlin`, `swift`, `scala` — joining `javascript` and
`ruby`. **Seventeen implementations now pass all 572 corpus entries**, and
`make check` runs every one of them.

They found **nothing further wrong with the canonical**, which is the
result a settled contract should produce. What they found instead is
**three places two implementations could disagree and the corpus would
not notice** — the same three in every language, mutation-tested
independently. **All three are now closed:**

1. ~~Shape validation at catalog REGISTRATION is pinned by nothing.~~
   **CLOSED** — `declare/shape` (7 entries) and `declare/register` (3).
   Nothing carried a `shape` because the driver's `define` command was a
   **no-op in all seventeen ports**, so `catalog.add`'s check was
   unreachable by construction; `define` is now implemented everywhere,
   all three of its documented keys live. Closing it uncovered a
   canonical bug — **`apply` dropped a first-time instance's options
   entirely** — now fixed in the eight ports that had it and pinned by
   three new `apply/idempotent` entries.
2. ~~`providersof` comparing refs uncanonicalized.~~ **CLOSED** —
   `depend/byref` (5 entries). Wider than its name: the whole
   ref-satisfaction branch was dead code (`if (false)` passed all 552
   entries) and the rule lived only in a comment in the canonical's
   source. **Design §11.1 now states it.**
3. ~~Whether `nest` counts the inner host as an open resource.~~
   **CLOSED** — `nest/open` (4 entries). It counts nothing: the scope
   entry is a teardown, not an acquisition, and the inner host keeps its
   own counter.

Gaps 2 and 3 needed **no port change** — all seventeen already agreed,
which is what a coverage gap rather than a divergence looks like.

handover.md §18 has all of it, plus a fourth that is a SCALE gap rather
than a coverage one (dart's unstable sort above 32 elements), the two
port-side bugs the corpus DID catch, and two non-mutations recorded so
nobody re-derives them.

**All three are done, so P6's tier-4 ports are next.** See §18 for what
the sizing got wrong in both directions — and for why a gap's *name* can
be narrower than the gap, which is what gap 2 turned out to be.

Merged since this section last named a tip:

**voxgig/plugin#17** — the register refresh, and the review round on it.

**voxgig/plugin#15** — P3.2 (the sdkgen bridge), **P4 complete** (the go
and python ports) and **P5's first two** (javascript, ruby) — merged as
`153c878`. Five implementations pass all 19 corpus sections.

**voxgig/station#9** — Stages 2, 3 and 3b, 11/11 CI ports green — merged
as `f7656aa`, review follow-ups merged in voxgig/station#10. **C3 is
discharged.**

plugin `main` is **`9ffe3f9`**; station `main` is **`dcfdd0a`**, which is
**95 commits past the `2036cd6` this section used to name** — the npm and
OIDC release work plus voxgig/station#15, #16 and #17 all landed in
between. C1 and C2 were discharged by voxgig/plugin#7; C3 by
voxgig/station#9.

Both tips were re-read from the repositories when this was written.
Neither is carried forward from what this file previously said, which is
how it came to name a station tip 95 commits out of date while asserting
nothing was in flight.


## Pick this up first

**P3.1 — it is runnable now.** C3 merged (voxgig/station#9, `f7656aa`),
so the extraction has a working station to run against. Its acceptance
bar is station's own integration test, and the three stages that bar
needs are implemented and on station `main`: twenty-plus declared
instances with none constructed at `open()` (Stage 3), two instances of
one api with distinct placeholders (Stage 2), and a fleet-wide feature
default reaching an instance that never mentions it (Stage 3b).

What P3 extracts already exists in the shape it needs to be in:
station's `typescript/src/feature.ts` carries the constraint-and-band
resolver **written to plugin's §7 semantics** — constraints beating
bands, vacuous satisfaction of an absent name, ties by declaration
position rather than alphabet, and the innermost pin. That was
deliberate, and it makes P3 a move rather than a rewrite.

**P6's six tier-4 ports** — the corpus gaps are all closed (above): `c` and `cpp` first — gcc/g++ 13.3.0 are
present — and `zig`, `haskell`, `ocaml`, `lean` after their toolchains
are installed and verified. Porting a language nobody can execute ships
an implementation nobody has run; say which are gated rather than
shipping unverifiable work — the same call station's Stage 5 made.

**Read [`handover.md`](handover.md) §13 first if you are porting.** All
six defects the pair found were of two kinds — a rule the design states
that no entry can distinguish, and a code path no entry enters. Expect
more, and fix them in the canonical: §18's P4 exit says so in those
words and does not stop applying at P5.

Copy `go/`'s or `python/`'s layout: library and driver split, all four
Makefile targets real, and a coverage test asserting every corpus
section is dispatched.

**§11 is complete** (P3b): 11.1 ranking and 11.2 versions from P2, 11.3
from voxgig/plugin#13, and 11.4's `resolve()` already carried all four
`Why` kinds. Nothing else in plugin is unblocked before P3.

**Station's remaining tail**, for anyone with capacity: the rest of
Stage 4 (#9 landed the feature-model half) and Stage 5's tail. All
eleven CI ports crossed the `plugin` -> `sdk` rename in #9; what
remains is the declarative front door in the ten non-TypeScript CI
ports (`validateConfig`, `instanceRef` and `feature.ts` are
TypeScript-only for now), plus the **five** toolchain-gated ports —
lua, dart, elixir, csharp, swift — still on the old `plugin` grammar.
The corpus carries both grammars until those five cross; see station
`spec/README.md`.


## Blocked on a human

**Two decisions**, neither the implementer's to make, and each has a row in [`progress.md`](progress.md) — this
table is the summary, that file is the authority. Neither blocks P1.

| Decision | Register row | Gates |
|---|---|---|
| **Does station take the library as a dependency?** | 5.2 | Only whether station's ports later *replace* their native implementation, and the +800-lines-per-port trade. Deferred to P5 by design and **non-blocking** for the native rollout. |
| **Does sdkgen adopt plugin?** (§17.2) | 6.2 | Nested hosts natively, `transport`'s deletion, the seventeen-model change. Uncommitted. If it never adopts, station is a sixteen-language library carrying a generic abstraction for a single consumer — the risk that invalidates the plan rather than delaying it. |


## Recently settled

- **Does station hold Stage 5 until P4?** (register 5.3) — **moot: the
  hold expired rather than being decided.** P4 merged 2026-08-23, so
  station's remaining Stage 5 work carries no divergence risk from this
  repo's canonical and needs no decision here.
- **`active` vs `live`** — settled before P1 wrote a fixture, which was
  the point of dating it. voxgig/plugin#6. See
  [`handover.md`](handover.md) §1.
