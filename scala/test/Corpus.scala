package voxgig.plugin.test

import voxgig.plugin._

/** The corpus runner.
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

  /** An `Option[Value]` is the sentinel: `None` means "this key was not
    * present", which is exactly the distinction `__UNDEF__` and `__NULL__` pin,
    * and scala already has a type for it.
    */
  def section(spec: Value, name: String): Map[String, List[Value]] = {
    val sec = spec.at("primary").get(name).getOrElse(
      throw new Driver.DriverError("no such corpus section: " + name)
    )
    sec.keys.filter(_ != "DEF").flatMap { group =>
      val body = sec.at(group)
      if (body.isMap && body.at("set").isList) Some(group -> body.at("set").items)
      else None
    }.toMap
  }

  /** A stable label, so a failure names the entry rather than an index. */
  def label(group: String, i: Int, entry: Value): String =
    entry.at("id").asString.getOrElse(group + "#" + i)

  /** Partial match: every key the expectation names must agree, and keys it
    * does not name are ignored. `__EXISTS__` asserts presence without pinning a
    * value; `/re/` matches a string as a regular expression.
    */
  def matches(expect: Value, actual: Option[Value]): Boolean = {
    if (expect == VStr("__EXISTS__")) return actual.exists(!_.isNull)
    if (expect == VStr("__UNDEF__")) return actual.isEmpty
    if (expect == VStr("__NULL__")) return actual.exists(_.isNull)

    val got = actual.getOrElse(VNull)

    expect match {
      case VStr(p) if p.length > 2 && p.startsWith("/") && p.endsWith("/") =>
        got.asString.exists(text => p.substring(1, p.length - 1).r.findFirstIn(text).isDefined)
      case VList(want) =>
        got.isList && want.length == got.items.length &&
          want.zip(got.items).forall { case (e, a) => matches(e, Some(a)) }
      case VMap(_) =>
        got.isMap && expect.keys.forall(k => matches(expect.at(k), got.get(k)))
      case _ => expect == got
    }
  }

  /** Run one entry against a subject and report the disagreement, if any.
    *
    * The three combinations the spec format allows are enforced here as well as
    * at build time, because a runner that quietly accepted `err` beside `out`
    * would let a contradictory entry pass.
    */
  def check(entry: Value, subject: Value => Value): Option[String] = {
    if (entry.has("err") && entry.has("out")) return Some("entry has both err and out")

    val outcome: Either[Throwable, Value] =
      try Right(subject(entry))
      catch { case e: Exception => Left(e) }

    outcome match {
      case Left(e) if entry.has("err") =>
        // Errors compare by CODE (section 12). Message wording is a port's own
        // business, and pinning it would make every translation a corpus
        // change.
        val want = entry.at("err")
        val got = Types.codeOf(e)
        if (want != VBool(true) && VStr(got) != want) {
          Some("expected code " + want.json + ", got " + got + " (" + Types.messageOf(e) + ")")
        } else if (entry.has("match")) {
          val shown = Value.map("err" -> Value.map(
            "code" -> VStr(got), "message" -> VStr(Types.messageOf(e)),
            "name" -> VStr("PluginError")
          ))
          if (matches(entry.at("match"), Some(shown))) None
          else Some(
            "error did not match " + entry.at("match").json + ", got " + shown.json
          )
        } else {
          None
        }

      case Left(e) =>
        Some("unexpected raise: " + Types.codeOf(e) + " " + Types.messageOf(e))

      case Right(value) if entry.has("err") =>
        Some("expected a raise, got: " + value.json)

      case Right(value) =>
        if (entry.has("out") && entry.at("out") != value) {
          Some("expected " + entry.at("out").json + ", got " + value.json)
        } else if (entry.has("match") &&
          !matches(entry.at("match"), Some(Value.map("in" -> entry.at("in"), "out" -> value)))) {
          Some("did not match " + entry.at("match").json + ", got out=" + value.json)
        } else if (!entry.has("out") && !entry.has("match")) {
          Some("entry asserts nothing")
        } else {
          None
        }
    }
  }
}
