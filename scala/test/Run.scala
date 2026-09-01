package voxgig.plugin.test

import voxgig.plugin._
import scala.collection.mutable
import scala.io.Source

/** The whole suite: pure sections by direct call, driver sections by command
  * list, and a coverage guard above both.
  *
  * A plain runner rather than ScalaTest or munit, for the same reason the port
  * has no `libraryDependencies`: a conformance suite whose only job is to run
  * one corpus and report which entries disagree does not need a framework, and
  * adding one would make `make test` depend on a resolver nobody else in this
  * repo has.
  */
object Run {

  private val failures = mutable.ListBuffer[String]()
  private var ranSections = 0
  private var ranEntries = 0

  private val pure = List(
    "ref", "env", "version", "capability", "graph", "resolve", "config"
  )
  private val driver = List(
    "lifecycle", "order", "point", "export", "depend",
    "declare", "state", "resource", "nest", "trace", "apply", "error"
  )

  private def inOf(e: Value): Value = e.at("in")

  private def argAt(e: Value, i: Int): Value = {
    val args = e.at("args").items
    if (i < args.length) args(i) else VNull
  }

  /** Dispatch every group, and fail on a group the runner does not know - a
    * group silently not run is worse than a failure.
    */
  private def runSection(
      spec: Value, name: String, subjectFor: String => Option[Value => Value]
  ): Unit = {
    val groups = Corpus.section(spec, name)
    ranSections += 1
    groups.keys.toList.sorted.foreach { group =>
      subjectFor(group) match {
        case None => failures += (name + ": corpus group with no subject: " + group)
        case Some(fn) =>
          groups(group).zipWithIndex.foreach { case (entry, i) =>
            ranEntries += 1
            Corpus.check(entry, fn).foreach { why =>
              failures += (name + "/" + Corpus.label(group, i, entry) + ": " + why)
            }
          }
      }
    }
  }

  /** The common case: a group name selects the subject directly. */
  private def runMapped(
      spec: Value, name: String, subjects: Map[String, Value => Value]
  ): Unit = runSection(spec, name, subjects.get)

  def main(args: Array[String]): Unit = {
    val source = Source.fromFile("../spec/plugin.json", "UTF-8")
    val spec = try Json.parse(source.mkString) finally source.close()

    runMapped(spec, "ref", Map(
      "parse" -> ((e: Value) => Plugin.parseRef(inOf(e))),
      "parsebad" -> ((e: Value) => Plugin.parseRef(inOf(e))),
      "format" -> ((e: Value) => VStr(Plugin.formatRef(argAt(e, 0), argAt(e, 1)))),
      "formatbad" -> ((e: Value) => VStr(Plugin.formatRef(argAt(e, 0), argAt(e, 1)))),
      "canon" -> ((e: Value) => VStr(Refs.canonRef(inOf(e)))),
      "name" -> ((e: Value) => VBool(Plugin.checkName(inOf(e)))),
      "tag" -> ((e: Value) => VBool(Plugin.checkTag(inOf(e)))),
      "bound" -> ((e: Value) => VBool(Plugin.checkName(inOf(e)))),
      "boundtag" -> ((e: Value) => VBool(Plugin.checkTag(inOf(e))))
    ))

    val env: Value => Value = (e: Value) => Plugin.applyEnv(inOf(e))
    runMapped(spec, "env", Map(
      "option" -> env, "value" -> env, "toggle" -> env,
      "profile" -> env, "ambiguous" -> env, "reserved" -> env
    ))

    val rng: Value => Value = (e: Value) => Version.parseRange(inOf(e))
    runMapped(spec, "version", Map(
      "range" -> rng, "rangebad" -> rng,
      "satisfies" -> ((e: Value) =>
        VBool(Version.satisfies(inOf(e).at("version"), inOf(e).at("range"))))
    ))

    val cap: Value => Value = (e: Value) =>
      VList(Capability.resolveCapability(inOf(e).at("req"), inOf(e).at("candidates")))
    runMapped(spec, "capability", Map("match" -> cap, "nested" -> cap, "rank" -> cap))

    val graph: Value => Value = (e: Value) => Graph.resolveGraph(inOf(e))
    runMapped(spec, "graph", Map("resolve" -> graph, "blocked" -> graph))

    runMapped(spec, "resolve", Map(
      "candidates" -> ((e: Value) => VList(Resolve.resolveCandidates(
        inOf(e).at("name").asString.getOrElse(""), inOf(e).at("sources")
      ).map(VStr))),
      "from" -> ((e: Value) => VList(Resolve.resolveFrom(inOf(e))))
    ))

    // `config` picks its subject by group PREFIX rather than by name, because
    // the two functions split the section cleanly.
    runSection(spec, "config", group =>
      if (group.startsWith("norm")) Some((e: Value) => Plugin.normalizeConfig(inOf(e)))
      else if (group.startsWith("opt")) Some((e: Value) => Plugin.resolveOptions(inOf(e)))
      else None
    )

    driver.foreach { name =>
      runSection(spec, name, _ => Some((e: Value) => Driver.drive(e.at("cmd").items)))
    }

    // EVERY CORPUS SECTION IS RUN. The per-section dispatch already fails on a
    // GROUP with no subject; this closes the level above, because a whole
    // SECTION the runner never mentions is a section silently not run.
    val primary = spec.at("primary")
    val ran = pure ++ driver

    // The corpus metadata block is what turns on strict entry validation in
    // every runner, so a corpus that lost it must not silently downgrade this
    // port's checking.
    if (spec.at("PLUGIN").at("version") != VNum(1)) {
      failures += "corpus PLUGIN.version must be 1"
    }

    val missing = primary.keys.filterNot(ran.contains).sorted
    if (missing.nonEmpty) {
      failures += ("corpus sections no test runs: " + missing.mkString(", "))
    }
    val extra = ran.filterNot(primary.has).sorted
    if (extra.nonEmpty) {
      failures += ("tests name sections the corpus does not have: " + extra.mkString(", "))
    }

    // A floor, not a fixture: the corpus grows, and a run that suddenly covers
    // a fraction of it is the failure worth catching.
    if (ranEntries < 400) {
      failures += ("only " + ranEntries + " corpus entries reachable")
    }

    if (failures.isEmpty) {
      println(
        "scala: " + ranEntries + " corpus entries across " + ranSections +
          " sections, all pass"
      )
      System.exit(0)
    }
    failures.foreach(System.err.println)
    System.err.println(
      "\nscala: " + failures.length + " failure(s) of " + ranEntries + " entries"
    )
    System.exit(1)
  }
}
