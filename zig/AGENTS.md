# The zig port — agent notes

Zig is the closest thing in the set to `c`: no exceptions, no closures,
manual memory. It is tier-4 by the loader (design §10.3) *and* by every
other measure. What it gives that `c` does not is worth stating
precisely, because it is one thing.

## Errors are values without payloads

There is no `throw` carrying an object and no `setjmp`. There is
`error.Plugin` and an explicit `try` at every call. So **the diagnostic
travels beside the error**: `types.fail` parks a `PluginError` in a
module-level `pending` and returns `error.Plugin`, and every handler
calls `types.take()` as its **first act**.

**That discipline is load-bearing.** `pending` holds one error; a
handler that calls something fallible before reading it gets the second
error's payload with the first error's control flow. Every `catch` in
this port takes first and works afterwards, and that is the thing to
check when adding one.

**What it buys over `c`**: an explicit `try` means the compiler will not
let a fallible call be ignored. The "missed check continues silently
past a failure" mode that `c`'s `longjmp` exists to prevent cannot
happen here at all — and there is no `volatile` discipline, because
there is no `longjmp`.

## A release cannot fail in the type system

`ReleaseFn` returns `void`. A release that could return an error would
make every unwind site fallible, for a failure §8.3 says must not stop
the rest of the unwind. So a release that must report one writes to
`host.release_error`, which `host.unwind` reads and clears around each
entry. `resource/failrelease` is the only thing that exercises it.

## Closures are a function pointer plus a context

Exactly as in `c`, and for the same reason: a zig function literal that
captures is not a value you can store. `chain` gets an explicit
`*Chain` to call back into, and a binding's `ctx` is its `*Inst`.

## Thread safety: not claimed

`pending`, and the arena below it, are **module-global** rather than
per-host — the same shape `c` has, arrived at because zig's errors carry
no payload. Two threads racing them corrupt values and lose errors even
on separate `Host`s. **This port does not claim thread safety**, per
[`../docs/ADR.md`](../docs/ADR.md) ADR-2: the baseline contract is
single-threaded, and a host driving this port from more than one thread
must serialise its own calls.

## The arena, and why nothing here frees

Same argument `c` makes — every `Value` lives in one arena, so nothing
frees an individual value and nothing can double-free one — except that
zig hands the arena over in `std.heap` rather than making the port build
it.

## run.zig is at the port root, not in test/

Zig restricts imports to the **root source file's directory**, so a root
at `test/run.zig` cannot reach `../src`. `run.zig` at the port root is a
one-line delegate; the actual runner stays in `test/run.zig` where every
other port keeps it.

## The JSON reader is hand-written even though `std.json` exists

That is a choice, not a constraint: `std.json` is the standard library,
so §16 permits it, and its `ObjectMap` even preserves insertion order.
The reason to write it here is symmetry — `c`, `cpp`, `ocaml` and
`haskell` all carry the same reader, and a port whose value type is its
own is a port whose ordering rules are visible in one place.

## Build

`make build` has no warning switch because zig makes unused variables
and unreachable code **compile errors** — stricter than `-Werror`, and
not optional. No `build.zig.zon`, no package fetch, nothing outside the
standard library.
