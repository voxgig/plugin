package voxgig.plugin.test;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import voxgig.plugin.Catalog;
import voxgig.plugin.Definition;
import voxgig.plugin.Entry;
import voxgig.plugin.Host;
import voxgig.plugin.Inst;
import voxgig.plugin.Json;
import voxgig.plugin.Point;
import voxgig.plugin.PluginException;
import voxgig.plugin.Types;

/**
 * The driver (DOCS.md §4).
 *
 * <p>Every port implements this same small thing and nothing else is
 * port-specific: the probe catalog, the command interpreter, and the
 * canonical observable.
 */
public final class Driver {

  private Driver() {}

  /**
   * A sentinel for "this command produced nothing", so a command that
   * legitimately produces null - {@code export} of a missing key - still
   * overwrites the previous result.
   */
  public static final Object NOTHING = new Object();

  /** A value rendered as text: a string is itself, anything else is JSON. */
  static String text(Object value) {
    String s = Types.str(value);
    return null == s ? Json.write(value) : s;
  }

  static double num(Object value) {
    Double n = Types.num(value);
    return null == n ? 0 : n;
  }

  /**
   * §4.3's six probes. Their behaviour is as much the contract as the
   * runner is - this is where twenty implementations of {@code noisy} are
   * made to fail at the same callback in the same way.
   */
  public static List<Definition> probes() {
    List<Definition> out = new ArrayList<>();

    Definition probe = new Definition("probe");
    probe.define =
        i -> {
          if (!i.state().containsKey("count")) {
            i.state().put("count", 0.0);
          }
          Object band = Types.get(i.options(), "band");
          // One hook binding (`p`) and one chain wrap (`c`) - the
          // workhorse shape DOCS.md §4.3 specifies.
          i.bind(
              "p",
              (next, args) -> {
                i.state().put("count", num(i.state().get("count")) + 1);
                return null;
              },
              band);
          // Wrap AFTER next, so the result spells the nesting left to
          // right: outermost first. Wrapping the ARGUMENT instead would
          // spell it backwards and make every chain expectation read
          // wrong.
          i.bind(
              "c",
              (next, args) -> {
                String wrap = Types.str(Types.get(i.options(), "wrap"));
                Object inner = null == next ? null : next.call(args);
                return (null == wrap ? ":" : wrap) + text(inner);
              },
              band);
          i.export("client", i.ref);
          // The instance api itself, so the driver's `stray` command can
          // call `release` from OUTSIDE a lifecycle callback.
          i.export("inst", i);
          declareprovides(i);
        };
    probe.activate =
        i -> {
          i.acquire();
          // §6.5: an instance that is itself a host. The outer owns the
          // inner's lifetime - registered in the scope, so it closes on
          // deactivate in the same reverse unwind as every other resource.
          Object nest = Types.get(i.options(), "nest");
          if (null == nest) {
            return;
          }
          Map<String, Object> opts = Types.newmap();
          opts.put("points", withpoints(null));
          Host inner = i.nest(opts);
          for (Definition d : probes()) {
            inner.define(d);
          }
          for (Object r : Types.list(nest)) {
            inner.ready(r);
          }
        };
    out.add(probe);

    Definition noisy = new Definition("noisy");
    noisy.define =
        i -> {
          if (!i.state().containsKey("count")) {
            i.state().put("count", 0.0);
          }
          boom(i, "define");
        };
    noisy.activate =
        i -> {
          // Acquire BEFORE the raise, so a failing activate has something
          // to leak if the scope does not unwind - which is the whole
          // point of the entry that asserts open == 0 afterwards.
          i.acquire();
          reenter(i, "activate");
          boom(i, "activate");
        };
    noisy.deactivate = i -> boom(i, "deactivate");
    noisy.close = i -> boom(i, "close");
    out.add(noisy);

    Definition greedy = new Definition("greedy");
    greedy.define =
        i -> {
          i.state().put("count", 0.0);
          // §8.1 puts resource capture in `activate`. `early` NAMES the
          // call that reaches for it in `define`, because `acquire` and
          // `release` carry the guard separately.
          Object early = Types.get(i.options(), "early");
          if ("acquire".equals(early)) {
            i.acquire();
          }
          if ("release".equals(early)) {
            i.release(() -> {});
          }
        };
    greedy.activate =
        i -> {
          Object opts = i.options();
          int n = (int) num(Types.get(opts, "acquire"));
          int rel = (int) num(Types.get(opts, "release"));
          List<Entry.ScopeFn> handles = new ArrayList<>();
          for (int k = 0; k < n; k++) {
            handles.add(i.acquire());
          }
          // Release some explicitly; the DIFFERENCE is what the instance
          // scope must unwind by itself (§8.3), and that difference is the
          // whole test.
          for (int k = 0; k < Math.min(rel, handles.size()); k++) {
            handles.get(k).run();
          }

          // `bind` is `early`'s counterpart for §8.1's OTHER half. Binding
          // declaration belongs in `define`; this names the callback that
          // tries it from somewhere else.
          if ("activate".equals(Types.get(opts, "bind"))) {
            i.bind("p", (next, args) -> null, null);
          }

          // `mark` registers N FOREIGN releases - §8.3's `release`, the
          // half `acquire` cannot exercise - each recording its own index
          // as it runs. THE RECORDED LIST IS THE ONLY THING THAT
          // DISTINGUISHES A REVERSE UNWIND FROM A FORWARD ONE.
          i.state().put("unwound", new ArrayList<Object>());
          boolean markfail = Types.truthy(Types.get(opts, "markfail"));
          int mark = (int) num(Types.get(opts, "mark"));
          for (int k = 0; k < mark; k++) {
            final int index = k;
            i.release(
                () -> {
                  // `markfail` makes the release RAISE - the only way
                  // §8.3's `plugin_release_failed` and its `failed` status
                  // are reachable.
                  if (markfail) {
                    throw new IllegalStateException("release failed at " + index);
                  }
                  Types.list(i.state().get("unwound")).add((double) index);
                });
          }
        };
    // `deactivate` completes the pair: the guard is on the PHASE, not on
    // "not define", and an entry exercising only one leaves the other's
    // mutation alive.
    greedy.deactivate =
        i -> {
          if ("deactivate".equals(Types.get(i.options(), "bind"))) {
            i.bind("p", (next, args) -> null, null);
          }
        };
    out.add(greedy);

    Definition dep = new Definition("dep");
    dep.define =
        i -> {
          i.state().put("count", 0.0);
          declareprovides(i);
          Object exports = Types.get(i.options(), "exports");
          for (String k : Types.keys(exports)) {
            i.export(k, Types.get(exports, k));
          }
        };
    dep.activate = i -> i.acquire();
    out.add(dep);

    Definition provider = new Definition("provider");
    provider.define =
        i -> {
          i.state().put("count", 0.0);
          Object opts = i.options();
          String point = Types.str(Types.get(opts, "point"));
          i.bind(
              null == point ? "v" : point,
              (next, args) ->
                  Types.has(i.options(), "value") ? Types.get(i.options(), "value") : i.ref,
              Types.get(opts, "band"));
          declareprovides(i);
        };
    provider.activate = i -> i.acquire();
    out.add(provider);

    for (String name : new String[] {"slow", "other", "adapter", "late"}) {
      Definition d = new Definition(name);
      d.define =
          i -> {
            if (!i.state().containsKey("count")) {
              i.state().put("count", 0.0);
            }
          };
      d.activate = i -> i.acquire();
      out.add(d);
    }

    return out;
  }

  static void declareprovides(Inst inst) {
    List<Object> provides = Types.list(Types.get(inst.options(), "provides"));
    if (null == provides) {
      return;
    }
    for (Object p : provides) {
      inst.provides(p);
    }
  }

  static void boom(Inst inst, String callback) {
    Object opts = inst.options();
    if (!callback.equals(Types.get(opts, "fail"))) {
      return;
    }
    // `bare` raises WITHOUT a code - the ordinary library error §12's
    // `plugin_<phase>_failed` codes exist to wrap.
    if (Types.truthy(Types.get(opts, "bare"))) {
      throw new IllegalStateException("probe failed at " + callback);
    }
    String code = Types.str(Types.get(opts, "code"));
    throw new PluginException(
        null == code ? "plugin_" + callback + "_failed" : code,
        "probe failed at " + callback,
        null);
  }

  static void reenter(Inst inst, String callback) {
    if (!callback.equals(Types.get(inst.options(), "reenter"))) {
      return;
    }
    // A transition from inside a lifecycle callback (§5.2).
    inst.host.activate(inst.ref);
  }

  /**
   * The points every driver host declares. DOCS.md §4.3 defines {@code
   * probe} as binding one hook point ({@code p}) and wrapping one chain
   * point ({@code c}), so a host without them cannot load the probe at all
   * - they are part of the contract's baseline rather than a fixture
   * convenience. {@code v} is the provider point the {@code provider}
   * probe defaults to.
   */
  public static Map<String, Object> withpoints(Object extra) {
    Map<String, Object> out = Types.newmap();

    Map<String, Object> p = Types.newmap();
    p.put("kind", "hook");
    out.put("p", p);

    Map<String, Object> c = Types.newmap();
    c.put("kind", "chain");
    c.put("base", (Point.NextFn) args -> 0 < args.length ? args[0] : null);
    out.put("c", c);

    Map<String, Object> v = Types.newmap();
    v.put("kind", "provider");
    out.put("v", v);

    // A `host` command REPLACES a base point rather than merging into it,
    // so an entry can redeclare `c` with its own base or `v` as exclusive
    // without inheriting the default's shape.
    for (String k : Types.keys(extra)) {
      out.put(k, Types.get(extra, k));
    }
    return out;
  }

  static Host newhost(Object cmd) {
    Map<String, Object> opts = Types.newmap();
    opts.put("reserved", Types.get(cmd, "reserved"));
    opts.put("keys", Types.get(cmd, "keys"));
    opts.put("defaults", Types.get(cmd, "defaults"));
    opts.put("profile", Types.get(cmd, "profile"));
    opts.put("points", withpoints(Types.get(cmd, "points")));
    // §11.3's strict reading. Absent means `restart`.
    opts.put("dependency", Types.get(cmd, "dependency"));
    Host host = new Host(opts);
    host.catalog(Catalog.makeCatalog(probes()));
    return host;
  }

  /** One command's outcome: the host to carry on with, and any result. */
  private static final class Step {
    final Host host;
    final Object value;

    Step(Host host, Object value) {
      this.host = host;
      this.value = value;
    }
  }

  /**
   * Run a command list and return §4.5's observable. Stops at the first
   * raise; the entry's {@code err} matches its code.
   */
  public static Object drive(Object cmds) {
    Host host = newhost(Types.newmap());

    // §4.5: `result` is the value of THE LAST COMMAND THAT PRODUCES ONE.
    // Storing it and continuing - rather than returning at the first
    // producing command - is what lets an entry emit and then inspect,
    // which most of `point` needs.
    Object last = null;

    for (Object cmd : Types.list(cmds)) {
      try {
        Step step = docmd(host, cmd);
        host = step.host;
        if (NOTHING != step.value) {
          last = step.value;
        }
      } catch (RuntimeException e) {
        // §4.1: `catch` records the raise and lets the run continue, which
        // is the only way to observe a `failed` instance - §5.2's whole
        // claim is that it stays registered and inspectable.
        if (!Boolean.TRUE.equals(Types.get(cmd, "catch"))) {
          throw e;
        }
      }
    }
    return host.observable(last);
  }

  private static Step docmd(Host host, Object cmd) {
    Object ref = Types.get(cmd, "ref");
    String point = Types.str(Types.get(cmd, "point"));
    Map<String, Object> spec = Types.newmap();
    spec.put("options", Types.get(cmd, "options"));
    spec.put("order", Types.get(cmd, "order"));
    spec.put("definition", Types.get(cmd, "definition"));
    spec.put("tag", Types.get(cmd, "tag"));

    String verb = Types.str(Types.get(cmd, "do"));
    switch (null == verb ? "" : verb) {
      case "host":
        return new Step(newhost(cmd), NOTHING);
      // The catalog is pre-seeded with the probe set; `define` names which
      // entry backs this definition.
      case "define":
        return new Step(host, NOTHING);
      case "load":
        host.load(ref, spec);
        return new Step(host, NOTHING);
      case "ready":
        // declare FIRST, so the ordering block and definition reach the
        // instance - `ready` walks the staircase, it does not carry
        // configuration of its own.
        host.declare(ref, spec);
        host.ready(ref);
        return new Step(host, NOTHING);
      case "activate":
        host.activate(ref);
        return new Step(host, NOTHING);
      case "deactivate":
        host.deactivate(ref);
        return new Step(host, NOTHING);
      case "unload":
        host.unload(ref);
        return new Step(host, NOTHING);
      case "apply":
        host.apply(Types.get(cmd, "doc"), Types.get(cmd, "profile"));
        return new Step(host, NOTHING);
      case "options":
        host.options(ref, Types.get(cmd, "patch"));
        return new Step(host, NOTHING);
      case "close":
        host.close();
        return new Step(host, NOTHING);
      case "list":
        return new Step(host, host.list());
      case "emit":
        return new Step(host, host.emit(point, Types.get(cmd, "arg")));
      case "chain":
        return new Step(host, host.call(point, new Object[] {Types.get(cmd, "arg")}));
      case "provider":
        return new Step(host, host.provider(point, new Object[] {Types.get(cmd, "arg")}));
      case "shadowed":
        return new Step(host, new ArrayList<Object>(host.shadowed(point)));
      case "export":
        return new Step(host, host.exports(Types.str(Types.get(cmd, "key"))));
      case "capability":
        return new Step(host, new ArrayList<Object>(host.capability(Types.str(Types.get(cmd, "name")))));
      case "trace":
        return new Step(host, host.trace());
      case "hostdeclare":
        // §9.1's host-owned path: the embedding host installing the
        // instance whose name it reserved.
        return new Step(host, host.hostdeclare(ref, spec).ref);
      case "declare":
        return new Step(host, host.declare(ref, spec).ref);
      case "order":
        return new Step(host, new ArrayList<Object>(host.order(point)));
      case "seq":
        {
          Entry entry = host.instance(ref);
          return new Step(host, null == entry ? null : entry.seq);
        }
      case "pos":
        {
          Entry entry = host.instance(ref);
          return new Step(host, null == entry ? null : entry.pos);
        }
      case "inner":
        {
          Entry entry = host.instance(ref);
          return new Step(
              host, null == entry || null == entry.inner ? null : entry.inner.list());
        }
      case "call":
        return docall(host, cmd, ref, point);
      default:
        throw new IllegalStateException("unknown driver command: " + verb);
    }
  }

  private static Step docall(Host host, Object cmd, Object ref, String point) {
    Entry entry = host.instance(ref);
    if (null == entry) {
      throw new PluginException("plugin_not_loaded", "no such instance: " + ref, null);
    }
    String method = Types.str(Types.get(cmd, "method"));
    switch (null == method ? "" : method) {
      case "bump":
        entry.state.put("count", num(entry.state.get("count")) + 1);
        return new Step(host, NOTHING);
      case "count":
        return new Step(host, entry.state.containsKey("count") ? entry.state.get("count") : 0.0);
      case "unwound":
        return new Step(
            host,
            entry.state.containsKey("unwound")
                ? entry.state.get("unwound")
                : new ArrayList<Object>());
      // Reached through the instance api, which is where §6.6 puts it - a
      // plugin asks about itself.
      case "position":
        return new Step(host, host.positionof(Types.str(ref), point));
      case "stray":
        {
          // A release from OUTSIDE a lifecycle callback. THIS BRANCH USED
          // TO DO NOTHING, and its corpus row stayed green whatever
          // `release` did with its guard.
          Object exported = host.exports(Types.str(ref) + "/inst");
          ((Inst) exported).release(() -> {});
          return new Step(host, NOTHING);
        }
      default:
        return new Step(host, NOTHING);
    }
  }
}
