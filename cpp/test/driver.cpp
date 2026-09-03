/* The driver (DOCS.md §4).
 *
 * Every port implements this same small thing and nothing else is
 * port-specific: the probe catalog, the command interpreter, and the
 * canonical observable.
 *
 * A PROBE'S CALLBACKS ARE LAMBDAS OVER THE INSTANCE, which is the whole
 * difference from the `c` driver sitting next door: `std::function`
 * captures, so a binding closes over its instance the way the canonical
 * writes it rather than carrying an explicit context pointer. */

#include "driver.hpp"

#include <string>
#include <vector>

#include "../src/ref.hpp"

namespace plugin {

/* --- probe helpers --------------------------------------------------- */

static V opt(const Inst& i, const std::string& key) {
  return get(i.options(), key);
}

static double num(const V& v) { return isnum(v) ? asnum(v) : 0.0; }

static void bump(Inst& i, double start) {
  if (!has(i.state(), "count")) set(i.state(), "count", vnum(start));
}

/* `noisy` fails on demand: `options.fail` names the callback that
 * raises and `options.code` the error code. `options.bare` raises with
 * NO CODE AT ALL, which is the ordinary library error §12's
 * `plugin_<phase>_failed` codes exist to wrap. */
static void boom(Inst& i, const std::string& cb) {
  V f = opt(i, "fail");
  if (!isstr(f) || asstr(f) != cb) return;
  const std::string text = "probe failed at " + cb;
  if (truthy(opt(i, "bare"))) {
    /* `fail` needs a code, so the bare case uses a sentinel the host
     * recognises and wraps, which is what every other port gets from a
     * plain language error. */
    fail("plugin_bare", text);
  }
  V code = opt(i, "code");
  fail(isstr(code) ? asstr(code) : "plugin_" + cb + "_failed", text);
}

static void reenter(Inst& i, const std::string& cb) {
  V r = opt(i, "reenter");
  if (!isstr(r) || asstr(r) != cb) return;
  /* A transition from inside a lifecycle callback: §5.2's
   * `plugin_reentrant`, reached by actually attempting one. */
  i.host().activate(i.ref());
}

/* --- the `probe` bindings -------------------------------------------- */

static void bindprobe(Inst& i) {
  Inst* self = &i;
  V band = opt(i, "band");
  /* One hook binding (`p`) and one chain wrap (`c`) — the workhorse
   * shape DOCS.md §4.3 specifies. */
  i.bindhook("p", [self](const V&) -> V {
    set(self->state(), "count", vnum(num(get(self->state(), "count")) + 1));
    /* `p` RETURNS NOTHING, as the canonical's arrow-with-a-block does:
     * in `bail` mode a return is an answer, and a counter that answered
     * with its own count would make every hook that keeps one
     * un-bailable. */
    return nullptr;
  }, band);
  i.bindchain("c", [self](const Next& next, const V& arg) -> V {
    V wrap = opt(*self, "wrap");
    const std::string w = isstr(wrap) ? asstr(wrap) : ":";
    V inner = next(arg);
    const std::string tail =
        isstr(inner) ? asstr(inner) : (isnull(inner) ? "" : json(inner));
    /* Wrap AFTER next, so the result spells the nesting left to right:
     * outermost first. Wrapping the ARGUMENT instead would spell it
     * backwards and make every chain expectation read wrong. */
    return vstr(w + tail);
  }, band);
}

/* --- probe callbacks -------------------------------------------------- */

static void probedefine(Inst& i) {
  bump(i, 0);
  boom(i, "define");
  bindprobe(i);
  i.exportvalue("client", vstr(i.ref()));
  /* The instance api itself, so the driver's `stray` command can call
   * `release` from OUTSIDE a lifecycle callback — which is the only way
   * to exercise §8.3's scope guard. The driver looks the instance up by
   * ref; this export keeps the shape the other ports have. */
  i.exportvalue("inst", vstr(i.ref()));
  V provides = opt(i, "provides");
  for (size_t k = 0; k < len(provides); k++) i.provides(at(provides, k));
}

static void probeactivate(Inst& i) {
  i.acquire();
  reenter(i, "activate");
  boom(i, "activate");
  /* §6.5: an instance that is itself a host. The outer owns the inner's
   * lifetime — registered in the scope, so it closes on deactivate in
   * the same reverse unwind as every other resource. */
  V nest = opt(i, "nest");
  if (islist(nest) && 0 < len(nest)) {
    HostPtr inner = i.nest(driverhostopts(nullptr));
    driverseed(inner);
    for (size_t k = 0; k < len(nest); k++) inner->ready(asstr(at(nest, k)));
  }
}

/* `greedy` acquires `options.acquire` resources and releases
 * `options.release` of them explicitly, so the difference is what the
 * instance scope must unwind (§8.3). */
static void greedycapture(Inst& i) {
  size_t acquire = static_cast<size_t>(num(opt(i, "acquire")));
  size_t release = static_cast<size_t>(num(opt(i, "release")));
  /* Acquire N and hand back M, so the DIFFERENCE is what the instance
   * scope must unwind (§8.3). Handing one back early must not make
   * teardown wrong: the scope keeps the entry and unwinding it twice is
   * a no-op. */
  std::vector<AcquireHandle> held;
  for (size_t k = 0; k < acquire; k++) held.push_back(i.acquire());
  for (size_t k = 0; k < release && k < acquire; k++) i.giveback(held[k]);

  double markn = num(opt(i, "mark"));
  bool markfail = truthy(opt(i, "markfail"));
  Inst* self = &i;
  for (double k = 0; k < markn; k++) {
    i.release([self, k, markfail]() {
      V unwound = get(self->state(), "unwound");
      if (!islist(unwound)) {
        unwound = vlist();
        set(self->state(), "unwound", unwound);
      }
      push(unwound, vnum(k));
      if (markfail) {
        /* The only way §8.3's `plugin_release_failed` and its `failed`
         * status are reachable. */
        fail("probe_release_boom", "release raised");
      }
    });
  }
}

static void greedydefine(Inst& i) {
  bump(i, 0);
  /* `options.early` acquires in `define` instead, where §8.1 says
   * capture does not belong. */
  V early = opt(i, "early");
  if (isstr(early) && "acquire" == asstr(early)) i.acquire();
  if (isstr(early) && "release" == asstr(early)) i.release(nullptr);
  Inst* self = &i;
  if (!isstr(opt(i, "bind"))) {
    i.bindhook("p", [self](const V&) -> V {
      set(self->state(), "count", vnum(num(get(self->state(), "count")) + 1));
      return nullptr;
    }, opt(i, "band"));
  }
}

static void greedybindat(Inst& i, const std::string& cb) {
  /* `options.bind` names the callback that declares a BINDING outside
   * `define`, which is §8.1's other half and §12's `plugin_bind_scope`. */
  V bind = opt(i, "bind");
  if (!isstr(bind) || asstr(bind) != cb) return;
  i.bindhook("p", [](const V&) -> V { return nullptr; }, nullptr);
}

static void depdefine(Inst& i) {
  set(i.state(), "count", vnum(0));
  V provides = opt(i, "provides");
  for (size_t k = 0; k < len(provides); k++) i.provides(at(provides, k));
  V exports = opt(i, "exports");
  if (ismap(exports)) {
    for (const auto& k : keys(exports)) i.exportvalue(k, get(exports, k));
  }
}

static void providerdefine(Inst& i) {
  set(i.state(), "count", vnum(0));
  Inst* self = &i;
  V point = opt(i, "point");
  i.bindhook(isstr(point) ? asstr(point) : "v", [self](const V&) -> V {
    /* PRESENCE, not non-null. An authored `value: null` IS a value —
     * and in `bail` mode a null DECLINES and the next binding answers,
     * which is what `point/bail#null-declines` pins. Reading it as "no
     * value given" and substituting the ref made this probe answer
     * where the contract says it stands aside. */
    if (!has(self->options(), "value")) return vstr(self->ref());
    return opt(*self, "value");
  }, opt(i, "band"));
  /* The capability records come from `options.provides` VERBATIM, and
   * there is no second source. An earlier draft of this probe also
   * synthesized one from `options.capability`/`version`/`priority` —
   * three keys the canonical's `provider` does not read and no corpus
   * entry sets — and then dropped it on the floor. Dead code a reader
   * would take for behaviour. */
  V provides = opt(i, "provides");
  if (islist(provides)) {
    for (size_t k = 0; k < len(provides); k++) i.provides(at(provides, k));
  }
}

/* §4.3's six probes, plus the `record` family the corpus names. Their
 * behaviour is as much the contract as the runner is — this is where
 * twenty implementations of `noisy` are made to fail at the same
 * callback in the same way. */
static DefinitionPtr probedef(const std::string& name) {
  auto d = std::make_shared<Definition>();
  d->name = name;
  d->define = [](Inst& i) { bump(i, 0); };
  d->activate = [](Inst& i) { i.acquire(); };

  if ("probe" == name || "noisy" == name) {
    d->define = probedefine;
    d->activate = probeactivate;
    d->deactivate = [](Inst& i) { boom(i, "deactivate"); };
    d->close = [](Inst& i) { boom(i, "close"); };
  }
  else if ("greedy" == name) {
    d->define = greedydefine;
    d->activate = [](Inst& i) {
      greedycapture(i);
      greedybindat(i, "activate");
    };
    d->deactivate = [](Inst& i) { greedybindat(i, "deactivate"); };
  }
  else if ("dep" == name) {
    d->define = depdefine;
  }
  else if ("provider" == name) {
    d->define = providerdefine;
  }
  return d;
}

static const char* const PROBE_NAMES[] = {
  "probe", "noisy", "greedy", "dep", "provider",
  "slow", "other", "adapter", "late", nullptr
};

V driverprobes() {
  V out = vlist();
  for (int i = 0; nullptr != PROBE_NAMES[i]; i++) push(out, vstr(PROBE_NAMES[i]));
  return out;
}

DefinitionPtr driverprobe(const std::string& name) {
  for (int i = 0; nullptr != PROBE_NAMES[i]; i++) {
    if (name == PROBE_NAMES[i]) return probedef(name);
  }
  return nullptr;
}

void driverseed(const HostPtr& h) {
  for (int i = 0; nullptr != PROBE_NAMES[i]; i++) h->define(probedef(PROBE_NAMES[i]));
}

/* --- the base points every driver host declares ---------------------- */

/* DOCS.md §4.3 defines `probe` as binding one hook point (`p`) and
 * wrapping one chain point (`c`), so a host without them cannot load
 * the probe at all — they are part of the contract's baseline rather
 * than a fixture convenience. `v` is the provider point the `provider`
 * probe defaults to. */
HostOptions driverhostopts(const V& cmd) {
  HostOptions out;

  V points = vmap();
  V p = vmap();
  set(p, "kind", vstr("hook"));
  set(points, "p", p);
  V c = vmap();
  set(c, "kind", vstr("chain"));
  set(points, "c", c);
  V v = vmap();
  set(v, "kind", vstr("provider"));
  set(points, "v", v);

  V extra = get(cmd, "points");
  if (ismap(extra)) {
    /* A `host` command REPLACES a base point rather than merging into
     * it, so an entry can redeclare `c` with its own base or `v` as
     * exclusive without inheriting the default's shape. */
    for (const auto& k : keys(extra)) set(points, k, get(extra, k));
  }
  out.points = points;

  /* Every chain point gets the identity base: the host owns it and a
   * plugin cannot replace it (§6.2). */
  for (const auto& k : keys(points)) {
    V kind = get(get(points, k), "kind");
    if (isstr(kind) && "chain" == asstr(kind)) {
      out.bases[k] = [](const V& arg) { return arg; };
    }
  }

  out.reserved = get(cmd, "reserved");
  out.keys = get(cmd, "keys");
  out.defaults = get(cmd, "defaults");
  out.profile = get(cmd, "profile");
  /* §11.3's strict reading. Absent means `restart`, which is the
   * default precisely because a station that cannot swap a provider
   * without a restart has lost the argument for having a plugin
   * system. */
  V dep = get(cmd, "dependency");
  out.dependency = isstr(dep) ? asstr(dep) : "";
  return out;
}

/* --- the command interpreter ----------------------------------------- */

static DeclareSpec declspec(const V& cmd) {
  DeclareSpec out;
  V options = get(cmd, "options");
  /* PRESENT AND NOT NULL. Every driver builds its spec with all four
   * keys and a null for each absent one, so a presence test reads an
   * omitted `options` as an authored empty and wipes the real ones. */
  out.options = ismap(options) ? options : nullptr;
  out.order = get(cmd, "order");
  out.definition = asstr(get(cmd, "definition"));
  out.tag = asstr(get(cmd, "tag"));
  return out;
}

/* One command. `produced` is set when the verb yields a result; §4.5
 * makes `result` the value of THE LAST COMMAND THAT PRODUCES ONE, so
 * "produced nothing" and "produced null" have to stay distinguishable. */
static HostPtr docmd(HostPtr h, const V& cmd, V& produced, bool& hasresult) {
  const std::string verb = asstr(get(cmd, "do"));
  const std::string ref = asstr(get(cmd, "ref"));
  const std::string point = asstr(get(cmd, "point"));

  DeclareSpec spec = declspec(cmd);

  auto yield = [&produced, &hasresult](const V& value) {
    produced = value;
    hasresult = true;
  };

  if ("host" == verb) {
    HostPtr fresh = makehost(driverhostopts(cmd));
    driverseed(fresh);
    return fresh;
  }

  if ("define" == verb) {
    /* §10.1's static registration: the definition ENTERS THE CATALOG
     * here, and registration is where its option shape is validated
     * (§9.4) — before any load, so a malformed shape fails at one
     * moment in every host rather than whenever a document happens to
     * exercise the key.
     *
     * §4.2's three keys, all of them live. `probe` names the PROBE
     * whose callbacks back the definition and `name` is what the
     * definition is called. */
    const std::string name = asstr(get(cmd, "name"));
    std::string from = asstr(get(cmd, "probe"));
    if (from.empty()) from = name;
    DefinitionPtr base = from.empty() ? nullptr : driverprobe(from);
    auto def = base ? std::make_shared<Definition>(*base)
                    : std::make_shared<Definition>();
    def->name = name;
    if (has(cmd, "shape")) def->shape = get(cmd, "shape");
    h->define(def);
    return h;
  }

  if ("load" == verb) { h->load(ref, spec); return h; }
  if ("ready" == verb) {
    /* declare FIRST, so the ordering block and definition reach the
     * instance — `ready` walks the staircase, it does not carry
     * configuration of its own. */
    h->declare(ref, spec);
    h->ready(ref);
    return h;
  }
  if ("activate" == verb) { h->activate(ref); return h; }
  if ("deactivate" == verb) { h->deactivate(ref); return h; }
  if ("unload" == verb) { h->unload(ref); return h; }
  if ("close" == verb) { h->close(); return h; }
  if ("apply" == verb) { h->apply(get(cmd, "doc"), get(cmd, "profile")); return h; }
  if ("options" == verb) { h->setoptions(ref, get(cmd, "patch")); return h; }

  if ("declare" == verb) { yield(vstr(h->declare(ref, spec)->ref())); return h; }
  if ("hostdeclare" == verb) {
    /* §9.1's host-owned path: the embedding host installing the
     * instance whose name it reserved. */
    spec.hostowned = true;
    yield(vstr(h->declare(ref, spec)->ref()));
    return h;
  }

  if ("list" == verb) { yield(h->list()); return h; }
  if ("emit" == verb) { yield(h->emit(point, get(cmd, "arg"))); return h; }
  if ("chain" == verb) { yield(h->call(point, get(cmd, "arg"))); return h; }
  if ("provider" == verb) { yield(h->provider(point, get(cmd, "arg"))); return h; }
  if ("shadowed" == verb) { yield(h->shadowed(point)); return h; }
  if ("export" == verb) { yield(h->exports(asstr(get(cmd, "key")))); return h; }
  if ("capability" == verb) { yield(h->capability(asstr(get(cmd, "name")))); return h; }
  if ("trace" == verb) { yield(h->trace()); return h; }
  if ("order" == verb) { yield(h->order(point)); return h; }
  if ("seq" == verb) {
    InstPtr e = h->instance(ref);
    yield(e ? vnum(e->seq()) : vnull());
    return h;
  }
  if ("pos" == verb) {
    InstPtr e = h->instance(ref);
    yield(e ? vnum(e->pos()) : vnull());
    return h;
  }
  if ("inner" == verb) {
    InstPtr e = h->instance(ref);
    HostPtr inner = e ? e->inner() : nullptr;
    yield(inner ? inner->list() : vnull());
    return h;
  }

  if ("call" == verb) {
    InstPtr e = h->instance(ref);
    if (!e) fail("plugin_not_loaded", "no such instance: " + ref);
    const std::string method = asstr(get(cmd, "method"));
    if (method.empty()) return h;
    V st = e->state();
    if ("bump" == method) {
      set(st, "count", vnum(num(get(st, "count")) + 1));
      return h;
    }
    if ("count" == method) { yield(vnum(num(get(st, "count")))); return h; }
    if ("unwound" == method) {
      V u = get(st, "unwound");
      yield(islist(u) ? u : vlist());
      return h;
    }
    if ("position" == method) {
      /* Reached through the instance api, which is where §6.6 puts it —
       * a plugin asks about itself. */
      yield(e->position(point));
      return h;
    }
    if ("stray" == method) {
      /* A release from OUTSIDE a lifecycle callback. The scope belongs
       * to the activation; a call from anywhere else has no scope to
       * belong to, so it raises. */
      e->release(nullptr);
      return h;
    }
    return h;
  }

  fail("plugin_bad_state", "unknown driver command: " + verb);
}

V drive(const V& cmds) {
  HostPtr host = makehost(driverhostopts(nullptr));
  driverseed(host);

  /* §4.5: `result` is the value of THE LAST COMMAND THAT PRODUCES ONE.
   * Storing it and continuing — rather than returning at the first
   * producing command — is what lets an entry emit and then inspect,
   * which most of `point` needs. */
  V last;
  bool haslast = false;

  for (size_t i = 0; i < len(cmds); i++) {
    V cmd = at(cmds, i);
    V produced;
    bool hasresult = false;
    try {
      host = docmd(host, cmd, produced, hasresult);
      if (hasresult) { last = produced; haslast = true; }
    }
    catch (const PluginError&) {
      /* §4.1: `catch` records the raise and lets the run continue, which
       * is the only way to observe a `failed` instance — §5.2's whole
       * claim is that it stays registered and inspectable. */
      if (!truthy(get(cmd, "catch"))) throw;
    }
  }

  return host->observable(last, haslast);
}

}  // namespace plugin
