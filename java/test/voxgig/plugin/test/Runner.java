package voxgig.plugin.test;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Function;
import voxgig.plugin.Config;
import voxgig.plugin.Env;
import voxgig.plugin.Graph;
import voxgig.plugin.Plugin;
import voxgig.plugin.Refs;
import voxgig.plugin.Resolve;
import voxgig.plugin.Types;
import voxgig.plugin.Version;

/**
 * The whole suite: pure sections by direct call, driver sections by
 * command list, and a coverage guard above both.
 *
 * <p>A plain {@code main} rather than JUnit, for the same reason the port
 * has no build tool: a conformance suite whose only job is to run one
 * corpus and report which entries disagree does not need a framework, and
 * adding one would make {@code make test} depend on a jar nobody else in
 * this repo has.
 */
public final class Runner {

  private Runner() {}

  private static final List<String> FAILURES = new ArrayList<>();
  private static int sections;
  private static int entries;

  private static final List<String> PURE_SECTIONS =
      List.of("ref", "env", "version", "capability", "graph", "resolve", "config");

  private static final List<String> DRIVER_SECTIONS =
      List.of(
          "lifecycle", "order", "point", "export", "depend", "declare", "state", "resource",
          "nest", "trace", "apply", "error");

  private static void report(String name, String group, int i, Object entry, String why) {
    FAILURES.add(name + "/" + Corpus.label(group, i, entry) + ": " + why);
  }

  /**
   * Dispatch every group, and fail on a group the runner does not know - a
   * group silently not run is worse than a failure.
   */
  private static void section(String name, Map<String, Function<Object, Object>> subjects) {
    Map<String, List<Object>> groups = Corpus.section(name);
    sections++;
    for (Map.Entry<String, List<Object>> g : groups.entrySet()) {
      Function<Object, Object> subject = subjects.get(g.getKey());
      if (null == subject) {
        FAILURES.add(name + ": corpus group with no subject: " + g.getKey());
        continue;
      }
      List<Object> set = g.getValue();
      for (int i = 0; i < set.size(); i++) {
        entries++;
        String why = Corpus.check(set.get(i), subject);
        if (null != why) {
          report(name, g.getKey(), i, set.get(i), why);
        }
      }
    }
  }

  private static Map<String, Function<Object, Object>> subjects(Object... pairs) {
    Map<String, Function<Object, Object>> out = new LinkedHashMap<>();
    for (int i = 0; i + 1 < pairs.length; i += 2) {
      @SuppressWarnings("unchecked")
      Function<Object, Object> f = (Function<Object, Object>) pairs[i + 1];
      out.put((String) pairs[i], f);
    }
    return out;
  }

  public static void main(String[] args) {
    Function<Object, Object> parse = e -> Refs.parseRef(Types.get(e, "in"));
    Function<Object, Object> format =
        e -> {
          Object list = Types.get(e, "args");
          return Refs.formatRef(Types.at(list, 0), Types.at(list, 1));
        };
    Function<Object, Object> name = e -> Refs.checkName(Types.get(e, "in"));
    Function<Object, Object> tag = e -> Refs.checkTag(Types.get(e, "in"));

    section(
        "ref",
        subjects(
            "parse", parse,
            "parsebad", parse,
            "format", format,
            "formatbad", format,
            "canon", (Function<Object, Object>) e -> Refs.canonRef(Types.get(e, "in")),
            "name", name,
            "tag", tag,
            "bound", name,
            "boundtag", tag));

    Function<Object, Object> env = e -> Env.applyEnv(Types.get(e, "in"));
    section(
        "env",
        subjects(
            "option", env, "value", env, "toggle", env, "profile", env, "ambiguous", env,
            "reserved", env));

    Function<Object, Object> range = e -> Version.parseRange(Types.get(e, "in"));
    section(
        "version",
        subjects(
            "range",
            range,
            "rangebad",
            range,
            "satisfies",
            (Function<Object, Object>)
                e ->
                    Version.satisfies(
                        Types.get(Types.get(e, "in"), "version"),
                        Types.get(Types.get(e, "in"), "range"))));

    Function<Object, Object> cap =
        e ->
            Plugin.resolveCapability(
                Types.get(Types.get(e, "in"), "req"),
                Types.list(Types.get(Types.get(e, "in"), "candidates")));
    section("capability", subjects("match", cap, "nested", cap, "rank", cap));

    Function<Object, Object> graph = e -> Graph.resolveGraph(Types.get(e, "in"));
    section("graph", subjects("resolve", graph, "blocked", graph));

    section(
        "resolve",
        subjects(
            "candidates",
            (Function<Object, Object>)
                e ->
                    Resolve.resolveCandidates(
                        Types.str(Types.get(Types.get(e, "in"), "name")),
                        Types.get(Types.get(e, "in"), "sources")),
            "from",
            (Function<Object, Object>) e -> Resolve.resolveFrom(Types.get(e, "in"))));

    // `config` picks its subject by group PREFIX rather than by name,
    // because the two functions split the section cleanly.
    Map<String, List<Object>> configgroups = Corpus.section("config");
    sections++;
    for (Map.Entry<String, List<Object>> g : configgroups.entrySet()) {
      Function<Object, Object> subject = null;
      if (g.getKey().startsWith("norm")) {
        subject = e -> Config.normalizeConfig(Types.get(e, "in"));
      } else if (g.getKey().startsWith("opt")) {
        subject = e -> Config.resolveOptions(Types.get(e, "in"));
      }
      if (null == subject) {
        FAILURES.add("config: corpus group with no subject: " + g.getKey());
        continue;
      }
      List<Object> set = g.getValue();
      for (int i = 0; i < set.size(); i++) {
        entries++;
        String why = Corpus.check(set.get(i), subject);
        if (null != why) {
          report("config", g.getKey(), i, set.get(i), why);
        }
      }
    }

    // ---- driver sections --------------------------------------------

    Function<Object, Object> drive = e -> Driver.drive(Types.get(e, "in"));
    for (String name2 : DRIVER_SECTIONS) {
      Map<String, List<Object>> groups = Corpus.section(name2);
      sections++;
      for (Map.Entry<String, List<Object>> g : groups.entrySet()) {
        List<Object> set = g.getValue();
        for (int i = 0; i < set.size(); i++) {
          entries++;
          if (null == Types.list(Types.get(set.get(i), "in"))) {
            report(name2, g.getKey(), i, set.get(i), "driver entry without a command list in `in`");
            continue;
          }
          String why = Corpus.check(set.get(i), drive);
          if (null != why) {
            report(name2, g.getKey(), i, set.get(i), why);
          }
        }
      }
    }

    // ---- coverage ----------------------------------------------------
    //
    // EVERY CORPUS SECTION IS RUN. The per-section dispatch already fails
    // on a GROUP with no subject; this closes the level above, because a
    // whole SECTION the runner never mentions is a section silently not
    // run.

    Object spec = Corpus.corpus();
    Object primary = Types.get(spec, "primary");

    // The corpus metadata block is what turns on strict entry validation
    // in every runner, so a corpus that lost it must not silently
    // downgrade this port's checking.
    if (!Double.valueOf(1).equals(Types.num(Types.get(Types.get(spec, "PLUGIN"), "version")))) {
      FAILURES.add("corpus PLUGIN.version must be 1");
    }

    List<String> ran = new ArrayList<>(PURE_SECTIONS);
    ran.addAll(DRIVER_SECTIONS);
    List<String> missing = new ArrayList<>();
    for (String n : Types.keys(primary)) {
      if (!ran.contains(n)) {
        missing.add(n);
      }
    }
    if (!missing.isEmpty()) {
      FAILURES.add("corpus sections no test runs: " + String.join(", ", missing));
    }
    List<String> extra = new ArrayList<>();
    for (String n : ran) {
      if (!Types.has(primary, n)) {
        extra.add(n);
      }
    }
    if (!extra.isEmpty()) {
      FAILURES.add("tests name sections the corpus does not have: " + String.join(", ", extra));
    }

    // A floor, not a fixture: the corpus grows, and a run that suddenly
    // covers a fraction of it is the failure worth catching.
    if (entries < 400) {
      FAILURES.add("only " + entries + " corpus entries reachable");
    }

    // ---- report ------------------------------------------------------

    if (FAILURES.isEmpty()) {
      System.out.println(
          "java: " + entries + " corpus entries across " + sections + " sections, all pass");
      return;
    }

    for (String f : FAILURES) {
      System.err.println(f);
    }
    System.err.println("\njava: " + FAILURES.size() + " failure(s) of " + entries + " entries");
    System.exit(1);
  }
}
