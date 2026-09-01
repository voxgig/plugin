import VoxgigPlugin

#if canImport(Glibc)
import Glibc
#endif

/// The whole suite: pure sections by direct call, driver sections by command
/// list, and a coverage guard above both.
///
/// A plain runner rather than XCTest or swift-testing, for the same reason the
/// port has no `Package.swift` dependencies: a conformance suite whose only job
/// is to run one corpus and report which entries disagree does not need a
/// framework, and adding one would make `make test` depend on a resolver nobody
/// else in this repo has.
///
/// THE ONLY `import Foundation` IN THIS PORT WOULD BE HERE, AND IT IS NOT: the
/// corpus file is read through `Glibc`, and the ten `/re/` expectations go
/// through `Rex`. The library imports Foundation nowhere at all.
var failures: [String] = []
var ranSections = 0
var ranEntries = 0

let pureSections = ["ref", "env", "version", "capability", "graph", "resolve", "config"]
let driverSections = [
    "lifecycle", "order", "point", "export", "depend",
    "declare", "state", "resource", "nest", "trace", "apply", "error",
]

func readFile(_ path: String) -> String {
    guard let handle = fopen(path, "rb") else {
        fatalError("cannot read \(path)")
    }
    defer { fclose(handle) }
    var bytes: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = fread(&buffer, 1, buffer.count, handle)
        if n <= 0 { break }
        bytes.append(contentsOf: buffer[0 ..< n])
    }
    return String(decoding: bytes, as: UTF8.self)
}

func inOf(_ e: Value) -> Value { return e.at("in") }

func argAt(_ e: Value, _ i: Int) -> Value {
    let args = e.at("args").items
    return i < args.count ? args[i] : .null
}

/// Dispatch every group, and fail on a group the runner does not know - a group
/// silently not run is worse than a failure.
func runSection(
    _ spec: Value, _ name: String,
    _ subjectFor: (String) -> ((Value) throws -> Value)?
) throws {
    let groups = try Corpus.section(spec, name)
    ranSections += 1
    for group in groups.keys.sorted() {
        guard let fn = subjectFor(group) else {
            failures.append("\(name): corpus group with no subject: \(group)")
            continue
        }
        for (i, entry) in groups[group]!.enumerated() {
            ranEntries += 1
            if let why = Corpus.check(entry, fn) {
                failures.append("\(name)/\(Corpus.label(group, i, entry)): \(why)")
            }
        }
    }
}

/// The common case: a group name selects the subject directly.
func runMapped(
    _ spec: Value, _ name: String, _ subjects: [String: (Value) throws -> Value]
) throws {
    try runSection(spec, name) { subjects[$0] }
}

let spec = try Json.parse(readFile("../spec/plugin.json"))

try runMapped(spec, "ref", [
    "parse": { try Refs.parseRef(inOf($0)) },
    "parsebad": { try Refs.parseRef(inOf($0)) },
    "format": { .str(try Refs.formatRef(argAt($0, 0), argAt($0, 1))) },
    "formatbad": { .str(try Refs.formatRef(argAt($0, 0), argAt($0, 1))) },
    "canon": { .str(try Refs.canonRef(inOf($0))) },
    "name": { .bool(Refs.checkName(inOf($0))) },
    "tag": { .bool(Refs.checkTag(inOf($0))) },
    "bound": { .bool(Refs.checkName(inOf($0))) },
    "boundtag": { .bool(Refs.checkTag(inOf($0))) },
])

let env: (Value) throws -> Value = { try Env.applyEnv(inOf($0)) }
try runMapped(spec, "env", [
    "option": env, "value": env, "toggle": env,
    "profile": env, "ambiguous": env, "reserved": env,
])

let rng: (Value) throws -> Value = { try Version.parseRange(inOf($0)) }
try runMapped(spec, "version", [
    "range": rng, "rangebad": rng,
    "satisfies": {
        .bool(try Version.satisfies(inOf($0).at("version"), inOf($0).at("range")))
    },
])

let cap: (Value) throws -> Value = {
    .list(Capability.resolveCapability(inOf($0).at("req"), inOf($0).at("candidates")))
}
try runMapped(spec, "capability", ["match": cap, "nested": cap, "rank": cap])

let graph: (Value) throws -> Value = { Graph.resolveGraph(inOf($0)) }
try runMapped(spec, "graph", ["resolve": graph, "blocked": graph])

try runMapped(spec, "resolve", [
    "candidates": {
        .list(Resolve.resolveCandidates(
            inOf($0).at("name").asString ?? "", inOf($0).at("sources")
        ).map { .str($0) })
    },
    "from": { .list(Resolve.resolveFrom(inOf($0))) },
])

// `config` picks its subject by group PREFIX rather than by name, because the
// two functions split the section cleanly.
try runSection(spec, "config") { group in
    if group.hasPrefix("norm") { return { try Config.normalizeConfig(inOf($0)) } }
    if group.hasPrefix("opt") { return { try Config.resolveOptions(inOf($0)) } }
    return nil
}

for name in driverSections {
    try runSection(spec, name) { _ in { try Driver.drive($0.at("cmd").items) } }
}

// EVERY CORPUS SECTION IS RUN. The per-section dispatch already fails on a
// GROUP with no subject; this closes the level above, because a whole SECTION
// the runner never mentions is a section silently not run.
let primary = spec.at("primary")
let ran = pureSections + driverSections

// The corpus metadata block is what turns on strict entry validation in every
// runner, so a corpus that lost it must not silently downgrade this port's
// checking.
if spec.at("PLUGIN").at("version") != .num(1) {
    failures.append("corpus PLUGIN.version must be 1")
}

let missing = primary.keys.filter { !ran.contains($0) }.sorted()
if !missing.isEmpty {
    failures.append("corpus sections no test runs: " + missing.joined(separator: ", "))
}
let extra = ran.filter { !primary.has($0) }.sorted()
if !extra.isEmpty {
    failures.append(
        "tests name sections the corpus does not have: " + extra.joined(separator: ", ")
    )
}

// A floor, not a fixture: the corpus grows, and a run that suddenly covers a
// fraction of it is the failure worth catching.
if ranEntries < 400 {
    failures.append("only \(ranEntries) corpus entries reachable")
}

if failures.isEmpty {
    print("swift: \(ranEntries) corpus entries across \(ranSections) sections, all pass")
    exit(0)
}
for f in failures { FileHandleStderr.write(f + "\n") }
FileHandleStderr.write("\nswift: \(failures.count) failure(s) of \(ranEntries) entries\n")
exit(1)

enum FileHandleStderr {
    static func write(_ s: String) {
        fputs(s, stderr)
    }
}
