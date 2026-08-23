# Status — where the next session starts

Live snapshot, **2026-08-23**. The register in
[`progress.md`](progress.md) is the per-item authority,
[`contracts.md`](contracts.md) tracks what is owed across repos, and
[`handover.md`](handover.md) is the durable record. This file says what
is in flight *right now*, what is blocked on a human, and what to pick
up first.

**Update it at the end of a session, or delete it once it goes stale —
a wrong status file is worse than none.**


## In flight

**Both PRs are merged.** plugin `main` is `153c878` (#15: the sdkgen
bridge, **P4 complete**, and **P5's first two**); station `main` is
`f7656aa` (#9: Stages 2, 3, 3b and the port sweep, which **discharges
C3**). C1 and C2 were discharged by voxgig/plugin#7.

Five implementations pass all **19 corpus sections, 535 entries** —
typescript (canonical), go, python, javascript, ruby.

**Two review rounds against the ports produced twenty-two categorised
findings, and the split is the count that matters:** eight were
canonical defects with explicit design backing, eight more were
port-local, and a further six turned out to be neither — rules the design states that no
implementation had, in every port at once (`bail`'s null, the `slow`
probe, `plugin_bind_scope`, the `active` bar, `hold`'s holder set, and
always-reluctant rebinding). `handover.md` §16–§17 has each.

**Station carries sixteen open findings from #9**, six of them P1 —
including a verified allowlist bypass for imperatively tagged instances
(`connect(SDK, {as: 'test'})` gets no `profile.api` fallback, so the
policy's `hosts` list does not reach it) and two secret-name defects
that can route the wrong credential. Merged on the owner's call with the
fixes scheduled as a follow-up; they are the next station work, ahead of
Stages 4 and 5.


## Pick this up first

**The rest of P5.** javascript and ruby are in; **only four of the
remaining twelve have a toolchain in the usual environment** — php,
java, rust and perl. lua, csharp, swift, kotlin, scala, clojure, dart
and elixir do not, and porting a language nobody can execute ships an
implementation nobody has run. Say which are gated rather than shipping
unverifiable work — the same call station's Stage 5 made.

**Read [`handover.md`](handover.md) §13 first if you are porting.** All
six defects the pair found were of two kinds — a rule the design states
that no entry can distinguish, and a code path no entry enters. Expect
more, and fix them in the canonical: §18's P4 exit says so in those
words and does not stop applying at P5.

Copy `go/`'s or `python/`'s layout: library and driver split, all four
Makefile targets real, and a coverage test asserting every corpus
section is dispatched.

**P3.1, as soon as station#9 merges.** Its acceptance bar is station's own
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

**Three decisions**, none the implementer's to make, and each with a row
in [`progress.md`](progress.md) — this table is the summary, that file is
the authority. None blocks P1.

| Decision | Register row | Gates |
|---|---|---|
| **Does station hold Stage 5 after ts/js until P4?** | 5.3 | station's fourteen remaining ports. P4 is scheduled early to make model changes cheap; porting first makes them expensive again, in the other repo. The alternative is to accept divergence and budget a migration pass — said out loud rather than discovered. |
| **Does station take the library as a dependency?** | 5.2 | Only whether station's ports later *replace* their native implementation, and the +800-lines-per-port trade. Deferred to P5 by design and **non-blocking** for the native rollout. |
| **Does sdkgen adopt plugin?** (§17.2) | 6.2 | Nested hosts natively, `transport`'s deletion, the seventeen-model change. Uncommitted. If it never adopts, station is a sixteen-language library carrying a generic abstraction for a single consumer — the risk that invalidates the plan rather than delaying it. |


## Two rules the design states that no phase owns

Both surfaced by review of the go port, both confirmed against the
design, and **neither is a port defect** — the canonical does not
implement them either. They are here rather than in `progress.md`
because `adoption.md`'s P0–P6 never scheduled either one, which is the
actual gap.

### Option validation against the definition's shape

§16 says "this library validates an instance's `options` against **the
definition's** option shape", and §12 has carried `plugin_option_invalid`
— "options failed the definition's shape" — since the error table was
written. Nothing validates anything. A definition with a numeric option
default accepts a string from any of the ten configuration layers.

It is not a small fix, and the two reasons are not about effort:

- **It needs the repo's first runtime dependency, in five ports.**
  `AGENTS.md` §1 permits exactly one — `voxgig/struct` — and no port has
  taken it. That is a decision about every port's build.
- **There is nothing yet to validate against.** The `shape` today
  carries `$MERGE` directives and the level-1 defaults. It has **no
  vocabulary for types**. So the work starts by deciding what a shape
  says about types — adopting struct's `validate` vocabulary into the
  model and pinning it in the corpus across every port — and only then
  calls it.

Scheduling it means adding a phase or widening one. Suggested: after P5,
before the P6 tier, so it lands once and every subsequent port inherits
it rather than fourteen ports needing a second pass.

### The `dynamic` capability-change notification

§11.1 says a `dynamic` consumer "is re-pointed in place **and
notified**", and §11.3's policy matrix repeats it in both the mandatory
and the optional row. **The re-pointing is implemented** (§11.4's
remembered selection, and `reconcile` re-points a stale one). The
notification is not — and the design never names the callback, its
signature, or its failure semantics, so there is nothing to implement.

What has to be decided, and is deliberately not being guessed:

- **Name and shape.** The precedent is §9.4's `reconfigure(instance,
  options, previous)` — the existing "something changed under you, cope"
  callback — which suggests `rebind(instance, name, ref, previous)`.
- **What a definition without it gets.** `reconfigure`'s answer is
  deactivate-and-reactivate, which is exactly what `dynamic` promises
  will *not* happen. So this needs a different answer, and "nothing" is
  defensible.
- **Whether it can raise.** Every other callback lands the instance in
  `failed` via `plugin_<phase>_failed`. A notification that can fail a
  live instance is a much larger claim than a notification.

That is a new lifecycle callback across 23 ports. Until it is decided,
a mandatory-dynamic consumer keeps a correct selection and no signal —
which is the state the design describes minus its last two words.


## Recently settled

- **`active` vs `live`** — settled before P1 wrote a fixture, which was
  the point of dating it. voxgig/plugin#6. See
  [`handover.md`](handover.md) §1.
