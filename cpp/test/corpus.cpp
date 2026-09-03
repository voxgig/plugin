/* The corpus reader and the entry check. See corpus.hpp. */

#include "corpus.hpp"

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <regex>
#include <sstream>

namespace plugin {

static V loaded;

static std::string specpath() {
  const char* env = std::getenv("PLUGIN_SPEC");
  if (nullptr != env && '\0' != env[0]) return env;
  return "../spec/plugin.json";
}

const V& corpus() {
  if (loaded) return loaded;

  const std::string path = specpath();
  std::ifstream in(path, std::ios::binary);
  if (!in) {
    std::cerr << "cpp: cannot open " << path << "\n";
    std::exit(2);
  }
  std::ostringstream buf;
  buf << in.rdbuf();

  std::string err;
  V v = parsejson(buf.str(), err);
  if (!v) {
    std::cerr << "cpp: " << path << " is not valid JSON: " << err << "\n";
    std::exit(2);
  }

  /* Version 1 turns on strict entry validation in every runner. A
   * corpus that lost its version marker is a corpus whose shape nobody
   * checked, so refuse it rather than run against it. */
  V version = get(get(v, "PLUGIN"), "version");
  if (!isnum(version) || 1 != static_cast<int>(asnum(version))) {
    std::cerr << "cpp: unsupported spec version\n";
    std::exit(2);
  }

  loaded = v;
  return loaded;
}

V corpussection(const std::string& name) {
  V section = get(get(corpus(), "primary"), name);
  if (!ismap(section)) {
    std::cerr << "cpp: no such corpus section: " << name << "\n";
    std::exit(2);
  }
  return section;
}

std::string corpuslabel(const std::string& group, size_t i, const V& entry) {
  V id = get(entry, "id");
  if (isstr(id)) return asstr(id);
  return group + "#" + std::to_string(i);
}

bool corpusequal(const V& a, const V& b) {
  bool anull = isnull(a), bnull = isnull(b);
  if (anull || bnull) return anull && bnull;
  if (a->kind != b->kind) return false;
  switch (a->kind) {
    case Kind::Bool: return a->boolean == b->boolean;
    case Kind::Num: return a->num == b->num;
    case Kind::Str: return a->str == b->str;
    case Kind::List: {
      if (len(a) != len(b)) return false;
      for (size_t i = 0; i < len(a); i++) {
        if (!corpusequal(at(a, i), at(b, i))) return false;
      }
      return true;
    }
    case Kind::Map: {
      if (len(a) != len(b)) return false;
      for (const auto& k : keys(a)) {
        if (!has(b, k)) return false;
        if (!corpusequal(get(a, k), get(b, k))) return false;
      }
      return true;
    }
    default: return true;
  }
}

bool corpusmatches(const V& expect, const V& actual, bool present) {
  if (isstr(expect)) {
    const std::string s = asstr(expect);
    if ("__EXISTS__" == s) return present && !isnull(actual);
    if ("__UNDEF__" == s) return !present;
    if ("__NULL__" == s) return present && isnull(actual);

    if (2 < s.size() && '/' == s.front() && '/' == s.back()) {
      if (!isstr(actual)) return false;
      try {
        /* ECMAScript, which is std::regex's default and the dialect the
         * corpus is actually written in: the patterns are JavaScript
         * `/.../` literals, so they escape `/` and `$` the way
         * JavaScript does. POSIX ERE leaves `\\/` undefined — glibc
         * tolerates it, which is why the c port next door gets away
         * with REG_EXTENDED, and libstdc++ does not. */
        std::regex re(s.substr(1, s.size() - 2));
        return std::regex_search(asstr(actual), re);
      }
      catch (const std::regex_error&) {
        return false;
      }
    }
  }

  if (islist(expect)) {
    if (!islist(actual) || len(expect) != len(actual)) return false;
    for (size_t i = 0; i < len(expect); i++) {
      if (!corpusmatches(at(expect, i), at(actual, i), true)) return false;
    }
    return true;
  }

  if (ismap(expect)) {
    if (!ismap(actual)) return false;
    for (const auto& k : sortedkeys(expect)) {
      if (!corpusmatches(get(expect, k), get(actual, k), has(actual, k))) {
        return false;
      }
    }
    return true;
  }

  return corpusequal(expect, actual);
}

std::string corpuscheck(const V& entry, const Subject& subject) {
  bool haserr = has(entry, "err");
  bool hasout = has(entry, "out");
  bool hasmatch = has(entry, "match");

  if (haserr && hasout) return "entry has both err and out";
  if (!haserr && !hasout && !hasmatch) return "entry asserts nothing";

  V value;
  bool raised = false;
  std::string code, message;

  try {
    value = subject(entry);
  }
  catch (const PluginError& e) {
    raised = true;
    code = e.code;
    message = e.message;
  }

  if (haserr) {
    if (!raised) return "expected a raise, got: " + json(value);
    V want = get(entry, "err");
    if (isstr(want)) {
      /* Errors compare by CODE (§12). Message wording is a port's own
       * business; pinning it would make every translation a corpus
       * change. */
      if (code != asstr(want)) {
        return "expected code " + asstr(want) + ", got " + code + " (" +
               message + ")";
      }
    }
    if (hasmatch) {
      V err = vmap();
      set(err, "code", vstr(code));
      set(err, "message", vstr(message));
      set(err, "name", vstr("PluginError"));
      V got = vmap();
      set(got, "err", err);
      if (!corpusmatches(get(entry, "match"), got, true)) {
        return "error did not match " + json(get(entry, "match")) + ", got " +
               json(got);
      }
    }
    return "";
  }

  if (raised) return "unexpected raise: " + code + " " + message;

  if (hasout && !corpusequal(get(entry, "out"), value)) {
    return "expected " + json(get(entry, "out")) + ", got " + json(value);
  }

  if (hasmatch) {
    V got = vmap();
    set(got, "in", get(entry, "in"));
    set(got, "out", value);
    if (!corpusmatches(get(entry, "match"), got, true)) {
      return "did not match " + json(get(entry, "match")) + ", got out=" +
             json(value);
    }
  }

  return "";
}

void corpusrungroup(Tally& t, const std::string& section,
                    const std::string& group, const V& entries,
                    const Subject& subject) {
  V entryset = get(entries, "set");
  if (!islist(entryset)) return;
  for (size_t i = 0; i < len(entryset); i++) {
    V entry = at(entryset, i);
    t.entries++;
    const std::string why = corpuscheck(entry, subject);
    if (why.empty()) continue;
    t.failures++;
    /* The label is the entry's own `id` when it has one, and those
     * already carry the section — printing the section again would
     * read `ref/ref/canon#trailing`. */
    const std::string label = corpuslabel(group, i, entry);
    if (has(entry, "id")) std::cout << label << ": " << why << "\n";
    else std::cout << section << "/" << label << ": " << why << "\n";
  }
}

void corpusrunsection(Tally& t, const std::string& section,
                      const std::function<Subject(const std::string&)>& lookup) {
  V groups = corpussection(section);
  /* SORTED, so a failure names the same group in the same place on
   * every run. */
  for (const auto& name : sortedkeys(groups)) {
    Subject s = lookup(name);
    if (!s) {
      /* A group the runner does not know is a group silently not run,
       * which is worse than a failure. */
      t.failures++;
      std::cout << section << "/" << name << ": no subject for this group\n";
      continue;
    }
    corpusrungroup(t, section, name, get(groups, name), s);
  }
}

}  // namespace plugin
