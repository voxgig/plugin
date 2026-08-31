# AGENTS.md — the lua port

Read [`../AGENTS.md`](../AGENTS.md) first. The prime directives there are
not negotiable here: **TypeScript is canonical**, **the corpus is the
contract**, **change canonical first then propagate**, and **never weaken
the corpus to make this port pass**.

## The rule that matters most here

**A disagreement with the corpus is this port's bug — until you have
established it is the canonical's.** Both happen;
[`../doc/plan/handover.md`](../doc/plan/handover.md) §13 has the running
list.

## Lua-specific traps

**Every table this port builds is TAGGED.** `types.map` and `types.list`
set a metatable, and `ismap`/`islist` read it. A bare `{}` is neither, and
a value that reaches a comparison untagged will silently take the wrong
branch. If you build a table that a corpus value could compare against,
build it through `T.map` or `T.list`.

**`types.NULL` is a present null; `nil` is absence.** A lua table cannot
store a nil, so this is not a stylistic choice. Use `T.has` for presence,
`T.getv` when you want NULL flattened to nil, and remember that a probe
returning NULL means "the plugin returned JSON null".

**`a and b or c` IS NOT A TERNARY.** When `b` can be `false` the expression
yields `c`. Ten entries failed on exactly this in the corpus runner. Write
the `if`.

**`table.sort` is not stable, and `pairs` has no order.** Every sort goes
through `T.stable_sort`, and every walk of a map goes through `T.keys`
(sorted) or `Host:refs()` (sorted). This is not tidiness: without it a
teardown order changes between runs of the same process.

**`math.type` distinguishes integer from float; `tonumber` coerces.** §7's
band is an integer a document wrote as one, so the test is
`'integer' == math.type(v)`, never `tonumber(v)`.

What lua gives free: `true == 1` and `1 == '1'` are both false (no
coercion in `==`), so the type-strict `match` rule needs no guard — unlike
php and perl. And a lua pattern's `$` anchors at the end of the SUBJECT,
so `^...$` cannot admit a trailing newline.

## What the corpus cannot currently distinguish

Five mutations survive:

- **`islist` blinded to the tag** (an empty map reading as a list). This
  is the empty-map-versus-empty-list distinction php cannot draw at all,
  and its survival here is the evidence that nothing in the corpus turns
  on it. If an entry ever does, php gets a note and this port gets a
  guard that bites.
- Deep-merging two LISTS: a non-mutation, because `mergeone` falls
  straight back to replace for anything that is not two maps.
- `order.band` accepting a numeric string, `providersof` without `canon`,
  and `config_pick` reading an authored null as absence — the same three
  php, perl, rust and java found independently.

None is a licence to relax the code.

## Local shape

- One module per §-area under `src/plugin/`; `src/plugin.lua` forwards so
  the canonical surface is visible in one place.
- `Host` and `Inst` are metatable classes; an `entry` is a plain internal
  table (never a corpus value, so never tagged).
- `make build` is `luac -p` over every file. Not a no-op: a syntax error in
  a file no test happens to require would otherwise ship.

## Adding a corpus section

Dispatch it explicitly in `test/run.lua`. The runner fails on a *group*
with no subject, and its coverage block fails if a whole SECTION exists in
the corpus and nothing runs it. A section or group silently not run is
worse than a failing one.
