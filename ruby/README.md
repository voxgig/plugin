# voxgig/plugin — ruby

The ruby port of [voxgig/plugin](../README.md). It is a **port**, not an
independent implementation: behaviour is defined by `typescript/`, and
`spec/plugin.json` — the same corpus every port runs — is the arbiter.

```bash
make build     # syntax-check every file
make test      # the corpus, all 19 sections
make inspect   # interpreter version
make clean
```

No gems, and no test framework: the suite is a plain runner, because a
conformance suite whose only job is to run one corpus and report which
entries disagree does not need one.

## Layout

| | |
|---|---|
| `lib/voxgig_plugin/` | the library |
| `lib/voxgig_plugin.rb` | the public surface |
| `test/` | the driver (DOCS.md §4), the corpus runner, and `run.rb` |

## Using it

```ruby
require 'voxgig_plugin'

catalog = VoxgigPlugin.make_catalog([
  { 'name' => 'retry',
    'define' => ->(i) { i.bind('request', ->(nxt, *a) { nxt.call(*a) }) } }
])

host = VoxgigPlugin.make_host(
  'catalog' => catalog,
  'points' => { 'request' => { 'kind' => 'chain', 'base' => transport } }
)

host.ready('retry$fast')
```

Definitions are plain hashes with callable values, which is what makes a
catalog a data structure a document could produce. Errors are raised as
`VoxgigPlugin::PluginError`, carrying the §12 `code` the corpus compares
by.

## The two traps this port had to be written around

**`^` and `$` match at every LINE boundary.** Ruby's anchors are not
string anchors, so `/^[a-z]+$/` accepts `"abc\ndef"`. Every regex here
uses `\A` and `\z`. This is not theoretical: the *python* port shipped
with the same class of hole — its `$` also matches before a trailing
newline — and it went undetected until this port's anchors were written
deliberately. Pinned now by `ref/name#trailing-newline`,
`ref/tag#trailing-newline`, `ref/parsebad#trailing-newline` and
`version/rangebad#trailing-newline`.

**`Array#sort` is not stable.** The canonical leans on JavaScript's
stable sort in three places whose comparators fall through to a
tie-break. Every sort here goes through `VoxgigPlugin::Util.stable_sort_by`,
which decorates with the original index.

What Ruby gives for free, and other dynamic ports do not: `true == 1` is
already false, so the type-strict `match` rule needs no guard here.
`capability/match` pins it anyway, for php, perl and lua.
