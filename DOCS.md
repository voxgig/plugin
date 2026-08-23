# Voxgig Plugin — Comprehensive Guide

> One plugin architecture, defined once and ported to every language.

This is the in-depth, language-neutral companion to the
[`README.md`](./README.md) overview, and it is **also the driver
contract**: the probe behaviours it specifies are as much a part of the
conformance corpus as the runner is (design §15.2).

---

## Status: P1 — §4 is written, the rest is scheduled

**Scheduled, not forgotten.** The section headings below are the shape
this takes, and each names the phase that fills it. §4 carries a date
that is an obligation to another repository rather than an internal
milestone — see [`AGENTS.md`](./AGENTS.md) §5.

| section | filled by |
|---|---|
| 1. Tutorial | P1 (after the tracer bullet runs) |
| 2. How-to guides | P2 |
| 3. Reference — the canonical API | P1, extended per phase |
| **4. The driver contract** | **DRAFT WRITTEN** — extended at P2 |
| 5. Explanation | P2 |

**§4 is in draft, and draft means coverage rather than stability.** It
specifies what `lifecycle` and `order` need and is meant to be relied
on; P2 extends it for the remaining driver sections rather than
rewriting it.

For everything else, [`docs/design/plugin.md`](./docs/design/plugin.md)
is the authority, and it is complete.

---

## 1. Tutorial

*P1.* A guided tour: declare a host, define a plugin, load and activate
it, bind a `hook` and a `chain`, deactivate and watch the resources go.

## 2. How-to guides

*P2.* Recipes: configure instances from a document, add a profile
overlay, share defaults across instances of one definition, order
bindings with constraints and bands, load a definition dynamically,
reserve a ref a host owns.

## 3. Reference

*P1, extended per phase.* The complete API, function by function, with
exact semantics and edge cases. The canonical surface `make parity`
checks is in `AGENTS.md` §4.

## 4. The driver contract

**P1, in draft. This one has a consumer waiting.**

Design §15.3 marks `lifecycle`, `order` and eleven other sections as
*driver* rather than pure data. A port cannot run them from corpus files
alone: it needs the probe catalog, the command vocabulary and the
canonical observable, and none of those belong in the corpus. They are
here.

voxgig/station is owed `lifecycle` and `order` before P1 exits
([the plan](https://github.com/voxgig/station/blob/main/docs/design/station-and-plugin-plan.md)
§3, C2), and shipping them without this contract would hand its other
fifteen ports two suites they could each implement differently — which
is precisely the drift an early corpus exists to prevent.

**Draft status is about coverage, not stability.** What is written below
is what `lifecycle` and `order` need, and it is meant to be relied on.
P2 extends it for the remaining driver sections; it does not rewrite it.

### 4.1 How a driver entry runs

A driver entry carries **`cmd`**, a list of commands, in place of the
`in`/`args` a pure entry uses. The driver:

1. builds a fresh host,
2. runs each command in order,
3. stops at the first command that raises, and
4. returns **one observable map** (§4.4).

`out` compares against that whole map; `match` asserts on part of it;
`err` matches the code of the raise that stopped the run. `err` beside
`out` is invalid, exactly as for a pure entry.

**A command may carry `catch: true`, and §5.2 forces it.** That section's
central claim is that a failed instance *remains registered and
inspectable* — "the point is that a failed plugin must be visible, not
vanished" — and a run that stops at the raise can never observe it. A
command marked `catch` records its raise and the run continues, so the
observable afterwards shows `failed` in `status` and whatever the scope
unwound in `open`. Without it the corpus could pin that activation
raises, or that the instance survives, but never both.

A command is a **map with a `do` key** naming the verb, plus that verb's
own keys:

```json
{ "cmd": [
    { "do": "define", "name": "probe" },
    { "do": "load",   "ref": "probe$a" },
    { "do": "activate", "ref": "probe$a" }
] }
```

A map rather than a positional list, because the verbs do not share an
argument shape and a positional form would make every optional argument
a counting exercise in twenty languages.

### 4.2 The command vocabulary

**Seventeen verbs.** Design §15.2 lists sixteen and omits `ready`,
which §5.1 defines and §15.3 explicitly requires the `declare` section
to pin ("`ready` walking the staircase"). The list is incomplete
against the design's own section table rather than deliberately
excluding it, so the vocabulary carries it and
[`doc/plan/handover.md`](./doc/plan/handover.md) §6 records the
correction owed to §15.2.

Every port implements all of them; a section that never uses one still
needs it present, because the next section will.

| `do` | keys | effect |
|---|---|---|
| `host` | `reserved?`, `keys?`, `defaults?`, `profile?`, `points?` | rebuild the host with these construction options, discarding the current one. `points` declares extension points and their `kind`/`pin` (§7). Only valid as the **first** command. |
| `define` | `name`, `probe?`, `shape?` | register a definition in the catalog. `probe` names the catalog entry (§4.3); default is `probe`. |
| `load` | `ref`, `options?`, `order?`, `definition?` | declare if absent, then load. `order` is the instance's ordering block (§4.4); `definition` names the catalog entry when it differs from the ref's name. |
| `ready` | `ref` | run the whole forward path in one call (§5.1) |
| `activate` | `ref` | `loaded` → `live`, or `pending` |
| `deactivate` | `ref` | → `loaded` |
| `unload` | `ref` | → absent |
| `apply` | `doc`, `profile?` | apply a declarative document (§9.6) |
| `options` | `ref`, `patch` | runtime patch at the top of the ladder |
| `call` | `ref`, `method?`, `args?` | invoke a probe's own method; the value becomes `result` |
| `emit` | `point`, `arg?` | fire a hook point; every live binding runs in resolved order |
| `provider` | `point`, `arg?` | invoke a provider point; the winner's value becomes `result` |
| `export` | `key?` | read the export map, or one key |
| `order` | `point?` | the resolved order; the value becomes `result` |
| `list` | — | the status map; the value becomes `result` |
| `env` | `vars` | set `VOXGIG_PLUGIN_*` for subsequent commands |
| `close` | — | tear the host down, unwinding every instance |

Any command may additionally carry **`catch: true`** (§4.1): its raise
is recorded and the run continues, which is the only way to observe a
`failed` instance at all.

A command naming a ref that does not exist, or a verb that does not
apply in the instance's current state, raises the §12 code for that
case. It does **not** silently no-op — except where §5.2 makes a
transition explicitly idempotent, and those cases are pinned in
`lifecycle` rather than left to the reader.

### 4.3 The probe catalog

Six definitions, implemented identically in every port. **Their
behaviour is as much the contract as the runner is**, and this is where
twenty implementations of `noisy` are made to fail at the same callback
in the same way.

| probe | behaviour |
|---|---|
| `probe` | The workhorse. Records every callback it receives into the log, binds one hook point (`p`), wraps one chain point (`c`), holds an integer counter in its state, and **acquires exactly one synthetic resource per activation**. |
| `noisy` | Fails on demand. `options.fail` names the callback that raises — `define`, `activate`, `deactivate` or `close` — and `options.code` the error code. Everything else is `probe`. |
| `greedy` | Acquires `options.acquire` resources on activation and releases `options.release` of them explicitly, so the difference is what the instance scope must unwind (§8.3). |
| `dep` | Declares requirements. `options.requires` is a list of refs or capability names, `options.optional` those that are optional rather than mandatory. |
| `provider` | Binds a provider point named by `options.point`, returning `options.value`. `options.version` and `options.priority` feed the selection rank. |
| `slow` | Where the language has async, every callback yields once before completing; where it does not, it is `probe`. Exists to prove the lifecycle settles **eagerly** — a transition runs the state machine to a fixed point rather than suspending on a promise (§18's portability budget). |

Every probe records its callbacks into the shared log, so a `lifecycle`
entry asserts the *sequence* of callbacks and not merely the end state.

### 4.4 The ordering block

§7 describes "an integer `order`" for a band while §9.1's document shows
`"order": {"after": "retry"}` — a map. Both cannot be the spelling, and
two spellings for one thing is the defect class this repo exists to
avoid, so the corpus is the arbiter (as it is for §4 rule 5) and pins
**one map**:

```json
{ "order": { "before": "<ref|name>", "after": "<ref|name>", "band": 0 } }
```

`band` rather than a nested `order`, because `order.order` is a name
that has to be explained every time it is read. Every key is optional;
absent `band` is `0`.

Matching is **by ref, or by name across all of that definition's
instances** (§7) — so `after: "retry"` orders behind every instance of
`retry`, and `after: "retry$fast"` behind exactly one.

### 4.5 The canonical observable

The driver returns exactly this map. **Sorted keys, refs rather than
object identities, errors as `{code}`** — the three properties that make
one expected value work in twenty languages.

```json
{
  "status": { "probe$a": "live", "probe$b": "loaded" },
  "open":   1,
  "log":    ["probe$a:define", "probe$a:activate"],
  "result": null
}
```

- **`status`** — every declared instance, ref → status (§5.1's seven).
  Sorted by ref, so output does not depend on a map's iteration order.
  An instance that was never declared is absent, not `null`.
- **`open`** — synthetic resources currently held, counted by the
  driver. This is what makes "what is open" **data** rather than an
  assertion each port words differently, and it is the whole test for
  §8.3's unwind.
- **`log`** — the ordered record of probe callbacks, each
  `"<ref>:<callback>"`. Order is the assertion; a set would pass a port
  that unwinds in the wrong direction.
- **`result`** — the value of the last command that produces one
  (`call`, `provider`, `export`, `order`, `list`), else `null`.

Object identity is never observable. Where §5.4 requires that
`host.instance(ref)` returns the same object across activation cycles,
the corpus pins it through the probe's **counter surviving** rather than
through identity, because a port whose language has no stable identity
would otherwise fail a test about something else.

### 4.6 What a port must NOT do

- **No clock.** No entry may depend on elapsed time; `slow` yields, it
  does not sleep.
- **No parallelism inside a run.** Commands are sequential, so a port
  may not reorder them for speed.
- **No error text matching.** Errors compare by `code` (§12). Message
  wording is a port's own business, and pinning it would make every
  translation a corpus change.
- **No port-local skips.** A driver section entry that a port cannot
  run is a divergence to report, not a case to filter — that inverts
  the one mechanism keeping the ports honest (AGENTS.md §1).

## 5. Explanation

*P2.* The ideas behind the design: why identity is `name$tag`, why
`declared` costs nothing, why resource capture is a scope rather than a
ledger, and why the corpus is the contract.

---

## Per-language documentation

Each port carries its own `DOCS.md` with the exact local spelling. None
exist yet; P1 adds `typescript/`.
