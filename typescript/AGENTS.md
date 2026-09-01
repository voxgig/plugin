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

## Releasing to npm

This port is the only one published as a package: `@voxgig/plugin`, by
`.github/workflows/publish.yml`, on a `typescript-vX.Y.Z` tag or a manual
run. **There is no npm token anywhere in this repository, and there must
never be one.** The workflow authenticates with npm TRUSTED PUBLISHING —
`id-token: write` mints a short-lived OIDC token that npm verifies against
the trusted publisher registered for the package. Nothing long-lived is
stored, so nothing long-lived can leak.

**The first publish cannot use OIDC, and this is npm's limitation rather
than a missing step here.** A trusted publisher is configured on an
existing package's settings page, and a package that has never been
published has no settings page — PyPI lets you pre-register a name, npm
does not. So the bootstrap is, once, in this order:

1. Publish `0.1.0` by hand with a granular access token scoped to this one
   package (`npm publish --provenance` from `typescript/`, or the token in
   `NODE_AUTH_TOKEN`). `publishConfig.access` is already `public`, which a
   scoped package's first publish needs.
2. On npmjs.com, `@voxgig/plugin` → Settings → Trusted Publisher → GitHub
   Actions, with organization `voxgig`, repository `plugin`, workflow file
   `publish.yml`.
3. **Revoke the token.** It has done its only job, and leaving it alive
   re-creates exactly the standing credential trusted publishing exists to
   remove.

Every release after that is the workflow, and the token stays revoked.

Two things that are load-bearing and look like decoration:

- **`repository` in `package.json` must match this repo, case
  sensitively.** Provenance generation reads it, and a mismatch fails the
  publish rather than quietly skipping the attestation.
- **`prepublishOnly` rebuilds from clean.** `files` ships `dist/src`, and
  without the hook a publish would happily package whatever `dist` last
  contained — including nothing.
