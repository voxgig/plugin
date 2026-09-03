//! The zig port's test runner.
//!
//! NO TEST FRAMEWORK (§16): a `main` that counts. It reports the entry
//! count as well as the pass, because "all pass" over zero entries is
//! the failure doc/plan/handover.md §4 warns about.

const std = @import("std");
const v = @import("../src/value.zig");
const t = @import("../src/types.zig");
const ref = @import("../src/ref.zig");
const version = @import("../src/version.zig");
const cap = @import("../src/capability.zig");
const resolve = @import("../src/resolve.zig");
const env = @import("../src/env.zig");
const cfg = @import("../src/config.zig");
const graph = @import("../src/graph.zig");
const corpus = @import("corpus.zig");
const driver = @import("driver.zig");

// --- ref: the four pure functions -------------------------------------

fn subCheckname(e: ?*v.Value) t.Err!?*v.Value {
    return v.vbool(ref.checkname(v.get(e, "in")));
}
fn subChecktag(e: ?*v.Value) t.Err!?*v.Value {
    return v.vbool(ref.checktag(v.get(e, "in")));
}
fn subParseref(e: ?*v.Value) t.Err!?*v.Value {
    return try ref.parseref(v.get(e, "in"));
}
fn subFormatref(e: ?*v.Value) t.Err!?*v.Value {
    const args = v.get(e, "args");
    return v.vstr(try ref.formatref(v.at(args, 0), v.at(args, 1)));
}
fn subCanonref(e: ?*v.Value) t.Err!?*v.Value {
    return v.vstr(try ref.canonref(v.get(e, "in")));
}

/// §15.3's `ref` section, group by group. EVERY group must have a
/// subject: a group the runner does not know is a group silently not
/// run, which is worse than a failure.
fn refSubject(group: []const u8) ?corpus.Subject {
    const eq = std.mem.eql;
    if (eq(u8, group, "name") or eq(u8, group, "bound")) return subCheckname;
    if (eq(u8, group, "tag") or eq(u8, group, "boundtag")) return subChecktag;
    if (eq(u8, group, "parse") or eq(u8, group, "parsebad")) return subParseref;
    if (eq(u8, group, "format") or eq(u8, group, "formatbad")) return subFormatref;
    if (eq(u8, group, "canon")) return subCanonref;
    return null;
}

// --- version: the range grammar and the one predicate -----------------

fn subParserange(e: ?*v.Value) t.Err!?*v.Value {
    return try version.parserange(v.get(e, "in"));
}
fn subSatisfies(e: ?*v.Value) t.Err!?*v.Value {
    const in = v.get(e, "in");
    return v.vbool(try version.satisfies(v.get(in, "version"), v.get(in, "range")));
}
fn versionSubject(group: []const u8) ?corpus.Subject {
    const eq = std.mem.eql;
    if (eq(u8, group, "range") or eq(u8, group, "rangebad")) return subParserange;
    if (eq(u8, group, "satisfies")) return subSatisfies;
    return null;
}

// --- capability: matching and the total rank --------------------------

fn subResolvecapability(e: ?*v.Value) t.Err!?*v.Value {
    const in = v.get(e, "in");
    return cap.resolvecapability(v.get(in, "req"), v.get(in, "candidates"));
}
fn capabilitySubject(group: []const u8) ?corpus.Subject {
    const eq = std.mem.eql;
    if (eq(u8, group, "match") or eq(u8, group, "nested") or eq(u8, group, "rank")) return subResolvecapability;
    return null;
}

// --- resolve: name to candidate module ids ----------------------------

fn subCandidates(e: ?*v.Value) t.Err!?*v.Value {
    const in = v.get(e, "in");
    return resolve.resolvecandidates(v.get(in, "name"), v.get(in, "sources"));
}
fn subFrom(e: ?*v.Value) t.Err!?*v.Value {
    return resolve.resolvefrom(v.get(e, "in"));
}
fn resolveSubject(group: []const u8) ?corpus.Subject {
    const eq = std.mem.eql;
    if (eq(u8, group, "candidates")) return subCandidates;
    if (eq(u8, group, "from")) return subFrom;
    return null;
}

// --- env: the lossy encoding, and its collision -----------------------

fn subApplyenv(e: ?*v.Value) t.Err!?*v.Value {
    return try env.applyenv(v.get(e, "in"));
}
/// Every group in `env` is one call: the section is a single pure
/// function over the whole input.
fn envSubject(group: []const u8) ?corpus.Subject {
    _ = group;
    return subApplyenv;
}

// --- config: normalization and the ten-level ladder -------------------

fn subNormalizeconfig(e: ?*v.Value) t.Err!?*v.Value {
    return try cfg.normalizeconfig(v.get(e, "in"));
}
fn subResolveoptions(e: ?*v.Value) t.Err!?*v.Value {
    return try cfg.resolveoptions(v.get(e, "in"));
}
/// The prefix IS the dispatch: `norm*` groups normalize, `opt*` groups
/// resolve. A group with neither prefix gets no subject and fails
/// loudly, rather than being silently skipped.
fn configSubject(group: []const u8) ?corpus.Subject {
    if (std.mem.startsWith(u8, group, "norm")) return subNormalizeconfig;
    if (std.mem.startsWith(u8, group, "opt")) return subResolveoptions;
    return null;
}

// --- graph: resolved/blocked, and the explanation ---------------------

fn subResolvegraph(e: ?*v.Value) t.Err!?*v.Value {
    return graph.resolvegraph(v.get(e, "in"));
}
fn graphSubject(group: []const u8) ?corpus.Subject {
    const eq = std.mem.eql;
    if (eq(u8, group, "resolve") or eq(u8, group, "blocked")) return subResolvegraph;
    return null;
}

// --- the twelve DRIVER sections ---------------------------------------

/// Every entry carries `cmd`, and a port needs DOCS.md §4 to run them —
/// the probe catalog, the command vocabulary, and the canonical
/// observable {status, open, log, result}. Corpus files alone are not
/// enough, which is why C2 shipped both together.
fn subDrive(e: ?*v.Value) t.Err!?*v.Value {
    return driver.drive(v.get(e, "cmd"));
}
fn driverSubject(group: []const u8) ?corpus.Subject {
    _ = group;
    return subDrive;
}

pub fn main() !void {
    var tally = corpus.Tally{};

    corpus.runSection(&tally, "ref", refSubject);
    corpus.runSection(&tally, "version", versionSubject);
    corpus.runSection(&tally, "capability", capabilitySubject);
    corpus.runSection(&tally, "resolve", resolveSubject);
    corpus.runSection(&tally, "env", envSubject);
    corpus.runSection(&tally, "config", configSubject);
    corpus.runSection(&tally, "graph", graphSubject);

    // The driver sections, in §15.3's order. Each entry is a command
    // list against a fresh host.
    const DRIVER = [_][]const u8{
        "lifecycle", "order",    "point", "export", "depend", "declare",
        "state",     "resource", "nest",  "trace",  "apply",  "error",
    };
    for (DRIVER) |s| corpus.runSection(&tally, s, driverSubject);

    const out = std.io.getStdOut().writer();
    if (tally.entries == 0) {
        try out.print("zig: no corpus entries ran\n", .{});
        std.process.exit(1);
    }
    if (tally.failures > 0) {
        try out.print("\nzig: {d} failure(s) of {d} entries\n", .{ tally.failures, tally.entries });
        std.process.exit(1);
    }
    try out.print("zig: {d} corpus entries, all pass\n", .{tally.entries});
}
