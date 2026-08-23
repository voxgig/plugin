# AGENTS.md — the ruby port

Read [`../AGENTS.md`](../AGENTS.md) first. The prime directives there
are not negotiable here: **TypeScript is canonical**, **the corpus is
the contract**, **change canonical first then propagate**, and **never
weaken the corpus to make this port pass**.

This file is only what is specific to ruby.

## The rule that matters most here

**A disagreement with the corpus is this port's bug — until you have
established it is the canonical's.** Both happen;
[`../doc/plan/handover.md`](../doc/plan/handover.md) §13 has the running
list. But the default is that a port got a coercion or ordering rule
wrong, and the burden is on the change to show otherwise.

When it *is* the canonical: fix `typescript/`, add corpus entries that
pin the fixed reading, then propagate. In one change set. Never a local
workaround.

## Ruby-specific traps

**`^` and `$` are LINE anchors.** `/^[a-z]+$/` matches `"abc\ndef"`.
Every regex in this port uses `\A` and `\z`, and the four
`#trailing-newline` corpus entries exist because writing this port is
what surfaced the same class of hole in python (whose `$` also matches
before a trailing newline). If you add a regex, use `\A`/`\z` and add
an entry.

**`Array#sort` and `#sort_by` are not stable.** Use
`VoxgigPlugin::Util.stable_sort_by`. The canonical's comparators fall
through to a `pos` or ref tie-break that JavaScript's stable sort
resolves by position, and an unstable sort here diverges on cases the
corpus can only sometimes name.

**`Hash#[]` collapses absent and nil.** Where the canonical tests
`undefined !== x`, use `key?`. `config_pick` exists for exactly that;
the corpus runner carries a `MISSING` sentinel for the same reason, so
`__UNDEF__` and `__NULL__` stay different assertions.

**Blocks capture the variable, not the value.** `point.compose` gives
each layer its own block-local `fn`/`inner` pair; sharing one would
leave every layer calling the last.

**What ruby gets right for free:** `true == 1` is false, and
`true.is_a?(Integer)` is false — so neither the type-strict `match` rule
nor the `{"deep": true}` rejection needs the explicit guard python does.
An explicit boolean guard was written into `matchvalue` first and then
removed: a mutation deleting it survived the corpus, which is what a
guard that cannot fire looks like. **Do not re-add defensive code the
language already makes unreachable** — it reads as protection and is
dead.

## Local shape

- Plain modules and module functions on `VoxgigPlugin`; two classes,
  `Host` and `Inst`, because they hold state.
- String keys throughout, never symbols: the corpus arrives as parsed
  JSON, and a port that symbolised keys would need to un-symbolise them
  at every boundary.
- `make build` is `ruby -c` over every file. Not a no-op: a syntax error
  in a file no test happens to require would otherwise ship.

## Adding a corpus section

Dispatch it explicitly in `test/run.rb`. The runner fails on a *group*
with no subject, and its coverage block fails if a whole SECTION exists
in the corpus and nothing runs it. A section or group silently not run
is worse than a failing one.
