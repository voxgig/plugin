//! The corpus reader and the entry check (DOCS.md §4.5, §15).
//!
//! THE PLUGIN LIBRARY MUST NEVER BE USED TO IMPLEMENT ITS OWN TESTS
//! (AGENTS.md prime directive 6), and that covers the TYPING as well as
//! the comparison. This file asks `value.zig` what a value is, because
//! `value.zig` is the JSON reader rather than the library under test —
//! but `same`, `truthy` and the merge semantics the corpus pins are all
//! re-derived here rather than borrowed from `types.zig`.
//!
//! NO TEST FRAMEWORK: §16 permits one runtime dependency, zig has no
//! port of it, and zig's own `std.testing` is a discovery harness rather
//! than something that can drive a data corpus. The runner is a `main`
//! that counts.

const std = @import("std");
const v = @import("../src/value.zig");
const t = @import("../src/types.zig");

var loaded: ?*v.Value = null;

/// Modern zig HANDS `main` its I/O and its environment rather than
/// letting a library reach for them; `main` parks them here before the
/// first corpus read. On the legacy toolchain there is nothing to park.
pub var io: if (v.modern) ?std.Io else void = if (v.modern) null else {};
pub var env: if (v.modern) ?*const std.process.Environ.Map else void = if (v.modern) null else {};

fn specpath() []const u8 {
    const given = if (v.modern) env.?.get("PLUGIN_SPEC") else std.posix.getenv("PLUGIN_SPEC");
    return given orelse "../spec/plugin.json";
}

fn readspec(path: []const u8) []const u8 {
    if (v.modern) {
        return std.Io.Dir.cwd().readFileAlloc(io.?, path, v.arena(), .unlimited) catch {
            std.debug.print("zig: cannot read {s}\n", .{path});
            std.process.exit(2);
        };
    }
    const f = std.fs.cwd().openFile(path, .{}) catch {
        std.debug.print("zig: cannot open {s}\n", .{path});
        std.process.exit(2);
    };
    defer f.close();
    return f.readToEndAlloc(v.arena(), 1 << 28) catch {
        std.debug.print("zig: cannot read {s}\n", .{path});
        std.process.exit(2);
    };
}

/// The whole corpus, parsed once. Exits loudly if the JSON is missing or
/// malformed: a runner that reports zero tests as a pass is the failure
/// mode doc/plan/handover.md §4 exists to prevent.
pub fn corpus() *v.Value {
    if (loaded) |c| return c;
    const path = specpath();
    const text = readspec(path);
    var err: []const u8 = "";
    const parsed = v.parse(text, &err) orelse {
        std.debug.print("zig: {s} is not valid JSON: {s}\n", .{ path, err });
        std.process.exit(2);
    };
    // Version 1 turns on strict entry validation in every runner. A
    // corpus that lost its version marker is a corpus whose shape nobody
    // checked, so refuse it rather than run against it.
    const version = v.get(v.get(parsed, "PLUGIN"), "version");
    if (!v.isNum(version) or v.asNum(version) != 1) {
        std.debug.print("zig: unsupported spec version\n", .{});
        std.process.exit(2);
    }
    loaded = parsed;
    return parsed;
}

pub fn section(name: []const u8) *v.Value {
    const s = v.get(v.get(corpus(), "primary"), name);
    if (!v.isMap(s)) {
        std.debug.print("zig: no such corpus section: {s}\n", .{name});
        std.process.exit(2);
    }
    return s;
}

/// A stable label, so a failure names the entry rather than an index.
pub fn label(group: []const u8, i: usize, entry: ?*v.Value) []const u8 {
    const id = v.get(entry, "id");
    if (v.isStr(id)) return v.asStr(id);
    return v.print("{s}#{d}", .{ group, i });
}

/// Deep equality over spec values: key order never matters, list order
/// always does. Written here, not taken from the library.
pub fn equal(a: ?*v.Value, b: ?*v.Value) bool {
    const anull = v.isNull(a);
    const bnull = v.isNull(b);
    if (anull or bnull) return anull and bnull;
    if (a.?.kind != b.?.kind) return false;
    return switch (a.?.kind) {
        .boolean => v.asBool(a) == v.asBool(b),
        .num => v.asNum(a) == v.asNum(b),
        .str => std.mem.eql(u8, v.asStr(a), v.asStr(b)),
        .list => blk: {
            if (v.len(a) != v.len(b)) break :blk false;
            for (v.items(a), 0..) |x, i| {
                if (!equal(x, v.at(b, i))) break :blk false;
            }
            break :blk true;
        },
        .map => blk: {
            if (v.len(a) != v.len(b)) break :blk false;
            for (v.keys(a)) |k| {
                if (!v.has(b, k)) break :blk false;
                if (!equal(v.get(a, k), v.get(b, k))) break :blk false;
            }
            break :blk true;
        },
        else => true,
    };
}

/// A LITERAL-WITH-ANCHORS MATCHER, NOT A REGEX ENGINE.
///
/// Zig's standard library carries no regex engine, and §16 permits no
/// second dependency to supply one. Every pattern the corpus writes is a
/// literal, optionally `^`-anchored, so this unescapes and compares —
/// and PANICS on any unescaped metacharacter, because the one thing a
/// hand-rolled matcher must never do is quietly report a mismatch it
/// could not evaluate.
///
/// Same shape as `lua/test/corpus.lua`'s `regexlite`, deliberately.
pub fn regexlite(pattern: []const u8, text: []const u8) bool {
    var lit = v.List(u8).init(v.arena());
    var anchorstart = false;
    var anchorend = false;
    var i: usize = 0;
    while (i < pattern.len) {
        const c = pattern[i];
        if (c == '\\' and i + 1 < pattern.len) {
            lit.append(pattern[i + 1]) catch @panic("oom");
            i += 2;
        } else if (c == '^' and i == 0) {
            anchorstart = true;
            i += 1;
        } else if (c == '$' and i == pattern.len - 1) {
            anchorend = true;
            i += 1;
        } else {
            if (std.mem.indexOfScalar(u8, "*+?()[]{}|.", c) != null) {
                std.debug.print("corpus regex needs a real engine, which this port does not have: {s}\n", .{pattern});
                std.process.exit(3);
            }
            lit.append(c) catch @panic("oom");
            i += 1;
        }
    }
    const l = lit.items;
    if (anchorstart and anchorend) return std.mem.eql(u8, text, l);
    if (anchorstart) return std.mem.startsWith(u8, text, l);
    if (anchorend) return std.mem.endsWith(u8, text, l);
    return std.mem.indexOf(u8, text, l) != null;
}

/// `match` semantics: __EXISTS__, __UNDEF__, __NULL__, /regex/, and
/// partial map matching. `present` distinguishes an absent key from one
/// holding null, which __UNDEF__ and __NULL__ exist to tell apart.
pub fn matches(expect: ?*v.Value, actual: ?*v.Value, present: bool) bool {
    if (v.isStr(expect)) {
        const s = v.asStr(expect);
        if (std.mem.eql(u8, s, "__EXISTS__")) return present and !v.isNull(actual);
        if (std.mem.eql(u8, s, "__UNDEF__")) return !present;
        if (std.mem.eql(u8, s, "__NULL__")) return present and v.isNull(actual);
        if (s.len > 2 and s[0] == '/' and s[s.len - 1] == '/') {
            if (!v.isStr(actual)) return false;
            return regexlite(s[1 .. s.len - 1], v.asStr(actual));
        }
    }

    if (v.isList(expect)) {
        if (!v.isList(actual) or v.len(expect) != v.len(actual)) return false;
        for (v.items(expect), 0..) |x, i| {
            if (!matches(x, v.at(actual, i), true)) return false;
        }
        return true;
    }

    if (v.isMap(expect)) {
        if (!v.isMap(actual)) return false;
        for (v.sortedKeys(expect)) |k| {
            if (!matches(v.get(expect, k), v.get(actual, k), v.has(actual, k))) return false;
        }
        return true;
    }

    return equal(expect, actual);
}

/// The subject produces the entry's observable, or raises.
pub const Subject = *const fn (?*v.Value) t.Err!?*v.Value;

pub const Tally = struct { entries: usize = 0, failures: usize = 0 };

/// Run one entry and report the disagreement, or null when it passes.
///
/// The three combinations the spec format allows are enforced here as
/// well as at build time, because a runner that quietly accepted `err`
/// beside `out` would let a contradictory entry pass.
pub fn check(entry: ?*v.Value, subject: Subject) ?[]const u8 {
    const haserr = v.has(entry, "err");
    const hasout = v.has(entry, "out");
    const hasmatch = v.has(entry, "match");

    if (haserr and hasout) return "entry has both err and out";
    if (!haserr and !hasout and !hasmatch) return "entry asserts nothing";

    var value: ?*v.Value = null;
    var raised: ?t.PluginError = null;
    if (subject(entry)) |ok| {
        value = ok;
    } else |_| {
        raised = t.take();
    }

    if (haserr) {
        const e = raised orelse return v.print("expected a raise, got: {s}", .{v.json(value)});
        const want = v.get(entry, "err");
        // Errors compare by CODE (§12). Message wording is a port's own
        // business; pinning it would make every translation a corpus
        // change.
        if (v.isStr(want) and !std.mem.eql(u8, e.code, v.asStr(want))) {
            return v.print("expected code {s}, got {s} ({s})", .{ v.asStr(want), e.code, e.message });
        }
        if (hasmatch) {
            const errv = v.vmap();
            v.set(errv, "code", v.vstr(e.code));
            v.set(errv, "message", v.vstr(e.message));
            v.set(errv, "name", v.vstr("PluginError"));
            const got = v.vmap();
            v.set(got, "err", errv);
            if (!matches(v.get(entry, "match"), got, true)) {
                return v.print("error did not match {s}, got {s}", .{ v.json(v.get(entry, "match")), v.json(got) });
            }
        }
        return null;
    }

    if (raised) |e| return v.print("unexpected raise: {s} {s}", .{ e.code, e.message });

    if (hasout and !equal(v.get(entry, "out"), value)) {
        return v.print("expected {s}, got {s}", .{ v.json(v.get(entry, "out")), v.json(value) });
    }

    if (hasmatch) {
        const got = v.vmap();
        v.set(got, "in", v.get(entry, "in"));
        v.set(got, "out", value);
        if (!matches(v.get(entry, "match"), got, true)) {
            return v.print("did not match {s}, got out={s}", .{ v.json(v.get(entry, "match")), v.json(value) });
        }
    }

    return null;
}

pub fn runGroup(tally: *Tally, sec: []const u8, group: []const u8, entries: ?*v.Value, subject: Subject) void {
    const set = v.get(entries, "set");
    if (!v.isList(set)) return;
    for (v.items(set), 0..) |entry, i| {
        tally.entries += 1;
        const why = check(entry, subject) orelse continue;
        tally.failures += 1;
        // The label is the entry's own `id` when it has one, and those
        // already carry the section — printing the section again would
        // read `ref/ref/canon#trailing`.
        const l = label(group, i, entry);
        if (v.has(entry, "id")) {
            std.debug.print("{s}: {s}\n", .{ l, why });
        } else {
            std.debug.print("{s}/{s}: {s}\n", .{ sec, l, why });
        }
    }
}

pub const Lookup = *const fn ([]const u8) ?Subject;

pub fn runSection(tally: *Tally, sec: []const u8, lookup: Lookup) void {
    const groups = section(sec);
    // SORTED, so a failure names the same group in the same place on
    // every run.
    for (v.sortedKeys(groups)) |name| {
        const s = lookup(name) orelse {
            // A group the runner does not know is a group silently not
            // run, which is worse than a failure.
            tally.failures += 1;
            std.debug.print("{s}/{s}: no subject for this group\n", .{ sec, name });
            continue;
        };
        runGroup(tally, sec, name, v.get(groups, name), s);
    }
}
