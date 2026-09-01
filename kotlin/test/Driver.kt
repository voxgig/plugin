package voxgig.plugin.test

import voxgig.plugin.Binding
import voxgig.plugin.BindingFn
import voxgig.plugin.Catalog
import voxgig.plugin.Host
import voxgig.plugin.Inst
import voxgig.plugin.Plugin
import voxgig.plugin.Types
import java.util.TreeMap

/**
 * The driver (DOCS.md section 4).
 *
 * Every port implements this same small thing and nothing else is
 * port-specific: the probe catalog, the command interpreter, and the canonical
 * observable.
 */
object Driver {

    /**
     * A sentinel for "this command produced nothing", so a command that
     * legitimately produces nil - `export` of a missing key - still overwrites
     * the previous result.
     */
    val NOTHING = Any()

    private fun opt(i: Inst, k: String): Any? = Types.get(i.options, k)

    private fun count(i: Inst): Double = (i.state["count"] ?: 0.0) as Double

    private fun bump(i: Inst, by: Double) {
        i.state["count"] = count(i) + by
    }

    private fun declareProvides(i: Inst) {
        for (prov in (opt(i, "provides") ?: emptyList<Any?>()) as List<*>) i.provides(prov)
    }

    private fun boom(i: Inst, callback: String) {
        if (callback != opt(i, "fail")) return
        // `bare` raises WITHOUT a code - the ordinary library error section
        // 12's `plugin_<phase>_failed` codes exist to wrap.
        if (Types.truthy(opt(i, "bare"))) {
            throw IllegalStateException("probe failed at $callback")
        }
        Types.fail(
            (opt(i, "code") ?: "plugin_${callback}_failed") as String,
            "probe failed at $callback"
        )
    }

    private fun reenter(i: Inst, callback: String) {
        // A transition from inside a lifecycle callback (section 5.2).
        if (callback != opt(i, "reenter")) return
        i.host.activate(i.ref)
    }

    /**
     * The points every driver host declares. DOCS.md section 4.3 defines
     * `probe` as binding one hook point (`p`) and wrapping one chain point
     * (`c`), so a host without them cannot load the probe at all - they are
     * part of the contract's baseline rather than a fixture convenience. `v` is
     * the provider point the `provider` probe defaults to.
     */
    fun basePoints(): MutableMap<String, Any?> {
        val out = TreeMap<String, Any?>()
        out["p"] = mapOf("kind" to "hook")
        out["c"] = mapOf("kind" to "chain", "base" to { a: Any? -> a })
        out["v"] = mapOf("kind" to "provider")
        return out
    }

    /**
     * A `host` command REPLACES a base point rather than merging into it, so an
     * entry can redeclare `c` with its own base or `v` as exclusive without
     * inheriting the default's shape.
     */
    @JvmOverloads
    fun withPoints(extra: Any? = null): Map<String, Any?> {
        val out = basePoints()
        for (k in Types.keys(extra)) out[k] = Types.get(extra, k)
        return out
    }

    private fun record(name: String): Map<String, Any?> = mapOf(
        "name" to name,
        "define" to { i: Inst -> bump(i, 0.0) },
        "activate" to { i: Inst -> i.acquire() }
    )

    /**
     * Section 4.3's six probes. Their behaviour is as much the contract as the
     * runner is - this is where twenty implementations of `noisy` are made to
     * fail at the same callback in the same way.
     */
    fun probes(): List<Any?> {
        val probe = mapOf(
            "name" to "probe",
            "define" to { i: Inst ->
                bump(i, 0.0)
                val band = opt(i, "band")
                // One hook binding (`p`) and one chain wrap (`c`) - the
                // workhorse shape DOCS.md section 4.3 specifies. `p` RETURNS
                // NOTHING, as the canonical's arrow-with-a-block does: in
                // `bail` mode a return is an answer, and a counter that
                // answered with its own count would make every hook that keeps
                // one un-bailable.
                i.bind("p", { _: Any?, _: Any? -> bump(i, 1.0); null }, band)
                // Wrap AFTER next, so the result spells the nesting left to
                // right: outermost first. Wrapping the ARGUMENT instead would
                // spell it backwards and make every chain expectation read
                // wrong.
                i.bind("c", { next: Any?, v: Any? ->
                    @Suppress("UNCHECKED_CAST")
                    val inner = next as (Any?) -> Any?
                    "${opt(i, "wrap") ?: ":"}${inner(v)}"
                }, band)
                i.export("client", i.ref)
                // The instance api itself, so the driver's `stray` command can
                // call `release` from OUTSIDE a lifecycle callback.
                i.export("inst", i)
                declareProvides(i)
            },
            "activate" to { i: Inst ->
                i.acquire()
                // Section 6.5: an instance that is itself a host. The outer
                // owns the inner's lifetime - registered in the scope, so it
                // closes on deactivate in the same reverse unwind as every
                // other resource.
                val nest = opt(i, "nest")
                if (null != nest) {
                    val inner = i.nest(mapOf("points" to withPoints()))
                    for (d in probes()) inner.catalog.add(d)
                    for (r in nest as List<*>) inner.ready(r)
                }
            }
        )

        val noisy = mapOf(
            "name" to "noisy",
            "define" to { i: Inst -> bump(i, 0.0); boom(i, "define") },
            "activate" to { i: Inst ->
                // Acquire BEFORE the raise, so a failing activate has something
                // to leak if the scope does not unwind - which is the whole
                // point of the entry that asserts open == 0 afterwards.
                i.acquire()
                reenter(i, "activate")
                boom(i, "activate")
            },
            "deactivate" to { i: Inst -> boom(i, "deactivate") },
            "close" to { i: Inst -> boom(i, "close") }
        )

        val greedy = mapOf(
            "name" to "greedy",
            "define" to { i: Inst ->
                i.state["count"] = 0.0
                // Section 8.1 puts resource capture in `activate`. `early`
                // NAMES the call that reaches for it in `define`, because
                // `acquire` and `release` carry the guard separately.
                if ("acquire" == opt(i, "early")) i.acquire()
                if ("release" == opt(i, "early")) i.release {}
            },
            "activate" to { i: Inst ->
                val n = Types.asInt(opt(i, "acquire")) ?: 0
                val rel = Types.asInt(opt(i, "release")) ?: 0
                val handles = (0 until n).map { i.acquire() }
                // Release some explicitly; the DIFFERENCE is what the instance
                // scope must unwind by itself (section 8.3), and that
                // difference is the whole test.
                for (k in 0 until minOf(rel, handles.size)) handles[k]()

                // `bind` is `early`'s counterpart for section 8.1's OTHER half.
                // Binding declaration belongs in `define`; this names the
                // callback that tries it from somewhere else.
                if ("activate" == opt(i, "bind")) i.bind("p", { _: Any?, _: Any? -> null })

                // `mark` registers N FOREIGN releases - section 8.3's
                // `release`, the half `acquire` cannot exercise - each
                // recording its own index as it runs. THE RECORDED LIST IS THE
                // ONLY THING THAT DISTINGUISHES A REVERSE UNWIND FROM A FORWARD
                // ONE.
                i.state["unwound"] = ArrayList<Any?>()
                for (k in 0 until (Types.asInt(opt(i, "mark")) ?: 0)) {
                    val at = k
                    i.release {
                        // `markfail` makes the release RAISE - the only way
                        // section 8.3's `plugin_release_failed` and its
                        // `failed` status are reachable.
                        if (Types.truthy(opt(i, "markfail"))) {
                            throw IllegalStateException("release failed at $at")
                        }
                        @Suppress("UNCHECKED_CAST")
                        (i.state["unwound"] as ArrayList<Any?>).add(at.toDouble())
                    }
                }
            },
            // `deactivate` completes the pair: the guard is on the PHASE, not
            // on "not define", and an entry exercising only one leaves the
            // other's mutation alive.
            "deactivate" to { i: Inst ->
                if ("deactivate" == opt(i, "bind")) i.bind("p", { _: Any?, _: Any? -> null })
            }
        )

        val dep = mapOf(
            "name" to "dep",
            "define" to { i: Inst ->
                i.state["count"] = 0.0
                declareProvides(i)
                val exports = opt(i, "exports")
                for (k in Types.keys(exports)) i.export(k, Types.get(exports, k))
            },
            "activate" to { i: Inst -> i.acquire() }
        )

        val provider = mapOf(
            "name" to "provider",
            "define" to { i: Inst ->
                i.state["count"] = 0.0
                i.bind(
                    (opt(i, "point") ?: "v") as String,
                    { _: Any?, _: Any? ->
                        if (Types.has(i.options, "value")) opt(i, "value") else i.ref
                    },
                    opt(i, "band")
                )
                declareProvides(i)
            },
            "activate" to { i: Inst -> i.acquire() }
        )

        return listOf(
            probe, noisy, greedy, dep, provider,
            record("slow"), record("other"), record("adapter"), record("late")
        )
    }

    fun withProbes(): Catalog = Plugin.makeCatalog(probes())

    /**
     * Run a command list and return section 4.5's observable. Stops at the
     * first raise; the entry's `err` matches its code.
     */
    fun drive(cmds: List<Any?>): Map<String, Any?> {
        var host = Plugin.makeHost(
            mapOf("catalog" to withProbes(), "points" to withPoints())
        )

        // Section 4.5: `result` is the value of THE LAST COMMAND THAT PRODUCES
        // ONE. Storing it and continuing - rather than returning at the first
        // producing command - is what lets an entry emit and then inspect,
        // which most of `point` needs.
        var last: Any? = null

        for (cmd in cmds) {
            try {
                val produced = doCmd(host, cmd)
                host = produced[0] as Host
                if (NOTHING !== produced[1]) last = produced[1]
            } catch (e: Exception) {
                // Section 4.1: `catch` records the raise and lets the run
                // continue, which is the only way to observe a `failed`
                // instance - section 5.2's whole claim is that it stays
                // registered and inspectable.
                if (true != Types.get(cmd, "catch")) throw e
            }
        }
        return host.observable(last)
    }

    fun doCmd(host: Host, cmd: Any?): List<Any?> {
        val ref = Types.get(cmd, "ref")
        val point = Types.get(cmd, "point") as String?
        val spec = mapOf(
            "options" to Types.get(cmd, "options"),
            "order" to Types.get(cmd, "order"),
            "definition" to Types.get(cmd, "definition"),
            "tag" to Types.get(cmd, "tag")
        )

        return when (Types.get(cmd, "do")) {
            "host" -> listOf(
                Plugin.makeHost(
                    mapOf(
                        "catalog" to withProbes(),
                        "reserved" to Types.get(cmd, "reserved"),
                        "keys" to Types.get(cmd, "keys"),
                        "defaults" to Types.get(cmd, "defaults"),
                        "profile" to Types.get(cmd, "profile"),
                        "points" to withPoints(Types.get(cmd, "points")),
                        // Section 11.3's strict reading. Absent means
                        // `restart`.
                        "dependency" to Types.get(cmd, "dependency")
                    )
                ),
                NOTHING
            )
            // Section 10.1's static registration: the definition ENTERS
            // THE CATALOG here, and registration is where its option shape
            // is validated (section 9.4) - before any load, so a malformed
            // shape fails at one moment in every host rather than whenever
            // a document happens to exercise the key.
            //
            // The catalog is pre-seeded with the probe set, so
            // re-registering a probe by name is the identity this command
            // has always been; `shape` is what makes it do work. A name the
            // probe set does not hold registers a bare definition - enough
            // to reach the catalog, and never loaded.
            "define" -> {
                // Section 4.2's three keys, all of them live. `probe`
                // names the PROBE whose callbacks back the definition and
                // `name` is what the definition is called - two keys that
                // ten entries passed as equal strings, so a driver
                // ignoring `probe` passed them all.
                val dname = Types.get(cmd, "name")
                val source = if (Types.has(cmd, "probe")) Types.get(cmd, "probe") else dname
                var definition: Any? = mapOf("name" to dname)
                for (d in probes()) {
                    if (source == Types.get(d, "name")) {
                        val renamed = LinkedHashMap<String, Any?>()
                        for (k in Types.keys(d)) renamed[k] = Types.get(d, k)
                        renamed["name"] = dname
                        definition = renamed
                    }
                }
                if (Types.has(cmd, "shape")) {
                    val withshape = LinkedHashMap<String, Any?>()
                    for (k in Types.keys(definition)) withshape[k] = Types.get(definition, k)
                    withshape["shape"] = Types.get(cmd, "shape")
                    definition = withshape
                }
                host.define(definition)
                listOf(host, NOTHING)
            }
            "load" -> { host.load(ref, spec); listOf(host, NOTHING) }
            "ready" -> {
                // declare FIRST, so the ordering block and definition reach the
                // instance - `ready` walks the staircase, it does not carry
                // configuration of its own.
                host.declare(ref, spec)
                host.ready(ref)
                listOf(host, NOTHING)
            }
            "activate" -> { host.activate(ref); listOf(host, NOTHING) }
            "deactivate" -> { host.deactivate(ref); listOf(host, NOTHING) }
            "unload" -> { host.unload(ref); listOf(host, NOTHING) }
            "apply" -> {
                host.apply(Types.get(cmd, "doc"), Types.get(cmd, "profile"))
                listOf(host, NOTHING)
            }
            "options" -> { host.options(ref, Types.get(cmd, "patch")); listOf(host, NOTHING) }
            "close" -> { host.close(); listOf(host, NOTHING) }
            "list" -> listOf(host, host.list())
            "emit" -> listOf(host, host.emit(point!!, Types.get(cmd, "arg")))
            "chain" -> listOf(host, host.call(point!!, Types.get(cmd, "arg")))
            "provider" -> listOf(host, host.provider(point!!, Types.get(cmd, "arg")))
            "shadowed" -> listOf(host, host.shadowed(point!!))
            "export" -> listOf(host, host.exports(Types.get(cmd, "key") as String))
            "capability" -> listOf(host, host.capability(Types.get(cmd, "name") as String))
            "trace" -> listOf(host, host.trace())
            // Section 9.1's host-owned path: the embedding host installing the
            // instance whose name it reserved.
            "hostdeclare" -> listOf(host, host.hostdeclare(ref, spec).ref)
            "declare" -> listOf(host, host.declare(ref, spec).ref)
            "order" -> listOf(host, host.order(point))
            "seq" -> listOf(host, host.instance(ref)?.seq?.toDouble())
            "pos" -> listOf(host, host.instance(ref)?.pos?.toDouble())
            "inner" -> listOf(host, host.instance(ref)?.inner?.list())
            "call" -> doCall(host, cmd, ref, point)
            else -> throw IllegalStateException(
                "unknown driver command: ${Types.get(cmd, "do")}"
            )
        }
    }

    private fun doCall(host: Host, cmd: Any?, ref: Any?, point: String?): List<Any?> {
        val entry = host.instance(ref)
            ?: Types.fail("plugin_not_loaded", "no such instance: $ref")
        return when (Types.get(cmd, "method")) {
            "bump" -> {
                entry.state["count"] = ((entry.state["count"] ?: 0.0) as Double) + 1.0
                listOf(host, NOTHING)
            }
            "count" -> listOf(host, entry.state["count"] ?: 0.0)
            "unwound" -> listOf(host, entry.state["unwound"] ?: emptyList<Any?>())
            // Reached through the instance api, which is where section 6.6 puts
            // it - a plugin asks about itself.
            "position" -> listOf(host, host.positionOf(ref, point!!))
            "stray" -> {
                // A release from OUTSIDE a lifecycle callback. THIS BRANCH USED
                // TO DO NOTHING, and its corpus row stayed green whatever
                // `release` did with its guard.
                (host.exports("$ref/inst") as Inst).release {}
                listOf(host, NOTHING)
            }
            else -> listOf(host, NOTHING)
        }
    }
}
