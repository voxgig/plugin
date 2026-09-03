/* The driver (DOCS.md §4).
 *
 * Every port implements this same small thing and nothing else is
 * port-specific: the probe catalog, the command interpreter, and the
 * canonical observable.
 *
 * A PROBE'S CONTEXT IS ITS INSTANCE. C has no closures, so where every
 * other port writes `(i) => ...` capturing the instance, here each
 * callback takes `Inst *` and reads what it needs off it. The `ctx` a
 * binding carries is the instance too, for the same reason. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "driver.h"
#include "../src/ref.h"

/* --- probe helpers --------------------------------------------------- */

static Value *opt(Inst *i, const char *key) {
  return vget(inst_options(i), key);
}

static double num(Value *v) { return visnum(v) ? vasnum(v) : 0.0; }

static void bump(Inst *i, double start) {
  Value *st = inst_state(i);
  if (!vhas(st, "count")) vset(st, "count", vnum(start));
}

/* `noisy` fails on demand: `options.fail` names the callback that
 * raises and `options.code` the error code. `options.bare` raises with
 * NO CODE AT ALL, which is the ordinary library error §12's
 * `plugin_<phase>_failed` codes exist to wrap. */
static void boom(Inst *i, const char *cb) {
  Value *f = opt(i, "fail");
  if (!visstr(f) || 0 != strcmp(vasstr(f), cb)) return;
  size_t sz = strlen(cb) + 32;
  char *text = (char *)arena_alloc(sz);
  snprintf(text, sz, "probe failed at %s", cb);
  if (vtruthy(opt(i, "bare"))) {
    /* C has no "error without a code" — `fail` needs one — so the bare
     * case uses a sentinel the host recognises and wraps, which is what
     * every other port gets from a plain language error. */
    fail("plugin_bare", text, NULL);
  }
  Value *code = opt(i, "code");
  char *c = (char *)arena_alloc(strlen(cb) + 24);
  snprintf(c, strlen(cb) + 24, "plugin_%s_failed", cb);
  fail(visstr(code) ? vasstr(code) : c, text, NULL);
}

static void reenter(Inst *i, const char *cb) {
  Value *r = opt(i, "reenter");
  if (!visstr(r) || 0 != strcmp(vasstr(r), cb)) return;
  /* A transition from inside a lifecycle callback: §5.2's
   * `plugin_reentrant`, reached by actually attempting one. */
  host_activate(inst_host(i), inst_ref(i));
}

/* --- the `probe` bindings -------------------------------------------- */

static Value *probe_hook(Value *arg, void *ctx) {
  (void)arg;
  Inst *i = (Inst *)ctx;
  Value *st = inst_state(i);
  vset(st, "count", vnum(num(vget(st, "count")) + 1));
  /* `p` RETURNS NOTHING, as the canonical's arrow-with-a-block does: in
   * `bail` mode a return is an answer, and a counter that answered with
   * its own count would make every hook that keeps one un-bailable. */
  return NULL;
}

static Value *probe_chain(Chain *next, Value *arg, void *ctx) {
  Inst *i = (Inst *)ctx;
  Value *wrap = opt(i, "wrap");
  const char *w = visstr(wrap) ? vasstr(wrap) : ":";
  Value *inner = chain_next(next, arg);
  const char *tail = visstr(inner) ? vasstr(inner) : (visnull(inner) ? "" : vjson(inner));
  size_t sz = strlen(w) + strlen(tail) + 1;
  char *out = (char *)arena_alloc(sz);
  /* Wrap AFTER next, so the result spells the nesting left to right:
   * outermost first. Wrapping the ARGUMENT instead would spell it
   * backwards and make every chain expectation read wrong. */
  snprintf(out, sz, "%s%s", w, tail);
  return vstr(out);
}

static Value *provider_hook(Value *arg, void *ctx) {
  (void)arg;
  Inst *i = (Inst *)ctx;
  /* PRESENCE, not non-null. An authored `value: null` IS a value — and
   * in `bail` mode a null DECLINES and the next binding answers, which
   * is what `point/bail#null-declines` pins. Reading it as "no value
   * given" and substituting the ref made this probe answer where the
   * contract says it stands aside. */
  if (!vhas(inst_options(i), "value")) return vstr(inst_ref(i));
  return opt(i, "value");
}

/* --- probe callbacks -------------------------------------------------- */

static void probe_define(Inst *i) {
  bump(i, 0);
  boom(i, "define");
  Value *band = opt(i, "band");
  /* One hook binding (`p`) and one chain wrap (`c`) — the workhorse
   * shape DOCS.md §4.3 specifies. */
  inst_bind(i, "p", probe_hook, NULL, i, band);
  inst_bind(i, "c", NULL, probe_chain, i, band);
  inst_export(i, "client", vstr(inst_ref(i)));
  /* The instance api itself, so the driver's `stray` command can call
   * `release` from OUTSIDE a lifecycle callback — which is the only way
   * to exercise §8.3's scope guard. C cannot put a pointer in a Value,
   * so the driver looks the instance up by ref instead; this export
   * keeps the shape the other ports have. */
  inst_export(i, "inst", vstr(inst_ref(i)));
  Value *provides = opt(i, "provides");
  for (size_t k = 0; k < vlen(provides); k++) inst_provides(i, vat(provides, k));
}

static void probe_activate(Inst *i) {
  inst_acquire(i);
  reenter(i, "activate");
  boom(i, "activate");
  /* §6.5: an instance that is itself a host. The outer owns the inner's
   * lifetime — registered in the scope, so it closes on deactivate in
   * the same reverse unwind as every other resource. */
  Value *nest = opt(i, "nest");
  if (vislist(nest) && 0 < vlen(nest)) {
    HostOptions inneropts;
    driver_hostopts(&inneropts, NULL);
    Host *inner = inst_nest(i, &inneropts);
    driver_seed(inner);
    for (size_t k = 0; k < vlen(nest); k++) {
      host_ready(inner, vasstr(vat(nest, k)));
    }
  }
}

static void probe_deactivate(Inst *i) { boom(i, "deactivate"); }
static void probe_close(Inst *i) { boom(i, "close"); }

static void record_define(Inst *i) { bump(i, 0); }
static void record_activate(Inst *i) { inst_acquire(i); }

/* `greedy` acquires `options.acquire` resources and releases
 * `options.release` of them explicitly, so the difference is what the
 * instance scope must unwind (§8.3). */
typedef struct MarkCtx {
  Inst *inst;
  double index;
  bool markfail;
} MarkCtx;

static void mark_release(void *ctx) {
  MarkCtx *m = (MarkCtx *)ctx;
  Value *st = inst_state(m->inst);
  Value *unwound = vget(st, "unwound");
  if (!vislist(unwound)) { unwound = vlist(); vset(st, "unwound", unwound); }
  vpush(unwound, vnum(m->index));
  if (m->markfail) {
    /* The only way §8.3's `plugin_release_failed` and its `failed`
     * status are reachable. */
    fail("probe_release_boom", "release raised", NULL);
  }
}

static void greedy_capture(Inst *i) {
  size_t acquire = (size_t)num(opt(i, "acquire"));
  size_t release = (size_t)num(opt(i, "release"));
  /* Acquire N and hand back M, so the DIFFERENCE is what the instance
   * scope must unwind (§8.3). Handing one back early must not make
   * teardown wrong: the scope keeps the entry and unwinding it twice is
   * a no-op. */
  AcquireHandle **held = (AcquireHandle **)arena_alloc(
      sizeof(AcquireHandle *) * (acquire + 1));
  for (size_t k = 0; k < acquire; k++) held[k] = inst_acquire(i);
  for (size_t k = 0; k < release && k < acquire; k++) inst_giveback(i, held[k]);

  double markn = num(opt(i, "mark"));
  bool markfail = vtruthy(opt(i, "markfail"));
  for (double k = 0; k < markn; k++) {
    MarkCtx *m = (MarkCtx *)arena_alloc(sizeof(MarkCtx));
    m->inst = i;
    m->index = k;
    m->markfail = markfail;
    inst_release(i, mark_release, m);
  }
}

static void greedy_define(Inst *i) {
  bump(i, 0);
  /* `options.early` acquires in `define` instead, where §8.1 says
   * capture does not belong. */
  if (visstr(opt(i, "early")) && 0 == strcmp(vasstr(opt(i, "early")), "acquire")) {
    inst_acquire(i);
  }
  if (visstr(opt(i, "early")) && 0 == strcmp(vasstr(opt(i, "early")), "release")) {
    inst_release(i, NULL, NULL);
  }
  Value *bind = opt(i, "bind");
  if (!visstr(bind)) inst_bind(i, "p", probe_hook, NULL, i, opt(i, "band"));
}

static void greedy_activate(Inst *i) {
  greedy_capture(i);
  /* `options.bind` names the callback that declares a BINDING outside
   * `define`, which is §8.1's other half and §12's `plugin_bind_scope`. */
  Value *bind = opt(i, "bind");
  if (visstr(bind) && 0 == strcmp(vasstr(bind), "activate")) {
    inst_bind(i, "p", probe_hook, NULL, i, NULL);
  }
}

static void greedy_deactivate(Inst *i) {
  Value *bind = opt(i, "bind");
  if (visstr(bind) && 0 == strcmp(vasstr(bind), "deactivate")) {
    inst_bind(i, "p", probe_hook, NULL, i, NULL);
  }
}

static void dep_define(Inst *i) {
  Value *st = inst_state(i);
  vset(st, "count", vnum(0));
  Value *provides = opt(i, "provides");
  for (size_t k = 0; k < vlen(provides); k++) inst_provides(i, vat(provides, k));
  Value *exports = opt(i, "exports");
  if (vismap(exports)) {
    const char **keys;
    size_t n = vkeys(exports, &keys);
    for (size_t k = 0; k < n; k++) inst_export(i, keys[k], vget(exports, keys[k]));
  }
}

static void provider_define(Inst *i) {
  Value *st = inst_state(i);
  vset(st, "count", vnum(0));
  Value *point = opt(i, "point");
  inst_bind(i, visstr(point) ? vasstr(point) : "v", provider_hook, NULL, i,
            opt(i, "band"));
  /* The capability records come from `options.provides` VERBATIM, and
   * there is no second source. An earlier draft of this probe also
   * synthesized one from `options.capability`/`version`/`priority` —
   * three keys the canonical's `provider` does not read and no corpus
   * entry sets — and then dropped it on the floor. Dead code a reader
   * would take for behaviour. */
  Value *provides = opt(i, "provides");
  if (vislist(provides)) {
    for (size_t k = 0; k < vlen(provides); k++) inst_provides(i, vat(provides, k));
  }
}

/* §4.3's six probes, plus the `record` family the corpus names. Their
 * behaviour is as much the contract as the runner is — this is where
 * twenty implementations of `noisy` are made to fail at the same
 * callback in the same way. */
static Definition *probedef(const char *name) {
  Definition *d = (Definition *)arena_alloc(sizeof(Definition));
  d->name = arena_strdup(name);
  d->shape = NULL;
  d->define = record_define;
  d->activate = record_activate;
  d->deactivate = NULL;
  d->close = NULL;
  d->reconfigure = NULL;

  if (0 == strcmp(name, "probe")) {
    d->define = probe_define;
    d->activate = probe_activate;
    d->deactivate = probe_deactivate;
    d->close = probe_close;
  }
  else if (0 == strcmp(name, "noisy")) {
    d->define = probe_define;
    d->activate = probe_activate;
    d->deactivate = probe_deactivate;
    d->close = probe_close;
  }
  else if (0 == strcmp(name, "greedy")) {
    d->define = greedy_define;
    d->activate = greedy_activate;
    d->deactivate = greedy_deactivate;
  }
  else if (0 == strcmp(name, "dep")) {
    d->define = dep_define;
  }
  else if (0 == strcmp(name, "provider")) {
    d->define = provider_define;
  }
  return d;
}

static const char *PROBE_NAMES[] = {
  "probe", "noisy", "greedy", "dep", "provider",
  "slow", "other", "adapter", "late", NULL
};

Value *driver_probes(void) {
  Value *out = vlist();
  for (int i = 0; NULL != PROBE_NAMES[i]; i++) vpush(out, vstr(PROBE_NAMES[i]));
  return out;
}

Definition *driver_probe(const char *name) {
  for (int i = 0; NULL != PROBE_NAMES[i]; i++) {
    if (0 == strcmp(PROBE_NAMES[i], name)) return probedef(name);
  }
  return NULL;
}

void driver_seed(Host *h) {
  for (int i = 0; NULL != PROBE_NAMES[i]; i++) {
    host_define(h, probedef(PROBE_NAMES[i]));
  }
}

/* --- the base points every driver host declares ---------------------- */

/* DOCS.md §4.3 defines `probe` as binding one hook point (`p`) and
 * wrapping one chain point (`c`), so a host without them cannot load
 * the probe at all — they are part of the contract's baseline rather
 * than a fixture convenience. `v` is the provider point the `provider`
 * probe defaults to. */
static Value *identity_base(Value *arg, void *ctx) {
  (void)ctx;
  return arg;
}

void driver_hostopts(HostOptions *out, Value *cmd) {
  memset(out, 0, sizeof(*out));

  Value *points = vmap();
  Value *p = vmap();
  vset(p, "kind", vstr("hook"));
  vset(points, "p", p);
  Value *c = vmap();
  vset(c, "kind", vstr("chain"));
  vset(points, "c", c);
  Value *v = vmap();
  vset(v, "kind", vstr("provider"));
  vset(points, "v", v);

  Value *extra = vget(cmd, "points");
  if (vismap(extra)) {
    const char **keys;
    size_t n = vkeys(extra, &keys);
    for (size_t i = 0; i < n; i++) {
      /* A `host` command REPLACES a base point rather than merging into
       * it, so an entry can redeclare `c` with its own base or `v` as
       * exclusive without inheriting the default's shape. */
      vset(points, keys[i], vget(extra, keys[i]));
    }
  }
  out->points = points;

  /* Every chain point gets the identity base: the host owns it and a
   * plugin cannot replace it (§6.2). */
  Value *basepoints = vlist();
  const char **keys;
  size_t n = vkeys(points, &keys);
  HookFn *fns = (HookFn *)arena_alloc(sizeof(HookFn) * (n + 1));
  size_t bn = 0;
  for (size_t i = 0; i < n; i++) {
    Value *spec = vget(points, keys[i]);
    Value *kind = vget(spec, "kind");
    if (visstr(kind) && 0 == strcmp(vasstr(kind), "chain")) {
      vpush(basepoints, vstr(keys[i]));
      fns[bn++] = identity_base;
    }
  }
  out->basepoints = basepoints;
  out->basefns = fns;

  out->reserved = vget(cmd, "reserved");
  out->keys = vget(cmd, "keys");
  out->defaults = vget(cmd, "defaults");
  out->profile = vget(cmd, "profile");
  /* §11.3's strict reading. Absent means `restart`, which is the
   * default precisely because a station that cannot swap a provider
   * without a restart has lost the argument for having a plugin
   * system. */
  Value *dep = vget(cmd, "dependency");
  out->dependency = visstr(dep) ? vasstr(dep) : NULL;
}

/* --- the command interpreter ----------------------------------------- */

static void declspec(DeclareSpec *out, Value *cmd) {
  memset(out, 0, sizeof(*out));
  Value *options = vget(cmd, "options");
  /* PRESENT AND NOT NULL. Every driver builds its spec with all four
   * keys and a null for each absent one, so a presence test reads an
   * omitted `options` as an authored empty and wipes the real ones. */
  out->options = vismap(options) ? options : NULL;
  out->order = vget(cmd, "order");
  Value *def = vget(cmd, "definition");
  out->definition = visstr(def) ? vasstr(def) : NULL;
  Value *tag = vget(cmd, "tag");
  out->tag = visstr(tag) ? vasstr(tag) : NULL;
}

static const char *cmdstr(Value *cmd, const char *key) {
  Value *v = vget(cmd, key);
  return visstr(v) ? vasstr(v) : NULL;
}

/* One command. `*produced` is set when the verb yields a result; §4.5
 * makes `result` the value of THE LAST COMMAND THAT PRODUCES ONE, so
 * "produced nothing" and "produced null" have to stay distinguishable. */
static Host *docmd(Host *h, Value *cmd, Value *volatile *produced,
                   volatile bool *hasresult) {
  const char *verb = cmdstr(cmd, "do");
  const char *ref = cmdstr(cmd, "ref");
  const char *point = cmdstr(cmd, "point");
  if (NULL == verb) verb = "";

  DeclareSpec spec;
  declspec(&spec, cmd);

  if (0 == strcmp(verb, "host")) {
    HostOptions o;
    driver_hostopts(&o, cmd);
    Host *fresh = makehost(&o);
    driver_seed(fresh);
    return fresh;
  }

  if (0 == strcmp(verb, "define")) {
    /* §10.1's static registration: the definition ENTERS THE CATALOG
     * here, and registration is where its option shape is validated
     * (§9.4) — before any load, so a malformed shape fails at one
     * moment in every host rather than whenever a document happens to
     * exercise the key.
     *
     * §4.2's three keys, all of them live. `probe` names the PROBE
     * whose callbacks back the definition and `name` is what the
     * definition is called. */
    const char *name = cmdstr(cmd, "name");
    const char *from = cmdstr(cmd, "probe");
    if (NULL == from) from = name;
    Definition *base = (NULL == from) ? NULL : driver_probe(from);
    Definition *def = (Definition *)arena_alloc(sizeof(Definition));
    if (NULL == base) {
      memset(def, 0, sizeof(*def));
    }
    else {
      *def = *base;
    }
    def->name = (NULL == name) ? NULL : arena_strdup(name);
    if (vhas(cmd, "shape")) def->shape = vget(cmd, "shape");
    host_define(h, def);
    return h;
  }

  if (0 == strcmp(verb, "load")) { host_load(h, ref, &spec); return h; }
  if (0 == strcmp(verb, "ready")) {
    /* declare FIRST, so the ordering block and definition reach the
     * instance — `ready` walks the staircase, it does not carry
     * configuration of its own. */
    host_declare(h, ref, &spec);
    host_ready(h, ref);
    return h;
  }
  if (0 == strcmp(verb, "activate")) { host_activate(h, ref); return h; }
  if (0 == strcmp(verb, "deactivate")) { host_deactivate(h, ref); return h; }
  if (0 == strcmp(verb, "unload")) { host_unload(h, ref); return h; }
  if (0 == strcmp(verb, "close")) { host_close(h); return h; }
  if (0 == strcmp(verb, "apply")) {
    host_apply(h, vget(cmd, "doc"), vget(cmd, "profile"));
    return h;
  }
  if (0 == strcmp(verb, "options")) {
    host_setoptions(h, ref, vget(cmd, "patch"));
    return h;
  }

  if (0 == strcmp(verb, "declare")) {
    Inst *e = host_declare(h, ref, &spec);
    *produced = vstr(inst_ref(e));
    *hasresult = true;
    return h;
  }
  if (0 == strcmp(verb, "hostdeclare")) {
    /* §9.1's host-owned path: the embedding host installing the
     * instance whose name it reserved. */
    spec.hostowned = true;
    Inst *e = host_declare(h, ref, &spec);
    *produced = vstr(inst_ref(e));
    *hasresult = true;
    return h;
  }

  if (0 == strcmp(verb, "list")) {
    *produced = host_list(h); *hasresult = true; return h;
  }
  if (0 == strcmp(verb, "emit")) {
    *produced = host_emit(h, point, vget(cmd, "arg")); *hasresult = true; return h;
  }
  if (0 == strcmp(verb, "chain")) {
    *produced = host_call(h, point, vget(cmd, "arg")); *hasresult = true; return h;
  }
  if (0 == strcmp(verb, "provider")) {
    *produced = host_provider(h, point, vget(cmd, "arg")); *hasresult = true; return h;
  }
  if (0 == strcmp(verb, "shadowed")) {
    *produced = host_shadowed(h, point); *hasresult = true; return h;
  }
  if (0 == strcmp(verb, "export")) {
    *produced = host_exports(h, cmdstr(cmd, "key")); *hasresult = true; return h;
  }
  if (0 == strcmp(verb, "capability")) {
    *produced = host_capability(h, cmdstr(cmd, "name")); *hasresult = true; return h;
  }
  if (0 == strcmp(verb, "trace")) {
    *produced = host_trace(h); *hasresult = true; return h;
  }
  if (0 == strcmp(verb, "order")) {
    *produced = host_order(h, point); *hasresult = true; return h;
  }
  if (0 == strcmp(verb, "seq")) {
    Inst *e = host_instance(h, ref);
    *produced = NULL == e ? vnull() : vnum(inst_seq(e));
    *hasresult = true;
    return h;
  }
  if (0 == strcmp(verb, "pos")) {
    Inst *e = host_instance(h, ref);
    *produced = NULL == e ? vnull() : vnum(inst_pos(e));
    *hasresult = true;
    return h;
  }
  if (0 == strcmp(verb, "inner")) {
    Inst *e = host_instance(h, ref);
    Host *inner = (NULL == e) ? NULL : inst_inner(e);
    *produced = (NULL == inner) ? vnull() : host_list(inner);
    *hasresult = true;
    return h;
  }

  if (0 == strcmp(verb, "call")) {
    Inst *e = host_instance(h, ref);
    if (NULL == e) {
      size_t sz = (NULL == ref ? 0 : strlen(ref)) + 32;
      char *text = (char *)arena_alloc(sz);
      snprintf(text, sz, "no such instance: %s", NULL == ref ? "" : ref);
      fail("plugin_not_loaded", text, NULL);
    }
    const char *method = cmdstr(cmd, "method");
    if (NULL == method) return h;
    Value *st = inst_state(e);
    if (0 == strcmp(method, "bump")) {
      vset(st, "count", vnum(num(vget(st, "count")) + 1));
      return h;
    }
    if (0 == strcmp(method, "count")) {
      *produced = vnum(num(vget(st, "count"))); *hasresult = true; return h;
    }
    if (0 == strcmp(method, "unwound")) {
      Value *u = vget(st, "unwound");
      *produced = vislist(u) ? u : vlist();
      *hasresult = true;
      return h;
    }
    if (0 == strcmp(method, "position")) {
      /* Reached through the instance api, which is where §6.6 puts it —
       * a plugin asks about itself. */
      *produced = inst_position(e, point); *hasresult = true; return h;
    }
    if (0 == strcmp(method, "stray")) {
      /* A release from OUTSIDE a lifecycle callback. The scope belongs
       * to the activation; a call from anywhere else has no scope to
       * belong to, so it raises. */
      inst_release(e, NULL, NULL);
      return h;
    }
    return h;
  }

  {
    size_t sz = strlen(verb) + 40;
    char *text = (char *)arena_alloc(sz);
    snprintf(text, sz, "unknown driver command: %s", verb);
    fail("plugin_bad_state", text, NULL);
  }
  return h;
}

Value *drive(Value *cmds) {
  HostOptions o;
  driver_hostopts(&o, NULL);
  Host *host = makehost(&o);
  driver_seed(host);

  /* §4.5: `result` is the value of THE LAST COMMAND THAT PRODUCES ONE.
   * Storing it and continuing — rather than returning at the first
   * producing command — is what lets an entry emit and then inspect,
   * which most of `point` needs. */
  Value *last = NULL;
  bool haslast = false;

  for (size_t i = 0; i < vlen(cmds); i++) {
    Value *cmd = vat(cmds, i);
    /* VOLATILE: both straddle the PLUGIN_TRY below, and C guarantees
     * only that `volatile` locals keep their value across a `longjmp`.
     * gcc's -Wclobbered finds these; the arena is what makes the jump
     * safe at all, and this is what makes it correct. */
    Value *volatile produced = NULL;
    volatile bool hasresult = false;

    CatchFrame f;
    if (0 == PLUGIN_TRY(&f)) {
      host = docmd(host, cmd, &produced, &hasresult);
      PLUGIN_END(&f);
      if (hasresult) { last = produced; haslast = true; }
    }
    else {
      /* §4.1: `catch` records the raise and lets the run continue, which
       * is the only way to observe a `failed` instance — §5.2's whole
       * claim is that it stays registered and inspectable. */
      if (!vtruthy(vget(cmd, "catch"))) {
        fail(f.err->code, f.err->text, f.err->details);
      }
    }
  }

  return host_observable(host, last, haslast);
}
