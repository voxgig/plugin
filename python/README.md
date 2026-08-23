# voxgig/plugin — python

The python port of [voxgig/plugin](../README.md). It is a **port**, not an
independent implementation: behaviour is defined by `typescript/`, and
`spec/plugin.json` — the same corpus every port runs — is the arbiter.

```bash
make build     # bytecode-compile the package (the nearest thing to "does this parse")
make test      # the corpus, all 19 sections
make inspect   # interpreter version
make clean
```

No dependencies, and no test framework beyond the standard library.
Python 3.8+.

## Layout

| | |
|---|---|
| `voxgig_plugin/` | the library |
| `test/` | the driver (DOCS.md §4), the corpus runner, and the tests |

## Using it

```python
from voxgig_plugin import make_catalog, make_host

catalog = make_catalog([{
    'name': 'retry',
    'define': lambda i: i.bind('request', lambda nxt, *a: nxt(*a)),
}])

host = make_host({
    'catalog': catalog,
    'points': {'request': {'kind': 'chain', 'base': transport}},
})

host.ready('retry$fast')
```

Definitions are plain dicts with callable values, which is what makes the
catalog a data structure a document could produce. Errors are raised as
`PluginError`, carrying the §12 `code` that the corpus compares by.

## The traps this port had to be written around

**`True == 1`.** Python's `==` says a boolean and an integer are the same
value; the canonical's `===` says they are not, and JSON gives them
distinct types. It matters in exactly one place in the library —
`capability.matchvalue` — and in the corpus runner's own comparison, and
both carry an explicit guard. Four `capability/match` entries now pin it
for every port whose language has the same rule (php, perl, lua).

**Closures capture the variable, not the value.** `point.compose` binds
`fn` and `inner` into default arguments; a plain closure in that loop
leaves every layer calling the last one, which is the single most common
way to get chain composition wrong.

**`isinstance(True, int)` is `True`.** `config.check_shape` rejects
`{"deep": true}` explicitly, because an int check alone would read it as
depth 1.

**A stale `__pycache__` makes a mutation test a lie.** Bytecode is keyed
on source mtime and size; restoring a mutated file can land on the same
pair and reuse the old `.pyc`. Clear both cache directories around any
run whose point is that the source changed.
