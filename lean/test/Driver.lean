import Plugin.Machine
import Corpus

/-!
# The driver (DOCS.md §4)

Every port implements this same small thing and nothing else is
port-specific: the probe catalog, the command interpreter, and the
canonical observable.

A PROBE'S CALLBACK GETS AN `InstApi`, NOT AN INSTANCE — see `Defs`'s
header for why Lean's kernel forbids the latter. In practice a probe
reads `i.getOptions`, calls `i.bindHook`, and closes over `i` exactly the
way the canonical closes over its instance.
-/

namespace Plugin

-- --- probe helpers -----------------------------------------------------

def opt (i : InstApi) (key : String) : PluginM Value := do
  return (← i.getOptions).get key

def numOf (v : Value) : Float := if v.isNum then v.asNum else 0.0

def bumpState (i : InstApi) (start : Float) : PluginM Unit := do
  let st ← i.getState
  if !st.has "count" then i.setState (st.set "count" (.num start))

def addCount (i : InstApi) : PluginM Unit := do
  let st ← i.getState
  i.setState (st.set "count" (.num (numOf (st.get "count") + 1.0)))

/-- `noisy` fails on demand: `options.fail` names the callback that
raises and `options.code` the error code. `options.bare` raises with NO
CODE AT ALL, which is the ordinary library error §12's
`plugin_<phase>_failed` codes exist to wrap. -/
def boom (i : InstApi) (cb : String) : PluginM Unit := do
  let f ← opt i "fail"
  if !f.isStr || f.asStr != cb then return
  let text := "probe failed at " ++ cb
  -- `raise` needs a code, so the bare case uses a sentinel the host
  -- recognises and wraps, which is what every other port gets from a
  -- plain language error.
  if (← opt i "bare").truthy then raise "plugin_bare" text
  let code ← opt i "code"
  raise (if code.isStr then code.asStr else "plugin_" ++ cb ++ "_failed") text

def reenter (i : InstApi) (cb : String) : PluginM Unit := do
  let r ← opt i "reenter"
  -- A transition from inside a lifecycle callback: §5.2's
  -- `plugin_reentrant`, reached by actually attempting one.
  if r.isStr && r.asStr == cb then i.activateSelf

-- --- the `probe` bindings ----------------------------------------------

def bindProbe (i : InstApi) : PluginM Unit := do
  let band ← opt i "band"
  -- One hook binding (`p`) and one chain wrap (`c`) — the workhorse
  -- shape DOCS.md §4.3 specifies. `p` RETURNS NOTHING, as the
  -- canonical's arrow-with-a-block does: in `bail` mode a return is an
  -- answer, and a counter that answered with its own count would make
  -- every hook that keeps one un-bailable.
  i.bindHook "p" (fun _ => do addCount i; return none) band
  i.bindChain "c" (fun next arg => do
    let wrap ← opt i "wrap"
    let w := if wrap.isStr then wrap.asStr else ":"
    let inner ← next arg
    let tail := if inner.isStr then inner.asStr
      else if inner.isNull then "" else Value.json inner
    -- Wrap AFTER next, so the result spells the nesting left to right:
    -- outermost first. Wrapping the ARGUMENT instead would spell it
    -- backwards and make every chain expectation read wrong.
    return .str (w ++ tail)) band

-- --- probe callbacks ---------------------------------------------------

def probeDefine (i : InstApi) : PluginM Unit := do
  bumpState i 0.0
  boom i "define"
  bindProbe i
  i.exportValue "client" (.str i.ref)
  -- The instance api itself, so the driver's `stray` command can call
  -- `release` from OUTSIDE a lifecycle callback — which is the only way
  -- to exercise §8.3's scope guard. The driver looks the instance up by
  -- ref; this export keeps the shape the other ports have.
  i.exportValue "inst" (.str i.ref)
  for p in (← opt i "provides").items do i.provides p

def probeActivate (i : InstApi) : PluginM Unit := do
  let _ ← i.acquire
  reenter i "activate"
  boom i "activate"
  -- §6.5: an instance that is itself a host. The outer owns the inner's
  -- lifetime — registered in the scope, so it closes on deactivate in
  -- the same reverse unwind as every other resource.
  let nest ← opt i "nest"
  if nest.isList && nest.len > 0 then
    let inner ← i.nest
    for r in nest.items do inner.ready r.asStr

/-- `greedy` acquires `options.acquire` resources and releases
`options.release` of them explicitly, so the difference is what the
instance scope must unwind (§8.3). -/
def greedyCapture (i : InstApi) : PluginM Unit := do
  let acquireN := (numOf (← opt i "acquire")).toUInt64.toNat
  let releaseN := (numOf (← opt i "release")).toUInt64.toNat
  -- Acquire N and hand back M, so the DIFFERENCE is what the instance
  -- scope must unwind (§8.3). Handing one back early must not make
  -- teardown wrong: the scope keeps the entry and unwinding it twice is
  -- a no-op.
  let mut held : List Nat := []
  for _ in [0:acquireN] do held := held ++ [← i.acquire]
  for k in held.take releaseN do i.giveback k

  let markN := (numOf (← opt i "mark")).toUInt64.toNat
  let markfail := (← opt i "markfail").truthy
  for k in [0:markN] do
    i.release (some (do
      let st ← i.getState
      let unwound := let u := st.get "unwound"; if u.isList then u else Value.vlist
      i.setState (st.set "unwound" (unwound.push (.num (Float.ofNat k))))
      -- The only way §8.3's `plugin_release_failed` and its `failed`
      -- status are reachable.
      if markfail then raise "probe_release_boom" "release raised"))

def greedyDefine (i : InstApi) : PluginM Unit := do
  bumpState i 0.0
  -- `options.early` acquires in `define` instead, where §8.1 says
  -- capture does not belong.
  let early ← opt i "early"
  if early.isStr && early.asStr == "acquire" then let _ ← i.acquire
  if early.isStr && early.asStr == "release" then i.release none
  if !(← opt i "bind").isStr then
    i.bindHook "p" (fun _ => do addCount i; return none) (← opt i "band")

/-- `options.bind` names the callback that declares a BINDING outside
`define`, which is §8.1's other half and §12's `plugin_bind_scope`. -/
def greedyBindAt (i : InstApi) (cb : String) : PluginM Unit := do
  let b ← opt i "bind"
  if b.isStr && b.asStr == cb then i.bindHook "p" (fun _ => return none) .null

def depDefine (i : InstApi) : PluginM Unit := do
  i.setState ((← i.getState).set "count" (.num 0.0))
  for p in (← opt i "provides").items do i.provides p
  let exports ← opt i "exports"
  if exports.isMap then
    for k in exports.keys do i.exportValue k (exports.get k)

def providerDefine (i : InstApi) : PluginM Unit := do
  i.setState ((← i.getState).set "count" (.num 0.0))
  let point ← opt i "point"
  i.bindHook (if point.isStr then point.asStr else "v")
    (fun _ => do
      -- PRESENCE, not non-null. An authored `value: null` IS a value —
      -- and in `bail` mode a null DECLINES and the next binding answers,
      -- which is what `point/bail#null-declines` pins. Reading it as "no
      -- value given" and substituting the ref made this probe answer
      -- where the contract says it stands aside.
      let opts ← i.getOptions
      return some (if opts.has "value" then opts.get "value" else .str i.ref))
    (← opt i "band")
  -- The capability records come from `options.provides` VERBATIM, and
  -- there is no second source. `c` once synthesized one from
  -- `options.capability`/`version`/`priority` — three keys the
  -- canonical's `provider` does not read and no corpus entry sets — and
  -- then dropped it on the floor; the haskell port found it.
  for p in (← opt i "provides").items do i.provides p

/-- §4.3's six probes, plus the `record` family the corpus names. Their
behaviour is as much the contract as the runner is — this is where twenty
implementations of `noisy` are made to fail at the same callback in the
same way. -/
def probeDef (name : String) : Definition :=
  let base : Definition := {
    name := name
    define := some (fun i => bumpState i 0.0)
    activate := some (fun i => do let _ ← i.acquire) }
  if name == "probe" || name == "noisy" then
    { base with
      define := some probeDefine
      activate := some probeActivate
      deactivate := some (fun i => boom i "deactivate")
      close := some (fun i => boom i "close") }
  else if name == "greedy" then
    { base with
      define := some greedyDefine
      activate := some (fun i => do greedyCapture i; greedyBindAt i "activate")
      deactivate := some (fun i => greedyBindAt i "deactivate") }
  else if name == "dep" then { base with define := some depDefine }
  else if name == "provider" then { base with define := some providerDefine }
  else base

def probeNames : List String :=
  ["probe", "noisy", "greedy", "dep", "provider", "slow", "other", "adapter", "late"]

def driverProbes : Value := .list (probeNames.map Value.str)

def driverProbe (name : String) : Option Definition :=
  if probeNames.contains name then some (probeDef name) else none

/-- Register the whole probe set into a host's catalog. -/
def driverSeed (h : HostState) : PluginM Unit := do
  for n in probeNames do hostDefine h (probeDef n)

-- --- the base points every driver host declares ------------------------

/-- DOCS.md §4.3 defines `probe` as binding one hook point (`p`) and
wrapping one chain point (`c`), so a host without them cannot load the
probe at all — they are part of the contract's baseline rather than a
fixture convenience. `v` is the provider point the `provider` probe
defaults to. -/
def buildOptions (cmd : Value) : HostOptions :=
  let kindMap := fun (k v : String) => (k, Value.vmap.set "kind" (.str v))
  let base := ([kindMap "p" "hook", kindMap "c" "chain", kindMap "v" "provider"]).foldl
    (fun m p => m.set p.1 p.2) Value.vmap
  let extra := cmd.get "points"
  -- A `host` command REPLACES a base point rather than merging into it,
  -- so an entry can redeclare `c` with its own base or `v` as exclusive
  -- without inheriting the default's shape.
  let points := if extra.isMap then (extra.keys).foldl (fun m k => m.set k (extra.get k)) base
    else base
  -- Every chain point gets the identity base: the host owns it and a
  -- plugin cannot replace it (§6.2).
  let bases := (points.keys).filterMap (fun k =>
    let kd := (points.get k).get "kind"
    if kd.isStr && kd.asStr == "chain" then some (k, fun (a : Value) => (pure a : PluginM Value))
    else none)
  let d := cmd.get "dependency"
  { points := points, bases := bases
    reserved := cmd.get "reserved", keys := cmd.get "keys"
    defaults := cmd.get "defaults", profile := cmd.get "profile"
    -- §11.3's strict reading. Absent means `restart`, which is the
    -- default precisely because a station that cannot swap a provider
    -- without a restart has lost the argument for having a plugin
    -- system.
    dependency := if d.isStr then d.asStr else "" }

-- --- the command interpreter -------------------------------------------

def declSpec (cmd : Value) : DeclareSpec :=
  let options := cmd.get "options"
  { -- PRESENT AND NOT NULL. Every driver builds its spec with all four
    -- keys and a null for each absent one, so a presence test reads an
    -- omitted `options` as an authored empty and wipes the real ones.
    options := if options.isMap then some options else none
    order := cmd.get "order"
    definition := (cmd.get "definition").asStr
    tag := (cmd.get "tag").asStr }

/-- One command. Answers the (possibly new) host and, when the verb
yields one, a result; §4.5 makes `result` the value of THE LAST COMMAND
THAT PRODUCES ONE, so "produced nothing" and "produced null" have to stay
distinguishable — which is why the result is an `Option`. -/
def docmd (h : HostState) (cmd : Value) : PluginM (HostState × Option Value) := do
  let verb := (cmd.get "do").asStr
  let r := (cmd.get "ref").asStr
  let point := (cmd.get "point").asStr
  let spec := declSpec cmd
  let none' := (h, (none : Option Value))
  let yields := fun (v : Value) => (h, some v)

  if verb == "host" then
    let fresh ← makeHost (buildOptions cmd)
    driverSeed fresh
    return (fresh, none)
  if verb == "define" then
    -- §10.1's static registration: the definition ENTERS THE CATALOG
    -- here, and registration is where its option shape is validated
    -- (§9.4) — before any load, so a malformed shape fails at one moment
    -- in every host rather than whenever a document happens to exercise
    -- the key.
    --
    -- §4.2's three keys, all of them live. `probe` names the PROBE whose
    -- callbacks back the definition and `name` is what the definition is
    -- called.
    let name := (cmd.get "name").asStr
    let from_ := let p := (cmd.get "probe").asStr; if p == "" then name else p
    let base := (driverProbe from_).getD { name := name }
    let def_ := { base with name := name }
    hostDefine h (if cmd.has "shape" then { def_ with shape := cmd.get "shape" } else def_)
    return none'
  if verb == "load" then let _ ← hostLoad h r spec; return none'
  if verb == "ready" then
    -- declare FIRST, so the ordering block and definition reach the
    -- instance — `ready` walks the staircase, it does not carry
    -- configuration of its own.
    let _ ← hostDeclare h r spec
    let _ ← hostReady h r
    return none'
  if verb == "activate" then let _ ← hostActivate h r; return none'
  if verb == "deactivate" then let _ ← hostDeactivate h r; return none'
  if verb == "unload" then hostUnload h r; return none'
  if verb == "close" then hostClose h; return none'
  if verb == "apply" then hostApply h (cmd.get "doc") (cmd.get "profile"); return none'
  if verb == "options" then hostSetOptions h r (cmd.get "patch"); return none'
  if verb == "declare" then return yields (.str (← hostDeclare h r spec).ref)
  if verb == "hostdeclare" then
    -- §9.1's host-owned path: the embedding host installing the instance
    -- whose name it reserved.
    return yields (.str (← hostDeclare h r { spec with hostOwned := true }).ref)
  if verb == "list" then return yields (← hostList h)
  if verb == "emit" then return yields ((← hostEmit h point (cmd.get "arg")).getD .null)
  if verb == "chain" then return yields (← hostCall h point (cmd.get "arg"))
  if verb == "provider" then return yields ((← hostProvider h point (cmd.get "arg")).getD .null)
  if verb == "shadowed" then return yields (← hostShadowed h point)
  if verb == "export" then
    return yields ((← hostExports h (cmd.get "key").asStr).getD .null)
  if verb == "capability" then return yields (← hostCapability h (cmd.get "name").asStr)
  if verb == "trace" then return yields (← hostTrace h)
  if verb == "order" then return yields (← hostOrder h point)
  if verb == "seq" then
    return yields (match ← hostInstance h r with | some e => .num e.seq | none => .null)
  if verb == "pos" then
    match ← hostInstance h r with
    | some e => return yields (.num (← e.pos.get))
    | none => return yields .null
  if verb == "inner" then
    match ← hostInstance h r with
    | some e => match ← e.inner.get with
      | some api => return yields (← api.list)
      | none => return yields .null
    | none => return yields .null
  if verb == "call" then
    match ← hostInstance h r with
    | none => raise "plugin_not_loaded" ("no such instance: " ++ r)
    | some e =>
      let method := (cmd.get "method").asStr
      if method == "" then return none'
      if method == "bump" then
        e.state.set ((← e.state.get).set "count"
          (.num (numOf ((← e.state.get).get "count") + 1.0)))
        return none'
      if method == "count" then
        return yields (.num (numOf ((← e.state.get).get "count")))
      if method == "unwound" then
        let u := (← e.state.get).get "unwound"
        return yields (if u.isList then u else Value.vlist)
      if method == "position" then
        -- Reached through the instance api, which is where §6.6 puts it
        -- — a plugin asks about itself.
        return yields (← positionOf h e.ref point)
      if method == "stray" then
        -- A release from OUTSIDE a lifecycle callback. The scope belongs
        -- to the activation; a call from anywhere else has no scope to
        -- belong to, so it raises.
        instRelease h e none
        return none'
      return none'
  raise "plugin_bad_state" ("unknown driver command: " ++ verb)

def drive (cmds : Value) : PluginM Value := do
  let mut h ← makeHost (buildOptions .null)
  driverSeed h
  -- §4.5: `result` is the value of THE LAST COMMAND THAT PRODUCES ONE.
  -- Storing it and continuing — rather than returning at the first
  -- producing command — is what lets an entry emit and then inspect,
  -- which most of `point` needs.
  let mut last : Option Value := none
  for cmd in cmds.items do
    try
      let (h', produced) ← docmd h cmd
      h := h'
      match produced with
      | some _ => last := produced
      | none => pure ()
    catch e =>
      -- §4.1: `catch` records the raise and lets the run continue, which
      -- is the only way to observe a `failed` instance — §5.2's whole
      -- claim is that it stays registered and inspectable.
      if !(cmd.get "catch").truthy then throw e
  observable h last

end Plugin
