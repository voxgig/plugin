/* The corpus reader and the entry check (DOCS.md §4.5, §15).
 *
 * THE PLUGIN LIBRARY MUST NEVER BE USED TO IMPLEMENT ITS OWN TESTS
 * (AGENTS.md prime directive 6), and that covers the TYPING as well as
 * the comparison. This file asks `value.h` what a value is, because
 * `value.h` is the JSON reader rather than the library under test — but
 * `same`, `truthy` and the merge semantics the corpus pins are all
 * re-derived here rather than borrowed from `types.c`.
 *
 * NO TEST FRAMEWORK: §16 permits one runtime dependency, C has no port
 * of it, and a unit-test library would be a second. The runner is a
 * `main` that counts.
 */

#ifndef VOXGIG_PLUGIN_CORPUS_H
#define VOXGIG_PLUGIN_CORPUS_H

#include <stdbool.h>

#include "../src/types.h"
#include "../src/value.h"

/* The whole corpus, parsed once. Exits loudly if the JSON is missing or
 * malformed: a runner that reports zero tests as a pass is the failure
 * mode doc/plan/handover.md §4 exists to prevent. */
Value *corpus(void);

/* One section's groups. Raises through `fail` if the section is absent,
 * because a section named in §15.3 and missing here is a corpus bug. */
Value *corpus_section(const char *name);

/* A stable label, so a failure names the entry rather than an index. */
const char *corpus_label(const char *group, size_t i, Value *entry);

/* Deep equality over spec values: key order never matters, list order
 * always does. Written here, not taken from the library. */
bool corpus_equal(Value *a, Value *b);

/* `match` semantics: __EXISTS__, __UNDEF__, __NULL__, /regex/, and
 * partial map matching. `present` distinguishes an absent key from one
 * holding null, which __UNDEF__ and __NULL__ exist to tell apart. */
bool corpus_matches(Value *expect, Value *actual, bool present);

/* The subject produces the entry's observable, or raises. */
typedef Value *(*Subject)(Value *entry, void *ctx);

/* Run one entry and report the disagreement, or NULL when it passes.
 *
 * The three combinations the spec format allows are enforced here as
 * well as at build time, because a runner that quietly accepted `err`
 * beside `out` would let a contradictory entry pass. */
const char *corpus_check(Value *entry, Subject subject, void *ctx);

/* Section/group iteration helpers, so a runner reads as a list of
 * sections rather than as three nested loops. */
typedef struct {
  size_t entries;
  size_t failures;
} Tally;

void corpus_run_group(Tally *t, const char *section, const char *group,
                      Value *entries, Subject subject, void *ctx);
void corpus_run_section(Tally *t, const char *section, Subject subject,
                        void *ctx);

#endif
