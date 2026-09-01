package voxgig.plugin.test

import voxgig.plugin._
import scala.collection.mutable

/** The driver (DOCS.md section 4).
  *
  * Every port implements this same small thing and nothing else is
  * port-specific: the probe catalog, the command interpreter, and the canonical
  * observable.
  */
object Driver {

  /** An error the driver raises that carries NO section 12 code, so the host's
    * wrapping path (`plugin_<phase>_failed`) is what the corpus sees.
    */
  final class DriverError(message: String) extends RuntimeException(message)

  private def opt(i: Inst, k: String): Value = i.options.at(k)

  private def count(i: Inst): Double = i.state.at("count").asDouble.getOrElse(0.0)

  private def bump(i: Inst, by: Double): Unit = i.statePut("count", VNum(count(i) + by))

  private def declareProvides(i: Inst): Unit =
    opt(i, "provides").items.foreach(i.provides)

  private def boom(i: Inst, callback: String): Unit = {
    if (opt(i, "fail").asString.contains(callback)) {
      // `bare` raises WITHOUT a code - the ordinary library error section 12's
      // `plugin_<phase>_failed` codes exist to wrap.
      if (opt(i, "bare").truthy) {
        throw new DriverError("probe failed at " + callback)
      }
      Types.fail(
        opt(i, "code").asString.getOrElse("plugin_" + callback + "_failed"),
        "probe failed at " + callback
      )
    }
  }

  private def reenter(i: Inst, callback: String): Unit = {
    // A transition from inside a lifecycle callback (section 5.2).
    if (opt(i, "reenter").asString.contains(callback)) {
      i.host.activate(VStr(i.ref))
      ()
    }
  }

  /** The points every driver host declares. DOCS.md section 4.3 defines `probe`
    * as binding one hook point (`p`) and wrapping one chain point (`c`), so a
    * host without them cannot load the probe at all - they are part of the
    * contract's baseline rather than a fixture convenience. `v` is the provider
    * point the `provider` probe defaults to.
    */
  def basePoints: Map[String, PointSpec] = Map(
    "p" -> PointSpec(kind = "hook"),
    "c" -> PointSpec(kind = "chain", base = Some((a: Value) => a)),
    "v" -> PointSpec(kind = "provider")
  )

  /** A `host` command REPLACES a base point rather than merging into it, so an
    * entry can redeclare `c` with its own base or `v` as exclusive without
    * inheriting the default's shape.
    */
  def withPoints(extra: Value = VNull): Map[String, PointSpec] =
    extra.keys.foldLeft(basePoints) { (acc, k) =>
      val spec = extra.at(k)
      val kind = spec.at("kind").asString.getOrElse("hook")
      acc + (k -> PointSpec(
        kind = kind,
        mode = spec.at("mode").asString.getOrElse("emit"),
        // A chain point declared by an entry keeps the base the driver gives
        // every `c`: the corpus writes `{"kind":"chain"}` and means the
        // identity base, which is what a JSON document can express.
        base = if (kind == "chain") Some((a: Value) => a) else None,
        pin = spec.at("pin"),
        exclusive = spec.at("exclusive").truthy,
        dflt = spec.at("default")
      ))
    }

  private def record(name: String): Definition = Definition(
    name = name,
    define = Some((i: Inst) => bump(i, 0)),
    activate = Some((i: Inst) => { i.acquire(); () })
  )

  /** Section 4.3's six probes. Their behaviour is as much the contract as the
    * runner is - this is where twenty implementations of `noisy` are made to
    * fail at the same callback in the same way.
    */
  def probes: List[Definition] = {
    val probe = Definition(
      name = "probe",
      define = Some { (i: Inst) =>
        bump(i, 0)
        val band = opt(i, "band")
        // One hook binding (`p`) and one chain wrap (`c`) - the workhorse shape
        // DOCS.md section 4.3 specifies. `p` RETURNS NOTHING, as the
        // canonical's arrow-with-a-block does: in `bail` mode a return is an
        // answer, and a counter that answered with its own count would make
        // every hook that keeps one un-bailable.
        i.bind("p", (_, _) => { bump(i, 1); VNull }, band)
        // Wrap AFTER next, so the result spells the nesting left to right:
        // outermost first. Wrapping the ARGUMENT instead would spell it
        // backwards and make every chain expectation read wrong.
        i.bind("c", (next, v) => {
          val wrap = opt(i, "wrap").asString.getOrElse(":")
          val inner = next.get(v)
          VStr(wrap + inner.asString.getOrElse(inner.json))
        }, band)
        i.export("client", VStr(i.ref))
        // The instance api itself, so the driver's `stray` command can call
        // `release` from OUTSIDE a lifecycle callback.
        i.export("inst", VOpaque(i))
        declareProvides(i)
      },
      activate = Some { (i: Inst) =>
        i.acquire()
        // Section 6.5: an instance that is itself a host. The outer owns the
        // inner's lifetime - registered in the scope, so it closes on
        // deactivate in the same reverse unwind as every other resource.
        val nest = opt(i, "nest")
        if (!nest.isNull) {
          val inner = i.nest(HostOptions(points = withPoints()))
          probes.foreach(inner.catalog.add)
          nest.items.foreach(inner.ready)
        }
      }
    )

    val noisy = Definition(
      name = "noisy",
      define = Some((i: Inst) => { bump(i, 0); boom(i, "define") }),
      activate = Some { (i: Inst) =>
        // Acquire BEFORE the raise, so a failing activate has something to leak
        // if the scope does not unwind - which is the whole point of the entry
        // that asserts open == 0 afterwards.
        i.acquire()
        reenter(i, "activate")
        boom(i, "activate")
      },
      deactivate = Some((i: Inst) => boom(i, "deactivate")),
      close = Some((i: Inst) => boom(i, "close"))
    )

    val greedy = Definition(
      name = "greedy",
      define = Some { (i: Inst) =>
        i.statePut("count", VNum(0))
        // Section 8.1 puts resource capture in `activate`. `early` NAMES the
        // call that reaches for it in `define`, because `acquire` and `release`
        // carry the guard separately.
        if (opt(i, "early").asString.contains("acquire")) i.acquire()
        if (opt(i, "early").asString.contains("release")) i.release(() => ())
      },
      activate = Some { (i: Inst) =>
        val n = opt(i, "acquire").asInt.getOrElse(0)
        val rel = opt(i, "release").asInt.getOrElse(0)
        val handles = (0 until n).map(_ => i.acquire()).toList
        // Release some explicitly; the DIFFERENCE is what the instance scope
        // must unwind by itself (section 8.3), and that difference is the whole
        // test.
        handles.take(rel).foreach(_())

        // `bind` is `early`'s counterpart for section 8.1's OTHER half. Binding
        // declaration belongs in `define`; this names the callback that tries
        // it from somewhere else.
        if (opt(i, "bind").asString.contains("activate")) {
          i.bind("p", (_, _) => VNull)
        }

        // `mark` registers N FOREIGN releases - section 8.3's `release`, the
        // half `acquire` cannot exercise - each recording its own index as it
        // runs. THE RECORDED LIST IS THE ONLY THING THAT DISTINGUISHES A
        // REVERSE UNWIND FROM A FORWARD ONE.
        i.statePut("unwound", VList(Nil))
        (0 until opt(i, "mark").asInt.getOrElse(0)).foreach { k =>
          i.release(() => {
            // `markfail` makes the release RAISE - the only way section 8.3's
            // `plugin_release_failed` and its `failed` status are reachable.
            if (opt(i, "markfail").truthy) {
              throw new DriverError("release failed at " + k)
            }
            i.statePut("unwound", VList(i.state.at("unwound").items :+ VNum(k.toDouble)))
          })
        }
      },
      // `deactivate` completes the pair: the guard is on the PHASE, not on "not
      // define", and an entry exercising only one leaves the other's mutation
      // alive.
      deactivate = Some { (i: Inst) =>
        if (opt(i, "bind").asString.contains("deactivate")) {
          i.bind("p", (_, _) => VNull)
        }
      }
    )

    val dep = Definition(
      name = "dep",
      define = Some { (i: Inst) =>
        i.statePut("count", VNum(0))
        declareProvides(i)
        val exports = opt(i, "exports")
        exports.keys.foreach(k => i.export(k, exports.at(k)))
      },
      activate = Some((i: Inst) => { i.acquire(); () })
    )

    val provider = Definition(
      name = "provider",
      define = Some { (i: Inst) =>
        i.statePut("count", VNum(0))
        i.bind(
          opt(i, "point").asString.getOrElse("v"),
          (_, _) => if (i.options.has("value")) opt(i, "value") else VStr(i.ref),
          opt(i, "band")
        )
        declareProvides(i)
      },
      activate = Some((i: Inst) => { i.acquire(); () })
    )

    List(
      probe, noisy, greedy, dep, provider,
      record("slow"), record("other"), record("adapter"), record("late")
    )
  }

  def withProbes: Catalog = Plugin.makeCatalog(probes)

  /** Run a command list and return section 4.5's observable. Stops at the first
    * raise; the entry's `err` matches its code.
    */
  def drive(cmds: List[Value]): Value = {
    var host = Plugin.makeHost(HostOptions(catalog = Some(withProbes), points = withPoints()))

    // Section 4.5: `result` is the value of THE LAST COMMAND THAT PRODUCES ONE.
    // Storing it and continuing - rather than returning at the first producing
    // command - is what lets an entry emit and then inspect, which most of
    // `point` needs.
    var last: Value = VNull

    cmds.foreach { cmd =>
      try {
        val (next, produced) = doCmd(host, cmd)
        host = next
        produced.foreach(v => last = v)
      } catch {
        case e: Exception =>
          // Section 4.1: `catch` records the raise and lets the run continue,
          // which is the only way to observe a `failed` instance - section
          // 5.2's whole claim is that it stays registered and inspectable.
          if (cmd.at("catch") != VBool(true)) throw e
      }
    }
    host.observable(last)
  }

  /** The second element is None for a command that PRODUCES NOTHING, which is
    * scala's spelling of every other port's sentinel: an `Option[Value]` says
    * it in the type, so a command returning `VNull` still overwrites.
    */
  def doCmd(host: Host, cmd: Value): (Host, Option[Value]) = {
    val ref = cmd.at("ref")
    val point = cmd.at("point").asString
    val spec = Value.map(
      "options" -> cmd.at("options"), "order" -> cmd.at("order"),
      "definition" -> cmd.at("definition"), "tag" -> cmd.at("tag")
    )

    cmd.at("do").asString.getOrElse("") match {
      case "host" =>
        (Plugin.makeHost(HostOptions(
          catalog = Some(withProbes),
          reserved = cmd.at("reserved").items.flatMap(_.asString),
          points = withPoints(cmd.at("points")),
          // Section 11.3's strict reading. Absent means `restart`.
          dependency = cmd.at("dependency").asString.getOrElse("restart"),
          keys = cmd.at("keys"),
          defaults = cmd.at("defaults"),
          profile = cmd.at("profile").asString
        )), None)
      // The catalog is pre-seeded with the probe set; `define` names which
      // entry backs this definition.
      case "define"     => (host, None)
      case "load"       => host.load(ref, spec); (host, None)
      case "ready" =>
        // declare FIRST, so the ordering block and definition reach the
        // instance - `ready` walks the staircase, it does not carry
        // configuration of its own.
        host.declare(ref, spec)
        host.ready(ref)
        (host, None)
      case "activate"   => host.activate(ref); (host, None)
      case "deactivate" => host.deactivate(ref); (host, None)
      case "unload"     => host.unload(ref); (host, None)
      case "apply"      => host.apply(cmd.at("doc"), cmd.at("profile").asString); (host, None)
      case "options"    => host.options(ref, cmd.at("patch")); (host, None)
      case "close"      => host.close(); (host, None)
      case "list"       => (host, Some(host.list))
      case "emit"       => (host, Some(host.emit(point.get, cmd.at("arg"))))
      case "chain"      => (host, Some(host.call(point.get, cmd.at("arg"))))
      case "provider"   => (host, Some(host.provider(point.get, cmd.at("arg"))))
      case "shadowed"   => (host, Some(VList(host.shadowed(point.get).map(VStr))))
      case "export"     => (host, Some(host.exports(cmd.at("key").asString.getOrElse(""))))
      case "capability" =>
        (host, Some(VList(host.capability(cmd.at("name").asString.getOrElse("")).map(VStr))))
      case "trace"      => (host, Some(host.trace))
      // Section 9.1's host-owned path: the embedding host installing the
      // instance whose name it reserved.
      case "hostdeclare" => (host, Some(VStr(host.hostdeclare(ref, spec).ref)))
      case "declare"     => (host, Some(VStr(host.declare(ref, spec).ref)))
      case "order"       => (host, Some(VList(host.order(point).map(VStr))))
      case "seq" =>
        (host, Some(host.instance(ref).map(e => VNum(e.seq.toDouble)).getOrElse(VNull)))
      case "pos" =>
        (host, Some(host.instance(ref).map(e => VNum(e.pos.toDouble)).getOrElse(VNull)))
      case "inner" =>
        (host, Some(host.instance(ref).flatMap(_.inner).map(_.list).getOrElse(VNull)))
      case "call" => doCall(host, cmd, ref, point)
      case other  => throw new DriverError("unknown driver command: " + other)
    }
  }

  private def doCall(host: Host, cmd: Value, ref: Value, point: Option[String])
      : (Host, Option[Value]) = {
    val entry = host.instance(ref).getOrElse(Types.fail(
      "plugin_not_loaded", "no such instance: " + Refs.canon(ref)
    ))
    cmd.at("method").asString.getOrElse("") match {
      case "bump" =>
        entry.state = entry.state.setting(
          "count", VNum(entry.state.at("count").asDouble.getOrElse(0.0) + 1)
        )
        (host, None)
      case "count" => (host, Some(VNum(entry.state.at("count").asDouble.getOrElse(0.0))))
      case "unwound" =>
        (host, Some(if (entry.state.has("unwound")) entry.state.at("unwound") else VList(Nil)))
      // Reached through the instance api, which is where section 6.6 puts it -
      // a plugin asks about itself.
      case "position" => (host, Some(host.positionOf(ref, point.get)))
      case "stray" =>
        // A release from OUTSIDE a lifecycle callback. THIS BRANCH USED TO DO
        // NOTHING, and its corpus row stayed green whatever `release` did with
        // its guard.
        host.exports(Refs.canon(ref) + "/inst") match {
          case VOpaque(obj: Inst) => obj.release(() => ())
          case _ => throw new DriverError("stray: no instance handle exported")
        }
        (host, None)
      case _ => (host, None)
    }
  }
}
