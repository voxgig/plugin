package voxgig.plugin.test

import voxgig.plugin.Capability
import voxgig.plugin.Graph
import voxgig.plugin.Plugin
import voxgig.plugin.Refs
import voxgig.plugin.Resolve
import voxgig.plugin.Types
import voxgig.plugin.Version
import kotlin.system.exitProcess

/**
 * The whole suite: pure sections by direct call, driver sections by command
 * list, and a coverage guard above both.
 *
 * A plain runner rather than JUnit or kotlin.test, for the same reason the port
 * has no gradle `dependencies` block: a conformance suite whose only job is to
 * run one corpus and report which entries disagree does not need a framework,
 * and adding one would make `make test` depend on a resolver nobody else in
 * this repo has.
 */
object Run {

    private val failures = ArrayList<String>()
    private var ranSections = 0
    private var ranEntries = 0

    private val PURE = listOf(
        "ref", "env", "version", "capability", "graph", "resolve", "config"
    )
    private val DRIVER = listOf(
        "lifecycle", "order", "point", "export", "depend",
        "declare", "state", "resource", "nest", "trace", "apply", "error"
    )

    private fun inOf(e: Any?): Any? = Types.get(e, "in")

    private fun argAt(e: Any?, i: Int): Any? {
        val args = (Types.get(e, "args") ?: emptyList<Any?>()) as List<*>
        return if (i < args.size) args[i] else null
    }

    /**
     * Dispatch every group, and fail on a group the runner does not know - a
     * group silently not run is worse than a failure.
     */
    private fun runSection(
        spec: Any?,
        name: String,
        subjectFor: (String) -> ((Any?) -> Any?)?
    ) {
        val groups = Corpus.section(spec, name)
        ranSections++
        for (group in groups.keys.sorted()) {
            val fn = subjectFor(group)
            if (null == fn) {
                failures.add("$name: corpus group with no subject: $group")
                continue
            }
            groups[group]!!.forEachIndexed { i, entry ->
                ranEntries++
                val why = Corpus.check(entry, fn)
                if (null != why) failures.add("$name/${Corpus.label(group, i, entry)}: $why")
            }
        }
    }

    /** The common case: a group name selects the subject directly. */
    private fun runMapped(spec: Any?, name: String, subjects: Map<String, (Any?) -> Any?>) =
        runSection(spec, name) { subjects[it] }

    @JvmStatic
    fun main(args: Array<String>) {
        val spec = Corpus.corpus()

        runMapped(
            spec, "ref",
            mapOf(
                "parse" to { e: Any? -> Plugin.parseRef(inOf(e)) },
                "parsebad" to { e: Any? -> Plugin.parseRef(inOf(e)) },
                "format" to { e: Any? -> Plugin.formatRef(argAt(e, 0), argAt(e, 1)) },
                "formatbad" to { e: Any? -> Plugin.formatRef(argAt(e, 0), argAt(e, 1)) },
                "canon" to { e: Any? -> Refs.canonRef(inOf(e)) },
                "name" to { e: Any? -> Plugin.checkName(inOf(e)) },
                "tag" to { e: Any? -> Plugin.checkTag(inOf(e)) },
                "bound" to { e: Any? -> Plugin.checkName(inOf(e)) },
                "boundtag" to { e: Any? -> Plugin.checkTag(inOf(e)) }
            )
        )

        val env = { e: Any? -> Plugin.applyEnv(inOf(e)) }
        runMapped(
            spec, "env",
            mapOf(
                "option" to env, "value" to env, "toggle" to env,
                "profile" to env, "ambiguous" to env, "reserved" to env
            )
        )

        val rng = { e: Any? -> Version.parseRange(inOf(e)) }
        runMapped(
            spec, "version",
            mapOf(
                "range" to rng, "rangebad" to rng,
                "satisfies" to { e: Any? ->
                    Version.satisfies(
                        Types.get(inOf(e), "version"), Types.get(inOf(e), "range")
                    )
                }
            )
        )

        val cap = { e: Any? ->
            Capability.resolveCapability(
                Types.get(inOf(e), "req"), Types.get(inOf(e), "candidates")
            )
        }
        runMapped(spec, "capability", mapOf("match" to cap, "nested" to cap, "rank" to cap))

        val graph = { e: Any? -> Graph.resolveGraph(inOf(e)) }
        runMapped(spec, "graph", mapOf("resolve" to graph, "blocked" to graph))

        runMapped(
            spec, "resolve",
            mapOf(
                "candidates" to { e: Any? ->
                    Resolve.resolveCandidates(
                        Types.get(inOf(e), "name") as String, Types.get(inOf(e), "sources")
                    )
                },
                "from" to { e: Any? -> Resolve.resolveFrom(inOf(e)) }
            )
        )

        // `config` picks its subject by group PREFIX rather than by name,
        // because the two functions split the section cleanly.
        runSection(spec, "config") { group ->
            when {
                group.startsWith("norm") -> { e: Any? -> Plugin.normalizeConfig(inOf(e)) }
                group.startsWith("opt") -> { e: Any? -> Plugin.resolveOptions(inOf(e)) }
                else -> null
            }
        }

        for (name in DRIVER) {
            runSection(spec, name) {
                { e: Any? -> Driver.drive(Types.get(e, "cmd") as List<Any?>) }
            }
        }

        // EVERY CORPUS SECTION IS RUN. The per-section dispatch already fails
        // on a GROUP with no subject; this closes the level above, because a
        // whole SECTION the runner never mentions is a section silently not
        // run.
        val primary = Types.get(spec, "primary") ?: emptyMap<String, Any?>()
        val ran = PURE + DRIVER

        // The corpus metadata block is what turns on strict entry validation in
        // every runner, so a corpus that lost it must not silently downgrade
        // this port's checking.
        val pluginVersion = Types.get(Types.get(spec, "PLUGIN") ?: emptyMap<String, Any?>(), "version")
        if (1.0 != pluginVersion) failures.add("corpus PLUGIN.version must be 1")

        val missing = Types.keys(primary).filter { !ran.contains(it) }.sorted()
        if (missing.isNotEmpty()) {
            failures.add("corpus sections no test runs: ${missing.joinToString(", ")}")
        }
        val extra = ran.filter { !Types.has(primary, it) }.sorted()
        if (extra.isNotEmpty()) {
            failures.add(
                "tests name sections the corpus does not have: ${extra.joinToString(", ")}"
            )
        }

        // A floor, not a fixture: the corpus grows, and a run that suddenly
        // covers a fraction of it is the failure worth catching.
        if (400 > ranEntries) failures.add("only $ranEntries corpus entries reachable")

        if (failures.isEmpty()) {
            println("kotlin: $ranEntries corpus entries across $ranSections sections, all pass")
            exitProcess(0)
        }
        for (f in failures) System.err.println(f)
        System.err.println("\nkotlin: ${failures.size} failure(s) of $ranEntries entries")
        exitProcess(1)
    }
}
