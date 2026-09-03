/* The cpp port's test runner.
 *
 * NO TEST FRAMEWORK (§16): a `main` that counts. It reports the entry
 * count as well as the pass, because "all pass" over zero entries is
 * the failure doc/plan/handover.md §4 warns about. */

#include <algorithm>
#include <iostream>
#include <string>

#include "../src/capability.hpp"
#include "../src/config.hpp"
#include "../src/env.hpp"
#include "../src/graph.hpp"
#include "../src/ref.hpp"
#include "../src/resolve.hpp"
#include "../src/version.hpp"
#include "corpus.hpp"
#include "driver.hpp"

using namespace plugin;

/* §15.3's `ref` section, group by group. EVERY group must have a
 * subject: a group the runner does not know is a group silently not
 * run, which is worse than a failure. */
static Subject refsubject(const std::string& group) {
  if ("name" == group || "bound" == group) {
    return [](const V& e) { return vbool(checkname(get(e, "in"))); };
  }
  if ("tag" == group || "boundtag" == group) {
    return [](const V& e) { return vbool(checktag(get(e, "in"))); };
  }
  if ("parse" == group || "parsebad" == group) {
    return [](const V& e) { return parseref(get(e, "in")); };
  }
  if ("format" == group || "formatbad" == group) {
    return [](const V& e) {
      V args = get(e, "args");
      return vstr(formatref(at(args, 0), at(args, 1)));
    };
  }
  if ("canon" == group) {
    return [](const V& e) { return vstr(canonref(get(e, "in"))); };
  }
  return nullptr;
}

/* --- version: the range grammar and the one predicate --------------- */

static Subject versionsubject(const std::string& group) {
  if ("range" == group || "rangebad" == group) {
    return [](const V& e) { return parserange(get(e, "in")); };
  }
  if ("satisfies" == group) {
    return [](const V& e) {
      V in = get(e, "in");
      return vbool(satisfies(get(in, "version"), get(in, "range")));
    };
  }
  return nullptr;
}

/* --- capability: matching and the total rank ------------------------ */

static Subject capabilitysubject(const std::string& group) {
  if ("match" == group || "nested" == group || "rank" == group) {
    return [](const V& e) {
      V in = get(e, "in");
      return resolvecapability(get(in, "req"), get(in, "candidates"));
    };
  }
  return nullptr;
}

/* --- resolve: name to candidate module ids -------------------------- */

static Subject resolvesubject(const std::string& group) {
  if ("candidates" == group) {
    return [](const V& e) {
      V in = get(e, "in");
      return resolvecandidates(get(in, "name"), get(in, "sources"));
    };
  }
  if ("from" == group) {
    return [](const V& e) { return resolvefrom(get(e, "in")); };
  }
  return nullptr;
}

/* --- env: the lossy encoding, and its collision --------------------- */

static Subject envsubject(const std::string&) {
  /* Every group in `env` is one call: the section is a single pure
   * function over the whole input. */
  return [](const V& e) { return applyenv(get(e, "in")); };
}

/* --- config: normalization and the ten-level ladder ------------------ */

/* The prefix IS the dispatch: `norm*` groups normalize, `opt*` groups
 * resolve. A group with neither prefix gets no subject and fails
 * loudly, rather than being silently skipped. */
static Subject configsubject(const std::string& group) {
  if (0 == group.compare(0, 4, "norm")) {
    return [](const V& e) { return normalizeconfig(get(e, "in")); };
  }
  if (0 == group.compare(0, 3, "opt")) {
    return [](const V& e) { return resolveoptions(get(e, "in")); };
  }
  return nullptr;
}

/* --- graph: resolved/blocked, and the explanation ------------------- */

static Subject graphsubject(const std::string& group) {
  if ("resolve" == group || "blocked" == group) {
    return [](const V& e) { return resolvegraph(get(e, "in")); };
  }
  return nullptr;
}

/* --- the twelve DRIVER sections ------------------------------------- */

/* Every entry carries `cmd`, and a port needs DOCS.md §4 to run them —
 * the probe catalog, the command vocabulary, and the canonical
 * observable {status, open, log, result}. Corpus files alone are not
 * enough, which is why C2 shipped both together. */
static Subject driversubject(const std::string&) {
  return [](const V& e) { return drive(get(e, "cmd")); };
}

/* The sections driven by a direct function call. */
static const std::vector<std::string> PURE = {
  "ref", "version", "capability", "resolve", "env", "config", "graph"
};

/* The driver sections, in §15.3's order. Each entry is a command list
 * against a fresh host. */
static const std::vector<std::string> DRIVER = {
  "lifecycle", "order", "point", "export", "depend", "declare",
  "state", "resource", "nest", "trace", "apply", "error"
};

/* EVERY CORPUS SECTION IS RUN (AGENTS.md §"the layout to copy").
 *
 * `corpusrunsection` already fails on a GROUP with no subject. This
 * closes the level above: a whole SECTION the runner never mentions is
 * a section silently not run, and it would pass a suite that claims all
 * 572 entries. Sixteen of the seventeen earlier ports carry this check;
 * this port shipped without it.
 *
 * It also refuses a corpus with no PLUGIN.version, because that block
 * is what turns on strict entry validation in every runner and a corpus
 * that lost it must not silently downgrade this port's checking. */
static void coverage(Tally& t) {
  const V& spec = corpus();
  V primary = get(spec, "primary");
  V meta = get(spec, "PLUGIN");

  if (!ismap(meta) || 1 != asnum(get(meta, "version"))) {
    t.failures++;
    std::cout << "coverage: corpus PLUGIN.version must be 1\n";
  }

  auto listed = [](const std::vector<std::string>& ns, const std::string& w) {
    return std::find(ns.begin(), ns.end(), w) != ns.end();
  };

  for (const std::string& name : sortedkeys(primary)) {
    if (listed(PURE, name) || listed(DRIVER, name)) continue;
    t.failures++;
    std::cout << "coverage: corpus section no test runs: " << name << "\n";
  }

  for (const auto* list : { &PURE, &DRIVER }) {
    for (const std::string& name : *list) {
      if (has(primary, name)) continue;
      t.failures++;
      std::cout << "coverage: tests name a section the corpus does not have: "
                << name << "\n";
    }
  }

  /* A floor, not a fixture: the corpus grows, and a run that suddenly
   * covers a fraction of it is the failure worth catching. */
  if (400 > t.entries) {
    t.failures++;
    std::cout << "coverage: only " << t.entries
              << " corpus entries ran; the corpus has far more\n";
  }
}

int main() {
  Tally t;

  corpusrunsection(t, "ref", refsubject);
  corpusrunsection(t, "version", versionsubject);
  corpusrunsection(t, "capability", capabilitysubject);
  corpusrunsection(t, "resolve", resolvesubject);
  corpusrunsection(t, "env", envsubject);
  corpusrunsection(t, "config", configsubject);
  corpusrunsection(t, "graph", graphsubject);

  for (const std::string& name : DRIVER) {
    corpusrunsection(t, name, driversubject);
  }

  coverage(t);

  if (0 == t.entries) {
    std::cout << "cpp: no corpus entries ran\n";
    return 1;
  }
  if (0 < t.failures) {
    std::cout << "\ncpp: " << t.failures << " failure(s) of " << t.entries
              << " entries\n";
    return 1;
  }
  std::cout << "cpp: " << t.entries << " corpus entries, all pass\n";
  return 0;
}
