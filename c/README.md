# voxgig/plugin — c

The c port of [voxgig/plugin](../README.md). It is a **port**, not an
independent implementation: behaviour is defined by `typescript/`, and
`spec/plugin.json` — the same corpus every port runs — is the arbiter.

```bash
make build     # compile the library and the runner, -Werror
make test      # the corpus, all 19 sections
make inspect   # compiler version
make clean
```

**No dependencies.** §16 permits one runtime dependency, `voxgig/struct`,
which has no C port, so `src/value.c` is the JSON reader and
`plugin_merge` carries the merge semantics of `voxgig/struct`. POSIX
`<regex.h>` is part of the C library, not a package. The build is `-std=c11 -Wall -Wextra -Werror`, and
the test binary is built with the same flags, so a warning fails the
build rather than scrolling past.

## Layout

| | |
|---|---|
| `src/value.c` | the JSON value, its arena, and the only parser this port has |
| `src/types.c` | `PluginError`, the raise mechanism and the §12 message format |
| `src/*.c` | the library, one file per §-area, each with its header |
| `test/driver.c` | the driver (DOCS.md §4) and the probe catalog |
| `test/run.c` | the runner: a `main` that counts entries and failures |

## Using it

The canonical names keep their canonical spelling: `makehost`,
`makecatalog`, `parseref`, `normalizeconfig`, `applyenv` and the rest.
Host and instance methods are free functions, `host_ready(host, ref)`
and `inst_bind(inst, ...)`.

```c
#include <stdio.h>
#include "host.h"

static Value *transport(Value *arg, void *ctx) { (void)ctx; return arg; }

static Value *retry(Chain *next, Value *arg, void *ctx) {
  (void)ctx;
  return chain_next(next, arg);
}

static void retry_define(Inst *i) {
  inst_bind(i, "request", NULL, retry, i, NULL);
}

Definition retrydef = { .name = "retry", .define = retry_define };
Catalog *catalog = makecatalog();
catalog_add(catalog, &retrydef);

Value *request = vmap();
vset(request, "kind", vstr("chain"));
Value *points = vmap();
vset(points, "request", request);
Value *basepoints = vlist();
vpush(basepoints, vstr("request"));
HookFn basefns[] = { transport };

HostOptions opts = { .catalog = catalog, .points = points,
                     .basepoints = basepoints, .basefns = basefns };
Host *host = makehost(&opts);

CatchFrame f;
if (0 == PLUGIN_TRY(&f)) {
  host_ready(host, "retry$fast");
  PLUGIN_END(&f);
}
else {
  printf("%s\n", plugin_caught()->code);
}

arena_reset();
```

A chain base and a provider default are functions, which a `Value`
cannot hold, so they ride beside the point map: `basefns[i]` backs the
point named by `basepoints[i]`.

## Three decisions that hold each other up

**One arena, and nothing frees.** Every `Value` lives in one arena,
released all at once by `arena_reset`. Ownership per value buys nothing
a corpus-driven library needs and costs the thing C ports fail at: a
`free` on a path the corpus does not exercise. Nothing frees an
individual value, so nothing can free one twice.

**A raise is a `longjmp`.** The canonical raises, and the corpus is full
of entries asserting what survived a raise mid-sequence
(`resource/unwind`, `lifecycle/fail`). An error return threaded through
every function would let a missed check continue past a failure, which
is the one thing the corpus cannot see. `fail` jumps to the innermost
`PLUGIN_TRY` frame the way a `throw` unwinds, and `plugin_caught` reads
the error back. The jump is safe because of the arena: a frame that owns
nothing leaks nothing when it is abandoned. Every local that straddles a
`PLUGIN_TRY` and changes inside it must be `volatile`, and
`-Wclobbered`, on through `-Wextra`, finds the ones that are not.

**A closure is a function pointer plus a context.** A chain binding gets
its `next` as an explicit `Chain *` and calls `chain_next`; a binding's
`ctx` is whatever was passed to `inst_bind`, usually its `Inst *`. Same
composition, same order, no hidden state.

## Threads

The arena and the pending error are **process-wide**, not per host. Two
threads allocating values race the arena's bump pointer even on separate
hosts, and `plugin_caught` reads one slot for the whole process. The port
makes no thread-safety claim: like every port, it is single-threaded by
contract, and a host driving it from more than one thread must serialise
its own calls.

## What the corpus caught

- **`point/bail#null-declines`.** The `provider` probe has to test
  `value` for presence, not for non-null: an authored `value: null` is a
  value, and in `bail` mode a null declines so the next binding answers.
- **`resource/scope#difference`.** `inst_acquire` returns a handle a
  plugin can give back early with `inst_giveback`. The scope keeps the
  entry, and unwinding it twice does nothing; stubbing that out left
  `open` too high by exactly the number given back.
