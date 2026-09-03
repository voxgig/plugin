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

## Two toolchains, one source

This port's own CI builds it on **zig 0.13**, and its first consumer —
[voxgig/sekreto](https://github.com/voxgig/sekreto), whose zig port is
on **0.16** — compiles it as a named module. One `zig build-exe` cannot
mix toolchains, and the two standard libraries disagree in exactly
three places: the managed list (`std.ArrayList` became unmanaged in
0.15 and the managed one moved to `std.array_list.Managed`), file I/O
(`std.fs` gave way to `std.Io`, which `main` is handed), and the
environment (`std.posix.getenv` is gone; `main` is handed that too).

`value.modern` is the one switch — a comptime test of
`builtin.zig_version` — and every difference is a comptime branch on
it, so the untaken branch is never analysed against a standard library
that lacks it. `value.List(T)` is the list; `test/corpus.zig` parks the
I/O and environment `main` was handed; `test/run.zig` picks the `main`
signature and writes stdout through one helper. **Add a fourth
difference the same way**, behind `modern`, and never a second switch.
Both toolchains must stay green: 572/572 on each is the bar.

## The consumer root: `src/plugin.zig`

Zig confines a module's imports to its root's directory, and refuses a
file that lands in two modules — so a host cannot reach `host.zig`,
`value.zig` and `types.zig` through three roots in one directory.
`src/plugin.zig` is the one root a consumer names
(`-Mplugin=<checkout>/zig/src/plugin.zig`), and it re-exports **every**
module under `src/` — the canonical surface is the whole of it (api
parity), and a root that exposed the handful its first host needed
would make `resolveorder`, `resolvecandidates` and `applyenv`
unreachable by construction. The test driver in `test/` keeps importing
the files directly, because it lives beside them. A new file under
`src/` is one line in the root.

## Build

`make build` has no warning switch because zig makes unused variables
and unreachable code **compile errors** — stricter than `-Werror`, and
not optional. No `build.zig.zon`, no package fetch, nothing outside the
standard library. `make build ZIG=<other zig>` builds with the other
toolchain.
