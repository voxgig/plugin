# voxgig/plugin — php

The php port of [voxgig/plugin](../README.md). It is a **port**, not an
independent implementation: behaviour is defined by `typescript/`, and
`spec/plugin.json` — the same corpus every port runs — is the arbiter.

```bash
make build     # syntax-check every file
make test      # the corpus, all 19 sections
make inspect   # interpreter version
make clean
```

PHP 8.1 or later (it uses `array_is_list`, `str_starts_with` and
enum-free readonly-free plain classes). No composer manifest and no
PHPUnit: the suite is a plain runner, because a conformance suite whose
only job is to run one corpus and report which entries disagree does not
need a framework, and a `vendor/` tree would be a build step every
embedding host inherits.

## Layout

| | |
|---|---|
| `src/` | the library |
| `src/plugin.php` | the public surface — requires the rest |
| `test/` | the driver (DOCS.md §4), the corpus runner, and `run.php` |

## Using it

```php
require 'src/plugin.php';

use function Voxgig\Plugin\make_catalog;
use function Voxgig\Plugin\make_host;

$catalog = make_catalog([
    ['name' => 'retry',
     'define' => function ($i) {
         $i->bind('request', function ($nxt, ...$a) { return $nxt(...$a); });
     }],
]);

$host = make_host([
    'catalog' => $catalog,
    'points' => ['request' => ['kind' => 'chain', 'base' => $transport]],
]);

$host->ready('retry$fast');
```

Definitions are plain arrays with callable values, which is what makes a
catalog a data structure a document could produce. Errors are thrown as
`Voxgig\Plugin\PluginError`, carrying the §12 `code` the corpus compares
by — and because it widens `Exception`'s own `$code` property rather than
adding a second one, `getCode()` and `->code` cannot disagree.

## The three traps this port had to be written around

**An array is a VALUE.** `$b = $a` copies, so an instance record read out
of the registry cannot be mutated through the copy. Every record the host
mutates is an object — `Entry`, `Host`, `Inst` — and an instance's `state`
is a `Bag`, whose `offsetGet` returns **by reference** so that
`$i->state['unwound'][] = $k` reaches the instance instead of raising
"indirect modification" and silently doing nothing. Making `Bag` return by
value fails `resource/scope#reverse` immediately.

**`[]` is falsy, and `sort()` is not a string sort.** Ruby's trap is that
an empty list is truthy; php's is the mirror image, and the corpus pins
both ends — `declare/clear#empty-options` needs an empty options map to
CLEAR rather than be ignored, which `if ($spec['options'])` gets wrong.
And PHP's default comparison reads numeric-looking strings as numbers, so
every sort of refs, keys or names passes `SORT_STRING` through
`Util::sortstrings`.

**`true == 1`.** The type-strict `match` rule (`capability/match`) needs
real type equality, which `samescalar` provides — though not the way it
first did: see its comment for the boolean guard that could never fire and
was deleted rather than kept as decoration.

## What this port cannot see

**An empty map and an empty list are the same value.** PHP has one array
type, so `{}` and `[]` both parse to `[]` and no comparison can separate
them. It is the only corpus distinction this port cannot draw, it can only
ever make a passing entry pass for a weaker reason, and the two places
where a reading had to be chosen say which one and why:
`Util::maplike` (merge) and `matchvalue` (partial match).
