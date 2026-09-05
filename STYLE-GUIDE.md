# Documentation style guide

How the Voxgig Plugin documentation is written. This guide is normative
for the root [`README.md`](./README.md) and [`DOCS.md`](./DOCS.md) and for
every port's `README.md` — 19 pages, the ones a reader lands on from
GitHub, npm, PyPI and the rest. It exists so that a page written next
year sounds like a page written this year, and so that a reviewer can
point at a rule instead of arguing taste.

It is a port of [jostraca/jostraca](https://github.com/jostraca/jostraca)'s
guide, by way of [voxgig/struct](https://github.com/voxgig/struct)'s,
which share an author and a house voice with this project. The structure
and most of the rules are those projects'. Where this one differs — the
spaced em dash, the working-document set, the shape of the four parts —
the difference is recorded with the measurement behind it, because a
divergence nobody wrote down reads later as drift.

Three sources feed the guide, in a fixed priority order. The same order is
encoded in [`.vale.ini`](./.vale.ini), and every rule switched off there
names the reason and the count it produced:

    house voice  ->  Google  ->  Vale defaults

1. **This file.** Where it rules, it rules. The house voice is Richard
   Rodger's blog register, and the places it wins are listed with their
   reasons rather than left as silent exceptions: the spaced em dash,
   first-person plural in the tutorial section, British spellings, and
   quotation punctuation outside the quotes.
2. The [Google developer documentation style
   guide](https://developers.google.com/style) for everything this file
   does not cover: second person, present tense, active voice,
   sentence-style capitalisation in headings, serial commas, one idea per
   sentence.
3. [Vale](https://vale.sh) defaults, which mostly means spelling.

Two gates check it, and both run in CI:

| Gate | Runs | Checks |
|---|---|---|
| `vale --minAlertLevel=error $(python3 tools/check_prose.py --files)` | `make scan-prose`, `.github/workflows/docs.yml` | Google's rules plus the banned list, at the levels set in `.vale.ini` |
| `python3 tools/check_prose.py` | `make scan-prose`, `make test`, and the same workflow | the banned list, the em-dash spacing and ration, the first-person rules, no emoji, no citations of a working document, that every relative link resolves, and that the page set is complete |

The banned list is read from one file by both, so they cannot drift. The
page set comes from one function, `tools/check_prose.py --files`, for the
same reason: a gate reading a smaller set than the other is a gate that
reports green on a page nobody checked.

A Google rule sitting at `warning` rather than `error` was tried at error
level first and found wrong for these pages; `.vale.ini` records what it
produced and why it was demoted.

## The structure: four parts, as sections rather than files

`DOCS.md` is the one language-neutral guide: a tutorial, how-to recipes,
a reference, and an explanation, in that order, with the driver contract
between the reference and the explanation. Upstream gives each part its
own file. This project has 23 ports and one guide, so the part is a
**numbered section** inside `DOCS.md`, and the rules attach to the
section:

| Part | Where | May | May not |
|---|---|---|---|
| Tutorial | `DOCS.md` §1 | teach step by step, show output for every step, defer detail with a link | argue design, list every function, assume the reader's goal |
| How-to | `DOCS.md` §2 | solve one named task, assume competence, link the reference | teach basics, explain design, drift into a second task |
| Reference | `DOCS.md` §3 | state facts exhaustively and dryly, pin claims to corpus entries | narrate, persuade, teach |
| The driver contract | `DOCS.md` §4 | specify the command vocabulary, the probe catalog and the observable, exhaustively, as a second reference | describe a port's choices, argue the design |
| Explanation | `DOCS.md` §5 | argue, compare, admit trade-offs, tell the design's story | be the only place a fact lives |

§4 is reference material with a consumer: every port's driver is written
from it, and the corpus's driver sections are unrunnable without it. It
is held to the reference rules, and a change to it is a change every
port has to make.

`README.md` is the doorway and belongs to no part: it routes, gives the
status and the quick start, and states no fact of its own that `DOCS.md`
does not also state.

One fact appears in all four parts at different altitudes — met in the
tutorial, used in a how-to, specified in the reference, argued in the
explanation — but the normative statement lives in the reference and
everything else links to it.

**Documentation never names the framework.** The four parts come from
`Diátaxis`, and that is a fact about how these pages were planned, not
one a reader needs in order to read them. Say **tutorial**, **how-to**,
**reference** and **explanation**, which are ordinary words that describe
themselves, and let the structure do the explaining. This guide and the
contributor guides are where the name belongs, because there it answers a
question somebody is actually asking.

### The canonical page owns the behaviour

This project has a second axis upstream does not: 23 ports of one
library. The rule that falls out of it is the documentation half of the
rule the code already follows.

**Behaviour is documented once, on the language-neutral pages**, which are
the root `README.md` and `DOCS.md`. A port's `README.md` documents that
port: its spelling of the API, its build, the traps its language set, and
any place it diverges. A port page that re-explains what `ready` does has
taken on a copy of a fact that will go stale the day the canonical
changes, and there are 22 other copies of it that will not be updated in
the same commit.

**A divergence is stated where it happens, and pointed at the record.**
The design, [`docs/design/plugin.md`](./docs/design/plugin.md), is where
the model is specified section by section, and the corpus is where a rule
is pinned; a port page names the divergence, says what this port does,
and cites the design section or the corpus entry. Go returns errors where
the canonical throws, and says so in one paragraph that names §12 and
the code the corpus compares by. That is the shape.

## Documentation does not cite a working document

**A documentation page never sends a reader to a plan, a review, a
decision record, or an agent instruction file.** Those are working
documents: written for the people changing this repository, argued rather
than stated, and stale the moment the code moves past them. A reader who
follows a link out of the documentation and lands in one has been handed
the project's notes in place of an answer.

The banned set, by name:

| Document | What it is |
|---|---|
| `AGENTS.md`, `CLAUDE.md` (root and per port) | instructions to contributors and agents working in the repository |
| `docs/ADR.md` | the architecture decision records: the decisions that are expensive to reverse, with their reasoning |
| `doc/plan/adoption.md`, `progress.md`, `status.md`, `handover.md`, `contracts.md` | the register: the plan, its per-item state, the live snapshot, what a landed change decided, and the cross-repo obligations |
| any `*_PLAN.md` or `*_REVIEW.md`, and `BUILD_LOG.md` | the shapes this project has not needed yet, guarded in advance |

The ban covers the name as much as the link. "The full checklist is in
`AGENTS.md`" fails for the same reason the URL does: the reader still
cannot act on the sentence without leaving the documentation. So does
"§18 of the handover has the account", which names the register by
description rather than by filename.

State the fact instead. The README used to send a reader to the handover
before writing a port; "the six defects the proving pair found were all
of two kinds, a rule the design states that no corpus entry can
distinguish and a code path no corpus entry enters" is what that reader
needs, and a link to the file that also says so adds nothing to it. Where
the fact belongs in the documentation and is missing, write it into the
section that owns it rather than pointing outside.

The rule runs one way. Working documents cite each other and cite the
documentation freely, because a decision record that does not show its
working is not a decision record. Only the direction out of documentation
is closed.

### What stays linkable, and why

| Linkable | Because |
|---|---|
| source, each port's `test/`, and the corpus `spec/plugin.aon` with the `spec/plugin.json` compiled from it | code is the thing a claim is pinned to |
| `docs/design/plugin.md` | the design is a specification, not an argument: the model, the ref grammar, the state machine, ordering, resource capture, configuration and the error codes are *defined* there, section by section, and every page cites it as §n. `DOCS.md` names it as the authority on anything the pages disagree about |
| `DOCS.md` §4, the driver contract | normative for every port's driver; a port page pointing at §4.3 is pointing at a specification |
| this guide | normative rather than exploratory, and it names the working documents in order to ban them |
| the other READMEs | documentation themselves |

The rule behind the split: **a specification is citable, an argument is
not.** A reader sent to the design's §12 gets the error codes. A reader
sent to `docs/ADR.md` gets the reasoning behind a decision, which is
somebody's argument, mid-flight, and a reader sent to the register gets a
snapshot that was true on the day it was written.

`tools/check_prose.py` enforces this over the 19 reader-facing pages.
Vale does not, because Vale cannot tell a working document from a page.

## The voice

The house voice is Richard Rodger's blog register, adapted per section.
The portable part of that voice is its *rhythm*, not its stock phrases.
Ten habits, with the register they apply in:

1. **Open with a concrete fact or a plainly stated problem, then a short
   dry beat.** Tutorial and how-to sections. Reference sections open by
   stating what the thing is.
2. **Introduce code with a short colon-terminated sentence** — "Acquire
   in `activate` and forget about it:", "Bind innermost and do not call
   `next`:". Never "The following code snippet demonstrates". Everywhere.
3. **After a code block, point at the one interesting thing.** Do not
   recap the code. Everywhere.
4. **Parentheses carry definitions, caveats, and at most one dry aside per
   section.** Tutorial and how-to sections. In reference sections,
   parentheses carry facts only — a type, a default, a design section.
5. **A trade-off gets bolted on with a dash, and the dash earns its
   place.** One per paragraph at most, never two in a sentence.
6. **Alternate one long explanatory sentence with one short verdict
   sentence.** The short sentence is the payoff. Everywhere.
7. **Talk to the reader as "you", and route them** ("If you only want
   the ruby spelling, skip to…"). "We" appears only in the tutorial
   section, walking through code together. "I" appears nowhere.
8. **Show that the code is real.** No gate executes the snippets on these
   pages; the corpus is what is executed, by all 23 ports. So a page that
   states a behaviour names the corpus entry that pins it —
   `ref/name#trailing-newline`, `capability/match`, `order/list` — and a
   reader who doubts the sentence can open the entry. A claim with no
   entry behind it is a claim the corpus cannot defend, and the page
   should say so rather than imply otherwise.
9. **Jokes are self-directed or about the industry's mundanity, and the
   register goes fully serious the moment correctness or a user's data is
   on the table.** Never joke about the reader, other languages, or
   another port.
10. **Close by handing the reader something**: a link, a next step, one
    sentence. No summary paragraphs that restate the page.

Exclamation marks: at most one per page, in the tutorial section only, on
a genuine payoff.

## Banned phrases and patterns

These read as generated filler. Do not use them, in any document,
including commit messages that quote the docs.

**The list itself lives in
[`.vale/styles/config/vocabularies/Plugin/reject.txt`](./.vale/styles/config/vocabularies/Plugin/reject.txt)**,
one regular expression per line. That file is the single source of truth:
Vale reads it in CI, and `tools/check_prose.py` reads the same file rather
than keeping a second copy, so the two gates cannot disagree about what is
banned. Add a phrase there and both pick it up. What follows is a reader's
summary of it, not a second list; every phrase is shown as code so that
quoting a banned phrase in this guide does not fail the gate.

The list is upstream's, unchanged, and it draws on two sources: that
project's original house list, and [claudisms.ai](https://claudisms.ai/),
a catalogue of the patterns that mark machine-written prose. **It was
measured against these pages before it was adopted.** Seven entries
fired, fifteen times: `honest` four times, `load-bearing` four,
`quietly` three, and one each of `comprehensive` (in the title of
`DOCS.md`), `the point is` (inside a quotation from the design),
`not just` and `worth noting`. All fifteen were rewritten, and nothing
was dropped from the list to make it pass.

**Filler and false emphasis**: `worth noting` · `important to note` ·
`it cannot be overstated` · `at its core` · `when it comes to` ·
`let's break it down` · `here's where it gets interesting` ·
`the point is` · `because it matters`.

**Inflated vocabulary**: `delve` · `dive into` · `robust` · `seamless` ·
`comprehensive` · `holistic` · `intricate` · `leverage` · `foster` ·
`shed light on` · `pave the way` · `pivotal` · `transformative` ·
`game-changing` · `cutting-edge` · `groundbreaking` · `testament to` ·
`paradigm shift` · `realm` · `landscape of` · `underscores the` ·
`lean into` · `throughline` · `double-click on` · `mature setup`.

**Consultant register**: `north star` · `key takeaways` ·
`best practices` (name the practice instead) · `at the end of the day` ·
`pressure-test` · `right-size` · `strategic imperative` ·
`three things to know` · `dispatches from` · `best operators` ·
`lessons learned`.

**Metaphor inflation**: `load-bearing` · `heavy lifting` ·
`is doing the work` · `different physics` · `hits hardest` ·
`quietly` (say `silently`, which is the term of art for a failure that
reports nothing).

**The contrast frame and its cousins**: `not just` · `not only X but Y` ·
`it's not about` · `the whole game` · `the entire point` ·
`the only thing that matters`. Say what the thing is.

**False singularity**: `the right way/answer/tool/question` ·
`the best thing you can do` · `if I had to pick` · `what struck me` ·
`stuck with me` · `struck a chord` · `hit a nerve` ·
`we've seen this movie before`.

**Reflective pose**: `sit with` · `worth exploring/considering/asking` ·
`keeps coming back to` · `that's the tell` · `where I landed`.

**Invented observation about people**: `most people` ·
`everyone I've worked with` · `a lot of folks` · `nobody I know`. If it
did not happen, do not claim to have noticed it.

**Signposting**: `let's explore` · `now let's turn to` · `moving on to` ·
`in today's rapidly evolving` · `reflecting a broader trend` ·
`great question`.

**`honest`, and every form of it**, is banned differently from the rest.
The word is fine English; it is on the list because it had become a tic
across the repositories that share this list, where it flattered a
sentence rather than said anything the sentence did not already say. It
had reached these pages four times: `DOCS.md` said the corpus keeps the
ports "honest" twice and called a limit "the honest limit", and the
swift page called a `throws` signature "honest". In every one the word
came out and nothing was lost; "in agreement" is what the first two had
meant, and the other two meant nothing the sentence did not already say.

**The gate is absolute, and the lack of an inline exemption is the
point.** There is no `allow` comment and no suppression the second gate
would honour, because an escape hatch that exists is an escape hatch that
gets used. A use the author wants kept is approved by changing
`reject.txt`: one line, in one file, visible in review, which is where an
approval belongs.

### What is not banned, and why

Several entries on claudisms.ai are deliberately absent, because they name
things this project documents. A gate that fires on the subject matter is
a gate people learn to switch off. The same standard governs
`Plugin.WordChoice`, which carries three of Google's substitutions and
leaves the rest at warning.

| Not banned | Because |
|---|---|
| `canonical` | It is this project's word for the TypeScript source every port is a port of, and `make parity` checks the canonical API. |
| `shape` | A definition declares an option *shape*, and `declare/shape` is the corpus section that pins where it is validated. |
| `surface` | `the canonical API surface` is what `tools/check_parity.py` compares across ports, and a port's public surface is a row in every layout table. |
| `live` | It is the lifecycle status, `declared → loaded → pending → live`. Which is also why it is dangerous: say *concrete*, *runtime* or *real* when you mean the instance rather than the status, because "a live instance" is a claim about a `loaded` one that reads as English and is false. |
| `hold`, `carry`, `hands` | An instance holds resources, a command carries `catch: true`, the host hands out what the scope unwinds. |
| `real` | `real type equality`, `a real resource`, and the trap in the row two up: the word for the thing that is not the status. |

The rule behind the list: ban the phrase that adds nothing, never the word
that names a thing.

**Matching spans a line wrap.** These pages hard-wrap, and most of the
list is multi-word, so the gate joins each paragraph before matching:
`worth\nnoting` fails exactly as `worth noting` does. Upstream records
that the day its gate started reading paragraphs it found two phrases that
had been passing since the gate was written, each saved only by where its
line happened to break.

**Patterns** (not mechanically checkable, enforced at review):

- Announcing structure before delivering it ("There are three things to
  understand").
- Restating the question before answering it.
- A closing one-liner that restates the thesis.
- Stacked short declaratives (four or more in a row).
- Superlative self-ranking ("the most important thing", "the part that
  matters most").
- A list of `**Bold term**: explanation` pairs, which is the single most
  recognisable machine-written list. Write sentences, or a table.

## Punctuation rulings

**The em dash is spaced here**: `a dash — like this`. This is the one
place where the guide contradicts both Google and jostraca, and it is the
Voxgig convention rather than drift — 206 spaced dashes across the 19
pages when the gate was written, and not one unspaced. A naive count
finds twelve without a space on one side, and every one of them is a dash
at the edge of a hard-wrapped line, where the newline is the space.
`Google.EmDash` is therefore off, and `tools/check_prose.py`
`em-dashes-are-spaced` enforces the convention in the other direction: an
unspaced dash fails.

Dashes stay **rationed to one aside per line**: either a single dash
before a trailing clause, or one matched pair around a parenthetical,
never both and never two asides. Three on a line is the stacking the
ration exists to stop, and one line had it when the gate arrived: the
`greedy` row of the probe catalog, whose matched pair became parentheses.
Prefer a comma or parentheses when the aside is mild.

The rest:

- In a link list, separate the link from its gloss with a full stop, not a
  dash:

  ```markdown
  - [`docs/design/plugin.md`](./docs/design/plugin.md). The design: the model, naming, the state machine, and the rest.
  ```

- **Every relative link must resolve, and stay inside the repository.**
  `tools/check_prose.py` checks the path, not the anchor, since a heading
  slug depends on the renderer; it reads both the inline form, with the
  target in parentheses, and the reference form `[text][label]` with its
  definition. A target that resolves on a Linux
  runner but climbs out of the checkout resolves nowhere on GitHub or in a
  published package, so it fails too. It found no dead link the day it
  was written. What the working-document rule found beside it was ten
  links and citations out of four pages into the register and the agent
  guide, all of them resolving and all of them now facts stated in place.
- No emoji in documentation.
- Sentence-style capitalisation in headings (Google style), except where
  the heading names a proper noun or a code identifier: `No Foundation,
  anywhere`, ``Why identity is `name$tag` ``. A port heading keeps the
  port's lowercase directory name, `voxgig/plugin — php`, because that is
  the port's name and not a sentence.
- British spellings (`-ise`, `-isation`) for new prose. Google style is US
  English and so is the dictionary; this is one of the places the house
  voice wins, and
  [`accept.txt`](./.vale/styles/config/vocabularies/Plugin/accept.txt)
  carries the British forms — **listed one by one**, never matched by
  suffix, because `\w+ise` accepts any word ending in those three letters
  and punches a hole straight through the spelling gate. A US spelling
  already on a page is not a defect, and a filename keeps whatever
  spelling it was created with.
- Quotation punctuation goes **outside** the quotes, against US
  convention, because putting a period inside a quoted `code span` is
  actively wrong when the quote is a literal.

## Terminology

- The project is **Voxgig Plugin**, or **`voxgig/plugin`** when the
  repository is meant; the packages are `@voxgig/plugin`,
  `voxgig-plugin`, `voxgig_plugin`, `VoxgigPlugin` and their
  per-ecosystem spellings. A bare lowercase **plugin** in prose is an
  instance of the model, the thing a host loads, so name the project
  rather than lean on the word.
- **canonical** — the TypeScript source in `typescript/`. Every other
  language is a **port** of it. Never "reference implementation"; the
  corpus is the reference.
- **the corpus** — `spec/plugin.aon` and the `spec/plugin.json` compiled
  from it, 572 entries in 19 **sections**. It is the **contract**: a
  port that disagrees with it is wrong, and the JSON is never hand-edited.
  Never "the test suite", which is a port's own runner.
- **a corpus entry** — one named case, `ref/name#trailing-newline`. Not
  "a fixture", not "a test".
- **parity** — the property `tools/check_parity.py` checks: the canonical
  API names in every port, in local casing. Not "consistency".
- **host** — the library that embeds the plugin system and declares the
  extension points; station and sekreto are hosts. **definition** — a
  plugin kind, registered in a **catalog**. **instance** — a concrete,
  stateful incarnation of one, addressed by its **ref** `name$tag`. The
  name is always the definition; the tag says which instance.
- **`live`** is a lifecycle status and **`active`** is the configuration
  key, and they answer different questions: `active: true` with
  `start: "lazy"` sits at `declared`. Never rename either, and never use
  `live` to mean "real".
- **driver** — the runner that executes a corpus entry's `cmd` list
  against a fresh host, specified in `DOCS.md` §4. **probe** — one of the
  six definitions in the driver catalog (`probe`, `noisy`, `greedy`,
  `dep`, `provider`, `slow`), implemented identically in every port. Not
  "a mock", not "a fixture".
- **absent** and **null** are different. Say **absent** for a key that is
  not there and **null** for one whose value is null; the corpus writes
  them `__UNDEF__` and `__NULL__`. Never "undefined", which is one
  language's spelling of absent.
- **versions** — `VERSION` is the one version line, and every port ships
  at it; a port "ships at" a version, it does not "have" one.

## Templates, part by part

**Tutorial section** (`DOCS.md` §1): goal sentence → snippet → output →
the one observation → forward link. Every step's output shown.

**How-to section** (`DOCS.md` §2): the task as a heading in imperative or
"-ing" form; one sentence of situation; the recipe; one paragraph of what
to watch for; links to the reference for the constructs.

**Reference sections** (`DOCS.md` §3 and §4): definition, then behaviour,
then edge cases, then a pinned example. Every claim that has a corpus
entry names it.

**Explanation section** (`DOCS.md` §5): the question, the answer, the
argument, the trade-off admitted. May quote history when the history is
the argument.

**A port's `README.md`**: what it is (a port, and of what), the four
`make` targets, the layout table, the local spelling of the quick start,
then the decisions and traps the language forced, each pinned to the
design section or the corpus entry that shows it. A divergence is stated
there and nowhere else.

## Updating this guide

Change it the way behaviour changes: in the same commit as the first page
that follows the new rule, with the reasoning in the commit message.

To ban a phrase, add the regular expression to
[`reject.txt`](./.vale/styles/config/vocabularies/Plugin/reject.txt)
and summarise it in the preceding list. Both gates pick it up from that
one file; there is no second list to update, and `tools/check_prose.py`
names this file, so a drift is a build failure with a pointer.

To change a Google rule's level, edit [`.vale.ini`](./.vale.ini) and write
down what the rule produced on a clean run. "It was noisy" is not a
reason; "it maps `touch` to `tap`, and it objects to `snake_case`, which
this project names on purpose — 143 hits" is. A rule demoted without that
note reads later as an oversight, and gets re-promoted by someone
repeating the work.

To widen what the gates read, change the configuration block at the top
of `tools/check_prose.py`. Both gates take their file set from it, so
widening it once widens both — and a page added to the repository without
being added there is a page neither gate has ever read. A port that gains
a `README.md` joins the set by existing; the six tier-4 ports without one
are outside it until they do.
