package voxgig.plugin.test

import voxgig.plugin.Json
import voxgig.plugin.Types
import java.nio.file.Files
import java.nio.file.Paths

/**
 * The corpus runner.
 *
 * Reads spec/plugin.json - the COMMITTED artifact, not the aontu source -
 * exactly as every other port's runner does. No port needs a Node toolchain to
 * run its tests, and this one does not get a private door into the source
 * either.
 *
 * A group name selects the subject. That is the whole dispatch, and it is
 * deliberately dumb: a runner that inferred the subject from the entry's shape
 * would silently run the wrong function when an entry was mistyped.
 */
object Corpus {

    /**
     * A sentinel for "this key was not present". A map returns null for both an
     * absent key and a JSON null, and `__UNDEF__` and `__NULL__` are different
     * assertions.
     */
    val MISSING = Any()

    fun corpus(): Any? =
        Json.parse(String(Files.readAllBytes(Paths.get("../spec/plugin.json"))))

    fun section(spec: Any?, name: String): Map<String, List<Any?>> {
        val sec = Types.get(Types.get(spec, "primary") ?: emptyMap<String, Any?>(), name)
            ?: throw IllegalStateException("no such corpus section: $name")

        val out = LinkedHashMap<String, List<Any?>>()
        for (group in Types.keys(sec)) {
            if ("DEF" == group) continue
            val body = Types.get(sec, group)
            if (body !is Map<*, *>) continue
            val set = Types.get(body, "set")
            if (set !is List<*>) continue
            out[group] = set
        }
        return out
    }

    /** A stable label, so a failure names the entry rather than an index. */
    fun label(group: String, i: Int, entry: Any?): String =
        (Types.get(entry, "id") ?: "$group#$i") as String

    /**
     * Partial match: every key the expectation names must agree, and keys it
     * does not name are ignored. `__EXISTS__` asserts presence without pinning
     * a value; `/re/` matches a string as a regular expression.
     */
    fun matches(expect: Any?, actualIn: Any?): Boolean {
        if ("__EXISTS__" == expect) return MISSING !== actualIn && null != actualIn
        if ("__UNDEF__" == expect) return MISSING === actualIn
        if ("__NULL__" == expect) return MISSING !== actualIn && null == actualIn

        val actual = if (MISSING === actualIn) null else actualIn

        if (expect is String && 2 < expect.length &&
            expect.startsWith("/") && expect.endsWith("/")
        ) {
            if (actual !is String) return false
            return Regex(expect.substring(1, expect.length - 1)).containsMatchIn(actual)
        }

        if (expect is List<*>) {
            if (actual !is List<*> || expect.size != actual.size) return false
            return expect.indices.all { matches(expect[it], actual[it]) }
        }

        if (expect is Map<*, *>) {
            if (actual !is Map<*, *>) return false
            return Types.keys(expect).all {
                matches(
                    Types.get(expect, it),
                    if (actual.containsKey(it)) actual[it] else MISSING
                )
            }
        }

        return same(expect, actual)
    }

    /**
     * Deep equality over spec values. Key order never matters; list order
     * always does.
     *
     * AGENTS.md section 1: "The plugin library must never be used to implement
     * its own tests." A shared comparison lets a broken implementation and its
     * oracle be wrong together and stay green, so the corpus's equality is
     * written here rather than imported.
     */
    fun same(a: Any?, b: Any?): Boolean {
        if (a is Map<*, *> || b is Map<*, *>) {
            if (a !is Map<*, *> || b !is Map<*, *> || a.size != b.size) return false
            return a.all { (k, v) -> b.containsKey(k) && same(v, b[k]) }
        }
        if (a is List<*> || b is List<*>) {
            if (a !is List<*> || b !is List<*> || a.size != b.size) return false
            return a.indices.all { same(a[it], b[it]) }
        }
        return if (null == a) null == b else a == b
    }

    /**
     * Run one entry against a subject and report the disagreement, if any.
     *
     * The three combinations the spec format allows are enforced here as well
     * as at build time, because a runner that quietly accepted `err` beside
     * `out` would let a contradictory entry pass.
     */
    fun check(entry: Any?, subject: (Any?) -> Any?): String? {
        if (Types.has(entry, "err") && Types.has(entry, "out")) {
            return "entry has both err and out"
        }

        var value: Any? = null
        var raised: Throwable? = null
        try {
            value = subject(entry)
        } catch (e: Exception) {
            raised = e
        }

        if (Types.has(entry, "err")) {
            if (null == raised) return "expected a raise, got: ${Json.write(value)}"

            // Errors compare by CODE (section 12). Message wording is a port's
            // own business, and pinning it would make every translation a
            // corpus change.
            val want = Types.get(entry, "err")
            val got = Types.codeOf(raised)
            if (true != want && got != want) {
                return "expected code $want, got $got (${Types.messageOf(raised)})"
            }
            if (Types.has(entry, "match")) {
                val shown = mapOf(
                    "err" to mapOf(
                        "code" to got,
                        "message" to Types.messageOf(raised),
                        "name" to "PluginError"
                    )
                )
                if (!matches(Types.get(entry, "match"), shown)) {
                    return "error did not match ${Json.write(Types.get(entry, "match"))}, " +
                        "got ${Json.write(shown)}"
                }
            }
            return null
        }

        if (null != raised) {
            return "unexpected raise: ${Types.codeOf(raised)} ${Types.messageOf(raised)}"
        }

        if (Types.has(entry, "out") && !same(Types.get(entry, "out"), value)) {
            return "expected ${Json.write(Types.get(entry, "out"))}, got ${Json.write(value)}"
        }

        if (Types.has(entry, "match")) {
            val shown = mapOf("in" to Types.get(entry, "in"), "out" to value)
            if (!matches(Types.get(entry, "match"), shown)) {
                return "did not match ${Json.write(Types.get(entry, "match"))}, " +
                    "got out=${Json.write(value)}"
            }
        }

        if (!Types.has(entry, "out") && !Types.has(entry, "match")) {
            return "entry asserts nothing"
        }
        return null
    }
}
