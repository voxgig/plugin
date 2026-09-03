(* The ocaml port's test runner.

   NO TEST FRAMEWORK (§16): a `main` that counts. It reports the entry
   count as well as the pass, because "all pass" over zero entries is
   the failure doc/plan/handover.md §4 warns about. *)

module V = Value

(* §15.3's `ref` section, group by group. EVERY group must have a
   subject: a group the runner does not know is a group silently not
   run, which is worse than a failure. *)
let refsubject = function
  | "name" | "bound" -> Some (fun e -> V.vbool (Ref.checkname (V.get e "in")))
  | "tag" | "boundtag" -> Some (fun e -> V.vbool (Ref.checktag (V.get e "in")))
  | "parse" | "parsebad" -> Some (fun e -> Ref.parseref (V.get e "in"))
  | "format" | "formatbad" ->
    Some
      (fun e ->
        let args = V.get e "args" in
        V.vstr (Ref.formatref (V.at args 0) (V.at args 1)))
  | "canon" -> Some (fun e -> V.vstr (Ref.canonref (V.get e "in")))
  | _ -> None

(* --- version: the range grammar and the one predicate --------------- *)

let versionsubject = function
  | "range" | "rangebad" -> Some (fun e -> Version.parserange (V.get e "in"))
  | "satisfies" ->
    Some
      (fun e ->
        let i = V.get e "in" in
        V.vbool (Version.satisfies (V.get i "version") (V.get i "range")))
  | _ -> None

(* --- capability: matching and the total rank ------------------------ *)

let capabilitysubject = function
  | "match" | "nested" | "rank" ->
    Some
      (fun e ->
        let i = V.get e "in" in
        Capability.resolvecapability (V.get i "req") (V.get i "candidates"))
  | _ -> None

(* --- resolve: name to candidate module ids -------------------------- *)

let resolvesubject = function
  | "candidates" ->
    Some
      (fun e ->
        let i = V.get e "in" in
        Resolve.resolvecandidates (V.get i "name") (V.get i "sources"))
  | "from" -> Some (fun e -> Resolve.resolvefrom (V.get e "in"))
  | _ -> None

(* --- env: the lossy encoding, and its collision --------------------- *)

(* Every group in `env` is one call: the section is a single pure
   function over the whole input. *)
let envsubject _ = Some (fun e -> Env.applyenv (V.get e "in"))

(* --- config: normalization and the ten-level ladder ------------------ *)

let starts p s =
  String.length s >= String.length p && String.sub s 0 (String.length p) = p

(* The prefix IS the dispatch: `norm*` groups normalize, `opt*` groups
   resolve. A group with neither prefix gets no subject and fails
   loudly, rather than being silently skipped. *)
let configsubject g =
  if starts "norm" g then Some (fun e -> Config.normalizeconfig (V.get e "in"))
  else if starts "opt" g then Some (fun e -> Config.resolveoptions (V.get e "in"))
  else None

(* --- graph: resolved/blocked, and the explanation ------------------- *)

let graphsubject = function
  | "resolve" | "blocked" -> Some (fun e -> Graph.resolvegraph (V.get e "in"))
  | _ -> None

(* --- the twelve DRIVER sections ------------------------------------- *)

(* Every entry carries `cmd`, and a port needs DOCS.md §4 to run them —
   the probe catalog, the command vocabulary, and the canonical
   observable {status, open, log, result}. Corpus files alone are not
   enough, which is why C2 shipped both together. *)
let driversubject _ = Some (fun e -> Driver.drive (V.get e "cmd"))

(* The sections driven by a direct function call. *)
let pure =
  [ "ref"; "version"; "capability"; "resolve"; "env"; "config"; "graph" ]

(* The driver sections, in §15.3's order. Each entry is a command list
   against a fresh host. *)
let driver =
  [ "lifecycle"; "order"; "point"; "export"; "depend"; "declare";
    "state"; "resource"; "nest"; "trace"; "apply"; "error" ]

(* EVERY CORPUS SECTION IS RUN (AGENTS.md §"the layout to copy").

   `runsection` already fails on a GROUP with no subject. This closes the
   level above: a whole SECTION the runner never mentions is a section
   silently not run, and it would pass a suite that claims all 572
   entries. Sixteen of the seventeen earlier ports carry this check; this
   port shipped without it.

   It also refuses a corpus with no PLUGIN.version, because that block is
   what turns on strict entry validation in every runner and a corpus
   that lost it must not silently downgrade this port's checking. *)
let coverage (t : Corpus.tally) =
  let spec = Corpus.corpus () in
  let primary = V.get spec "primary" in
  let meta = V.get spec "PLUGIN" in
  let fail msg =
    t.Corpus.failures <- t.Corpus.failures + 1;
    print_endline ("coverage: " ^ msg)
  in

  if 1.0 <> V.as_num (V.get meta "version") then
    fail "corpus PLUGIN.version must be 1";

  List.iter
    (fun name ->
      if not (List.mem name pure || List.mem name driver) then
        fail ("corpus section no test runs: " ^ name))
    (V.sortedkeys primary);

  List.iter
    (fun name ->
      if not (V.has primary name) then
        fail ("tests name a section the corpus does not have: " ^ name))
    (pure @ driver);

  (* A floor, not a fixture: the corpus grows, and a run that suddenly
     covers a fraction of it is the failure worth catching. *)
  if 400 > t.Corpus.entries then
    fail
      (Printf.sprintf "only %d corpus entries ran; the corpus has far more"
         t.Corpus.entries)

let () =
  let t = { Corpus.entries = 0; failures = 0 } in

  Corpus.runsection t "ref" refsubject;
  Corpus.runsection t "version" versionsubject;
  Corpus.runsection t "capability" capabilitysubject;
  Corpus.runsection t "resolve" resolvesubject;
  Corpus.runsection t "env" envsubject;
  Corpus.runsection t "config" configsubject;
  Corpus.runsection t "graph" graphsubject;

  List.iter (fun s -> Corpus.runsection t s driversubject) driver;

  coverage t;

  if 0 = t.Corpus.entries then begin
    print_endline "ocaml: no corpus entries ran";
    exit 1
  end;
  if 0 < t.Corpus.failures then begin
    print_endline
      (Printf.sprintf "\nocaml: %d failure(s) of %d entries" t.Corpus.failures
         t.Corpus.entries);
    exit 1
  end;
  print_endline
    (Printf.sprintf "ocaml: %d corpus entries, all pass" t.Corpus.entries)
