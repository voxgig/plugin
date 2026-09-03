/* The corpus reader and the entry check (DOCS.md §4.5, §15).
 *
 * THE PLUGIN LIBRARY MUST NEVER BE USED TO IMPLEMENT ITS OWN TESTS
 * (AGENTS.md prime directive 6), and that covers the TYPING as well as
 * the comparison. This file asks `value.hpp` what a value is, because
 * `value.hpp` is the JSON reader rather than the library under test —
 * but `same`, `truthy` and the merge semantics the corpus pins are all
 * re-derived here rather than borrowed from `types.cpp`.
 *
 * NO TEST FRAMEWORK: §16 permits one runtime dependency, C++ has no
 * port of it, and a unit-test library would be a second. The runner is
 * a `main` that counts. */

#ifndef VOXGIG_PLUGIN_CORPUS_HPP
#define VOXGIG_PLUGIN_CORPUS_HPP

#include <functional>
#include <string>

#include "../src/types.hpp"
#include "../src/value.hpp"

namespace plugin {

/* The whole corpus, parsed once. Exits loudly if the JSON is missing or
 * malformed: a runner that reports zero tests as a pass is the failure
 * mode doc/plan/handover.md §4 exists to prevent. */
const V& corpus();

/* One section's groups. Exits if the section is absent, because a
 * section named in §15.3 and missing here is a corpus bug. */
V corpussection(const std::string& name);

/* A stable label, so a failure names the entry rather than an index. */
std::string corpuslabel(const std::string& group, size_t i, const V& entry);

/* Deep equality over spec values: key order never matters, list order
 * always does. Written here, not taken from the library. */
bool corpusequal(const V& a, const V& b);

/* `match` semantics: __EXISTS__, __UNDEF__, __NULL__, /regex/, and
 * partial map matching. `present` distinguishes an absent key from one
 * holding null, which __UNDEF__ and __NULL__ exist to tell apart. */
bool corpusmatches(const V& expect, const V& actual, bool present);

/* The subject produces the entry's observable, or raises. */
using Subject = std::function<V(const V& entry)>;

/* Run one entry and report the disagreement, or empty when it passes.
 *
 * The three combinations the spec format allows are enforced here as
 * well as at build time, because a runner that quietly accepted `err`
 * beside `out` would let a contradictory entry pass. */
std::string corpuscheck(const V& entry, const Subject& subject);

struct Tally {
  size_t entries = 0;
  size_t failures = 0;
};

/* Section/group iteration helpers, so a runner reads as a list of
 * sections rather than as three nested loops. */
void corpusrungroup(Tally& t, const std::string& section,
                    const std::string& group, const V& entries,
                    const Subject& subject);
void corpusrunsection(Tally& t, const std::string& section,
                      const std::function<Subject(const std::string&)>& lookup);

}  // namespace plugin

#endif
