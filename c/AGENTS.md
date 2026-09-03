# The c port — agent notes

C is a tier-4 static-only language (design §10.3): no dynamic loading,
no closures, no exceptions, no garbage collector. Three decisions carry
the port, and they hold each other up.

## The arena, and why nothing here frees

Every `Value` lives in one arena, freed all at once by `arena_reset`.
Ownership-per-value or refcounting buys nothing a corpus-driven library
needs and costs the thing C ports actually fail at: a `free` on a path
the corpus does not exercise. **Nothing frees an individual value, so
nothing can double-free one.**

## setjmp/longjmp, and why it is safe HERE

The canonical raises, and the corpus is full of entries asserting what
survived a raise mid-sequence (`resource/unwind`, `lifecycle/fail`).
Threading an error return through every function would let a missed
check continue silently past a failure — the one thing the corpus
cannot see and the one thing it is trying to pin. `longjmp` abandons the
frame the way a `throw` does.

`longjmp` past a frame leaks whatever that frame owned. Nothing here
owns anything, so there is nothing to leak. **The arena is what makes
the jump safe, and the jump is what makes the semantics match.**

**Every local that straddles a `PLUGIN_TRY` must be `volatile`.** C
guarantees only that `volatile` locals keep their value across a
`longjmp`; without it, a flag set before the jump and read after it is
indeterminate. `-Wclobbered` (on, via `-Werror`) finds these. It found
seven while this port was written, in `reconcile`, `cascade` and
`drive`.

## Closures are a function pointer plus a context

`chain` needs to hand a binding its `next`, which every other port
writes as a closure. Here `next` is an explicit `Chain *` the binding
calls back into, and a binding's `ctx` is its `Inst *`. Same
composition, same order, no hidden state.

## What the corpus caught

- **`point/bail#null-declines`.** The `provider` probe must test
  `value` for PRESENCE, not for non-null: an authored `value: null` IS
  a value, and in `bail` mode a null DECLINES so the next binding
  answers. Reading it as "no value given" and substituting the ref made
  the probe answer where the contract says it stands aside.
- **`resource/scope#difference`.** `acquire` has to return a handle a
  plugin can hand back early; the scope keeps the entry and unwinding it
  twice is a no-op. Stubbing the release count out left `open` too high
  by exactly the number handed back.

## Build

`make build` is a real gate: `-std=c11 -Wall -Wextra -Werror`. POSIX
`<regex.h>` is libc, not a package — §16's one permitted runtime
dependency (voxgig/struct) has no C port, so `src/value.c` is the JSON
reader and the runner is a `main` that counts.
