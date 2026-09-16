# `patch/` — a change this session could not push

`.github/workflows/` is refused to the session that wrote this change, on
both write paths:

- **git push** — `refusing to allow an OAuth App to create or update workflow
  .github/workflows/ci.yml without workflow scope`
- **the GitHub App's file API** — fails on that path while writing any other
  file in the same breath

The change is a workflow change, so it cannot travel as a branch. It travels
as a patch instead, and this folder is transient: delete it once the patch is
applied.

## Apply it

From any checkout that carries this folder — this branch, or `main` once the
delivery commit is merged:

```sh
git am patch/0001-ci-build-the-lean-port-with-the-compiler-it-pins.patch
```

Read it from the worktree rather than from a branch ref: the source branch is
usually deleted after merging and a fresh clone never had it, so a command
naming that branch would fail exactly when it is most likely to be run. If you
would rather not check the branch out, name a ref that outlives it:

```sh
git show origin/main:patch/0001-ci-build-the-lean-port-with-the-compiler-it-pins.patch | git am
```

## What it does

One line, plus the comment that explains it.

| | version |
|---|---|
| `lean/lean-toolchain` | `leanprover/lean4:v4.32.1` |
| `.github/workflows/ci.yml`, before | `v4.15.0` |
| `.github/workflows/ci.yml`, after | `v4.32.1` |

## Why it is worth doing

**The `lean` job has failed on every run since `48392f5`**, including every
run on `main`. That commit moved the port to 4.32.1, for the reason it gives:
voxgig/struct's lean port and the sdkgen scaffold both pin it, and four
repositories vendored together as one checkpoint cannot be compiled side by
side on three different pins. The workflow kept fetching 4.15.0, so CI
compiles 4.32.1 sources with a compiler that predates the `String.Slice`
changes the port was rewritten for.

It fails at `make build-lean`, which reads as a port failure and is not one.
Anyone reading a red `lean` check on their own branch learns nothing true
about their change.

The port's bump landed without this file because an agent session cannot write
it — the same boundary this folder exists for. The comment added above the
step now says the two versions must move together, so the next bump has one
place to look.

## Checks

**Both compilers were fetched and the port built under each**, so the
failure this fixes is reproduced rather than inferred.

```
v4.15.0   make build-lean
          Some required builds logged failures:
          - Corpus
          - Plugin.Env
          - Plugin.Version
          error: build failed

v4.32.1   make build-lean   clean
          make test-lean    572 corpus entries across 19 sections, all pass
```

- `git apply --check` of this patch onto `5c1df34`: clean
- `.github/workflows/ci.yml` parses as YAML after applying, four jobs:
  `spec-freshness`, `parity`, `port`, `newer-toolchain`
- the v4.32.1 linux asset resolves at the URL the job builds:
  `https://github.com/leanprover/lean4/releases/download/v4.32.1/lean-4.32.1-linux.tar.zst`

The lean port itself is not touched and needs nothing. What this restores
is CI's ability to say so.
