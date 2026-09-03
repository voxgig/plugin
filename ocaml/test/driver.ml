(* The driver (DOCS.md §4).

   Every port implements this same small thing and nothing else is
   port-specific: the probe catalog, the command interpreter, and the
   canonical observable.

   A PROBE'S CALLBACKS ARE CLOSURES OVER THE INSTANCE, the way the
   canonical writes them — OCaml has closures, so unlike `c` there is
   no context pointer to thread. *)

module V = Value
open Defs

(* --- probe helpers --------------------------------------------------- *)

let opt (i : inst) key = V.get i.options key
let num v = if V.is_num v then V.as_num v else 0.0

let bump (i : inst) start =
  if not (V.has i.istate "count") then V.set i.istate "count" (V.vnum start)

(* `noisy` fails on demand: `options.fail` names the callback that
   raises and `options.code` the error code. `options.bare` raises with
   NO CODE AT ALL, which is the ordinary library error §12's
   `plugin_<phase>_failed` codes exist to wrap. *)
let boom i cb =
  let f = opt i "fail" in
  if V.is_str f && V.as_str f = cb then begin
    let text = "probe failed at " ^ cb in
    if V.truthy (opt i "bare") then
      (* `fail` needs a code, so the bare case uses a sentinel the host
         recognises and wraps, which is what every other port gets from
         a plain language error. *)
      Types.fail "plugin_bare" text;
    let code = opt i "code" in
    Types.fail
      (if V.is_str code then V.as_str code else "plugin_" ^ cb ^ "_failed")
      text
  end

let reenter i cb =
  let r = opt i "reenter" in
  if V.is_str r && V.as_str r = cb then
    (* A transition from inside a lifecycle callback: §5.2's
       `plugin_reentrant`, reached by actually attempting one. *)
    ignore (Host.activate i.owner i.iref)

(* --- the `probe` bindings -------------------------------------------- *)

let bindprobe (i : inst) =
  let band = opt i "band" in
  (* One hook binding (`p`) and one chain wrap (`c`) — the workhorse
     shape DOCS.md §4.3 specifies. *)
  Host.bindhook i "p"
    (fun _ ->
      V.set i.istate "count" (V.vnum (num (V.get i.istate "count") +. 1.0));
      (* `p` RETURNS NOTHING, as the canonical's arrow-with-a-block
         does: in `bail` mode a return is an answer, and a counter that
         answered with its own count would make every hook that keeps
         one un-bailable. *)
      None)
    band;
  Host.bindchain i "c"
    (fun next arg ->
      let wrap = opt i "wrap" in
      let w = if V.is_str wrap then V.as_str wrap else ":" in
      let inner = next arg in
      let tail =
        if V.is_str inner then V.as_str inner
        else if V.is_null inner then ""
        else V.json inner
      in
      (* Wrap AFTER next, so the result spells the nesting left to
         right: outermost first. Wrapping the ARGUMENT instead would
         spell it backwards and make every chain expectation read
         wrong. *)
      V.vstr (w ^ tail))
    band

(* --- the base points every driver host declares ---------------------- *)

(* DOCS.md §4.3 defines `probe` as binding one hook point (`p`) and
   wrapping one chain point (`c`), so a host without them cannot load
   the probe at all — they are part of the contract's baseline rather
   than a fixture convenience. `v` is the provider point the `provider`
   probe defaults to.

   Defined HERE, above the probes, because `probe`'s own `activate`
   nests a host and needs it; it has no probe dependency of its own. *)
let build cmd =
  let points = V.vmap () in
  let kind k v =
    let m = V.vmap () in
    V.set m "kind" (V.vstr v);
    V.set points k m
  in
  kind "p" "hook";
  kind "c" "chain";
  kind "v" "provider";

  let extra = V.get cmd "points" in
  if V.is_map extra then
    (* A `host` command REPLACES a base point rather than merging into
       it, so an entry can redeclare `c` with its own base or `v` as
       exclusive without inheriting the default's shape. *)
    List.iter (fun k -> V.set points k (V.get extra k)) (V.keys extra);

  (* Every chain point gets the identity base: the host owns it and a
     plugin cannot replace it (§6.2). *)
  let bases =
    List.filter_map
      (fun k ->
        let kd = V.get (V.get points k) "kind" in
        if V.is_str kd && "chain" = V.as_str kd then Some (k, fun a -> a)
        else None)
      (V.keys points)
  in
  let dep = V.get cmd "dependency" in
  { nohostoptions with
    opoints = points;
    obases = bases;
    oreserved = V.get cmd "reserved";
    okeys = V.get cmd "keys";
    odefaults = V.get cmd "defaults";
    oprofile = V.get cmd "profile";
    (* §11.3's strict reading. Absent means `restart`, which is the
       default precisely because a station that cannot swap a provider
       without a restart has lost the argument for having a plugin
       system. *)
    odependency = (if V.is_str dep then V.as_str dep else "") }

let probe_names =
  [ "probe"; "noisy"; "greedy"; "dep"; "provider";
    "slow"; "other"; "adapter"; "late" ]

(* --- probe callbacks -------------------------------------------------- *)

let probedefine (i : inst) =
  bump i 0.0;
  boom i "define";
  bindprobe i;
  Host.exportvalue i "client" (V.vstr i.iref);
  (* The instance api itself, so the driver's `stray` command can call
     `release` from OUTSIDE a lifecycle callback — which is the only
     way to exercise §8.3's scope guard. The driver looks the instance
     up by ref; this export keeps the shape the other ports have. *)
  Host.exportvalue i "inst" (V.vstr i.iref);
  List.iter (Host.provides i) (V.items (opt i "provides"))

let greedycapture (i : inst) =
  let acquire = int_of_float (num (opt i "acquire")) in
  let release = int_of_float (num (opt i "release")) in
  (* Acquire N and hand back M, so the DIFFERENCE is what the instance
     scope must unwind (§8.3). Handing one back early must not make
     teardown wrong: the scope keeps the entry and unwinding it twice
     is a no-op. *)
  let held = List.init acquire (fun _ -> Host.acquire i) in
  List.iteri (fun k s -> if k < release then Host.giveback i s) held;

  let markn = int_of_float (num (opt i "mark")) in
  let markfail = V.truthy (opt i "markfail") in
  for k = 0 to markn - 1 do
    Host.release i
      (Some
         (fun () ->
           let unwound = V.get i.istate "unwound" in
           let unwound =
             if V.is_list unwound then unwound
             else (let l = V.vlist () in V.set i.istate "unwound" l; l)
           in
           V.push unwound (V.vnum (float_of_int k));
           if markfail then
             (* The only way §8.3's `plugin_release_failed` and its
                `failed` status are reachable. *)
             Types.fail "probe_release_boom" "release raised"))
  done

let greedydefine (i : inst) =
  bump i 0.0;
  (* `options.early` acquires in `define` instead, where §8.1 says
     capture does not belong. *)
  let early = opt i "early" in
  if V.is_str early && "acquire" = V.as_str early then ignore (Host.acquire i);
  if V.is_str early && "release" = V.as_str early then Host.release i None;
  if not (V.is_str (opt i "bind")) then
    Host.bindhook i "p"
      (fun _ ->
        V.set i.istate "count" (V.vnum (num (V.get i.istate "count") +. 1.0));
        None)
      (opt i "band")

(* `options.bind` names the callback that declares a BINDING outside
   `define`, which is §8.1's other half and §12's `plugin_bind_scope`. *)
let greedybindat (i : inst) cb =
  let b = opt i "bind" in
  if V.is_str b && V.as_str b = cb then
    Host.bindhook i "p" (fun _ -> None) V.vnull

let depdefine (i : inst) =
  V.set i.istate "count" (V.vnum 0.0);
  List.iter (Host.provides i) (V.items (opt i "provides"));
  let exports = opt i "exports" in
  if V.is_map exports then
    List.iter (fun k -> Host.exportvalue i k (V.get exports k)) (V.keys exports)

let providerdefine (i : inst) =
  V.set i.istate "count" (V.vnum 0.0);
  let point = opt i "point" in
  Host.bindhook i
    (if V.is_str point then V.as_str point else "v")
    (fun _ ->
      (* PRESENCE, not non-null. An authored `value: null` IS a value —
         and in `bail` mode a null DECLINES and the next binding
         answers, which is what `point/bail#null-declines` pins.
         Reading it as "no value given" and substituting the ref made
         this probe answer where the contract says it stands aside. *)
      if not (V.has i.options "value") then Some (V.vstr i.iref)
      else Some (opt i "value"))
    (opt i "band");
  (* The capability records come from [options.provides] VERBATIM, and
     there is no second source. An earlier draft of this probe also
     synthesized one from [options.capability]/[version]/[priority] --
     three keys the canonical's [provider] does not read and no corpus
     entry sets -- and then dropped it on the floor. Dead code a reader
     would take for behaviour. *)
  let provides = opt i "provides" in
  if V.is_list provides then List.iter (Host.provides i) (V.items provides)

(* §4.3's six probes, plus the `record` family the corpus names. Their
   behaviour is as much the contract as the runner is — this is where
   twenty implementations of `noisy` are made to fail at the same
   callback in the same way. *)
let rec probeactivate (i : inst) =
  ignore (Host.acquire i);
  reenter i "activate";
  boom i "activate";
  (* §6.5: an instance that is itself a host. The outer owns the
     inner's lifetime — registered in the scope, so it closes on
     deactivate in the same reverse unwind as every other resource. *)
  let nest = opt i "nest" in
  if V.is_list nest && 0 < V.len nest then begin
    let inner = Host.nest i (build V.vnull) in
    seed inner;
    List.iter (fun r -> ignore (Host.ready inner (V.as_str r))) (V.items nest)
  end

(* `greedy` acquires `options.acquire` resources and releases
   `options.release` of them explicitly, so the difference is what the
   instance scope must unwind (§8.3). *)

and probedef name =
  let base =
    { dname = name; shape = V.vnull;
      define = Some (fun i -> bump i 0.0);
      activate = Some (fun i -> ignore (Host.acquire i));
      deactivate = None; close = None; reconfigure = None }
  in
  match name with
  | "probe" | "noisy" ->
    { base with
      define = Some probedefine;
      activate = Some probeactivate;
      deactivate = Some (fun i -> boom i "deactivate");
      close = Some (fun i -> boom i "close") }
  | "greedy" ->
    { base with
      define = Some greedydefine;
      activate = Some (fun i -> greedycapture i; greedybindat i "activate");
      deactivate = Some (fun i -> greedybindat i "deactivate") }
  | "dep" -> { base with define = Some depdefine }
  | "provider" -> { base with define = Some providerdefine }
  | _ -> base

(* Register the whole probe set into a host's catalog. *)
and seed h = List.iter (fun n -> Host.define h (probedef n)) probe_names

let probes () = V.oflist (List.map V.vstr probe_names)
let probe name = if List.mem name probe_names then Some (probedef name) else None

(* --- the command interpreter ----------------------------------------- *)

let declspec cmd =
  let options = V.get cmd "options" in
  { nospec with
    (* PRESENT AND NOT NULL. Every driver builds its spec with all four
       keys and a null for each absent one, so a presence test reads an
       omitted `options` as an authored empty and wipes the real
       ones. *)
    soptions = (if V.is_map options then Some options else None);
    sorder = V.get cmd "order";
    sdefinition = V.as_str (V.get cmd "definition");
    stag = V.as_str (V.get cmd "tag") }

(* One command. Answers (host, result), where the result is `Some v`
   when the verb yields one; §4.5 makes `result` the value of THE LAST
   COMMAND THAT PRODUCES ONE, so "produced nothing" and "produced null"
   have to stay distinguishable — which is why the answer is an option
   of an option. *)
let docmd h cmd =
  let verb = V.as_str (V.get cmd "do") in
  let r = V.as_str (V.get cmd "ref") in
  let point = V.as_str (V.get cmd "point") in
  let spec = declspec cmd in
  let none = (h, None) in
  let yields v = (h, Some v) in

  match verb with
  | "host" ->
    let fresh = Host.makehost (build cmd) in
    seed fresh;
    (fresh, None)
  | "define" ->
    (* §10.1's static registration: the definition ENTERS THE CATALOG
       here, and registration is where its option shape is validated
       (§9.4) — before any load, so a malformed shape fails at one
       moment in every host rather than whenever a document happens to
       exercise the key.

       §4.2's three keys, all of them live. `probe` names the PROBE
       whose callbacks back the definition and `name` is what the
       definition is called. *)
    let name = V.as_str (V.get cmd "name") in
    let from = V.as_str (V.get cmd "probe") in
    let from = if "" = from then name else from in
    let base = probe from in
    let def =
      match base with
      | Some b -> { b with dname = name }
      | None ->
        { dname = name; shape = V.vnull; define = None; activate = None;
          deactivate = None; close = None; reconfigure = None }
    in
    if V.has cmd "shape" then def.shape <- V.get cmd "shape";
    Host.define h def;
    none
  | "load" -> ignore (Host.load h r spec); none
  | "ready" ->
    (* declare FIRST, so the ordering block and definition reach the
       instance — `ready` walks the staircase, it does not carry
       configuration of its own. *)
    ignore (Host.declare h r spec);
    ignore (Host.ready h r);
    none
  | "activate" -> ignore (Host.activate h r); none
  | "deactivate" -> ignore (Host.deactivate h r); none
  | "unload" -> Host.unload h r; none
  | "close" -> Host.close h; none
  | "apply" -> Host.apply h (V.get cmd "doc") (V.get cmd "profile"); none
  | "options" -> Host.setoptions h r (V.get cmd "patch"); none
  | "declare" -> yields (V.vstr (Host.declare h r spec).iref)
  | "hostdeclare" ->
    (* §9.1's host-owned path: the embedding host installing the
       instance whose name it reserved. *)
    yields (V.vstr (Host.declare h r { spec with shostowned = true }).iref)
  | "list" -> yields (Host.list h)
  | "emit" -> (h, Some (match Host.emit h point (V.get cmd "arg") with
                        | Some v -> v | None -> V.vnull))
  | "chain" -> yields (Host.call h point (V.get cmd "arg"))
  | "provider" ->
    (h, Some (match Host.provider h point (V.get cmd "arg") with
              | Some v -> v | None -> V.vnull))
  | "shadowed" -> yields (Host.shadowed h point)
  | "export" ->
    (h, Some (match Host.exports h (V.as_str (V.get cmd "key")) with
              | Some v -> v | None -> V.vnull))
  | "capability" -> yields (Host.capability h (V.as_str (V.get cmd "name")))
  | "trace" -> yields (Host.trace h)
  | "order" -> yields (Host.order h point)
  | "seq" ->
    yields (match Host.instance h r with
            | Some e -> V.vnum e.seq | None -> V.vnull)
  | "pos" ->
    yields (match Host.instance h r with
            | Some e -> V.vnum e.pos | None -> V.vnull)
  | "inner" ->
    yields
      (match Host.instance h r with
       | Some { inner = Some i; _ } -> Host.list i
       | _ -> V.vnull)
  | "call" -> (
    match Host.instance h r with
    | None -> Types.fail "plugin_not_loaded" ("no such instance: " ^ r)
    | Some e -> (
      let method_ = V.as_str (V.get cmd "method") in
      match method_ with
      | "" -> none
      | "bump" ->
        V.set e.istate "count" (V.vnum (num (V.get e.istate "count") +. 1.0));
        none
      | "count" -> yields (V.vnum (num (V.get e.istate "count")))
      | "unwound" ->
        let u = V.get e.istate "unwound" in
        yields (if V.is_list u then u else V.vlist ())
      | "position" ->
        (* Reached through the instance api, which is where §6.6 puts
           it — a plugin asks about itself. *)
        yields (Host.position e point)
      | "stray" ->
        (* A release from OUTSIDE a lifecycle callback. The scope
           belongs to the activation; a call from anywhere else has no
           scope to belong to, so it raises. *)
        Host.release e None;
        none
      | _ -> none))
  | _ -> Types.fail "plugin_bad_state" ("unknown driver command: " ^ verb)

let drive cmds =
  let host = ref (Host.makehost (build V.vnull)) in
  seed !host;

  (* §4.5: `result` is the value of THE LAST COMMAND THAT PRODUCES ONE.
     Storing it and continuing — rather than returning at the first
     producing command — is what lets an entry emit and then inspect,
     which most of `point` needs. *)
  let last = ref None in
  List.iter
    (fun cmd ->
      try
        let h, produced = docmd !host cmd in
        host := h;
        match produced with Some _ -> last := produced | None -> ()
      with Types.Plugin_error e ->
        (* §4.1: `catch` records the raise and lets the run continue,
           which is the only way to observe a `failed` instance —
           §5.2's whole claim is that it stays registered and
           inspectable. *)
        if not (V.truthy (V.get cmd "catch")) then
          raise (Types.Plugin_error e))
    (V.items cmds);

  Host.observable !host !last
