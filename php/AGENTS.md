# AGENTS.md — the php port

Read [`../AGENTS.md`](../AGENTS.md) first. The prime directives there are
not negotiable here: **TypeScript is canonical**, **the corpus is the
contract**, **change canonical first then propagate**, and **never weaken
the corpus to make this port pass**.

This file is only what is specific to php.

## The rule that matters most here

**A disagreement with the corpus is this port's bug — until you have
established it is the canonical's.** Both happen;
[`../doc/plan/handover.md`](../doc/plan/handover.md) §13 has the running
list. But the default is that a port got a coercion or ordering rule
wrong, and the burden is on the change to show otherwise.

When it *is* the canonical: fix `typescript/`, add corpus entries that pin
the fixed reading, then propagate. In one change set. Never a local
workaround.

## PHP-specific traps

**Arrays are values.** `$copy = $host->inst[$ref]` copies the record, and
writing to the copy changes nothing. Every mutable record is an object:
`Entry` for an instance, `Host`, `Inst`, and `Bag` for an instance's
`state`. If you add state, add it to the object — a new array property on
a plain array record is a bug that passes its own unit test.

**`Bag::offsetGet` returns BY REFERENCE**, which is the only way
`$i->state['unwound'][] = $k` works: an ordinary `ArrayAccess` raises
"indirect modification of overloaded element" and discards the write. The
cost is that a bare read of an absent key CREATES it as null, so read a
possibly-absent key with `??`, which consults `offsetExists` first.

**`[]` is falsy.** The mirror of ruby's trap. `if ($spec['options'])`
skips an empty options map, and `declare/clear#empty-options` says that
map must CLEAR the instance's options. Transcribed truthiness tests go
through `Util::truthy`, which is "present, and not false" — ruby's
semantics, spelled out.

**`sort()` compares numeric-looking strings as NUMBERS.** `['10','9']`
sorts to `['9','10']`. Every sort of refs, keys or names goes through
`Util::sortstrings`/`Util::sortedkeys` and their `SORT_STRING`. No corpus
entry has a numeric-looking ref, so this one is latent rather than pinned
— a mutation dropping the flag survives.

**`true == 1` and `1 === 1.0`.** PHP's `==` is too loose in one direction
and its `===` too strict in the other, so JSON equality is
`Capability::samescalar`: `===` everywhere except between two numbers.

**PCRE's `$` matches before a trailing newline.** Every regex uses `\A`
and `\z`, and `ref/name#trailing-newline` catches the alternative
immediately.

**`declare` and `list` are language constructs but legal METHOD names**
(PHP 7+). `$host->declare(...)` and `$host->list()` are the same spelling
every other port uses, and they parse.

## What php cannot express

**An empty map and an empty list are one value.** `json_decode('{}',
true)` and `json_decode('[]', true)` both give `[]`. This cannot make a
failing entry pass — every non-empty shape still differs — but it does
mean two readings had to be chosen rather than derived, and both say so
where they are written:

- `Util::maplike` — an empty array counts as a map for merging, so `{}`
  merging onto a map leaves it alone (what a javascript spread does).
- `matchvalue` — an empty `match` requirement is "no constraint".

Nothing in the corpus exercises either. If an entry ever does, it belongs
in the corpus first, and this file gets the note about which way php had
to go.

## Local shape

- Namespaced functions in `Voxgig\Plugin`, snake_case, mirroring the
  canonical names; classes for the things that hold state.
- String keys throughout: the corpus arrives as parsed JSON.
- `make build` is `php -l` over every file. Not a no-op: a syntax error in
  a file no test happens to require would otherwise ship.
- `make test` runs with `error_reporting=E_ALL`, and `run.php` promotes
  every notice to an exception. PHP's defaults would let an undefined
  index warn and continue with null, which surfaces as a corpus failure
  three functions away from the mistake.

## Adding a corpus section

Dispatch it explicitly in `test/run.php`. The runner fails on a *group*
with no subject, and its coverage block fails if a whole SECTION exists in
the corpus and nothing runs it. A section or group silently not run is
worse than a failing one.
