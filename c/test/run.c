/* The c port's test runner.
 *
 * NO TEST FRAMEWORK (§16): a `main` that counts. It reports the entry
 * count as well as the pass, because "all pass" over zero entries is
 * the failure doc/plan/handover.md §4 warns about.
 */

#include <stdio.h>
#include <string.h>

#include "corpus.h"
#include "../src/ref.h"
#include "../src/version.h"
#include "../src/capability.h"
#include "../src/resolve.h"
#include "../src/env.h"
#include "../src/config.h"
#include "../src/graph.h"
#include "driver.h"

/* --- ref: the four pure functions ----------------------------------- */

static Value *sub_checkname(Value *e, void *ctx) {
  (void)ctx;
  return vbool(checkname(vget(e, "in")));
}

static Value *sub_checktag(Value *e, void *ctx) {
  (void)ctx;
  return vbool(checktag(vget(e, "in")));
}

static Value *sub_parseref(Value *e, void *ctx) {
  (void)ctx;
  return parseref(vget(e, "in"));
}

static Value *sub_formatref(Value *e, void *ctx) {
  (void)ctx;
  Value *args = vget(e, "args");
  return vstr(formatref(vat(args, 0), vat(args, 1)));
}

static Value *sub_canonref(Value *e, void *ctx) {
  (void)ctx;
  return vstr(canonref(vget(e, "in")));
}

/* §15.3's `ref` section, group by group. EVERY group must have a
 * subject: a group the runner does not know is a group silently not
 * run, which is worse than a failure. */
static Subject ref_subject(const char *group) {
  if (0 == strcmp(group, "name")) return sub_checkname;
  if (0 == strcmp(group, "bound")) return sub_checkname;
  if (0 == strcmp(group, "tag")) return sub_checktag;
  if (0 == strcmp(group, "boundtag")) return sub_checktag;
  if (0 == strcmp(group, "parse")) return sub_parseref;
  if (0 == strcmp(group, "parsebad")) return sub_parseref;
  if (0 == strcmp(group, "format")) return sub_formatref;
  if (0 == strcmp(group, "formatbad")) return sub_formatref;
  if (0 == strcmp(group, "canon")) return sub_canonref;
  return NULL;
}

/* --- version: the range grammar and the one predicate --------------- */

static Value *sub_parserange(Value *e, void *ctx) {
  (void)ctx;
  return parserange(vget(e, "in"));
}

static Value *sub_satisfies(Value *e, void *ctx) {
  (void)ctx;
  Value *in = vget(e, "in");
  return vbool(satisfies(vget(in, "version"), vget(in, "range")));
}

static Subject version_subject(const char *group) {
  if (0 == strcmp(group, "range")) return sub_parserange;
  if (0 == strcmp(group, "rangebad")) return sub_parserange;
  if (0 == strcmp(group, "satisfies")) return sub_satisfies;
  return NULL;
}

/* --- capability: matching and the total rank ------------------------ */

static Value *sub_resolvecapability(Value *e, void *ctx) {
  (void)ctx;
  Value *in = vget(e, "in");
  return resolvecapability(vget(in, "req"), vget(in, "candidates"));
}

static Subject capability_subject(const char *group) {
  if (0 == strcmp(group, "match")) return sub_resolvecapability;
  if (0 == strcmp(group, "nested")) return sub_resolvecapability;
  if (0 == strcmp(group, "rank")) return sub_resolvecapability;
  return NULL;
}

/* --- resolve: name to candidate module ids -------------------------- */

static Value *sub_candidates(Value *e, void *ctx) {
  (void)ctx;
  Value *in = vget(e, "in");
  return resolvecandidates(vget(in, "name"), vget(in, "sources"));
}

static Value *sub_from(Value *e, void *ctx) {
  (void)ctx;
  return resolvefrom(vget(e, "in"));
}

static Subject resolve_subject(const char *group) {
  if (0 == strcmp(group, "candidates")) return sub_candidates;
  if (0 == strcmp(group, "from")) return sub_from;
  return NULL;
}

/* --- env: the lossy encoding, and its collision --------------------- */

static Value *sub_applyenv(Value *e, void *ctx) {
  (void)ctx;
  return applyenv(vget(e, "in"));
}

static Subject env_subject(const char *group) {
  (void)group;
  /* Every group in `env` is one call: the section is a single pure
   * function over the whole input. */
  return sub_applyenv;
}

/* --- config: normalization and the ten-level ladder ------------------ */

static Value *sub_normalizeconfig(Value *e, void *ctx) {
  (void)ctx;
  return normalizeconfig(vget(e, "in"));
}

static Value *sub_resolveoptions(Value *e, void *ctx) {
  (void)ctx;
  return resolveoptions(vget(e, "in"));
}

/* The prefix IS the dispatch: `norm*` groups normalize, `opt*` groups
 * resolve. A group with neither prefix gets no subject and fails
 * loudly, rather than being silently skipped. */
static Subject config_subject(const char *group) {
  if (0 == strncmp(group, "norm", 4)) return sub_normalizeconfig;
  if (0 == strncmp(group, "opt", 3)) return sub_resolveoptions;
  return NULL;
}

/* --- graph: resolved/blocked, and the explanation ------------------- */

static Value *sub_resolvegraph(Value *e, void *ctx) {
  (void)ctx;
  return resolvegraph(vget(e, "in"));
}

static Subject graph_subject(const char *group) {
  if (0 == strcmp(group, "resolve")) return sub_resolvegraph;
  if (0 == strcmp(group, "blocked")) return sub_resolvegraph;
  return NULL;
}

/* --- the twelve DRIVER sections ------------------------------------- */

/* Every entry carries `cmd`, and a port needs DOCS.md §4 to run them —
 * the probe catalog, the command vocabulary, and the canonical
 * observable {status, open, log, result}. Corpus files alone are not
 * enough, which is why C2 shipped both together. */
static Value *sub_drive(Value *e, void *ctx) {
  (void)ctx;
  return drive(vget(e, "cmd"));
}

static Subject driver_subject(const char *group) {
  (void)group;
  return sub_drive;
}

/* Dispatch a whole section, failing loudly on a group with no subject:
 * a group the runner does not know is a group silently not run. */
static void run_section(Tally *t, const char *section,
                        Subject (*lookup)(const char *)) {
  Value *groups = corpus_section(section);
  const char **names;
  size_t n = vsortedkeys(groups, &names);
  for (size_t i = 0; i < n; i++) {
    Subject s = lookup(names[i]);
    if (NULL == s) {
      t->failures++;
      printf("%s/%s: no subject for this group\n", section, names[i]);
      continue;
    }
    corpus_run_group(t, section, names[i], vget(groups, names[i]), s, NULL);
  }
}

static void run_ref(Tally *t) {
  Value *groups = corpus_section("ref");
  const char **names;
  size_t n = vsortedkeys(groups, &names);
  for (size_t i = 0; i < n; i++) {
    Subject s = ref_subject(names[i]);
    if (NULL == s) {
      t->failures++;
      printf("ref/%s: no subject for this group\n", names[i]);
      continue;
    }
    corpus_run_group(t, "ref", names[i], vget(groups, names[i]), s, NULL);
  }
}

/* The sections driven by a direct function call. */
static const char *PURE[] = {
  "ref", "version", "capability", "resolve", "env", "config", "graph", NULL
};

/* The driver sections, in §15.3's order. Each entry is a command list
 * against a fresh host. */
static const char *DRIVER[] = {
  "lifecycle", "order", "point", "export", "depend", "declare",
  "state", "resource", "nest", "trace", "apply", "error", NULL
};

static bool listed(const char **names, const char *want) {
  for (int i = 0; NULL != names[i]; i++) {
    if (0 == strcmp(names[i], want)) return true;
  }
  return false;
}

/* EVERY CORPUS SECTION IS RUN (AGENTS.md §"the layout to copy").
 *
 * `run_section` already fails on a GROUP with no subject. This closes
 * the level above: a whole SECTION the runner never mentions is a
 * section silently not run, and it would pass a suite that claims all
 * 572 entries. The `go`, `python` and `ruby` ports carry the same check
 * in the same words; sixteen of the seventeen earlier ports have it,
 * and this port shipped without it.
 *
 * It also refuses a corpus with no PLUGIN.version, because that block
 * is what turns on strict entry validation in every runner and a corpus
 * that lost it must not silently downgrade this port's checking. */
static void coverage(Tally *t) {
  Value *spec = corpus();
  Value *primary = vget(spec, "primary");
  Value *meta = vget(spec, "PLUGIN");

  if (NULL == meta || 1 != vasnum(vget(meta, "version"))) {
    t->failures++;
    printf("coverage: corpus PLUGIN.version must be 1\n");
  }

  const char **names;
  size_t n = vsortedkeys(primary, &names);
  for (size_t i = 0; i < n; i++) {
    if (listed(PURE, names[i]) || listed(DRIVER, names[i])) continue;
    t->failures++;
    printf("coverage: corpus section no test runs: %s\n", names[i]);
  }

  const char **lists[] = { PURE, DRIVER };
  for (int l = 0; l < 2; l++) {
    for (int i = 0; NULL != lists[l][i]; i++) {
      if (vhas(primary, lists[l][i])) continue;
      t->failures++;
      printf("coverage: tests name a section the corpus does not have: %s\n",
             lists[l][i]);
    }
  }

  /* A floor, not a fixture: the corpus grows, and a run that suddenly
   * covers a fraction of it is the failure worth catching. */
  if (400 > t->entries) {
    t->failures++;
    printf("coverage: only %zu corpus entries ran; the corpus has far more\n",
           t->entries);
  }
}

int main(void) {
  Tally t = { 0, 0 };

  run_ref(&t);
  run_section(&t, "version", version_subject);
  run_section(&t, "capability", capability_subject);
  run_section(&t, "resolve", resolve_subject);
  run_section(&t, "env", env_subject);
  run_section(&t, "config", config_subject);
  run_section(&t, "graph", graph_subject);

  for (int i = 0; NULL != DRIVER[i]; i++) {
    run_section(&t, DRIVER[i], driver_subject);
  }

  coverage(&t);

  if (0 == t.entries) {
    printf("c: no corpus entries ran\n");
    return 1;
  }
  if (0 < t.failures) {
    printf("\nc: %zu failure(s) of %zu entries\n", t.failures, t.entries);
    return 1;
  }
  printf("c: %zu corpus entries, all pass\n", t.entries);
  return 0;
}
