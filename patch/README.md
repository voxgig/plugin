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
git am patch/0001-ci-build-scala-and-kotlin-under-their-newer-compiler.patch
```

**Read it from the worktree, not from a branch ref.** An earlier draft of this
file said `git show origin/claude/plugin-ci-second-toolchain-patch:… | git am`
and claimed that works after merging. It does not: merging is usually followed
by deleting the source branch, and a fresh clone never had it, so the one
documented command would fail exactly when it is most likely to be run. The
file is tracked, so the worktree copy is the durable one.

If you would rather not check the branch out at all, name a ref that outlives
it:

```sh
git show origin/main:patch/0001-ci-build-scala-and-kotlin-under-their-newer-compiler.patch | git am
```

## What it does

Adds one job, `newer-toolchain`, with two lanes:

| lane | toolchain | from |
|---|---|---|
| `scala (newer toolchain)` | scala 3.9.0 | `scala3-3.9.0.tar.gz`, github.com/scala/scala3 |
| `kotlin (newer toolchain)` | kotlin 2.2.0 | `kotlin-compiler-2.2.0.zip`, github.com/JetBrains/kotlin |

Both are pinned release archives, the same trade `dart`, `swift`, `zig` and
`lean` already take in this file.

It also rewords the two `apt` comments in the `port` job, which said 2.11 and
1.3.31 are "what this port is written to". After #29 and #30 they are the
OLDEST compilers each port must satisfy, not the only ones, and the comments
now say so and name the job that checks the other end.

## Why it is worth doing

#29 made the kotlin port compile under kotlin 1.3.31 **and** 2.x. #30 made
the scala port compile under scala 2.11 **and** scala 3. Neither newer half
was built by anything on GitHub: the `port` job installs ubuntu's archive
packages, so a later change could break scala 3 or kotlin 2 and every check
would stay green.

That is the gap this file already names in the `port` matrix comment — *the
gate stays green BECAUSE the case is missing from it* — in a second place.

## What it needs from the ports

Nothing. Both Makefiles already take the compiler and the runner as
overridable variables and probe for what they got, so each lane is the
ordinary `make build-<port>`, `make test-<port>`, `make inspect-<port>` with
`PATH` pointing at the newer toolchain. That was the point of the probes.

## Checks

Both lanes were run with the same archives the job fetches, before the patch
was written:

```
scala    19 files compile
         572 corpus entries across 19 sections, all pass
         inspect: Scala compiler version 3.9.0

kotlin   19 files compile
         572 corpus entries across 19 sections, all pass
         inspect: kotlinc-jvm 2.2.0
```

- `git am` of this patch onto `main`: clean
- `.github/workflows/ci.yml` parses as YAML after applying, four jobs:
  `spec-freshness`, `parity`, `port`, `newer-toolchain`
