# voxgig/plugin — lua

The lua port of [voxgig/plugin](../README.md). It is a **port**, not an
independent implementation: behaviour is defined by `typescript/`, and
`spec/plugin.json` — the same corpus every port runs — is the arbiter.

```bash
make build     # syntax-check every file
make test      # the corpus, all 19 sections
make inspect   # interpreter version
make clean
```

Lua 5.4 (it uses `math.type` and integer division of labour between
integers and floats). **No luarocks**: §16 permits one runtime dependency
and lua has no port of it, so the JSON parser is `src/plugin/json.lua` and
the suite is a plain script rather than busted.

## Layout

| | |
|---|---|
| `src/plugin/types.lua` | the value model — tagged tables, `NULL`, the error type |
| `src/plugin/json.lua` | the parser, which tags everything it builds |
| `src/plugin/*.lua` | the library, one module per §-area |
| `src/plugin.lua` | the public surface — forwards, nothing else |
| `test/` | the driver (DOCS.md §4), the corpus runner, and `run.lua` |

## Using it

```lua
local P = require 'plugin'

local host = P.make_host(P.types.map {
  catalog = P.make_catalog { {
    name = 'retry',
    define = function(i)
      i:bind('request', function(nxt, ...) return nxt(...) end)
    end,
  } },
  points = P.types.map { request = P.types.map { kind = 'chain', base = transport } },
})

host:ready('retry$fast')
```

Definitions are plain tables with function values, which is what makes a
catalog a data structure a document could produce. Errors are `error()`d as
tables carrying the §12 `code` the corpus compares by, and stringify to the
pinned `plugin/<code>: <text> [k=v]` message.

## The two things lua cannot do, and what this port does instead

**A table is both a map and a list, and `{}` is neither.** So the parser
**tags** every table it builds — `types.map` / `types.list` — and every
table the library builds goes through the same two constructors. That is
what lets this port tell `{}` from `[]`, a distinction php genuinely cannot
draw. A mutation that blinds `islist` to the tag (treating an empty map as
a list) **survives the whole corpus**, which is the direct evidence for
what the php port had to assume: the distinction is real, and nothing in
the corpus currently turns on it.

**`t[k] = nil` deletes the key**, so a JSON null cannot be stored as one.
`types.NULL` is a unique sentinel: `t[k] == nil` is ABSENT and `t[k] ==
NULL` is a present null — exactly what `__UNDEF__` and `__NULL__` assert.
It has one consequence worth knowing: a probe returning a JSON null returns
the sentinel, so `point_emit`'s bail arm treats **both** spellings of
nothing as declining. `point/bail#null-declines` is what says so.

## The trap that cost ten entries

**`a and b or c` is not a ternary when `b` can be `false`.** The corpus
runner wrote `T.has(got, k) and got[k] or MISSING`, so every present
`false` read as *absent* and ten entries failed whose only crime was a
`false` in the expectation. Both sites are now explicit `if`s and both say
why.

What lua gives for free: `true == 1` and `1 == '1'` are both false, so the
type-strict `match` rule needs no guard here — the same gift ruby gets, and
the opposite of php and perl. And lua patterns anchor `$` at the END OF THE
SUBJECT with no multiline mode, so the four `#trailing-newline` entries
pass without the port having to know they exist.

## What the corpus cannot see here

Mutation testing: 20 mutations, 15 caught. Of the five survivors, one is a
non-mutation (deep-merging two lists immediately falls back to replace),
one is the empty-map-versus-empty-list evidence above, and three are the
gaps php, perl, rust and java each found independently — `order.band`
accepting a non-integer, `providersof` without `canon`, and `config_pick`
reading an authored null as absence.
