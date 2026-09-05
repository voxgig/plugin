# voxgig/plugin — clojure

The clojure port of [voxgig/plugin](../README.md). It is a **port**, not an
independent implementation: behaviour is defined by `typescript/`, and
`spec/plugin.json` — the same corpus every port runs — is the arbiter.

```bash
make build     # load every namespace; reflection warnings are failures
make test      # the corpus, all 19 sections
make inspect   # clojure and java versions
make clean
```

Clojure 1.11 on any JDK 11+. **No `deps.edn` `:deps` map, no leiningen**:
§16 permits one runtime dependency and clojure has no port of it, so the
JSON parser is `src/voxgig/plugin/json.clj`, the suite is a plain script
rather than `clojure.test`, and the whole build is `clojure -cp src:test`.

## Layout

| | |
|---|---|
| `src/voxgig/plugin/types.clj` | the value model, the error type, the JSON writer |
| `src/voxgig/plugin/json.clj` | the parser |
| `src/voxgig/plugin/*.clj` | the library, one namespace per §-area |
| `src/voxgig/plugin/host.clj` | the state machine and the instance api |
| `src/voxgig/plugin.clj` | the public surface — eleven aliases, nothing else |
| `test/` | the driver (DOCS.md §4), the corpus runner, `run.clj` and `build.clj` |

## Using it

```clojure
(require '[voxgig.plugin :as p]
         '[voxgig.plugin.host :as h])

(def host
  (p/make-host
   {"catalog" (p/make-catalog
               [{"name" "retry"
                 "define" (fn [i] (h/bind! i "request" (fn [nxt req] (nxt req))))}])
    "points" {"request" {"kind" "chain" "base" transport}}}))

(h/ready host "retry$fast")
```

Definitions are plain maps with function values, which is what makes a
catalog a data structure a document could produce. Errors are `ex-info`
carrying the §12 `code` as **data**, which is what lets the corpus runner
compare by code without parsing a message; the message itself is the pinned
`plugin/<code>: <text> [k=v]` format.

## Two decisions clojure forces

**Keys are strings, not keywords.** Idiomatic clojure would read
`(:status entry)`, and every corpus value would then need converting on the
way in and back on the way out — two conversions whose only job is to make
a foreign document look native, and which lose the distinction between the
key `"a"` and the keyword `:a` in a document that used both. The corpus is
JSON; this port holds JSON. Internal shapes that are *never* corpus values
— `Order`'s bindings, `Point`'s bindings, `Export`'s rows — do use keyword
keys, and each says so where it is defined.

**The registry is an atom, and `swap!` retries.** That is the whole of what
makes this port's host different from ruby's. Two rules follow, and neither
is optional:

- *Callbacks never run inside `swap!`.* A retried `swap!` would run a
  definition's `activate` twice, and a callback that called back into its
  own host would be reading the atom it is mid-update on. Every function
  computes outside and writes with a short, pure, targeted `swap!`.
- *Never write back a whole snapshot.* A callback mutates the registry
  while it runs (`export!`, `bind!`, `state-put!`), so the entry read
  before running one is stale afterwards. Every internal function takes a
  **ref**, not an entry.

The atom is not a concurrency boundary either. It makes each read and each
write atomic and nothing larger; two threads calling `activate` at once
would interleave transitions, which §5.2 forbids and which no amount of
atom discipline here would fix, because the interleaving is in the caller's
control flow.

One happy consequence of immutability: the canonical's **"REFILL rather
than REBIND"** (§9.6) is a problem this port does not have. The canonical
must empty and refill the options map because a definition closes over the
object it was handed at `define`; here an instance is a `{host, ref}`
handle and `inst-options` reads the entry, so `apply` simply replaces the
map.

What clojure gives free: `{}` is not `[]`; `contains?` separates an
authored null from an absent key; `(= true 1)` and `(= "1" 1)` are both
false, so the type-strict `match` rule needs no guard; and `sort-by` is
stable, so §7's fall-through to `pos` lands where the canonical's does.

## The two name collisions

`clojure.core/Inst` is a protocol, so `(deftype Inst ...)` fails with a
`ClassCastException` naming neither. The type is `Instance`.
`voxgig.plugin.host` also excludes `list`, `load`, `apply` and `declare`
from `clojure.core` so the four host verbs keep the names every other port
gives them.

## What the corpus cannot see here

Mutation testing: 24 mutations, **18 caught**. Three survivors are real
gaps:

- **Shape validation skipped at catalog registration.** §10.1 puts it there
  so a malformed shape "fails once, and in the same place everywhere", but
  no corpus definition carries a `shape`, so every port could defer it to
  `resolve-options` and stay green. The elixir port found this
  independently.
- **`providers-of` comparing refs uncanonicalized** — the gap six other
  ports each found.
- **A nested host counted as an open resource.** Nothing in `nest` asserts
  `open` while an inner host is live.

Three more turned out to be **non-mutations**, and are recorded so nobody
re-derives them: `==` for `=` on numbers in `same` (the parser produces a
`Long` for every integer, so no entry ever compares `1` with `1.0`);
`\A`/`\z` for `^`/`$` in the ref grammar (`re-matches` already requires a
whole-input match, so the four `#trailing-newline` entries pass either way
— the anchors stay because they are the defence if anyone reaches for
`re-find`); and `sort-by seq` for `sort-by pos` in `order`, which the map's
own insertion order masks until the fallback is broken too, at which point
`order/order/seqtie` catches it.
