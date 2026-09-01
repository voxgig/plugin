import VoxgigPlugin

/// The corpus runner.
///
/// Reads spec/plugin.json - the COMMITTED artifact, not the aontu source -
/// exactly as every other port's runner does. No port needs a Node toolchain to
/// run its tests, and this one does not get a private door into the source
/// either.
///
/// A group name selects the subject. That is the whole dispatch, and it is
/// deliberately dumb: a runner that inferred the subject from the entry's shape
/// would silently run the wrong function when an entry was mistyped.
enum Corpus {

    /// A `Value?` is the sentinel: nil means "this key was not present", which
    /// is exactly the distinction `__UNDEF__` and `__NULL__` pin, and swift
    /// already has a type for it.
    static func section(_ spec: Value, _ name: String) throws -> [String: [Value]] {
        guard let sec = spec.at("primary").get(name) else {
            throw DriverError("no such corpus section: \(name)")
        }
        var out: [String: [Value]] = [:]
        for group in sec.keys where group != "DEF" {
            let body = sec.at(group)
            guard body.isMap, body.at("set").isList else { continue }
            out[group] = body.at("set").items
        }
        return out
    }

    /// A stable label, so a failure names the entry rather than an index.
    static func label(_ group: String, _ i: Int, _ entry: Value) -> String {
        return entry.at("id").asString ?? "\(group)#\(i)"
    }

    /// Partial match: every key the expectation names must agree, and keys it
    /// does not name are ignored. `__EXISTS__` asserts presence without pinning
    /// a value; `/re/` matches a string as a regular expression.
    static func matches(_ expect: Value, _ actual: Value?) -> Bool {
        if expect == .str("__EXISTS__") { return actual != nil && !actual!.isNull }
        if expect == .str("__UNDEF__") { return actual == nil }
        if expect == .str("__NULL__") { return actual != nil && actual!.isNull }

        let got = actual ?? .null

        if let pattern = expect.asString, pattern.count > 2,
           pattern.hasPrefix("/"), pattern.hasSuffix("/") {
            guard let text = got.asString else { return false }
            return Rex.match(String(pattern.dropFirst().dropLast()), text)
        }

        if case .list(let want) = expect {
            guard case .list(let g) = got, want.count == g.count else { return false }
            return zip(want, g).allSatisfy { matches($0, $1) }
        }

        if case .map = expect {
            guard got.isMap else { return false }
            return expect.keys.allSatisfy { matches(expect.at($0), got.get($0)) }
        }

        return expect == got
    }

    /// Run one entry against a subject and report the disagreement, if any.
    ///
    /// The three combinations the spec format allows are enforced here as well
    /// as at build time, because a runner that quietly accepted `err` beside
    /// `out` would let a contradictory entry pass.
    static func check(_ entry: Value, _ subject: (Value) throws -> Value) -> String? {
        if entry.has("err") && entry.has("out") { return "entry has both err and out" }

        var value = Value.null
        var raised: Error?
        do { value = try subject(entry) } catch { raised = error }

        if entry.has("err") {
            guard let e = raised else {
                return "expected a raise, got: \(value.json)"
            }
            // Errors compare by CODE (section 12). Message wording is a port's
            // own business, and pinning it would make every translation a corpus
            // change.
            let want = entry.at("err")
            let got = Types.codeOf(e)
            if want != .bool(true) && .str(got) != want {
                return "expected code \(want.json), got \(got) (\(Types.messageOf(e)))"
            }
            if entry.has("match") {
                let shown = Value.map(["err": .map([
                    "code": .str(got),
                    "message": .str(Types.messageOf(e)),
                    "name": .str("PluginError"),
                ])])
                if !matches(entry.at("match"), shown) {
                    return "error did not match \(entry.at("match").json), "
                        + "got \(shown.json)"
                }
            }
            return nil
        }

        if let e = raised {
            return "unexpected raise: \(Types.codeOf(e)) \(Types.messageOf(e))"
        }

        if entry.has("out"), entry.at("out") != value {
            return "expected \(entry.at("out").json), got \(value.json)"
        }

        if entry.has("match") {
            let shown = Value.map(["in": entry.at("in"), "out": value])
            if !matches(entry.at("match"), shown) {
                return "did not match \(entry.at("match").json), got out=\(value.json)"
            }
        }

        if !entry.has("out") && !entry.has("match") { return "entry asserts nothing" }
        return nil
    }
}

/// The regular-expression subset the corpus actually uses, and NOTHING MORE.
///
/// Ten expectations use `/re/`, and every one of them is a literal with
/// backslash escapes plus at most a leading `^`. Swift's stdlib has no regex on
/// Linux - `NSRegularExpression` lives in Foundation - so rather than import it
/// for ten substring searches, this implements the subset and TRAPS ON ANY
/// METACHARACTER IT DOES NOT HANDLE. The day the corpus adds a real pattern,
/// this port fails loudly instead of quietly matching the wrong thing.
enum Rex {

    static func match(_ pattern: String, _ text: String) -> Bool {
        var body = Substring(pattern)
        let anchored = body.hasPrefix("^")
        if anchored { body = body.dropFirst() }

        var literal = ""
        var escaped = false
        for c in body {
            if escaped {
                literal.append(c)
                escaped = false
                continue
            }
            if c == "\\" {
                escaped = true
                continue
            }
            if ".*+?()[]{}|$^".contains(c) {
                fatalError(
                    "corpus regular expression uses '\(c)', which this port's "
                        + "matcher does not implement: \(pattern)"
                )
            }
            literal.append(c)
        }

        return anchored ? text.hasPrefix(literal) : contains(text, literal)
    }

    static func contains(_ text: String, _ needle: String) -> Bool {
        if needle.isEmpty { return true }
        let t = Array(text)
        let n = Array(needle)
        if n.count > t.count { return false }
        for i in 0 ... (t.count - n.count) {
            if Array(t[i ..< i + n.count]) == n { return true }
        }
        return false
    }
}
