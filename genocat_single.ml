(* genocat_single.ml
   GenoCat — single-file OCaml jumpstart.

   Everything from the multi-file version, folded into one file as nested
   modules so it can be dropped anywhere and run with:
     ocaml genocat_single.ml
   or compiled directly with:
     ocamlfind ocamlopt -package str -linkpkg genocat_single.ml -o genocat
     (no external packages are actually required; plain ocamlopt/ocamlc
     genocat_single.ml -o genocat works too)

   Layout (mirrors the paper's section numbers):
     module Geno       -- Sec. 2-4: objects, iota, dagger on objects, (x)
     module Edit       -- Sec. 2-3: morphisms (typed edits), dagger on morphisms
     module Operad      -- Sec. 5:  the colored Splice operad
     module Metric      -- Sec. 6:  edit-distance enrichment
     module Polaron     -- Sec. 8:  skeleton PolaronCat + functor F
     module Typecheck   -- Sec. 10: Preservation / Progress
   followed by a short runnable demo.

   What's solid vs. what's a stub, briefly (see the multi-file README for
   the full version of this note):
     - Geno, Edit, Operad, Metric implement real, checkable structure.
     - Polaron.compile is a coarse numerical stub, not a physics engine;
       replace `default_hparams` with real data before drawing physical
       conclusions from it.
     - Edit.dagger takes an explicit `len_at_apply` because index reversal
       is length-dependent; a fuller version would track length through
       Compose symbolically instead.
     - Typecheck.progress is trivially total right now because the stub F
       never fails; it exists as a single call site to harden later.
   No synthesis routes, wet-lab protocols, or vector designs are included.
   The demo sequences are short placeholders, not real regulatory DNA. *)

(* ------------------------------------------------------------------ *)
(* Geno: objects of the category (Sections 2-4)                        *)
(* ------------------------------------------------------------------ *)
module Geno = struct
  (* The quaternary alphabet Sigma = {0,1,2,3}. *)
  module Base = struct
    type t = A | T | C | G

    let to_int = function A -> 0 | T -> 1 | C -> 2 | G -> 3

    let of_int = function
      | 0 -> A
      | 1 -> T
      | 2 -> C
      | 3 -> G
      | n -> invalid_arg (Printf.sprintf "Base.of_int: %d is not in {0,1,2,3}" n)

    (* iota: the fixed-point-free Watson-Crick involution, iota(iota(b)) = b. *)
    let iota = function A -> T | T -> A | C -> G | G -> C

    let to_char = function A -> 'A' | T -> 'T' | C -> 'C' | G -> 'G'

    let of_char = function
      | 'A' -> A
      | 'T' -> T
      | 'C' -> C
      | 'G' -> G
      | c -> invalid_arg (Printf.sprintf "Base.of_char: unexpected '%c'" c)

    let equal a b = to_int a = to_int b
  end

  (* Reading frame offset. *)
  type frame = F0 | F1 | F2

  (* Strand sense. *)
  type orient = Plus | Minus

  (* Cell / expression context label. Kept abstract on purpose: this is
     the base object the fibration of Section 7 (context-dependent
     expression) would range over; a real implementation would replace
     `string` with a proper `Cell.t` category object. *)
  type ctx = string

  type strand_type = { frame : frame; orient : orient; ctx : ctx }

  (* An object of Geno. *)
  type t = { seq : Base.t array; typ : strand_type }

  let make seq typ = { seq; typ }

  let of_string s ~frame ~orient ~ctx =
    {
      seq = Array.init (String.length s) (fun i -> Base.of_char s.[i]);
      typ = { frame; orient; ctx };
    }

  let to_string strand =
    String.init (Array.length strand.seq) (fun i -> Base.to_char strand.seq.(i))

  let length strand = Array.length strand.seq

  (* Advancing n bases shifts the reading frame by n mod 3. Used by Edit
     to discharge the frame-preservation proof obligation of Section 2. *)
  let next_frame f n =
    let f0 = match f with F0 -> 0 | F1 -> 1 | F2 -> 2 in
    match (f0 + n) mod 3 with 0 -> F0 | 1 -> F1 | _ -> F2

  let flip_orient = function Plus -> Minus | Minus -> Plus

  (* The dagger functor of Section 3, restricted to objects: reverse
     complement, with orientation flipped. iota is fixed-point-free, so
     dagger (dagger s) is equal to s up to the identity strand_type. *)
  let dagger (strand : t) : t =
    let n = length strand in
    let seq' = Array.init n (fun i -> Base.iota strand.seq.(n - 1 - i)) in
    { seq = seq'; typ = { strand.typ with orient = flip_orient strand.typ.orient } }

  (* Monoidal product (concatenation), Section 4. `concat` typechecks
     context and orientation before combining; `unchecked_concat` bypasses
     the check for callers that have already established compatibility. *)
  let unchecked_concat (a : t) (b : t) : t = { seq = Array.append a.seq b.seq; typ = a.typ }

  let concat ?(check_ctx = true) (a : t) (b : t) : t option =
    if check_ctx && a.typ.ctx <> b.typ.ctx then None
    else if a.typ.orient <> b.typ.orient then None
    else Some (unchecked_concat a b)

  (* The unit object I of the monoidal category. *)
  let empty ~ctx = { seq = [||]; typ = { frame = F0; orient = Plus; ctx } }
end

(* ------------------------------------------------------------------ *)
(* Edit: morphisms of the category (Sections 2-3)                      *)
(* ------------------------------------------------------------------ *)
module Edit = struct
  open Geno

  type t =
    | Id
    | Compose of t * t (* Compose (g, f): apply f, then g (g o f) *)
    | Substitute of int * Base.t (* site index, new base *)
    | Insert of int * Base.t array (* position, inserted fragment *)
    | Delete of int * int (* start, length *)
    | Invert of int * int (* start, length -- e.g. FLP/FRT-style inversion *)
    | Translocate of int * int * int (* src_start, src_len, dest_pos *)

  exception Type_error of string

  (* Effect of a primitive edit on the strand's type -- the proof
     obligation from Section 2 that must be discharged for the edit to be
     a morphism of Geno at all. *)
  let rec effect_on_type (e : t) (typ : strand_type) : strand_type =
    match e with
    | Id -> typ
    | Compose (g, f) -> effect_on_type g (effect_on_type f typ)
    | Substitute (_, _) -> typ
    | Insert (_, frag) -> { typ with frame = next_frame typ.frame (Array.length frag) }
    | Delete (_, len) -> { typ with frame = next_frame typ.frame (3 - (len mod 3)) }
    | Invert (_, _) -> { typ with orient = flip_orient typ.orient }
    | Translocate (_, _, _) -> typ

  (* Apply an edit. Raises Type_error rather than silently producing an
     inconsistent strand -- an edit that is out of range, or otherwise
     ill-formed, is not a morphism of Geno, and apply reflects that by
     failing loudly instead of quietly returning garbage. *)
  let rec apply (e : t) (s : Geno.t) : Geno.t =
    match e with
    | Id -> s
    | Compose (g, f) -> apply g (apply f s)
    | Substitute (i, b) ->
        if i < 0 || i >= Geno.length s then raise (Type_error "Substitute: site out of range")
        else
          let seq' = Array.copy s.seq in
          seq'.(i) <- b;
          { s with seq = seq' }
    | Insert (pos, frag) ->
        if pos < 0 || pos > Geno.length s then
          raise (Type_error "Insert: position out of range")
        else
          let before = Array.sub s.seq 0 pos in
          let after = Array.sub s.seq pos (Geno.length s - pos) in
          { seq = Array.concat [ before; frag; after ]; typ = effect_on_type e s.typ }
    | Delete (start, len) ->
        if start < 0 || len < 0 || start + len > Geno.length s then
          raise (Type_error "Delete: range out of bounds")
        else
          let before = Array.sub s.seq 0 start in
          let after = Array.sub s.seq (start + len) (Geno.length s - start - len) in
          { seq = Array.append before after; typ = effect_on_type e s.typ }
    | Invert (start, len) ->
        if start < 0 || len < 0 || start + len > Geno.length s then
          raise (Type_error "Invert: range out of bounds")
        else
          let before = Array.sub s.seq 0 start in
          let mid = Array.sub s.seq start len in
          let after = Array.sub s.seq (start + len) (Geno.length s - start - len) in
          let mid' = Array.init len (fun i -> Base.iota mid.(len - 1 - i)) in
          { seq = Array.concat [ before; mid'; after ]; typ = effect_on_type e s.typ }
    | Translocate (src, len, dest) ->
        if src < 0 || len < 0 || src + len > Geno.length s || dest < 0 || dest > Geno.length s
        then raise (Type_error "Translocate: range out of bounds")
        else
          let fragment = Array.sub s.seq src len in
          let without =
            Array.append (Array.sub s.seq 0 src)
              (Array.sub s.seq (src + len) (Geno.length s - src - len))
          in
          let dest' = if dest > src then dest - len else dest in
          let before = Array.sub without 0 dest' in
          let after = Array.sub without dest' (Array.length without - dest') in
          { seq = Array.concat [ before; fragment; after ]; typ = s.typ }

  let compose g f = Compose (g, f)

  (* The dagger on morphisms (Section 3): "the same edit, performed on the
     complementary strand." Index-reversal is length-dependent, so this
     takes the length of the strand the edit will be applied to; a fuller
     implementation would track lengths symbolically through Compose
     rather than requiring the caller to supply one length for a whole
     chain of edits. *)
  let rec dagger (e : t) (len_at_apply : int) : t =
    match e with
    | Id -> Id
    | Compose (g, f) -> Compose (dagger f len_at_apply, dagger g len_at_apply)
    | Substitute (i, b) -> Substitute (len_at_apply - 1 - i, Base.iota b)
    | Insert (pos, frag) ->
        let n = Array.length frag in
        Insert (len_at_apply - pos, Array.init n (fun k -> Base.iota frag.(n - 1 - k)))
    | Delete (start, l) -> Delete (len_at_apply - start - l, l)
    | Invert (start, l) -> Invert (len_at_apply - start - l, l)
    | Translocate (src, l, dest) -> Translocate (len_at_apply - src - l, l, len_at_apply - dest)
end

(* ------------------------------------------------------------------ *)
(* Operad: the colored Splice operad (Section 5)                       *)
(* ------------------------------------------------------------------ *)
module Operad = struct
  open Geno

  type site = { pos : int; required_frame : frame }
  type splice = { sites : site list; fragments : Geno.t list }

  exception Splice_type_error of string

  let frame_of_fragment (frag : Geno.t) = frag.typ.frame

  (* apply_splice: typecheck-and-insert. Fails if the number of sites and
     fragments disagree, or if any fragment's frame does not match its
     site's required frame -- the colored-operad composition law: an
     operadic composite only exists when the colors line up. *)
  let apply_splice (host : Geno.t) (sp : splice) : Geno.t =
    if List.length sp.sites <> List.length sp.fragments then
      raise (Splice_type_error "apply_splice: site/fragment count mismatch");
    List.iter2
      (fun site frag ->
        if frame_of_fragment frag <> site.required_frame then
          raise
            (Splice_type_error
               (Printf.sprintf "apply_splice: frame mismatch at site %d" site.pos)))
      sp.sites sp.fragments;
    (* Insert back-to-front (by descending position) so that earlier
       positions in the host remain valid as later insertions happen. *)
    let paired =
      List.combine sp.sites sp.fragments
      |> List.sort (fun (s1, _) (s2, _) -> compare s2.pos s1.pos)
    in
    List.fold_left
      (fun acc (site, frag) -> Edit.apply (Edit.Insert (site.pos, frag.seq)) acc)
      host paired
end

(* ------------------------------------------------------------------ *)
(* Metric: edit-distance enrichment (Section 6)                        *)
(* ------------------------------------------------------------------ *)
module Metric = struct
  open Geno

  let edit_distance (a : Geno.t) (b : Geno.t) : int =
    let m = Geno.length a and n = Geno.length b in
    let d = Array.make_matrix (m + 1) (n + 1) 0 in
    for i = 0 to m do
      d.(i).(0) <- i
    done;
    for j = 0 to n do
      d.(0).(j) <- j
    done;
    for i = 1 to m do
      for j = 1 to n do
        let cost = if Base.equal a.seq.(i - 1) b.seq.(j - 1) then 0 else 1 in
        d.(i).(j) <- min (min (d.(i - 1).(j) + 1) (d.(i).(j - 1) + 1)) (d.(i - 1).(j - 1) + cost)
      done
    done;
    d.(m).(n)

  (* Sanity check that the enrichment is coherent for a given triple --
     useful as a property-based test. *)
  let triangle_holds a b c = edit_distance a c <= edit_distance a b + edit_distance b c
end

(* ------------------------------------------------------------------ *)
(* Polaron: skeleton PolaronCat + semantic functor F (Section 8)       *)
(* ------------------------------------------------------------------ *)
module Polaron = struct
  open Geno

  type hparams = {
    eps : Base.t -> float; (* epsilon_b: on-site energy *)
    hop : Base.t -> Base.t -> float; (* t_{b,b'}: hopping integral *)
    chi : float; (* electron-phonon coupling strength *)
    j_tunnel : Base.t -> Base.t -> float; (* inter-strand tunneling J *)
  }

  let default_hparams : hparams =
    {
      eps = (fun b -> match b with Base.A | Base.T -> 0.2 | Base.C | Base.G -> 0.35);
      hop = (fun _ _ -> 0.1);
      chi = 0.05;
      j_tunnel = (fun _ _ -> 0.02);
    }

  (* The object part of F: a strand compiles to per-site Hamiltonian data. *)
  type polaron_object = {
    n_sites : int;
    onsite : float array; (* epsilon_{b_n} per site *)
    hopping : float array; (* t_{b_n,b_{n+1}}, length n_sites - 1 *)
    coupling : float array; (* chi per site (placeholder for chi * u_n) *)
    tunneling : float array; (* J_{b_n, iota(b_n)} per site *)
  }

  let compile ?(hparams = default_hparams) (s : Geno.t) : polaron_object =
    let n = Geno.length s in
    let onsite = Array.init n (fun i -> hparams.eps s.seq.(i)) in
    let hopping = Array.init (max 0 (n - 1)) (fun i -> hparams.hop s.seq.(i) s.seq.(i + 1)) in
    let coupling = Array.make n hparams.chi in
    let tunneling = Array.init n (fun i -> hparams.j_tunnel s.seq.(i) (Base.iota s.seq.(i))) in
    { n_sites = n; onsite; hopping; coupling; tunneling }

  (* The morphism part of F, in stub form: recompiles from the edited
     strand rather than transporting an actual quantum channel. A full
     implementation would build a genuine CPTP map here; this stub
     preserves the *interface* -- F applied to an edit gives a new
     physical object -- so callers don't need to know the difference yet. *)
  let compile_edit ?(hparams = default_hparams) (e : Edit.t) (s : Geno.t) : polaron_object =
    compile ~hparams (Edit.apply e s)
end

(* ------------------------------------------------------------------ *)
(* Typecheck: Preservation / Progress (Section 10)                     *)
(* ------------------------------------------------------------------ *)
module Typecheck = struct
  type result = Ok_typed of Geno.t | Failed of string

  let preservation (e : Edit.t) (s : Geno.t) : result =
    try Ok_typed (Edit.apply e s) with Edit.Type_error msg -> Failed msg

  let progress ?(hparams = Polaron.default_hparams) (s : Geno.t) : Polaron.polaron_object option
      =
    Some (Polaron.compile ~hparams s)

  let typecheck (e : Edit.t) (s : Geno.t) : (Geno.t * Polaron.polaron_object) option =
    match preservation e s with
    | Failed _ -> None
    | Ok_typed s' -> ( match progress s' with None -> None | Some obj -> Some (s', obj))
end

(* ------------------------------------------------------------------ *)
(* Demo                                                                 *)
(* ------------------------------------------------------------------ *)
let print_strand label s =
  Printf.printf "%s = %s (len %d)\n" label (Geno.to_string s) (Geno.length s)

let () =
  let prom_lac = Geno.of_string "ATCG" ~frame:Geno.F0 ~orient:Geno.Plus ~ctx:"ecoli" in
  let cds_tetr = Geno.of_string "ATCGATCGATCG" ~frame:Geno.F0 ~orient:Geno.Plus ~ctx:"ecoli" in
  print_strand "prom_lac" prom_lac;
  print_strand "cds_tetr" cds_tetr;

  let toggle_arm =
    match Geno.concat prom_lac cds_tetr with
    | Some s -> s
    | None -> failwith "concat: unexpected type mismatch in demo"
  in
  print_strand "toggle_arm" toggle_arm;

  let toggle_dagger = Geno.dagger toggle_arm in
  print_strand "toggle_arm^dagger" toggle_dagger;

  (* A typed edit: invert a 4-base site, FLP/FRT-style. *)
  let inv = Edit.Invert (2, 4) in
  (match Typecheck.typecheck inv toggle_arm with
  | None -> print_endline "edit failed to typecheck"
  | Some (toggle_arm', polaron_obj) ->
      print_strand "after inversion" toggle_arm';
      let n_sites = polaron_obj.Polaron.n_sites in
      let e0 = polaron_obj.Polaron.onsite.(0) in
      Printf.printf "compiled to PolaronCat: %d sites, first on-site energy = %.3f\n" n_sites e0);

  (* Splice a fragment in at a frame-checked site (the operad of Section 5). *)
  let reporter = Geno.of_string "GGCC" ~frame:Geno.F0 ~orient:Geno.Plus ~ctx:"ecoli" in
  let site = { Operad.pos = 4; required_frame = Geno.F0 } in
  let sp = { Operad.sites = [ site ]; fragments = [ reporter ] } in
  (try
     let spliced = Operad.apply_splice toggle_arm sp in
     print_strand "spliced" spliced
   with Operad.Splice_type_error msg -> Printf.printf "splice error: %s\n" msg);

  (* Metric enrichment: edit distance between the two fragments (Section 6). *)
  Printf.printf "edit_distance(prom_lac, cds_tetr) = %d\n"
    (Metric.edit_distance prom_lac cds_tetr)
