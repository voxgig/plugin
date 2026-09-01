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
  dependencies. It compiles to `dist/`; the suite compiles to
  `dist-test/`. `voxgig/struct` is the single permitted one and is not
  yet needed — when it is, it goes in `package.json` and nowhere else.
- `test/corpus.ts` dispatches by GROUP NAME, explicitly. Do not make it
  infer the subject from an entry's shape: a mistyped entry would then
  run the wrong function and pass.
- Both suites assert that **every corpus group has a subject**. A group
  the runner does not know is a group silently not run, which is worse
  than a failure.

## The npm scripts mirror `voxgig/struct`

`build watch typecheck test test-some test-cov doc clean reset repo-tag
repo-publish*` are the same names, in the same order, as
[`struct/typescript/package.json`](https://github.com/voxgig/struct/blob/main/typescript/package.json).
Muscle memory should carry between the two repositories; `npm run reset`
means the same thing in both.

**The layout is struct's too.** `src/` and `test/` are two SEPARATE
tsconfig projects, built with `tsc --build src test`:

| | |
|---|---|
| `src/tsconfig.json` | `outDir`/`declarationDir` `../dist`, `rootDir` `.` |
| `test/tsconfig.json` | `outDir` `../dist-test`, `rootDir` `.` |

So `dist/` is the library, flat — `dist/index.js` is the entry point —
and `dist-test/` is the compiled suite. There is no root `tsconfig.json`;
struct has none either, and `tsc --build src test` needs none.

Two consequences that are not obvious and will bite anyone who forgets
them:

- **The tests import `../dist`, not `../src`.** `test/` is its own
  project with `rootDir: "."`, so it CANNOT reach into `src/` — a
  `../src/index` import drags those files into the test project and
  breaks `rootDir`. Struct's tests import the built output for exactly
  this reason. It also means **a stale `dist` is a stale test run**: build
  before you test, which `make test` and `publish.yml` both do.
- **`corpus.ts` resolves the spec two levels up, not three.** It is
  `dist-test/corpus.js` now rather than `dist/test/corpus.js`, so the
  path to `spec/plugin.json` lost a `..`. Move the output again and this
  moves with it.

`tsBuildInfoFile` puts the incremental state in `.tsbuild/`, outside
`dist`, because `files` ships `dist` and build state is not something to
publish.

Three places the layout still forced an adaptation, all deliberate:

- **`test` does NOT build.** Struct's does not either, which is the point
  — a test script that silently rebuilds hides a stale `dist`. `make
  test` depends on `build`, and `publish.yml` has its own build step, so
  nothing runs the suite against an unbuilt tree.
- **`prepublishOnly` uses `clean-dist`, not `clean`.** `clean` removes
  `node_modules`, and the next thing `prepublishOnly` does is invoke
  `tsc`. That ordering deletes the compiler and then asks for it.
- **`repo-tag` tags `typescript-vX.Y.Z`**, not `vX.Y.Z`: seventeen ports
  share this repository and `publish.yml` keys on that prefix. It also
  pushes **that tag by name**, where struct pushes `--tags`: `--tags`
  sends every local tag, which in a repository this size can leak an
  unrelated work-in-progress tag or fire a second release.

**`repo-publish` does not publish.** In struct it ends in `npm stage
publish`; here it ends at `repo-tag`, because pushing the tag is what
starts the release — `publish.yml` does the publishing over OIDC, from a
runner, with no credential on anyone's laptop. Publishing locally would
need the standing token this whole arrangement exists to avoid.
`repo-publish-dry` still packs locally, which is the part that is useful
to run by hand.

There is no `lint`, `format` or `inject-version` yet. The first two need
eslint and prettier, which this port does not carry and which would
reformat the canonical implementation; `inject-version` has nothing to
inject, since no file here carries struct's `// VERSION:` comment.

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
   package. From `typescript/`, with the token in `$NPM_TOKEN`:

   ```bash
   export NPM_CONFIG_USERCONFIG="$(mktemp)"
   printf '//registry.npmjs.org/:_authToken=%s\n' "$NPM_TOKEN" \
     > "$NPM_CONFIG_USERCONFIG"
   npm publish
   rm -f "$NPM_CONFIG_USERCONFIG"
   ```

   **`NODE_AUTH_TOKEN` on its own does nothing here**, which is the trap
   worth spelling out. npm maps only environment variables prefixed
   `npm_config_`; `NODE_AUTH_TOKEN` works in CI solely because
   `actions/setup-node` writes an `.npmrc` containing the literal
   `${NODE_AUTH_TOKEN}` for npm to expand. With no such file, exporting it
   authenticates nothing and the publish fails. A throwaway
   `NPM_CONFIG_USERCONFIG` is used rather than `npm login` or
   `npm config set` because both of those leave the token sitting in
   `~/.npmrc` afterwards, and this token is meant to be revoked minutes
   later.

   **Not `--provenance`** — provenance can only be generated on a
   supported CI provider, and npm aborts the publish with `Automatic
   provenance generation not supported for provider` rather than skipping
   the attestation. So the bootstrap release is the one unsigned one;
   every release after it is signed, because the workflow passes the flag
   from inside Actions. `publishConfig.access` is already `public`, which
   a scoped package's first publish needs.
2. On npmjs.com, `@voxgig/plugin` → Settings → Trusted Publisher → GitHub
   Actions, with organization `voxgig`, repository `plugin`, workflow file
   `publish.yml`.
3. **Revoke the token.** It has done its only job, and leaving it alive
   re-creates exactly the standing credential trusted publishing exists to
   remove.

Every release after that is the workflow, and the token stays revoked.

The workflow will not publish a commit unless **`ci.yml` has completed
successfully on that exact SHA** — it looks the run up and waits for it,
rather than inferring anything from the commit being on main. `repo-tag`
pushes the branch and the tag seconds apart, so without the wait a
release would race the seventeen-port matrix, and without the conclusion
check it would sail past a matrix that went on to fail.

Two things that are load-bearing and look like decoration:

- **`repository` in `package.json` must match this repo, case
  sensitively.** Provenance generation reads it, and a mismatch fails the
  publish rather than quietly skipping the attestation.
- **`prepublishOnly` rebuilds from clean.** `files` ships `dist`, and
  without the hook a publish would happily package whatever `dist` last
  contained — including nothing.
