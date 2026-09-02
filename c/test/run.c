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

int main(void) {
  Tally t = { 0, 0 };

  run_ref(&t);

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
