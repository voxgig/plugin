import Plugin
import Driver

/-!
# The lean port's test runner

NO TEST FRAMEWORK (§16): a `main` that counts. It reports the entry count
as well as the pass, because "all pass" over zero entries is the failure
doc/plan/handover.md §4 warns about.
-/

open Plugin

/-- §15.3's `ref` section, group by group. EVERY group must have a
subject: a group the runner does not know is a group silently not run,
which is worse than a failure. -/
def refSubject (g : String) : Option Subject :=
  if g == "name" || g == "bound" then some (fun e => return .bool (checkname (e.get "in")))
  else if g == "tag" || g == "boundtag" then
    some (fun e => return .bool (checktag (e.get "in")))
  else if g == "parse" || g == "parsebad" then some (fun e => parseRef (e.get "in"))
  else if g == "format" || g == "formatbad" then
    some (fun e => do
      let args := e.get "args"
      return .str (← formatRef (args.idx 0) (args.idx 1)))
  else if g == "canon" then some (fun e => do return .str (← canonRef (e.get "in")))
  else none

-- --- version: the range grammar and the one predicate ------------------

def versionSubject (g : String) : Option Subject :=
  if g == "range" || g == "rangebad" then some (fun e => parseRange (e.get "in"))
  else if g == "satisfies" then
    some (fun e => do
      let i := e.get "in"
      return .bool (← satisfies (i.get "version") (i.get "range")))
  else none

-- --- capability: matching and the total rank ---------------------------

def capabilitySubject (g : String) : Option Subject :=
  if g == "match" || g == "nested" || g == "rank" then
    some (fun e => do
      let i := e.get "in"
      resolveCapability (i.get "req") (i.get "candidates"))
  else none

-- --- resolve: name to candidate module ids -----------------------------

def resolveSubject (g : String) : Option Subject :=
  if g == "candidates" then
    some (fun e => do
      let i := e.get "in"
      return resolveCandidates (i.get "name") (i.get "sources"))
  else if g == "from" then some (fun e => return resolveFrom (e.get "in"))
  else none

-- --- env: the lossy encoding, and its collision ------------------------

/-- Every group in `env` is one call: the section is a single pure
function over the whole input. -/
def envSubject (_ : String) : Option Subject := some (fun e => applyEnv (e.get "in"))

-- --- config: normalization and the ten-level ladder --------------------

/-- The prefix IS the dispatch: `norm*` groups normalize, `opt*` groups
resolve. A group with neither prefix gets no subject and fails loudly,
rather than being silently skipped. -/
def configSubject (g : String) : Option Subject :=
  if g.startsWith "norm" then some (fun e => normalizeConfig (e.get "in"))
  else if g.startsWith "opt" then some (fun e => resolveOptions (e.get "in"))
  else none

-- --- graph: resolved/blocked, and the explanation ----------------------

def graphSubject (g : String) : Option Subject :=
  if g == "resolve" || g == "blocked" then some (fun e => resolveGraph (e.get "in"))
  else none

-- --- the twelve DRIVER sections ----------------------------------------

/-- Every entry carries `in`, and a port needs DOCS.md §4 to run them —
the probe catalog, the command vocabulary, and the canonical observable
`{status, open, log, result}`. Corpus files alone are not enough, which
is why C2 shipped both together. -/
def driverSubject (_ : String) : Option Subject := some (fun e => drive (e.get "in"))

/-- The sections driven by a direct function call. -/
def pureSections : List String :=
  ["ref", "version", "capability", "resolve", "env", "config", "graph"]

/-- The driver sections, in §15.3's order. Each entry is a command list
against a fresh host. -/
def driverSections : List String :=
  ["lifecycle", "order", "point", "export", "depend", "declare",
   "state", "resource", "nest", "trace", "apply", "error"]

/-- EVERY CORPUS SECTION IS RUN (AGENTS.md §"the layout to copy").

`runSection` already fails on a GROUP with no subject. This closes the
level above: a whole SECTION the runner never mentions is a section
silently not run, and it would pass a suite that claims all 572 entries.
Sixteen of the seventeen earlier ports carry this check; this port
shipped without it.

It also refuses a corpus with no `PLUGIN.version`, because that block is
what turns on strict entry validation in every runner and a corpus that
lost it must not silently downgrade this port's checking. -/
def coverage (cor : Value) (tally : IO.Ref Tally) : IO Unit := do
  let primary := cor.get "primary"
  let meta := cor.get "PLUGIN"
  let run := pureSections ++ driverSections
  let bad (msg : String) : IO Unit := do
    tally.modify (fun t => { t with failures := t.failures + 1 })
    IO.println ("coverage: " ++ msg)

  if (meta.get "version").asNum != 1.0 then
    bad "corpus PLUGIN.version must be 1"

  for name in primary.sortedKeys do
    if !run.contains name then
      bad ("corpus section no test runs: " ++ name)

  for name in run do
    if !primary.has name then
      bad ("tests name a section the corpus does not have: " ++ name)

  -- A floor, not a fixture: the corpus grows, and a run that suddenly
  -- covers a fraction of it is the failure worth catching.
  let t ← tally.get
  if t.entries < 400 then
    bad ("only " ++ toString t.entries
      ++ " corpus entries ran; the corpus has far more")

def main : IO Unit := do
  let cor ← loadCorpus
  let tally ← IO.mkRef ({} : Tally)

  runSection cor tally "ref" refSubject
  runSection cor tally "version" versionSubject
  runSection cor tally "capability" capabilitySubject
  runSection cor tally "resolve" resolveSubject
  runSection cor tally "env" envSubject
  runSection cor tally "config" configSubject
  runSection cor tally "graph" graphSubject

  for s in driverSections do
    runSection cor tally s driverSubject

  coverage cor tally

  let t ← tally.get
  if t.entries == 0 then
    IO.println "lean: no corpus entries ran"
    IO.Process.exit 1
  if t.failures > 0 then
    IO.println ("\nlean: " ++ toString t.failures ++ " failure(s) of "
      ++ toString t.entries ++ " entries")
    IO.Process.exit 1
  IO.println ("lean: " ++ toString t.entries ++ " corpus entries, all pass")
