(* Exports (§11).

   THE UNQUALIFIED ALIAS IS THE INTERESTING PART. `retry/client`
   resolves to the UNTAGGED instance if one exists; if not, and exactly
   one tagged instance exports that key, it resolves to that one; if
   two do, it is `plugin_export_ambiguous` — deliberately diverging
   from seneca's silent last-wins, because with multi-instance as a
   headline feature an ambiguous alias is a defect waiting for
   production. *)

module V = Value

(* Answers None for "no such export", which is not an error —
   `export/missing` pins that, and is why the answer is an option
   rather than a null Value. *)
let resolveexport spec exported =
  let s = if V.is_str spec then V.as_str spec else "" in
  match String.index_opt s '/' with
  | None ->
    Types.fail "plugin_export_ambiguous"
      ("export spec needs a key: " ^ s)
      ~details:(Types.details1 "spec" (V.vstr s))
  | Some cut ->
    let head = String.sub s 0 cut in
    let key = String.sub s (cut + 1) (String.length s - cut - 1) in

    (* A fully qualified ref: exactly one answer or none. *)
    let byref =
      match Ref.tryref head with
      | None -> None
      | Some want ->
        List.fold_left
          (fun acc e ->
            match acc with
            | Some _ -> acc
            | None ->
              if V.as_str (V.get e "ref") = want && V.as_str (V.get e "key") = key
              then Some (V.get e "value")
              else None)
          None (V.items exported)
    in
    (match byref with
     | Some v -> Some v
     | None ->
       (* An alias: the NAME, not a ref. Look at every instance of it. *)
       let byname =
         List.filter
           (fun e ->
             Ref.refname (V.as_str (V.get e "ref")) = head
             && V.as_str (V.get e "key") = key)
           (V.items exported)
       in
       if [] = byname then None
       else
         (* The untagged instance wins outright when there is one. *)
         let untagged =
           List.find_opt
             (fun e -> None = String.index_opt (V.as_str (V.get e "ref")) '$')
             byname
         in
         (match untagged with
          | Some e -> Some (V.get e "value")
          | None ->
            if 1 = List.length byname then
              Some (V.get (List.hd byname) "value")
            else begin
              let refs =
                List.sort compare
                  (List.map (fun e -> V.as_str (V.get e "ref")) byname)
              in
              let d = V.vmap () in
              V.set d "spec" (V.vstr s);
              V.set d "refs" (V.oflist (List.map V.vstr refs));
              Types.fail "plugin_export_ambiguous"
                ("alias " ^ s ^ " matches "
                 ^ string_of_int (List.length byname)
                 ^ " instances: " ^ String.concat ", " refs)
                ~details:d
            end))
