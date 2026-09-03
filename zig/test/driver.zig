//! The driver (DOCS.md §4).
//!
//! Every port implements this same small thing and nothing else is
//! port-specific: the probe catalog, the command interpreter, and the
//! canonical observable.
//!
//! A PROBE'S CONTEXT IS ITS INSTANCE. Zig has no closures, so where the
//! canonical writes `(i) => ...` capturing the instance, here each
//! callback takes `*Inst` and reads what it needs off it. The `ctx` a
//! binding carries is the instance too, for the same reason — the same
//! shape `c` has.

const std = @import("std");
const v = @import("../src/value.zig");
const t = @import("../src/types.zig");
const host = @import("../src/host.zig");
const point = @import("../src/point.zig");
const catalog = @import("../src/catalog.zig");
const model = @import("../src/inst.zig");

const Inst = host.Inst;
const Host = host.Host;

// --- probe helpers -----------------------------------------------------

fn opt(i: *Inst, key: []const u8) *v.Value {
    return v.get(i.options, key);
}

fn num(x: ?*v.Value) f64 {
    return if (v.isNum(x)) v.asNum(x) else 0;
}

fn bump(i: *Inst, start: f64) void {
    if (!v.has(i.state, "count")) v.set(i.state, "count", v.vnum(start));
}

fn addCount(i: *Inst) void {
    v.set(i.state, "count", v.vnum(num(v.get(i.state, "count")) + 1));
}

/// `noisy` fails on demand: `options.fail` names the callback that
/// raises and `options.code` the error code. `options.bare` raises with
/// NO CODE AT ALL, which is the ordinary library error §12's
/// `plugin_<phase>_failed` codes exist to wrap.
fn boom(i: *Inst, cb: []const u8) t.Err!void {
    const f = opt(i, "fail");
    if (!v.isStr(f) or !std.mem.eql(u8, v.asStr(f), cb)) return;
    const text = v.print("probe failed at {s}", .{cb});
    if (v.truthy(opt(i, "bare"))) {
        // `fail` needs a code, so the bare case uses a sentinel the host
        // recognises and wraps, which is what every other port gets from
        // a plain language error.
        return t.fail("plugin_bare", text, null);
    }
    const code = opt(i, "code");
    return t.fail(if (v.isStr(code)) v.asStr(code) else v.print("plugin_{s}_failed", .{cb}), text, null);
}

fn reenter(i: *Inst, cb: []const u8) t.Err!void {
    const r = opt(i, "reenter");
    if (!v.isStr(r) or !std.mem.eql(u8, v.asStr(r), cb)) return;
    // A transition from inside a lifecycle callback: §5.2's
    // `plugin_reentrant`, reached by actually attempting one.
    _ = try host.activate(i.owner, i.ref);
}

// --- the `probe` bindings ----------------------------------------------

fn probeHook(arg: ?*v.Value, ctx: ?*anyopaque) t.Err!?*v.Value {
    _ = arg;
    const i: *Inst = @ptrCast(@alignCast(ctx.?));
    addCount(i);
    // `p` RETURNS NOTHING, as the canonical's arrow-with-a-block does:
    // in `bail` mode a return is an answer, and a counter that answered
    // with its own count would make every hook that keeps one
    // un-bailable.
    return null;
}

fn probeChain(next: *point.Chain, arg: ?*v.Value, ctx: ?*anyopaque) t.Err!?*v.Value {
    const i: *Inst = @ptrCast(@alignCast(ctx.?));
    const wrap = opt(i, "wrap");
    const w = if (v.isStr(wrap)) v.asStr(wrap) else ":";
    const inner = try point.chainNext(next, arg);
    const tail = if (v.isStr(inner)) v.asStr(inner) else if (v.isNull(inner)) "" else v.json(inner);
    // Wrap AFTER next, so the result spells the nesting left to right:
    // outermost first. Wrapping the ARGUMENT instead would spell it
    // backwards and make every chain expectation read wrong.
    return v.vstr(v.print("{s}{s}", .{ w, tail }));
}

fn providerHook(arg: ?*v.Value, ctx: ?*anyopaque) t.Err!?*v.Value {
    _ = arg;
    const i: *Inst = @ptrCast(@alignCast(ctx.?));
    // PRESENCE, not non-null. An authored `value: null` IS a value — and
    // in `bail` mode a null DECLINES and the next binding answers, which
    // is what `point/bail#null-declines` pins. Reading it as "no value
    // given" and substituting the ref made this probe answer where the
    // contract says it stands aside.
    if (!v.has(i.options, "value")) return v.vstr(i.ref);
    return opt(i, "value");
}

// --- probe callbacks ---------------------------------------------------

fn probeDefine(i: *Inst) t.Err!void {
    bump(i, 0);
    try boom(i, "define");
    const band = opt(i, "band");
    // One hook binding (`p`) and one chain wrap (`c`) — the workhorse
    // shape DOCS.md §4.3 specifies.
    try host.bind(i, "p", probeHook, null, i, band);
    try host.bind(i, "c", null, probeChain, i, band);
    host.exportvalue(i, "client", v.vstr(i.ref));
    // The instance api itself, so the driver's `stray` command can call
    // `release` from OUTSIDE a lifecycle callback — which is the only
    // way to exercise §8.3's scope guard. The driver looks the instance
    // up by ref; this export keeps the shape the other ports have.
    host.exportvalue(i, "inst", v.vstr(i.ref));
    for (v.items(opt(i, "provides"))) |p| host.provides(i, p);
}

fn probeActivate(i: *Inst) t.Err!void {
    _ = try host.acquire(i);
    try reenter(i, "activate");
    try boom(i, "activate");
    // §6.5: an instance that is itself a host. The outer owns the
    // inner's lifetime — registered in the scope, so it closes on
    // deactivate in the same reverse unwind as every other resource.
    const nest = opt(i, "nest");
    if (v.isList(nest) and v.len(nest) > 0) {
        const inner = try host.nest(i, hostopts(null));
        try seed(inner);
        for (v.items(nest)) |r| _ = try host.ready(inner, v.asStr(r));
    }
}

fn probeDeactivate(i: *Inst) t.Err!void {
    return boom(i, "deactivate");
}

fn probeClose(i: *Inst) t.Err!void {
    return boom(i, "close");
}

fn recordDefine(i: *Inst) t.Err!void {
    bump(i, 0);
}

fn recordActivate(i: *Inst) t.Err!void {
    _ = try host.acquire(i);
}

/// `greedy` acquires `options.acquire` resources and releases
/// `options.release` of them explicitly, so the difference is what the
/// instance scope must unwind (§8.3).
const MarkCtx = struct { inst: *Inst, index: f64, markfail: bool };

fn markRelease(ctx: ?*anyopaque) void {
    const m: *MarkCtx = @ptrCast(@alignCast(ctx.?));
    var unwound = v.get(m.inst.state, "unwound");
    if (!v.isList(unwound)) {
        unwound = v.vlist();
        v.set(m.inst.state, "unwound", unwound);
    }
    v.push(unwound, v.vnum(m.index));
    if (m.markfail) {
        // The only way §8.3's `plugin_release_failed` and its `failed`
        // status are reachable. A release CANNOT return an error in this
        // port's type system, so it reports through the host's release
        // slot — see `host.unwind`.
        host.release_error = "plugin/probe_release_boom: release raised";
    }
}

fn greedyCapture(i: *Inst) t.Err!void {
    const acquire: usize = @intFromFloat(num(opt(i, "acquire")));
    const rel: usize = @intFromFloat(num(opt(i, "release")));
    // Acquire N and hand back M, so the DIFFERENCE is what the instance
    // scope must unwind (§8.3). Handing one back early must not make
    // teardown wrong: the scope keeps the entry and unwinding it twice
    // is a no-op.
    const held = v.arena().alloc(*model.ScopeEntry, acquire) catch @panic("oom");
    var k: usize = 0;
    while (k < acquire) : (k += 1) held[k] = try host.acquire(i);
    k = 0;
    while (k < rel and k < acquire) : (k += 1) host.giveback(i, held[k]);

    const markn: usize = @intFromFloat(num(opt(i, "mark")));
    const markfail = v.truthy(opt(i, "markfail"));
    k = 0;
    while (k < markn) : (k += 1) {
        const m = v.arena().create(MarkCtx) catch @panic("oom");
        m.* = .{ .inst = i, .index = @floatFromInt(k), .markfail = markfail };
        try host.release(i, markRelease, m);
    }
}

fn greedyDefine(i: *Inst) t.Err!void {
    bump(i, 0);
    // `options.early` acquires in `define` instead, where §8.1 says
    // capture does not belong.
    const early = opt(i, "early");
    if (v.isStr(early) and std.mem.eql(u8, v.asStr(early), "acquire")) _ = try host.acquire(i);
    if (v.isStr(early) and std.mem.eql(u8, v.asStr(early), "release")) try host.release(i, null, null);
    if (!v.isStr(opt(i, "bind"))) try host.bind(i, "p", probeHook, null, i, opt(i, "band"));
}

/// `options.bind` names the callback that declares a BINDING outside
/// `define`, which is §8.1's other half and §12's `plugin_bind_scope`.
fn greedyBindAt(i: *Inst, cb: []const u8) t.Err!void {
    const b = opt(i, "bind");
    if (!v.isStr(b) or !std.mem.eql(u8, v.asStr(b), cb)) return;
    try host.bind(i, "p", probeHook, null, i, null);
}

fn greedyActivate(i: *Inst) t.Err!void {
    try greedyCapture(i);
    try greedyBindAt(i, "activate");
}

fn greedyDeactivate(i: *Inst) t.Err!void {
    try greedyBindAt(i, "deactivate");
}

fn depDefine(i: *Inst) t.Err!void {
    v.set(i.state, "count", v.vnum(0));
    for (v.items(opt(i, "provides"))) |p| host.provides(i, p);
    const exports = opt(i, "exports");
    if (v.isMap(exports)) {
        for (v.keys(exports)) |k| host.exportvalue(i, k, v.get(exports, k));
    }
}

fn providerDefine(i: *Inst) t.Err!void {
    v.set(i.state, "count", v.vnum(0));
    const pt = opt(i, "point");
    try host.bind(i, if (v.isStr(pt)) v.asStr(pt) else "v", providerHook, null, i, opt(i, "band"));
    // The capability records come from `options.provides` VERBATIM, and
    // there is no second source. `c` once synthesized one from
    // `options.capability`/`version`/`priority` — three keys the
    // canonical's `provider` does not read and no corpus entry sets —
    // and then dropped it on the floor; the haskell port found it.
    for (v.items(opt(i, "provides"))) |p| host.provides(i, p);
}

/// §4.3's six probes, plus the `record` family the corpus names. Their
/// behaviour is as much the contract as the runner is — this is where
/// twenty implementations of `noisy` are made to fail at the same
/// callback in the same way.
fn probedef(name: []const u8) *catalog.Definition {
    const d = v.arena().create(catalog.Definition) catch @panic("oom");
    d.* = .{ .name = v.dupe(name), .define = recordDefine, .activate = recordActivate };

    if (std.mem.eql(u8, name, "probe") or std.mem.eql(u8, name, "noisy")) {
        d.define = probeDefine;
        d.activate = probeActivate;
        d.deactivate = probeDeactivate;
        d.close = probeClose;
    } else if (std.mem.eql(u8, name, "greedy")) {
        d.define = greedyDefine;
        d.activate = greedyActivate;
        d.deactivate = greedyDeactivate;
    } else if (std.mem.eql(u8, name, "dep")) {
        d.define = depDefine;
    } else if (std.mem.eql(u8, name, "provider")) {
        d.define = providerDefine;
    }
    return d;
}

const PROBE_NAMES = [_][]const u8{
    "probe", "noisy", "greedy", "dep", "provider",
    "slow",  "other", "adapter", "late",
};

pub fn probes() *v.Value {
    const out = v.vlist();
    for (PROBE_NAMES) |n| v.push(out, v.vstr(n));
    return out;
}

pub fn probe(name: []const u8) ?*catalog.Definition {
    for (PROBE_NAMES) |n| {
        if (std.mem.eql(u8, n, name)) return probedef(name);
    }
    return null;
}

/// Register the whole probe set into a host's catalog.
pub fn seed(h: *Host) t.Err!void {
    for (PROBE_NAMES) |n| try host.define(h, probedef(n));
}

// --- the base points every driver host declares ------------------------

fn identityBase(arg: ?*v.Value, ctx: ?*anyopaque) t.Err!?*v.Value {
    _ = ctx;
    return arg;
}

/// DOCS.md §4.3 defines `probe` as binding one hook point (`p`) and
/// wrapping one chain point (`c`), so a host without them cannot load
/// the probe at all — they are part of the contract's baseline rather
/// than a fixture convenience. `v` is the provider point the `provider`
/// probe defaults to.
pub fn hostopts(cmd: ?*v.Value) host.HostOptions {
    const points = v.vmap();
    inline for (.{ .{ "p", "hook" }, .{ "c", "chain" }, .{ "v", "provider" } }) |pair| {
        const m = v.vmap();
        v.set(m, "kind", v.vstr(pair[1]));
        v.set(points, pair[0], m);
    }

    const extra = v.get(cmd, "points");
    if (v.isMap(extra)) {
        // A `host` command REPLACES a base point rather than merging
        // into it, so an entry can redeclare `c` with its own base or
        // `v` as exclusive without inheriting the default's shape.
        for (v.keys(extra)) |k| v.set(points, k, v.get(extra, k));
    }

    // Every chain point gets the identity base: the host owns it and a
    // plugin cannot replace it (§6.2).
    var bases = std.ArrayList(host.BaseFn).init(v.arena());
    for (v.keys(points)) |k| {
        const kind = v.get(v.get(points, k), "kind");
        if (v.isStr(kind) and std.mem.eql(u8, v.asStr(kind), "chain")) {
            bases.append(.{ .point = k, .func = identityBase }) catch @panic("oom");
        }
    }

    const d = v.get(cmd, "dependency");
    return .{
        .points = points,
        .bases = bases.items,
        .reserved = v.get(cmd, "reserved"),
        .keys = v.get(cmd, "keys"),
        .defaults = v.get(cmd, "defaults"),
        .profile = v.get(cmd, "profile"),
        // §11.3's strict reading. Absent means `restart`, which is the
        // default precisely because a station that cannot swap a
        // provider without a restart has lost the argument for having a
        // plugin system.
        .dependency = if (v.isStr(d)) v.asStr(d) else "",
    };
}

// --- the command interpreter -------------------------------------------

fn declspec(cmd: ?*v.Value) host.DeclareSpec {
    const options = v.get(cmd, "options");
    const def = v.get(cmd, "definition");
    const tag = v.get(cmd, "tag");
    return .{
        // PRESENT AND NOT NULL. Every driver builds its spec with all
        // four keys and a null for each absent one, so a presence test
        // reads an omitted `options` as an authored empty and wipes the
        // real ones.
        .options = if (v.isMap(options)) options else null,
        .order = v.get(cmd, "order"),
        .definition = if (v.isStr(def)) v.asStr(def) else "",
        .tag = if (v.isStr(tag)) v.asStr(tag) else "",
    };
}

fn cmdstr(cmd: ?*v.Value, key: []const u8) []const u8 {
    const x = v.get(cmd, key);
    return if (v.isStr(x)) v.asStr(x) else "";
}

const CmdResult = struct { host: *Host, produced: ?*v.Value = null, hasresult: bool = false };

/// One command. `produced` is set when the verb yields a result; §4.5
/// makes `result` the value of THE LAST COMMAND THAT PRODUCES ONE, so
/// "produced nothing" and "produced null" have to stay
/// distinguishable — which is why `hasresult` rides alongside.
fn docmd(h: *Host, cmd: ?*v.Value) t.Err!CmdResult {
    const verb = cmdstr(cmd, "do");
    const r = cmdstr(cmd, "ref");
    const pt = cmdstr(cmd, "point");
    const spec = declspec(cmd);
    const none = CmdResult{ .host = h };

    if (std.mem.eql(u8, verb, "host")) {
        const fresh = host.makehost(hostopts(cmd));
        try seed(fresh);
        return .{ .host = fresh };
    }

    if (std.mem.eql(u8, verb, "define")) {
        // §10.1's static registration: the definition ENTERS THE CATALOG
        // here, and registration is where its option shape is validated
        // (§9.4) — before any load, so a malformed shape fails at one
        // moment in every host rather than whenever a document happens
        // to exercise the key.
        //
        // §4.2's three keys, all of them live. `probe` names the PROBE
        // whose callbacks back the definition and `name` is what the
        // definition is called.
        const name = cmdstr(cmd, "name");
        var from = cmdstr(cmd, "probe");
        if (from.len == 0) from = name;
        const base = probe(from);
        const def = v.arena().create(catalog.Definition) catch @panic("oom");
        if (base) |b| def.* = b.* else def.* = .{ .name = "" };
        def.name = v.dupe(name);
        if (v.has(cmd, "shape")) def.shape = v.get(cmd, "shape");
        try host.define(h, def);
        return none;
    }

    if (std.mem.eql(u8, verb, "load")) {
        _ = try host.load(h, r, spec);
        return none;
    }
    if (std.mem.eql(u8, verb, "ready")) {
        // declare FIRST, so the ordering block and definition reach the
        // instance — `ready` walks the staircase, it does not carry
        // configuration of its own.
        _ = try host.declare(h, r, spec);
        _ = try host.ready(h, r);
        return none;
    }
    if (std.mem.eql(u8, verb, "activate")) {
        _ = try host.activate(h, r);
        return none;
    }
    if (std.mem.eql(u8, verb, "deactivate")) {
        _ = try host.deactivate(h, r);
        return none;
    }
    if (std.mem.eql(u8, verb, "unload")) {
        try host.unload(h, r);
        return none;
    }
    if (std.mem.eql(u8, verb, "close")) {
        try host.close(h);
        return none;
    }
    if (std.mem.eql(u8, verb, "apply")) {
        try host.apply(h, v.get(cmd, "doc"), v.get(cmd, "profile"));
        return none;
    }
    if (std.mem.eql(u8, verb, "options")) {
        try host.setoptions(h, r, v.get(cmd, "patch"));
        return none;
    }

    if (std.mem.eql(u8, verb, "declare")) {
        const e = try host.declare(h, r, spec);
        return .{ .host = h, .produced = v.vstr(e.ref), .hasresult = true };
    }
    if (std.mem.eql(u8, verb, "hostdeclare")) {
        // §9.1's host-owned path: the embedding host installing the
        // instance whose name it reserved.
        var s2 = spec;
        s2.hostowned = true;
        const e = try host.declare(h, r, s2);
        return .{ .host = h, .produced = v.vstr(e.ref), .hasresult = true };
    }

    if (std.mem.eql(u8, verb, "list")) return .{ .host = h, .produced = host.list(h), .hasresult = true };
    if (std.mem.eql(u8, verb, "emit")) return .{ .host = h, .produced = try host.emit(h, pt, v.get(cmd, "arg")), .hasresult = true };
    if (std.mem.eql(u8, verb, "chain")) return .{ .host = h, .produced = try host.call(h, pt, v.get(cmd, "arg")), .hasresult = true };
    if (std.mem.eql(u8, verb, "provider")) return .{ .host = h, .produced = try host.provider(h, pt, v.get(cmd, "arg")), .hasresult = true };
    if (std.mem.eql(u8, verb, "shadowed")) return .{ .host = h, .produced = try host.shadowed(h, pt), .hasresult = true };
    if (std.mem.eql(u8, verb, "export")) return .{ .host = h, .produced = try host.exports(h, cmdstr(cmd, "key")), .hasresult = true };
    if (std.mem.eql(u8, verb, "capability")) return .{ .host = h, .produced = host.capability(h, cmdstr(cmd, "name")), .hasresult = true };
    if (std.mem.eql(u8, verb, "trace")) return .{ .host = h, .produced = host.trace(h), .hasresult = true };
    if (std.mem.eql(u8, verb, "order")) return .{ .host = h, .produced = try host.order(h, pt), .hasresult = true };
    if (std.mem.eql(u8, verb, "seq")) {
        const e = try host.instance(h, r);
        return .{ .host = h, .produced = if (e) |x| v.vnum(x.seq) else v.vnull(), .hasresult = true };
    }
    if (std.mem.eql(u8, verb, "pos")) {
        const e = try host.instance(h, r);
        return .{ .host = h, .produced = if (e) |x| v.vnum(x.pos) else v.vnull(), .hasresult = true };
    }
    if (std.mem.eql(u8, verb, "inner")) {
        const e = try host.instance(h, r);
        const inner = if (e) |x| x.inner else null;
        return .{ .host = h, .produced = if (inner) |x| host.list(x) else v.vnull(), .hasresult = true };
    }

    if (std.mem.eql(u8, verb, "call")) {
        const e = (try host.instance(h, r)) orelse
            return t.fail("plugin_not_loaded", v.print("no such instance: {s}", .{r}), null);
        const method = cmdstr(cmd, "method");
        if (method.len == 0) return none;
        if (std.mem.eql(u8, method, "bump")) {
            addCount(e);
            return none;
        }
        if (std.mem.eql(u8, method, "count")) {
            return .{ .host = h, .produced = v.vnum(num(v.get(e.state, "count"))), .hasresult = true };
        }
        if (std.mem.eql(u8, method, "unwound")) {
            const u = v.get(e.state, "unwound");
            return .{ .host = h, .produced = if (v.isList(u)) u else v.vlist(), .hasresult = true };
        }
        if (std.mem.eql(u8, method, "position")) {
            // Reached through the instance api, which is where §6.6 puts
            // it — a plugin asks about itself.
            return .{ .host = h, .produced = try host.position(e, pt), .hasresult = true };
        }
        if (std.mem.eql(u8, method, "stray")) {
            // A release from OUTSIDE a lifecycle callback. The scope
            // belongs to the activation; a call from anywhere else has
            // no scope to belong to, so it raises.
            try host.release(e, null, null);
            return none;
        }
        return none;
    }

    return t.fail("plugin_bad_state", v.print("unknown driver command: {s}", .{verb}), null);
}

pub fn drive(cmds: ?*v.Value) t.Err!?*v.Value {
    var h = host.makehost(hostopts(null));
    try seed(h);

    // §4.5: `result` is the value of THE LAST COMMAND THAT PRODUCES ONE.
    // Storing it and continuing — rather than returning at the first
    // producing command — is what lets an entry emit and then inspect,
    // which most of `point` needs.
    var last: ?*v.Value = null;
    var haslast = false;

    for (v.items(cmds)) |cmd| {
        const res = docmd(h, cmd) catch {
            // TAKE FIRST: everything below can raise, and `pending`
            // holds one error.
            const err = t.take();
            // §4.1: `catch` records the raise and lets the run continue,
            // which is the only way to observe a `failed` instance —
            // §5.2's whole claim is that it stays registered and
            // inspectable.
            if (!v.truthy(v.get(cmd, "catch"))) return t.reraise(err);
            continue;
        };
        h = res.host;
        if (res.hasresult) {
            last = res.produced;
            haslast = true;
        }
    }

    return host.observable(h, last, haslast);
}
