import VoxgigPlugin

/// The driver (DOCS.md section 4).
///
/// Every port implements this same small thing and nothing else is
/// port-specific: the probe catalog, the command interpreter, and the canonical
/// observable.
enum Driver {

    /// A sentinel for "this command produced nothing", so a command that
    /// legitimately produces nil - `export` of a missing key - still overwrites
    /// the previous result. A class instance, compared by identity, because
    /// `Value` has no case the corpus cannot also produce.
    static let nothing = Sentinel()

    final class Sentinel {}

    static func opt(_ i: Inst, _ k: String) -> Value { return i.options.at(k) }

    static func count(_ i: Inst) -> Double { return i.state.at("count").asDouble ?? 0 }

    static func bump(_ i: Inst, _ by: Double) {
        i.statePut("count", .num(count(i) + by))
    }

    static func declareProvides(_ i: Inst) {
        for prov in opt(i, "provides").items { i.provides(prov) }
    }

    static func boom(_ i: Inst, _ callback: String) throws {
        guard opt(i, "fail").asString == callback else { return }
        // `bare` raises WITHOUT a code - the ordinary library error section 12's
        // `plugin_<phase>_failed` codes exist to wrap.
        if opt(i, "bare").truthy {
            throw DriverError("probe failed at \(callback)")
        }
        throw Types.fail(
            opt(i, "code").asString ?? "plugin_\(callback)_failed",
            "probe failed at \(callback)"
        )
    }

    static func reenter(_ i: Inst, _ callback: String) throws {
        // A transition from inside a lifecycle callback (section 5.2).
        guard opt(i, "reenter").asString == callback else { return }
        try i.host.activate(.str(i.ref))
    }

    /// The points every driver host declares. DOCS.md section 4.3 defines
    /// `probe` as binding one hook point (`p`) and wrapping one chain point
    /// (`c`), so a host without them cannot load the probe at all - they are
    /// part of the contract's baseline rather than a fixture convenience. `v` is
    /// the provider point the `provider` probe defaults to.
    static func basePoints() -> [String: PointSpec] {
        return [
            "p": PointSpec(kind: "hook"),
            "c": PointSpec(kind: "chain", base: { a in a }),
            "v": PointSpec(kind: "provider"),
        ]
    }

    /// A `host` command REPLACES a base point rather than merging into it, so an
    /// entry can redeclare `c` with its own base or `v` as exclusive without
    /// inheriting the default's shape.
    static func withPoints(_ extra: Value = .null) -> [String: PointSpec] {
        var out = basePoints()
        for k in extra.keys {
            let spec = extra.at(k)
            out[k] = PointSpec(
                kind: spec.at("kind").asString ?? "hook",
                mode: spec.at("mode").asString ?? "emit",
                // A chain point declared by an entry keeps the base the driver
                // gives every `c`: the corpus writes `{"kind":"chain"}` and means
                // the identity base, which is what a JSON document can express.
                base: spec.at("kind").asString == "chain" ? { a in a } : nil,
                pin: spec.at("pin"),
                exclusive: spec.at("exclusive").truthy,
                dflt: spec.at("default")
            )
        }
        return out
    }

    static func record(_ name: String) -> Definition {
        return Definition(
            name: name,
            define: { i in bump(i, 0) },
            activate: { i in _ = try i.acquire() }
        )
    }

    /// Section 4.3's six probes. Their behaviour is as much the contract as the
    /// runner is - this is where twenty implementations of `noisy` are made to
    /// fail at the same callback in the same way.
    static func probes() -> [Definition] {
        let probe = Definition(
            name: "probe",
            define: { i in
                bump(i, 0)
                let band = opt(i, "band")
                // One hook binding (`p`) and one chain wrap (`c`) - the workhorse
                // shape DOCS.md section 4.3 specifies. `p` RETURNS NOTHING, as
                // the canonical's arrow-with-a-block does: in `bail` mode a
                // return is an answer, and a counter that answered with its own
                // count would make every hook that keeps one un-bailable.
                try i.bind("p", { _, _ in bump(i, 1); return .null }, band)
                // Wrap AFTER next, so the result spells the nesting left to
                // right: outermost first. Wrapping the ARGUMENT instead would
                // spell it backwards and make every chain expectation read wrong.
                try i.bind("c", { next, v in
                    let wrap = opt(i, "wrap").asString ?? ":"
                    let inner = try next!(v)
                    return .str(wrap + (inner.asString ?? inner.json))
                }, band)
                i.export("client", .str(i.ref))
                // The instance api itself, so the driver's `stray` command can
                // call `release` from OUTSIDE a lifecycle callback.
                i.export("inst", .opaque(i))
                declareProvides(i)
            },
            activate: { i in
                _ = try i.acquire()
                // Section 6.5: an instance that is itself a host. The outer owns
                // the inner's lifetime - registered in the scope, so it closes on
                // deactivate in the same reverse unwind as every other resource.
                let nest = opt(i, "nest")
                if nest.isNull { return }
                let inner = try i.nest(HostOptions(points: withPoints()))
                for d in probes() { try inner.catalog.add(d) }
                for r in nest.items { try inner.ready(r) }
            }
        )

        let noisy = Definition(
            name: "noisy",
            define: { i in bump(i, 0); try boom(i, "define") },
            activate: { i in
                // Acquire BEFORE the raise, so a failing activate has something
                // to leak if the scope does not unwind - which is the whole point
                // of the entry that asserts open == 0 afterwards.
                _ = try i.acquire()
                try reenter(i, "activate")
                try boom(i, "activate")
            },
            deactivate: { i in try boom(i, "deactivate") },
            close: { i in try boom(i, "close") }
        )

        let greedy = Definition(
            name: "greedy",
            define: { i in
                i.statePut("count", .num(0))
                // Section 8.1 puts resource capture in `activate`. `early` NAMES
                // the call that reaches for it in `define`, because `acquire` and
                // `release` carry the guard separately.
                if opt(i, "early").asString == "acquire" { _ = try i.acquire() }
                if opt(i, "early").asString == "release" { try i.release {} }
            },
            activate: { i in
                let n = opt(i, "acquire").asInt ?? 0
                let rel = opt(i, "release").asInt ?? 0
                var handles: [() -> Void] = []
                for _ in 0 ..< n { handles.append(try i.acquire()) }
                // Release some explicitly; the DIFFERENCE is what the instance
                // scope must unwind by itself (section 8.3), and that difference
                // is the whole test.
                for k in 0 ..< min(rel, handles.count) { handles[k]() }

                // `bind` is `early`'s counterpart for section 8.1's OTHER half.
                // Binding declaration belongs in `define`; this names the
                // callback that tries it from somewhere else.
                if opt(i, "bind").asString == "activate" {
                    try i.bind("p", { _, _ in .null })
                }

                // `mark` registers N FOREIGN releases - section 8.3's `release`,
                // the half `acquire` cannot exercise - each recording its own
                // index as it runs. THE RECORDED LIST IS THE ONLY THING THAT
                // DISTINGUISHES A REVERSE UNWIND FROM A FORWARD ONE.
                i.statePut("unwound", .list([]))
                for k in 0 ..< (opt(i, "mark").asInt ?? 0) {
                    try i.release {
                        // `markfail` makes the release RAISE - the only way
                        // section 8.3's `plugin_release_failed` and its `failed`
                        // status are reachable.
                        if opt(i, "markfail").truthy {
                            throw DriverError("release failed at \(k)")
                        }
                        i.statePut("unwound", .list(i.state.at("unwound").items
                            + [.num(Double(k))]))
                    }
                }
            },
            // `deactivate` completes the pair: the guard is on the PHASE, not on
            // "not define", and an entry exercising only one leaves the other's
            // mutation alive.
            deactivate: { i in
                if opt(i, "bind").asString == "deactivate" {
                    try i.bind("p", { _, _ in .null })
                }
            }
        )

        let dep = Definition(
            name: "dep",
            define: { i in
                i.statePut("count", .num(0))
                declareProvides(i)
                let exports = opt(i, "exports")
                for k in exports.keys { i.export(k, exports.at(k)) }
            },
            activate: { i in _ = try i.acquire() }
        )

        let provider = Definition(
            name: "provider",
            define: { i in
                i.statePut("count", .num(0))
                try i.bind(
                    opt(i, "point").asString ?? "v",
                    { _, _ in i.options.has("value") ? opt(i, "value") : .str(i.ref) },
                    opt(i, "band")
                )
                declareProvides(i)
            },
            activate: { i in _ = try i.acquire() }
        )

        return [
            probe, noisy, greedy, dep, provider,
            record("slow"), record("other"), record("adapter"), record("late"),
        ]
    }

    static func withProbes() throws -> Catalog { return try makeCatalog(probes()) }

    /// Run a command list and return section 4.5's observable. Stops at the
    /// first raise; the entry's `err` matches its code.
    static func drive(_ cmds: [Value]) throws -> Value {
        var host = makeHost(HostOptions(catalog: try withProbes(), points: withPoints()))

        // Section 4.5: `result` is the value of THE LAST COMMAND THAT PRODUCES
        // ONE. Storing it and continuing - rather than returning at the first
        // producing command - is what lets an entry emit and then inspect, which
        // most of `point` needs.
        var last = Value.null

        for cmd in cmds {
            do {
                let (next, value) = try doCmd(host, cmd)
                host = next
                if let v = value { last = v }
            } catch {
                // Section 4.1: `catch` records the raise and lets the run
                // continue, which is the only way to observe a `failed` instance
                // - section 5.2's whole claim is that it stays registered and
                // inspectable.
                guard cmd.at("catch") == .bool(true) else { throw error }
            }
        }
        return host.observable(last)
    }

    /// The second element is nil for a command that PRODUCES NOTHING, which is
    /// swift's spelling of every other port's sentinel: an `Optional<Value>`
    /// says it in the type, so a command returning `.null` still overwrites.
    static func doCmd(_ host: Host, _ cmd: Value) throws -> (Host, Value?) {
        let ref = cmd.at("ref")
        let point = cmd.at("point").asString
        let spec = Value.map([
            "options": cmd.at("options"),
            "order": cmd.at("order"),
            "definition": cmd.at("definition"),
            "tag": cmd.at("tag"),
        ])

        switch cmd.at("do").asString ?? "" {
        case "host":
            return (makeHost(HostOptions(
                catalog: try withProbes(),
                reserved: cmd.at("reserved").items.compactMap { $0.asString },
                points: withPoints(cmd.at("points")),
                // Section 11.3's strict reading. Absent means `restart`.
                dependency: cmd.at("dependency").asString ?? "restart",
                keys: cmd.at("keys"),
                defaults: cmd.at("defaults"),
                profile: cmd.at("profile").asString
            )), nil)
        // Section 10.1's static registration: the definition ENTERS THE
        // CATALOG here, and registration is where its option shape is
        // validated (section 9.4) - before any load, so a malformed shape
        // fails at one moment in every host rather than whenever a document
        // happens to exercise the key.
        //
        // The catalog is pre-seeded with the probe set, so re-registering a
        // probe by name is the identity this command has always been;
        // `shape` is what makes it do work. A name the probe set does not
        // hold registers a bare definition - enough to reach the catalog,
        // and never loaded.
        case "define":
            // Section 4.2's three keys, all of them live. `probe` names
            // the PROBE whose callbacks back the definition and `name` is
            // what the definition is called - two keys that ten entries
            // passed as equal strings, so a driver ignoring `probe` passed
            // them all.
            let dname = cmd.at("name").asString ?? ""
            let source = cmd.at("probe").asString ?? dname
            var definition = Definition(name: dname)
            for d in probes() where d.name == source {
                definition = Definition(
                    name: dname,
                    define: d.define,
                    activate: d.activate,
                    deactivate: d.deactivate,
                    close: d.close,
                    reconfigure: d.reconfigure,
                    shape: d.shape
                )
            }
            if cmd.has("shape") {
                definition.shape = cmd.at("shape")
            }
            try host.define(definition)
            return (host, nil)
        case "load": try host.load(ref, spec); return (host, nil)
        case "ready":
            // declare FIRST, so the ordering block and definition reach the
            // instance - `ready` walks the staircase, it does not carry
            // configuration of its own.
            try host.declare(ref, spec)
            try host.ready(ref)
            return (host, nil)
        case "activate": try host.activate(ref); return (host, nil)
        case "deactivate": try host.deactivate(ref); return (host, nil)
        case "unload": try host.unload(ref); return (host, nil)
        case "apply":
            try host.apply(cmd.at("doc"), cmd.at("profile").asString)
            return (host, nil)
        case "options": try host.options(ref, cmd.at("patch")); return (host, nil)
        case "close": try host.close(); return (host, nil)
        case "list": return (host, host.list())
        case "emit": return (host, try host.emit(point!, cmd.at("arg")))
        case "chain": return (host, try host.call(point!, cmd.at("arg")))
        case "provider": return (host, try host.provider(point!, cmd.at("arg")))
        case "shadowed":
            return (host, .list(try host.shadowed(point!).map { .str($0) }))
        case "export": return (host, try host.exports(cmd.at("key").asString ?? ""))
        case "capability":
            return (host, .list(host.capability(cmd.at("name").asString ?? "")
                .map { .str($0) }))
        case "trace": return (host, host.trace())
        // Section 9.1's host-owned path: the embedding host installing the
        // instance whose name it reserved.
        case "hostdeclare":
            return (host, .str(try host.hostdeclare(ref, spec).ref))
        case "declare": return (host, .str(try host.declare(ref, spec).ref))
        case "order": return (host, .list(try host.order(point).map { .str($0) }))
        case "seq":
            return (host, try host.instance(ref).map { Value.num(Double($0.seq)) } ?? .null)
        case "pos":
            return (host, try host.instance(ref).map { Value.num(Double($0.pos)) } ?? .null)
        case "inner":
            return (host, try host.instance(ref)?.inner?.list() ?? .null)
        case "call": return try doCall(host, cmd, ref, point)
        default:
            throw DriverError("unknown driver command: \(cmd.at("do").json)")
        }
    }

    static func doCall(
        _ host: Host, _ cmd: Value, _ ref: Value, _ point: String?
    ) throws -> (Host, Value?) {
        guard let entry = try host.instance(ref) else {
            throw Types.fail("plugin_not_loaded", "no such instance: \(Refs.canon(ref))")
        }
        switch cmd.at("method").asString ?? "" {
        case "bump":
            entry.state = entry.state.setting(
                "count", .num((entry.state.at("count").asDouble ?? 0) + 1)
            )
            return (host, nil)
        case "count":
            return (host, .num(entry.state.at("count").asDouble ?? 0))
        case "unwound":
            return (host, entry.state.has("unwound") ? entry.state.at("unwound") : .list([]))
        // Reached through the instance api, which is where section 6.6 puts it -
        // a plugin asks about itself.
        case "position": return (host, try host.positionOf(ref, point!))
        case "stray":
            // A release from OUTSIDE a lifecycle callback. THIS BRANCH USED TO DO
            // NOTHING, and its corpus row stayed green whatever `release` did
            // with its guard.
            let exported = try host.exports("\(Refs.canon(ref))/inst")
            guard case .opaque(let obj) = exported, let inst = obj as? Inst else {
                throw DriverError("stray: no instance handle exported")
            }
            try inst.release {}
            return (host, nil)
        default: return (host, nil)
        }
    }
}

/// An error the driver raises that carries NO section 12 code, so the host's
/// wrapping path (`plugin_<phase>_failed`) is what the corpus sees.
struct DriverError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
