/* The corpus reader and the entry check. See corpus.h. */

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <regex.h>

#include "corpus.h"

static Value *loaded = NULL;

static const char *specpath(void) {
  const char *env = getenv("PLUGIN_SPEC");
  if (NULL != env && '\0' != env[0]) return env;
  return "../spec/plugin.json";
}

Value *corpus(void) {
  if (NULL != loaded) return loaded;

  const char *path = specpath();
  FILE *f = fopen(path, "rb");
  if (NULL == f) {
    fprintf(stderr, "c: cannot open %s\n", path);
    exit(2);
  }
  fseek(f, 0, SEEK_END);
  long size = ftell(f);
  fseek(f, 0, SEEK_SET);
  if (0 > size) {
    fprintf(stderr, "c: cannot size %s\n", path);
    exit(2);
  }
  char *text = (char *)malloc((size_t)size + 1);
  if (NULL == text) {
    fprintf(stderr, "c: out of memory reading %s\n", path);
    exit(2);
  }
  size_t got = fread(text, 1, (size_t)size, f);
  text[got] = '\0';
  fclose(f);

  const char *err = NULL;
  Value *v = vparse(text, &err);
  free(text);
  if (NULL == v) {
    fprintf(stderr, "c: %s is not valid JSON: %s\n", path, err);
    exit(2);
  }

  /* Version 1 turns on strict entry validation in every runner. A
   * corpus that lost its version marker is a corpus whose shape nobody
   * checked, so refuse it rather than run against it. */
  Value *plugin = vget(v, "PLUGIN");
  Value *version = vget(plugin, "version");
  if (!visnum(version) || 1 != (int)vasnum(version)) {
    fprintf(stderr, "c: unsupported spec version\n");
    exit(2);
  }

  loaded = v;
  return loaded;
}

Value *corpus_section(const char *name) {
  Value *primary = vget(corpus(), "primary");
  Value *section = vget(primary, name);
  if (!vismap(section)) {
    fprintf(stderr, "c: no such corpus section: %s\n", name);
    exit(2);
  }
  return section;
}

const char *corpus_label(const char *group, size_t i, Value *entry) {
  Value *id = vget(entry, "id");
  size_t sz = strlen(group) + 64;
  if (visstr(id)) sz += strlen(vasstr(id));
  char *out = (char *)arena_alloc(sz);
  if (visstr(id)) snprintf(out, sz, "%s", vasstr(id));
  else snprintf(out, sz, "%s#%zu", group, i);
  return out;
}

bool corpus_equal(Value *a, Value *b) {
  bool anull = visnull(a), bnull = visnull(b);
  if (anull || bnull) return anull && bnull;
  if (a->kind != b->kind) return false;
  switch (a->kind) {
    case VBOOL: return vasbool(a) == vasbool(b);
    case VNUM: return vasnum(a) == vasnum(b);
    case VSTR: return 0 == strcmp(vasstr(a), vasstr(b));
    case VLIST: {
      if (vlen(a) != vlen(b)) return false;
      for (size_t i = 0; i < vlen(a); i++) {
        if (!corpus_equal(vat(a, i), vat(b, i))) return false;
      }
      return true;
    }
    case VMAP: {
      if (vlen(a) != vlen(b)) return false;
      const char **keys;
      size_t n = vkeys(a, &keys);
      for (size_t i = 0; i < n; i++) {
        if (!vhas(b, keys[i])) return false;
        if (!corpus_equal(vget(a, keys[i]), vget(b, keys[i]))) return false;
      }
      return true;
    }
    default: return true;
  }
}

bool corpus_matches(Value *expect, Value *actual, bool present) {
  if (visstr(expect)) {
    const char *s = vasstr(expect);
    if (0 == strcmp(s, "__EXISTS__")) return present && !visnull(actual);
    if (0 == strcmp(s, "__UNDEF__")) return !present;
    if (0 == strcmp(s, "__NULL__")) return present && visnull(actual);

    size_t n = strlen(s);
    if (2 < n && '/' == s[0] && '/' == s[n - 1]) {
      if (!visstr(actual)) return false;
      char *pattern = arena_strndup(s + 1, n - 2);
      regex_t re;
      if (0 != regcomp(&re, pattern, REG_EXTENDED)) return false;
      int rc = regexec(&re, vasstr(actual), 0, NULL, 0);
      regfree(&re);
      return 0 == rc;
    }
  }

  if (vislist(expect)) {
    if (!vislist(actual) || vlen(expect) != vlen(actual)) return false;
    for (size_t i = 0; i < vlen(expect); i++) {
      if (!corpus_matches(vat(expect, i), vat(actual, i), true)) return false;
    }
    return true;
  }

  if (vismap(expect)) {
    if (!vismap(actual)) return false;
    const char **keys;
    size_t n = vsortedkeys(expect, &keys);
    for (size_t i = 0; i < n; i++) {
      bool has = vhas(actual, keys[i]);
      if (!corpus_matches(vget(expect, keys[i]), vget(actual, keys[i]), has)) {
        return false;
      }
    }
    return true;
  }

  return corpus_equal(expect, actual);
}

static const char *msgf(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  char probe[1];
  va_list ap2;
  va_copy(ap2, ap);
  int n = vsnprintf(probe, 1, fmt, ap2);
  va_end(ap2);
  char *out = (char *)arena_alloc((size_t)n + 1);
  vsnprintf(out, (size_t)n + 1, fmt, ap);
  va_end(ap);
  return out;
}

const char *corpus_check(Value *entry, Subject subject, void *ctx) {
  bool haserr = vhas(entry, "err");
  bool hasout = vhas(entry, "out");
  bool hasmatch = vhas(entry, "match");

  if (haserr && hasout) return "entry has both err and out";
  if (!haserr && !hasout && !hasmatch) return "entry asserts nothing";

  Value *value = NULL;
  PluginError *raised = NULL;

  CatchFrame frame;
  if (0 == PLUGIN_TRY(&frame)) {
    value = subject(entry, ctx);
    PLUGIN_END(&frame);
  }
  else {
    raised = plugin_caught();
  }

  if (haserr) {
    if (NULL == raised) {
      return msgf("expected a raise, got: %s", vjson(value));
    }
    Value *want = vget(entry, "err");
    if (visstr(want)) {
      /* Errors compare by CODE (§12). Message wording is a port's own
       * business; pinning it would make every translation a corpus
       * change. */
      if (0 != strcmp(raised->code, vasstr(want))) {
        return msgf("expected code %s, got %s (%s)",
                    vasstr(want), raised->code, raised->message);
      }
    }
    if (hasmatch) {
      Value *err = vmap();
      vset(err, "code", vstr(raised->code));
      vset(err, "message", vstr(raised->message));
      vset(err, "name", vstr("PluginError"));
      Value *got = vmap();
      vset(got, "err", err);
      if (!corpus_matches(vget(entry, "match"), got, true)) {
        return msgf("error did not match %s, got %s",
                    vjson(vget(entry, "match")), vjson(got));
      }
    }
    return NULL;
  }

  if (NULL != raised) {
    return msgf("unexpected raise: %s %s", raised->code, raised->message);
  }

  if (hasout) {
    if (!corpus_equal(vget(entry, "out"), value)) {
      return msgf("expected %s, got %s",
                  vjson(vget(entry, "out")), vjson(value));
    }
  }

  if (hasmatch) {
    Value *got = vmap();
    vset(got, "in", vget(entry, "in"));
    vset(got, "out", value);
    if (!corpus_matches(vget(entry, "match"), got, true)) {
      return msgf("did not match %s, got out=%s",
                  vjson(vget(entry, "match")), vjson(value));
    }
  }

  return NULL;
}

void corpus_run_group(Tally *t, const char *section, const char *group,
                      Value *entries, Subject subject, void *ctx) {
  Value *set = vget(entries, "set");
  if (!vislist(set)) return;
  for (size_t i = 0; i < vlen(set); i++) {
    Value *entry = vat(set, i);
    t->entries++;
    const char *why = corpus_check(entry, subject, ctx);
    if (NULL != why) {
      t->failures++;
      /* The label is the entry's own `id` when it has one, and those
       * already carry the section — printing the section again would
       * read `ref/ref/canon#trailing`. */
      const char *label = corpus_label(group, i, entry);
      if (vhas(entry, "id")) printf("%s: %s\n", label, why);
      else printf("%s/%s: %s\n", section, label, why);
    }
  }
}

void corpus_run_section(Tally *t, const char *section, Subject subject,
                        void *ctx) {
  Value *groups = corpus_section(section);
  const char **names;
  /* SORTED, so a failure names the same group in the same place on
   * every run. */
  size_t n = vsortedkeys(groups, &names);
  for (size_t i = 0; i < n; i++) {
    corpus_run_group(t, section, names[i], vget(groups, names[i]),
                     subject, ctx);
  }
}
