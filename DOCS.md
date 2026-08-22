# Voxgig Plugin — Comprehensive Guide

> One plugin architecture, defined once and ported to every language.

This is the in-depth, language-neutral companion to the
[`README.md`](./README.md) overview, and it is **also the driver
contract**: the probe behaviours it specifies are as much a part of the
conformance corpus as the runner is (design §15.2).

---

## Status: P0 — this document is a skeleton

**It is scheduled, not forgotten.** The section headings below are the
shape it will take, and each names the phase that fills it. Two of them
carry dates that are obligations to another repository rather than
internal milestones — see [`AGENTS.md`](./AGENTS.md) §5.

| section | filled by |
|---|---|
| 1. Tutorial | P1 (after the tracer bullet runs) |
| 2. How-to guides | P2 |
| 3. Reference — the canonical API | P1, extended per phase |
| **4. The driver contract** | **P1, in draft, before P1 exits** |
| 5. Explanation | P2 |

Until then, [`docs/design/plugin.md`](./docs/design/plugin.md) is the
authority on every question, and it is complete.

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

**P1, in draft, before P1 exits — and this one has a consumer waiting.**

Design §15.3 marks `lifecycle` and `order` as *driver* sections rather
than pure data. A port cannot run them from corpus files alone: it needs
the probe catalog, the command vocabulary and the canonical observable,
and those are specified here rather than in the corpus.

voxgig/station is owed those two sections before P1 exits
([the plan](https://github.com/voxgig/station/blob/main/docs/design/station-and-plugin-plan.md)
§3, C2), and shipping them without this contract would hand its other
fifteen ports two suites they cannot implement consistently — which is
precisely the drift the early corpus exists to prevent. So this section
is a P1 deliverable, drafted here and completed at P2.

What it will specify, from design §15.2:

- **The probe catalog** — `probe`, `noisy`, `greedy`, `dep`,
  `provider`, `slow` — each behaviour defined language-neutrally, so
  that twenty implementations of `noisy` fail at the same callback in
  the same way.
- **The synthetic resource counter**, so "what is open" is data rather
  than an assertion each port words differently.
- **The command interpreter** vocabulary: `host`, `define`, `load`,
  `activate`, `deactivate`, `unload`, `apply`, `options`, `call`,
  `emit`, `provider`, `export`, `order`, `list`, `env`, `close`.
- **The canonical observable** — sorted keys, refs rather than object
  identities, errors as `{code}`.

## 5. Explanation

*P2.* The ideas behind the design: why identity is `name$tag`, why
`declared` costs nothing, why resource capture is a scope rather than a
ledger, and why the corpus is the contract.

---

## Per-language documentation

Each port carries its own `DOCS.md` with the exact local spelling. None
exist yet; P1 adds `typescript/`.
