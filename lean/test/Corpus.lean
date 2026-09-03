import Plugin.Types

/-!
# The corpus reader and the entry check (DOCS.md §4.5, §15)

THE PLUGIN LIBRARY MUST NEVER BE USED TO IMPLEMENT ITS OWN TESTS
(AGENTS.md prime directive 6), and that covers the TYPING as well as the
comparison. This file asks `Plugin.Value` what a value is, because
`Value` is the JSON reader rather than the library under test — but
`same`, `truthy` and the merge semantics the corpus pins are all
re-derived here rather than borrowed from `Types`.

NO TEST FRAMEWORK: §16 permits one runtime dependency, Lean has no port
of it, and `lakefile.lean` declares no `require` at all. The runner is a
`main` that counts. The corpus is threaded through as a value rather
than parked in a global, which in Lean would want `unsafe` machinery for
"read a file once".
-/

namespace Plugin

structure Tally where
  entries : Nat := 0
  failures : Nat := 0

abbrev Subject := Value → PluginM Value

/-- The whole corpus, parsed once. Exits loudly if the JSON is missing or
malformed: a runner that reports zero tests as a pass is the failure mode
doc/plan/handover.md §4 exists to prevent. -/
def loadCorpus : IO Value := do
  let path := (← IO.getEnv "PLUGIN_SPEC").getD "../spec/plugin.json"
  let text ← IO.FS.readFile path
  match Value.parse text with
  | .error e =>
    IO.eprintln ("lean: " ++ path ++ " is not valid JSON: " ++ e)
    IO.Process.exit 2
  | .ok v =>
    -- Version 1 turns on strict entry validation in every runner. A
    -- corpus that lost its version marker is a corpus whose shape nobody
    -- checked, so refuse it rather than run against it.
    let version := (v.get "PLUGIN").get "version"
    if !version.isNum || version.asNum != 1.0 then
      IO.eprintln "lean: unsupported spec version"
      IO.Process.exit 2
    return v

def corpusSection (cor : Value) (name : String) : IO Value := do
  let s := (cor.get "primary").get name
  if !s.isMap then
    IO.eprintln ("lean: no such corpus section: " ++ name)
    IO.Process.exit 2
  return s

/-- A stable label, so a failure names the entry rather than an index. -/
def corpusLabel (group : String) (i : Nat) (entry : Value) : String :=
  let id := entry.get "id"
  if id.isStr then id.asStr else group ++ "#" ++ toString i

/-- Deep equality over spec values: key order never matters, list order
always does. Written here, not taken from the library. -/
partial def corpusEqual (a b : Value) : Bool :=
  match a, b with
  | .null, .null => true
  | .bool x, .bool y => x == y
  | .num x, .num y => x == y
  | .str x, .str y => x == y
  | .list x, .list y => x.length == y.length && (x.zip y).all (fun p => corpusEqual p.1 p.2)
  | .map x, .map y =>
    x.length == y.length && x.all (fun p => b.has p.1 && corpusEqual p.2 (b.get p.1))
  | _, _ => false

/-- A LITERAL-WITH-ANCHORS MATCHER, NOT A REGEX ENGINE.

Lean ships no regex engine, and §16 permits no second dependency to
supply one. Every pattern the corpus writes is a literal, optionally
`^`-anchored, so this unescapes and compares — and RAISES on any
unescaped metacharacter, because the one thing a hand-rolled matcher must
never do is quietly report a mismatch it could not evaluate.

Same shape as `lua/test/corpus.lua`'s `regexlite`, deliberately. -/
def regexLite (pattern text : String) : Except String Bool :=
  let rec go (cs : List Char) (acc : List Char) (anchorStart anchorEnd : Bool)
      : Except String (String × Bool × Bool) :=
    match cs with
    | [] => .ok (String.mk acc.reverse, anchorStart, anchorEnd)
    | '\\' :: c :: rest => go rest (c :: acc) anchorStart anchorEnd
    | '^' :: rest =>
      if acc.isEmpty && !anchorStart then go rest acc true anchorEnd
      else go rest ('^' :: acc) anchorStart anchorEnd
    | ['$'] => .ok (String.mk acc.reverse, anchorStart, true)
    | c :: rest =>
      if "*+?()[]{}|.".toList.contains c then
        .error ("corpus regex needs a real engine, which this port does not have: " ++ pattern)
      else go rest (c :: acc) anchorStart anchorEnd
  match go pattern.toList [] false false with
  | .error e => .error e
  | .ok (lit, anchorStart, anchorEnd) =>
    if anchorStart && anchorEnd then .ok (text == lit)
    else if anchorStart then .ok (text.startsWith lit)
    else if anchorEnd then .ok (text.endsWith lit)
    else
      let tl := text.toList
      let ll := lit.toList
      let rec scan (s : List Char) : Bool :=
        if ll.isPrefixOf s then true
        else match s with
          | [] => false
          | _ :: r => scan r
      .ok (scan tl)

/-- `match` semantics: `__EXISTS__`, `__UNDEF__`, `__NULL__`, `/regex/`,
and partial map matching. `present` distinguishes an absent key from one
holding null, which `__UNDEF__` and `__NULL__` exist to tell apart. -/
partial def corpusMatches (expect actual : Value) (present : Bool) : Except String Bool :=
  let structural : Except String Bool :=
    if expect.isList then
      if !actual.isList || expect.len != actual.len then .ok false
      else
        ((expect.items).zip (actual.items)).foldl
          (fun acc p => match acc with
            | .error e => .error e
            | .ok false => .ok false
            | .ok true => corpusMatches p.1 p.2 true)
          (.ok true)
    else if expect.isMap then
      if !actual.isMap then .ok false
      else
        (expect.sortedKeys).foldl
          (fun acc k => match acc with
            | .error e => .error e
            | .ok false => .ok false
            | .ok true => corpusMatches (expect.get k) (actual.get k) (actual.has k))
          (.ok true)
    else .ok (corpusEqual expect actual)
  if expect.isStr then
    let s := expect.asStr
    if s == "__EXISTS__" then .ok (present && !actual.isNull)
    else if s == "__UNDEF__" then .ok (!present)
    else if s == "__NULL__" then .ok (present && actual.isNull)
    else if s.length > 2 && s.startsWith "/" && s.endsWith "/" then
      if !actual.isStr then .ok false
      else regexLite (s.drop 1 |>.dropRight 1) actual.asStr
    else structural
  else structural

/-- Run one entry and report the disagreement, or `none` when it passes.

The three combinations the spec format allows are enforced here as well
as at build time, because a runner that quietly accepted `err` beside
`out` would let a contradictory entry pass. -/
def corpusCheck (entry : Value) (subject : Subject) : IO (Option String) := do
  let haserr := entry.has "err"
  let hasout := entry.has "out"
  let hasmatch := entry.has "match"
  if haserr && hasout then return some "entry has both err and out"
  if !haserr && !hasout && !hasmatch then return some "entry asserts nothing"

  let outcome ← (subject entry).run
  let judge : Except String Bool → IO (Option String) := fun r =>
    match r with
    | .error e => return some e
    | .ok true => return none
    | .ok false => return some "match failed"

  match outcome with
  | .error e =>
    if !haserr then
      return some ("unexpected raise: " ++ e.code ++ " " ++ e.message)
    let want := entry.get "err"
    -- Errors compare by CODE (§12). Message wording is a port's own
    -- business; pinning it would make every translation a corpus change.
    if want.isStr && e.code != want.asStr then
      return some ("expected code " ++ want.asStr ++ ", got " ++ e.code ++ " (" ++ e.message ++ ")")
    if hasmatch then
      let errv := (((Value.vmap.set "code" (.str e.code)).set "message" (.str e.message)).set
        "name" (.str "PluginError"))
      let got := Value.vmap.set "err" errv
      match corpusMatches (entry.get "match") got true with
      | .error msg => return some msg
      | .ok true => return none
      | .ok false =>
        return some ("error did not match " ++ Value.json (entry.get "match")
          ++ ", got " ++ Value.json got)
    return none
  | .ok value =>
    if haserr then return some ("expected a raise, got: " ++ Value.json value)
    if hasout && !corpusEqual (entry.get "out") value then
      return some ("expected " ++ Value.json (entry.get "out") ++ ", got " ++ Value.json value)
    if hasmatch then
      let got := (Value.vmap.set "in" (entry.get "in")).set "out" value
      match corpusMatches (entry.get "match") got true with
      | .error msg => return some msg
      | .ok true => return none
      | .ok false =>
        return some ("did not match " ++ Value.json (entry.get "match")
          ++ ", got out=" ++ Value.json value)
    judge (.ok true)

def runGroup (tally : IO.Ref Tally) (sec group : String) (entries : Value)
    (subject : Subject) : IO Unit := do
  let set := entries.get "set"
  if !set.isList then return
  for (entry, i) in Value.indexed (set.items) do
    tally.modify (fun t => { t with entries := t.entries + 1 })
    match ← corpusCheck entry subject with
    | none => pure ()
    | some why =>
      tally.modify (fun t => { t with failures := t.failures + 1 })
      -- The label is the entry's own `id` when it has one, and those
      -- already carry the section — printing the section again would
      -- read `ref/ref/canon#trailing`.
      let l := corpusLabel group i entry
      IO.println (if entry.has "id" then l ++ ": " ++ why else sec ++ "/" ++ l ++ ": " ++ why)

def runSection (cor : Value) (tally : IO.Ref Tally) (sec : String)
    (lookup : String → Option Subject) : IO Unit := do
  let groups ← corpusSection cor sec
  -- SORTED, so a failure names the same group in the same place on every
  -- run.
  for name in groups.sortedKeys do
    match lookup name with
    -- A group the runner does not know is a group silently not run,
    -- which is worse than a failure.
    | none =>
      tally.modify (fun t => { t with failures := t.failures + 1 })
      IO.println (sec ++ "/" ++ name ++ ": no subject for this group")
    | some s => runGroup tally sec name (groups.get name) s

end Plugin
