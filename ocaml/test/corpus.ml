(* The corpus reader and the entry check (DOCS.md §4.5, §15).

   THE PLUGIN LIBRARY MUST NEVER BE USED TO IMPLEMENT ITS OWN TESTS
   (AGENTS.md prime directive 6), and that covers the TYPING as well as
   the comparison. This file asks `value.ml` what a value is, because
   `value.ml` is the JSON reader rather than the library under test —
   but `same`, `truthy` and the merge semantics the corpus pins are all
   re-derived here rather than borrowed from `types.ml`.

   NO TEST FRAMEWORK: §16 permits one runtime dependency, OCaml has no
   port of it, and a unit-test library would be a second. The runner is
   a `main` that counts. *)

module V = Value

let loaded = ref None

let specpath () =
  match Sys.getenv_opt "PLUGIN_SPEC" with
  | Some p when "" <> p -> p
  | _ -> "../spec/plugin.json"

(* The whole corpus, parsed once. Exits loudly if the JSON is missing
   or malformed: a runner that reports zero tests as a pass is the
   failure mode doc/plan/handover.md §4 exists to prevent. *)
let corpus () =
  match !loaded with
  | Some v -> v
  | None ->
    let path = specpath () in
    let text =
      try
        let ic = open_in_bin path in
        let n = in_channel_length ic in
        let s = really_input_string ic n in
        close_in ic;
        s
      with _ ->
        prerr_endline ("ocaml: cannot open " ^ path);
        exit 2
    in
    let v =
      try V.parse text
      with V.Parse_error m ->
        prerr_endline ("ocaml: " ^ path ^ " is not valid JSON: " ^ m);
        exit 2
    in
    (* Version 1 turns on strict entry validation in every runner. A
       corpus that lost its version marker is a corpus whose shape
       nobody checked, so refuse it rather than run against it. *)
    let version = V.get (V.get v "PLUGIN") "version" in
    if (not (V.is_num version)) || 1.0 <> V.as_num version then begin
      prerr_endline "ocaml: unsupported spec version";
      exit 2
    end;
    loaded := Some v;
    v

let section name =
  let s = V.get (V.get (corpus ()) "primary") name in
  if not (V.is_map s) then begin
    prerr_endline ("ocaml: no such corpus section: " ^ name);
    exit 2
  end;
  s

(* A stable label, so a failure names the entry rather than an index. *)
let label group i entry =
  let id = V.get entry "id" in
  if V.is_str id then V.as_str id else group ^ "#" ^ string_of_int i

(* Deep equality over spec values: key order never matters, list order
   always does. Written here, not taken from the library. *)
let rec equal a b =
  match (a, b) with
  | V.Null, V.Null -> true
  | V.Bool x, V.Bool y -> x = y
  | V.Num x, V.Num y -> x = y
  | V.Str x, V.Str y -> x = y
  | V.List _, V.List _ ->
    V.len a = V.len b && List.for_all2 equal (V.items a) (V.items b)
  | V.Map _, V.Map _ ->
    V.len a = V.len b
    && List.for_all
         (fun k -> V.has b k && equal (V.get a k) (V.get b k))
         (V.keys a)
  | _ -> false

(* A LITERAL-WITH-ANCHORS MATCHER, NOT A REGEX ENGINE.

   OCaml ships `Str`, but `Str`'s syntax is a THIRD dialect — `\\(` for
   groups, its own `$` rule — and the corpus's patterns are JavaScript
   `/.../` literals. `cpp` was bitten by exactly this: it copied c's
   POSIX-ERE call and four entries failed on messages that plainly
   matched. Every pattern the corpus writes is a literal, optionally
   `^`-anchored, so this unescapes and compares — and ERRORS on any
   unescaped metacharacter, because the one thing a hand-rolled matcher
   must never do is quietly report a mismatch it could not evaluate.

   Same shape as `lua/test/corpus.lua`'s `regexlite`, deliberately. *)
let regexlite pattern text =
  let buf = Buffer.create (String.length pattern) in
  let anchorstart = ref false in
  let anchorend = ref false in
  let n = String.length pattern in
  let i = ref 0 in
  while !i < n do
    let c = pattern.[!i] in
    if '\\' = c && !i + 1 < n then begin
      Buffer.add_char buf pattern.[!i + 1];
      i := !i + 2
    end
    else if '^' = c && 0 = !i then (anchorstart := true; incr i)
    else if '$' = c && !i = n - 1 then (anchorend := true; incr i)
    else begin
      if String.contains "*+?()[]{}|." c then
        failwith
          ("corpus regex needs a real engine, which this port does not have: "
           ^ pattern);
      Buffer.add_char buf c;
      incr i
    end
  done;
  let lit = Buffer.contents buf in
  let ll = String.length lit and tl = String.length text in
  if !anchorstart && !anchorend then text = lit
  else if !anchorstart then ll <= tl && String.sub text 0 ll = lit
  else if !anchorend then ll <= tl && String.sub text (tl - ll) ll = lit
  else begin
    let found = ref false in
    for s = 0 to tl - ll do
      if (not !found) && String.sub text s ll = lit then found := true
    done;
    !found
  end

(* `match` semantics: __EXISTS__, __UNDEF__, __NULL__, /regex/, and
   partial map matching. `present` distinguishes an absent key from one
   holding null, which __UNDEF__ and __NULL__ exist to tell apart. *)
let rec matches expect actual present =
  let literal () =
    if V.is_list expect then
      V.is_list actual && V.len expect = V.len actual
      && List.for_all2 (fun e a -> matches e a true) (V.items expect)
           (V.items actual)
    else if V.is_map expect then
      V.is_map actual
      && List.for_all
           (fun k -> matches (V.get expect k) (V.get actual k) (V.has actual k))
           (V.sortedkeys expect)
    else equal expect actual
  in
  if V.is_str expect then begin
    let s = V.as_str expect in
    if "__EXISTS__" = s then present && not (V.is_null actual)
    else if "__UNDEF__" = s then not present
    else if "__NULL__" = s then present && V.is_null actual
    else if
      2 < String.length s && '/' = s.[0] && '/' = s.[String.length s - 1]
    then
      V.is_str actual
      && regexlite (String.sub s 1 (String.length s - 2)) (V.as_str actual)
    else literal ()
  end
  else literal ()

type subject = V.t -> V.t

type tally = { mutable entries : int; mutable failures : int }

(* Run one entry and report the disagreement, or None when it passes.

   The three combinations the spec format allows are enforced here as
   well as at build time, because a runner that quietly accepted `err`
   beside `out` would let a contradictory entry pass. *)
let check entry (subject : subject) =
  let haserr = V.has entry "err" in
  let hasout = V.has entry "out" in
  let hasmatch = V.has entry "match" in

  if haserr && hasout then Some "entry has both err and out"
  else if (not haserr) && (not hasout) && not hasmatch then
    Some "entry asserts nothing"
  else begin
    let outcome =
      try `Value (subject entry) with Types.Plugin_error e -> `Raised e
    in
    match outcome with
    | `Raised e ->
      if not haserr then
        Some ("unexpected raise: " ^ e.Types.code ^ " " ^ e.Types.message)
      else begin
        let want = V.get entry "err" in
        (* Errors compare by CODE (§12). Message wording is a port's
           own business; pinning it would make every translation a
           corpus change. *)
        if V.is_str want && e.Types.code <> V.as_str want then
          Some
            ("expected code " ^ V.as_str want ^ ", got " ^ e.Types.code ^ " ("
             ^ e.Types.message ^ ")")
        else if hasmatch then begin
          let err = V.vmap () in
          V.set err "code" (V.vstr e.Types.code);
          V.set err "message" (V.vstr e.Types.message);
          V.set err "name" (V.vstr "PluginError");
          let got = V.vmap () in
          V.set got "err" err;
          if matches (V.get entry "match") got true then None
          else
            Some
              ("error did not match "
               ^ V.json (V.get entry "match")
               ^ ", got " ^ V.json got)
        end
        else None
      end
    | `Value value ->
      if haserr then Some ("expected a raise, got: " ^ V.json value)
      else if hasout && not (equal (V.get entry "out") value) then
        Some ("expected " ^ V.json (V.get entry "out") ^ ", got " ^ V.json value)
      else if hasmatch then begin
        let got = V.vmap () in
        V.set got "in" (V.get entry "in");
        V.set got "out" value;
        if matches (V.get entry "match") got true then None
        else
          Some
            ("did not match "
             ^ V.json (V.get entry "match")
             ^ ", got out=" ^ V.json value)
      end
      else None
  end

let rungroup t sec group entries (subject : subject) =
  let set = V.get entries "set" in
  if V.is_list set then
    List.iteri
      (fun i entry ->
        t.entries <- t.entries + 1;
        match check entry subject with
        | None -> ()
        | Some why ->
          t.failures <- t.failures + 1;
          (* The label is the entry's own `id` when it has one, and
             those already carry the section — printing the section
             again would read `ref/ref/canon#trailing`. *)
          let l = label group i entry in
          if V.has entry "id" then print_endline (l ^ ": " ^ why)
          else print_endline (sec ^ "/" ^ l ^ ": " ^ why))
      (V.items set)

let runsection t sec lookup =
  let groups = section sec in
  (* SORTED, so a failure names the same group in the same place on
     every run. *)
  List.iter
    (fun name ->
      match lookup name with
      | None ->
        (* A group the runner does not know is a group silently not
           run, which is worse than a failure. *)
        t.failures <- t.failures + 1;
        print_endline (sec ^ "/" ^ name ^ ": no subject for this group")
      | Some s -> rungroup t sec name (V.get groups name) s)
    (V.sortedkeys groups)
