# voxgig/plugin — javascript

The javascript port of [voxgig/plugin](../README.md). It is a **port**,
not an independent implementation: behaviour is defined by
`typescript/`, and `spec/plugin.json` — the same corpus every port runs
— is the arbiter.

```bash
make build     # syntax-check every source and test file
make test      # the corpus, all 19 sections
make inspect   # runtime version
make clean
```

No dependencies, and no test framework beyond Node's built-in runner.
CommonJS.

## Layout

| | |
|---|---|
| `src/` | the library |
| `test/` | the driver (DOCS.md §4), the corpus runner, and the tests |

## Why this port exists at all

It is the canonical with the types removed, which makes it the port with
the **least** to say for itself and the one most worth having anyway:

- it is what `@voxgig/plugin-js` ships to a consumer that does not want
  a TypeScript toolchain in its dependency tree;
- it is the port where a divergence could only be carelessness rather
  than translation, so **any** corpus failure here is a bug in this
  directory and never a question about the model;
- and running the corpus twice over near-identical source is a cheap
  check that the corpus is testing behaviour rather than TypeScript.

The one thing it does not inherit is the canonical's compile-time shape
checking. That is exactly why the corpus runs here, unchanged, in full.
