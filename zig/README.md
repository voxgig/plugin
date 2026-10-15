# voxgig/plugin — zig

The zig port of [voxgig/plugin](../README.md). It is a **port**, not an
independent implementation: behaviour is defined by `typescript/`, and
`spec/plugin.json` — the same corpus every port runs — is the arbiter.

```bash
make build     # zig build-exe; unused code is a compile error
make test      # the corpus, all 19 sections
make inspect   # toolchain version
make clean
make build ZIG=/path/to/other/zig
```

**No dependencies.** No `build.zig.zon`, no package fetch, nothing
outside the standard library. §16 permits one runtime dependency,
`voxgig/struct`, which has no zig port, so `src/value.zig` is the JSON
reader. It is hand-written by choice: `std.json` is the standard library
and would be permitted, but the c, cpp, ocaml and haskell ports carry the
same reader, and a value type the port owns keeps its ordering rules in
one place. There is no warning switch, because zig already makes unused
variables and unreachable code compile errors.

**Two compiler versions, one source.** CI builds the port on zig 0.13, and
voxgig/sekreto compiles it as a named module on 0.16. The two standard
libraries disagree in three places: the managed list, file I/O, and the
environment. `value.modern`, a `comptime` test of `builtin.zig_version`,
is the one switch, and every difference is a `comptime` branch on it, so
the branch not taken is never analysed against a library that lacks it.

## Layout

| | |
|---|---|
| `src/plugin.zig` | the root a consumer imports; it re-exports every module in `src/` |
| `src/value.zig` | the JSON value, its arena, and the only parser this port has |
| `src/types.zig` | `PluginError`, `fail`, `take` and the §12 message format |
| `src/*.zig` | the rest of the library, one file per §-area |
| `run.zig` | the build root, at the port root so imports reach both `src/` and `test/` |
| `test/driver.zig` | the driver (DOCS.md §4) and the probe catalog |
| `test/run.zig`, `test/corpus.zig` | the runner, which counts entries and failures |

## Using it

A consumer takes the port as a named module through its one root,
`--dep plugin -Mplugin=<checkout>/zig/src/plugin.zig`, because zig
confines a module's imports to its root's directory. The canonical names
keep their canonical spelling: `host.makehost`, `catalog.makecatalog`,
`ref.parseref`, `config.normalizeconfig`, `env.applyenv` and the rest.

```zig
const std = @import("std");
const plugin = @import("plugin");
const v = plugin.value;
const host = plugin.host;
const point = plugin.point;
const types = plugin.types;

fn transport(arg: ?*v.Value, ctx: ?*anyopaque) types.Err!?*v.Value {
    _ = ctx;
    return arg;
}

fn retry(next: *point.Chain, arg: ?*v.Value, ctx: ?*anyopaque) types.Err!?*v.Value {
    _ = ctx;
    return point.chainNext(next, arg);
}

fn retryDefine(i: *host.Inst) types.Err!void {
    try host.bind(i, "request", null, retry, i, null);
}

pub fn main() !void {
    var retrydef = host.Definition{ .name = "retry", .define = retryDefine };
    const catalog = plugin.catalog.makecatalog();
    try catalog.add(&retrydef);

    const request = v.vmap();
    v.set(request, "kind", v.vstr("chain"));
    const points = v.vmap();
    v.set(points, "request", request);

    const h = host.makehost(.{
        .catalog = catalog,
        .points = points,
        .bases = &[_]host.BaseFn{.{ .point = "request", .func = transport }},
    });

    _ = host.ready(h, "retry$fast") catch {
        std.debug.print("{s}\n", .{types.take().code});
        return;
    };
}
```

A chain base is a function, which a `Value` cannot hold, so it rides
beside the point map in `bases`, keyed by point name.

## Errors are values without payloads

There is no `throw` carrying an object and no `setjmp`. There is
`error.Plugin` and an explicit `try` at every call, so **the diagnostic
travels beside the error**: `types.fail` parks a `PluginError` in a
module-level slot and returns `error.Plugin`, and every handler calls
`types.take()` as its first act. The slot holds one error, so a handler
that calls something fallible before reading it gets the second error's
payload with the first error's control flow.

What it buys over c is that the compiler refuses an ignored fallible
call. The missed check that continues past a failure, which the c port's
`longjmp` exists to prevent, cannot happen here, and with no `longjmp`
there is no `volatile` discipline either.

**A release cannot fail in the type system.** `ReleaseFn` returns
`void`, because a release that could return an error would make every
unwind site fallible, for a failure §8.3 says must not stop the rest of
the unwind. A release that has to report one writes `host.release_error`,
which the unwind reads and clears around each entry.

## Closures, memory, and threads

A zig function literal that captures is not a value you can store, so a
closure is a function pointer plus a context, as in c: a chain binding
gets an explicit `*Chain` to call `point.chainNext` on, and a binding's
`ctx` is whatever was passed to `host.bind`, usually its `*Inst`.

Every `Value` lives in one arena from `std.heap`, so nothing frees an
individual value and nothing can free one twice. The arena and the
pending error are module-wide rather than per host, the same shape c
has, so two threads racing them corrupt values and lose errors even on
separate hosts. The port makes no thread-safety claim: like every port,
it is single-threaded by contract, and a host driving it from more than
one thread must serialise its own calls.
