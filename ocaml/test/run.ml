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

let () =
  let t = { Corpus.entries = 0; failures = 0 } in

  Corpus.runsection t "ref" refsubject;
  Corpus.runsection t "version" versionsubject;
  Corpus.runsection t "capability" capabilitysubject;
  Corpus.runsection t "resolve" resolvesubject;
  Corpus.runsection t "env" envsubject;
  Corpus.runsection t "config" configsubject;
  Corpus.runsection t "graph" graphsubject;

  (* The driver sections, in §15.3's order. Each entry is a command
     list against a fresh host. *)
  List.iter
    (fun s -> Corpus.runsection t s driversubject)
    [ "lifecycle"; "order"; "point"; "export"; "depend"; "declare";
      "state"; "resource"; "nest"; "trace"; "apply"; "error" ];

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
