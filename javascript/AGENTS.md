# AGENTS.md — the javascript port

Read [`../AGENTS.md`](../AGENTS.md) first. The prime directives there
are not negotiable here: **TypeScript is canonical**, **the corpus is
the contract**, **change canonical first then propagate**, and **never
weaken the corpus to make this port pass**.

This file is only what is specific to javascript.

## The rule that matters most here

This port is the canonical with the types stripped. **A disagreement
with the corpus is a transcription error in this directory** — not a
question about the model, and not a candidate canonical defect. That is
the opposite of the standing advice for every other port, and it is
because this one shares a language, a runtime, and every coercion rule
with the thing it is a port of.

If you genuinely believe you have found a model defect while working
here, you have almost certainly found a typo. Diff the function against
`typescript/src/` before writing a corpus entry.

## The portability budget still applies

`../typescript/AGENTS.md` forbids reflection-backed APIs, `Proxy`,
dynamic property interception, decorators and meta-level interception.
JavaScript makes every one of those *easier* than the portable
alternative, which is precisely why the budget is worth restating here.
The exemption named in that file covers `FeatureHost.ts` and nothing
else; this port has no equivalent file.

## Local shape

- CommonJS (`require` / `module.exports`), `'use strict'` at the top of
  every file, no build step.
- One module per canonical module, same names, same exported names —
  `makehost`, `parseref`, `normalizeconfig` and the rest, verbatim, so
  `make parity` matches without a casing rule.
- `make build` is `node --check` over every source and test file. Not a
  no-op: a syntax error in a module no test happens to `require` would
  otherwise ship.

## Adding a corpus section

Dispatch it explicitly. `test/coverage.test.js` fails if a section
exists in the corpus and no test names it, and each section's test fails
on a *group* with no subject. A section or group silently not run is
worse than a failing one, which is why both guards exist.
