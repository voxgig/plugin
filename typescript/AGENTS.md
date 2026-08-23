# AGENTS.md — typescript (canonical)

Read the repo's [`AGENTS.md`](../AGENTS.md) first. This file only adds
what is local.

## The rule that matters here

**This port defines behaviour.** A fix applied here and not propagated
is a fork; a fix applied elsewhere first is backwards. If a port
disagrees with this one, this one is right *unless the corpus says
otherwise* — and then the corpus is right and this one is a bug.

## The portability budget is not a style preference

No reflection-backed APIs, no `Proxy`, no dynamic property
interception, no decorators, no meta-level interception, and eager
lifecycle reconciliation — a transition settles by running the state
machine to a fixed point, not by suspending on a promise.

Every one of those is cheap to obey now and expensive to remove at P4,
when Go and Python arrive and cannot follow. If you find yourself
wanting one, the design is wrong, not the budget.

### What the budget governs, and the one file outside it

The budget governs **the portable library** — everything twenty
languages implement from one corpus. It is not negotiable there, and
`Config.ts` cites it as the reason `apply` refills an options map rather
than installing a getter.

`src/FeatureHost.ts` is outside it, deliberately and alone. It is a
bridge to **sdkgen**, and it intercepts assignment to
`ctx.utility.fetcher` with a getter/setter pair — dynamic property
interception, exactly what the list above forbids.

The reason it is admissible is that **a bridge to sdkgen cannot be
ported and is not meant to be.** sdkgen generates SDKs in 23 languages,
each feature written in that language's idiom; a Go SDK's feature does
not assign `ctx.utility.fetcher`, so a Go translation of that file would
have nothing to intercept. Each language that wants the bridge writes
its own against its own generated code, and what they share is the
plugin model underneath, not the mechanism.

That reasoning does not extend to anything else. A second file wanting
an exemption is a design problem, not a precedent — and this one is
named here so the exception cannot be claimed silently. Review found it
unstated, which is how an exception becomes a precedent.

## Local shape

- `src/` is plain CommonJS-target TypeScript, `strict: true`, no runtime
  dependencies. `voxgig/struct` is the single permitted one and is not
  yet needed — when it is, it goes in `package.json` and nowhere else.
- `test/corpus.ts` dispatches by GROUP NAME, explicitly. Do not make it
  infer the subject from an entry's shape: a mistyped entry would then
  run the wrong function and pass.
- Both suites assert that **every corpus group has a subject**. A group
  the runner does not know is a group silently not run, which is worse
  than a failure.
