package voxgig.plugin.test;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Function;
import java.util.regex.Pattern;
import voxgig.plugin.Json;
import voxgig.plugin.Types;

/**
 * The corpus runner.
 *
 * <p>Reads spec/plugin.json - the COMMITTED artifact, not the aontu source
 * - exactly as every other port's runner does. No port needs a Node
 * toolchain to run its tests, and this one does not get a private door
 * into the source either.
 *
 * <p>A group name selects the subject. That is the whole dispatch, and it
 * is deliberately dumb: a runner that inferred the subject from the
 * entry's shape would silently run the wrong function when an entry was
 * mistyped.
 */
public final class Corpus {

  private Corpus() {}

  public static final Path SPEC = Path.of("..", "spec", "plugin.json");

  /**
   * A sentinel for "this key was not present". A java map returns null for
   * both an absent key and a JSON null, and {@code __UNDEF__} and {@code
   * __NULL__} are different assertions.
   */
  public static final Object MISSING = new Object();

  private static Object cache;

  public static Object corpus() {
    if (null == cache) {
      try {
        cache = Json.parse(Files.readString(SPEC));
      } catch (Exception e) {
        throw new RuntimeException("cannot read " + SPEC.toAbsolutePath(), e);
      }
    }
    return cache;
  }

  /** The groups of a section, minus {@code DEF}, in name order. */
  public static Map<String, List<Object>> section(String name) {
    Object sec = Types.get(Types.get(corpus(), "primary"), name);
    if (null == sec) {
      throw new RuntimeException("no such corpus section: " + name);
    }
    Map<String, List<Object>> out = new LinkedHashMap<>();
    for (String group : Types.keys(sec)) {
      if ("DEF".equals(group)) {
        continue;
      }
      List<Object> set = Types.list(Types.get(Types.get(sec, group), "set"));
      if (null == set) {
        continue;
      }
      out.put(group, set);
    }
    return out;
  }

  /** A stable label, so a failure names the entry rather than an index. */
  public static String label(String group, int i, Object entry) {
    String id = Types.str(Types.get(entry, "id"));
    return null == id ? group + "#" + i : id;
  }

  /**
   * Partial match: every key the expectation names must agree, and keys it
   * does not name are ignored. {@code __EXISTS__} asserts presence without
   * pinning a value; {@code /re/} matches a string as a regular
   * expression.
   */
  public static boolean matches(Object expect, Object actual) {
    if ("__EXISTS__".equals(expect)) {
      return MISSING != actual && null != actual;
    }
    if ("__UNDEF__".equals(expect)) {
      return MISSING == actual;
    }
    if ("__NULL__".equals(expect)) {
      return MISSING != actual && null == actual;
    }

    Object got = MISSING == actual ? null : actual;

    String pattern = Types.str(expect);
    if (null != pattern && 2 < pattern.length() && pattern.startsWith("/") && pattern.endsWith("/")) {
      String text = Types.str(got);
      if (null == text) {
        return false;
      }
      // `find`, not `matches`: the corpus writes javascript regex
      // literals, and `/cycle=\[/` is a SUBSTRING test there.
      return Pattern.compile(pattern.substring(1, pattern.length() - 1)).matcher(text).find();
    }

    List<Object> wl = Types.list(expect);
    if (null != wl) {
      List<Object> gl = Types.list(got);
      if (null == gl || wl.size() != gl.size()) {
        return false;
      }
      for (int i = 0; i < wl.size(); i++) {
        if (!matches(wl.get(i), gl.get(i))) {
          return false;
        }
      }
      return true;
    }

    Map<String, Object> wm = Types.map(expect);
    if (null != wm) {
      Map<String, Object> gm = Types.map(got);
      if (null == gm) {
        return false;
      }
      for (Map.Entry<String, Object> e : wm.entrySet()) {
        Object sub = gm.containsKey(e.getKey()) ? gm.get(e.getKey()) : MISSING;
        if (!matches(e.getValue(), sub)) {
          return false;
        }
      }
      return true;
    }

    return Types.same(expect, got);
  }

  /**
   * Run one entry against a subject and report the disagreement, if any.
   *
   * <p>The three combinations the spec format allows are enforced here as
   * well as at build time, because a runner that quietly accepted {@code
   * err} beside {@code out} would let a contradictory entry pass.
   */
  public static String check(Object entry, Function<Object, Object> subject) {
    if (Types.has(entry, "err") && Types.has(entry, "out")) {
      return "entry has both err and out";
    }

    Object value = null;
    RuntimeException raised = null;
    try {
      value = subject.apply(entry);
    } catch (RuntimeException e) {
      raised = e;
    }

    if (Types.has(entry, "err")) {
      if (null == raised) {
        return "expected a raise, got: " + Json.write(value);
      }
      Object want = Types.get(entry, "err");
      if (!Boolean.TRUE.equals(want)) {
        // Errors compare by CODE (§12). Message wording is a port's own
        // business, and pinning it would make every translation a corpus
        // change.
        String got = Types.codeof(raised);
        if (!got.equals(want)) {
          return "expected code " + Json.write(want) + ", got " + got + " (" + raised.getMessage() + ")";
        }
      }
      if (Types.has(entry, "match")) {
        Map<String, Object> err = Types.newmap();
        err.put("code", Types.codeof(raised));
        err.put("message", raised.getMessage());
        err.put("name", "PluginError");
        Map<String, Object> got = Types.newmap();
        got.put("err", err);
        if (!matches(Types.get(entry, "match"), got)) {
          return "error did not match "
              + Json.write(Types.get(entry, "match"))
              + ", got "
              + Json.write(got);
        }
      }
      return null;
    }

    if (null != raised) {
      return "unexpected raise: " + Types.codeof(raised) + " " + raised.getMessage();
    }

    if (Types.has(entry, "out") && !Types.same(Types.get(entry, "out"), value)) {
      return "expected " + Json.write(Types.get(entry, "out")) + ", got " + Json.write(value);
    }

    if (Types.has(entry, "match")) {
      Map<String, Object> got = Types.newmap();
      got.put("in", Types.get(entry, "in"));
      got.put("out", value);
      if (!matches(Types.get(entry, "match"), got)) {
        return "did not match "
            + Json.write(Types.get(entry, "match"))
            + ", got out="
            + Json.write(value);
      }
    }

    if (!Types.has(entry, "out") && !Types.has(entry, "match")) {
      return "entry asserts nothing";
    }

    return null;
  }
}
