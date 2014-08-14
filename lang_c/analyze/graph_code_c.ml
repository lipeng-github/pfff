(* Yoann Padioleau
 *
 * Copyright (C) 2012, 2014 Facebook
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public License
 * version 2.1 as published by the Free Software Foundation, with the
 * special exception on linking described in file license.txt.
 * 
 * This library is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the file
 * license.txt for more details.
 *)
open Common

open Ast_c
module Ast = Ast_c
module Flag = Flag_parsing_cpp
module E = Database_code
module G = Graph_code
module P = Graph_code_prolog

(*****************************************************************************)
(* Prelude *)
(*****************************************************************************)
(*
 * Graph of dependencies for C (and partially cpp). See graph_code.ml and 
 * main_codegraph.ml for more information.
 * 
 * See also lang_clang/analyze/graph_code_clang.ml to get arguably a more
 * precise and correct graph (if you can afford yourself to use clang).
 * update: actually a lots of code of graph_code_clang.ml have been ported
 * to this file now.
 * 
 * schema:
 *  Root -> Dir -> File (.c|.h) -> Function | Prototype
 *                              -> Global | GlobalExtern
 *                              -> Type (for Typedef)
 *                              -> Type (struct|union|enum)
 *                                 -> Field
 *                                 -> Constructor (enum)
 *                              -> Constant | Macro
 *       -> Dir -> SubDir -> ...
 * 
 * Note that here as opposed to graph_code_clang.ml constant and macros
 * are present. 
 * What about nested structures? they are lifted up in ast_c_build!
 * 
 * todo: 
 *  - Type is a bit overloaded maybe (used for struct/union/enum/typedefs)
 *  - there is different "namespaces" in C: 
 *    - functions/locals,
 *    - tags (struct name, enum name)
 *    - ???
 *)

(*****************************************************************************)
(* Types *)
(*****************************************************************************)

(* for the extract_uses visitor *)
type env = {
  g: Graph_code.graph;
  (* now in Graph_code.gensym:  cnt: int ref; *)

  phase: phase;

  current: Graph_code.node;
  ctx: Graph_code_prolog.context;

  c_file_readable: Common.filename;

  (* for prolog use/4, todo: merge in_assign with context? *)
  in_assign: bool;

  (* covers also the parameters *)
  locals: string list ref;
  (* for static functions, globals, 'main', and local enums/constants/macros *)
  local_rename: (string, string) Hashtbl.t;

  conf: config;

  (* less: we could also have a local_typedefs field *)
  typedefs: (string, Ast.type_) Hashtbl.t;

  (* error reporting *)
  dupes: (Graph_code.node, bool) Hashtbl.t;
  (* for ArrayInit when actually used for structs *)
  fields: (string, string list) Hashtbl.t;

  log: string -> unit;
  pr2_and_log: string -> unit;
}

 and phase = Defs | Uses

 and config = {
  types_dependencies: bool;
  fields_dependencies: bool;
  (* We normally expand references to typedefs, to normalize and simplify
   * things. Set this variable to true if instead you want to know who is
   * using a typedef.
   *)
  typedefs_dependencies: bool;
  propagate_deps_def_to_decl: bool;
}

type kind_file = Source | Header

(* for prolog *)
let hook_use_edge = ref (fun _ctx _in_assign (_src, _dst) _g -> ())

(*****************************************************************************)
(* Parsing *)
(*****************************************************************************)

(* less: could maybe call Parse_c.parse to get the parsing statistics *)
let parse ~show_parse_error file =
  try 
    (* less: make this parameters of parse_program? *) 
    Common.save_excursion Flag.error_recovery true (fun () ->
    Common.save_excursion Flag.show_parsing_error show_parse_error (fun () ->
    Common.save_excursion Flag.verbose_parsing show_parse_error (fun () ->
    Parse_c.parse_program file
    )))
  with 
  | Timeout -> raise Timeout
  | exn ->
    pr2_once (spf "PARSE ERROR with %s, exn = %s" file (Common.exn_to_s exn));
    raise exn

(*****************************************************************************)
(* Adjusters *)
(*****************************************************************************)
(* todo: copy paste of the one in graph_code_clang.ml, could factorize *)
let propagate_users_of_functions_globals_types_to_prototype_extern_typedefs g =
  let pred = G.mk_eff_use_pred g in
  g +> G.iter_nodes (fun n ->
    let n_def_opt =
      match n with
      | s, E.Prototype -> Some (s, E.Function)
      | s, E.GlobalExtern -> Some (s, E.Global)
      (* todo: actually should look at env.typedefs because it's not
       * necessaraly T_Xxxx -> S_Xxxx
       *)
      | s, E.Type when s =~ "T__\\(.*\\)$" -> 
        Some ("S__" ^(Common.matched1 s), E.Type)
      | _ -> None
    in
    n_def_opt +> Common.do_option (fun n_def ->
      let n_decl = n in
      if G.has_node n_def g 
      then begin
        (* let's create a link between the def and the decl *)
        g +> G.add_edge (n_def, n_decl) G.Use;
        (* and now the users *)
        let users = pred n_def in
        users +> List.iter (fun user ->
          g +> G.add_edge (user, n_decl) G.Use
        )
      end
    )
  )

(*****************************************************************************)
(* Helpers *)
(*****************************************************************************)

(* we can have different .c files using the same function name, so to avoid
 * dupes we locally rename those entities, e.g. main -> main__234.
 *)
let new_str_if_defs env s =
  if env.phase = Defs
  then begin
    let s2 = Graph_code.gensym s in
    Hashtbl.add env.local_rename s s2;
    s2
  end
  else Hashtbl.find env.local_rename s

(* anywhere you get a string from the AST you must use this function to
 * get the final "value" *)
let _str env s =
  if Hashtbl.mem env.local_rename s
  then Hashtbl.find env.local_rename s
  else s


let kind_file env =
  match env.c_file_readable with
  | s when s =~ ".*\\.[h]" -> Header
  | s when s =~ ".*\\.[c]" -> Source
  | _s  ->
   (* failwith ("unknown kind of file: " ^ s) *)
    Source

let expand_typedefs _typedefs t =
  pr2_once "expand_typedefs:Todo";
  t

let final_type env t =
  if env.conf.typedefs_dependencies
  then t 
  else 
    (* Can we do that anytime? like in Defs phase? 
     * No we need to wait for the first pass to have all the typedefs
     * before we can expand them!
     *)
    expand_typedefs env.typedefs t

let error env s =
  failwith (spf "%s: %s" env.c_file_readable s)

let add_prefix prefix (s, tok) = 
  prefix ^ s, tok
let replace s (_,tok) = 
  s, tok
   
(*****************************************************************************)
(* Add Node *)
(*****************************************************************************)

let add_node_and_edge_if_defs_mode env (name, kind) typopt =
  let str = Ast.str_of_name name in
  let str' =
    match kind, env.current with
    | E.Field, (s, E.Type) -> s ^ "." ^ str
    | _ -> str
  in
  let node = (str', kind) in

  if env.phase = Defs then
    (match () with
    (* if parent is a dupe, then don't want to attach yourself to the
     * original parent, mark this child as a dupe too.
     *)
    | _ when Hashtbl.mem env.dupes env.current ->
        Hashtbl.replace env.dupes node true

    (* already there? a dupe? *)
    | _ when G.has_node node env.g ->
      (match kind with
      | E.Function | E.Global | E.Constructor
      | E.Type | E.Field
        ->
          (match kind, str with
          (* dupe typedefs are ok as long as they are equivalent, and this
           * check is done for TypedefDecl below in decl().
           *)
          | E.Type, s when s =~ "T__" -> ()
          | _ when env.c_file_readable =~ ".*EXTERNAL" -> ()
          (* todo: if typedef then maybe ok if have same content!! *)
          | _ when not env.conf.typedefs_dependencies && str =~ "T__.*" -> 
              Hashtbl.replace env.dupes node true;
          | _ ->
              env.pr2_and_log (spf "DUPE entity: %s" (G.string_of_node node));
              let nodeinfo = G.nodeinfo node env.g in
              let orig_file = nodeinfo.G.pos.Parse_info.file in
              env.log (spf " orig = %s" orig_file);
              env.log (spf " dupe = %s" env.c_file_readable);
              Hashtbl.replace env.dupes node true;
          )
      (* todo: have no Use for now for those so skip errors *) 
      | E.Prototype | E.GlobalExtern -> 
        (* It's common to have multiple times the same prototype declared.
         * It can also happen that the same prototype have
         * different types (e.g. in plan9 newword() had an argument with type
         * 'Word' and another 'word'). We don't want to add to the same
         * entity dependencies to this different types so we need to mark
         * the prototype as a dupe too!
         * Anyway normally we should add the deps to the Function or Global
         * first so we should hit this code only for really external
         * entities.
         *)
         Hashtbl.replace env.dupes node true;
      | _ ->
          failwith (spf "Unhandled category: %s" (G.string_of_node node))
      )

    (* ok not a dupe, let's add it then *)
    | _ ->
      let typ = 
        match typopt with
        | None -> None
        | Some t ->
            (* hmmm can't call final_type here, no typedef pass yet
               let t = final_type env t in 
            *)
            let v = Meta_ast_c.vof_any (Type t) in
            let s = Ocaml.string_of_v v in
            Some s
      in
      (* less: still needed to have a try? *)
      try
        let pos = Parse_info.token_location_of_info (snd name) in
        let pos = { pos with Parse_info.file = env.c_file_readable } in
        let nodeinfo = { Graph_code.
          pos; typ;
          props = [];
        } in
        env.g +> G.add_node node;
        env.g +> G.add_edge (env.current, node) G.Has;
        env.g +> G.add_nodeinfo node nodeinfo;
      with Not_found ->
        error env ("Not_found:" ^ str)
    );
  { env with current = node }

(*****************************************************************************)
(* Add edge *)
(*****************************************************************************)

let rec add_use_edge env (name, kind) =
  let s = Ast.str_of_name name in
  let src = env.current in
  let dst = (s, kind) in
  match () with
  | _ when Hashtbl.mem env.dupes src || Hashtbl.mem env.dupes dst ->
      (* todo: stats *)
      env.pr2_and_log (spf "skipping edge (%s -> %s), one of it is a dupe"
                         (G.string_of_node src) (G.string_of_node dst));
  (* plan9, those are special functions in kencc? *)
  | _ when s =$= "USED" || s =$= "SET" ->  
      ()
  | _ when not (G.has_node src env.g) ->
      error env ("SRC FAIL:" ^ G.string_of_node src);
  (* the normal case *)
  | _ when G.has_node dst env.g ->
      G.add_edge (src, dst) G.Use env.g;
      !hook_use_edge env.ctx env.in_assign (src, dst) env.g
  (* try to 'rekind' *)
  | _ ->
    (match kind with
    (* look for Prototype if no Function *)
    | E.Function -> add_use_edge env (name, E.Prototype)
    (* look for GlobalExtern if no Global *)
    | E.Global -> add_use_edge env (name, E.GlobalExtern)
(* TODO
      (* sometimes people don't use uppercase for macros *)
      | E.Global ->
          add_use_edge env (name, E.Constant)
      | E.Function ->
          add_use_edge env (name, E.Macro)

          let kind_original =
            match kind with
            | E.Constant when not (looks_like_macro name) -> E.Global
            | E.Macro when not (looks_like_macro name) -> E.Function
            | _ -> kind
          in
*)

    | _ when env.c_file_readable =~ ".*EXTERNAL" -> 
        ()
    (* todo? still need code below?*)
(*
    | E.Type when s =~ "S__\\(.*\\)" ->
        add_use_edge env ("T__" ^ Common.matched1 s, E.Type)
    | E.Type when s =~ "U__\\(.*\\)" ->
        add_use_edge env ("T__" ^ Common.matched1 s, E.Type)
    | E.Type when s =~ "E__\\(.*\\)" ->
        add_use_edge env ("T__" ^ Common.matched1 s, E.Type)
*)
    | _ ->
        env.pr2_and_log (spf "Lookup failure on %s (%s:??)"
                            (G.string_of_node dst)
                            env.c_file_readable
        )
    )


(*****************************************************************************)
(* Defs/Uses *)
(*****************************************************************************)

let rec extract_defs_uses env ast =

  if env.phase = Defs then begin
    let dir = Common2.dirname env.c_file_readable in
    G.create_intermediate_directories_if_not_present env.g dir;
    let node = (env.c_file_readable, E.File) in
    env.g +> G.add_node node;
    env.g +> G.add_edge ((dir, E.Dir), node) G.Has;
  end;
  let env = { env with current = (env.c_file_readable, E.File); } in
  toplevels env ast

(* ---------------------------------------------------------------------- *)
(* Toplevels *)
(* ---------------------------------------------------------------------- *)

and toplevel env x =
  match x with
  | Define (name, body) ->
      let env = add_node_and_edge_if_defs_mode env (name, E.Constant) None in
      if env.phase = Uses 
      then define_body env body
  | Macro (name, params, body) -> 
      let env = add_node_and_edge_if_defs_mode env (name, E.Macro) None in
      let env = { env with locals = ref (params+>List.map Ast.str_of_name) } in
      if env.phase = Uses
      then define_body env body

  | FuncDef def | Prototype def -> 
      let name = def.f_name in
      let s = Ast.str_of_name name in
      let kind = 
        match x with 
        | Prototype _ -> E.Prototype
        | FuncDef _ -> E.Function
        | _ -> raise Impossible
      in
      let static = 
        (* if we are in an header file, then we don't want to rename
         * the inline static function because would have a different
         * local_rename hash. Renaming in the header file would lead to
         * some unresolved lookup in the c files.
         *)
        (def.f_static && kind_file env =*= Source) ||
        s = "main"
      in
      let s = if static && kind=E.Function then new_str_if_defs env s else s in
      let typ = Some (TFunction def.f_type) in

      (* todo: when static and prototype, we should create a new_str_if_defs
       * that will match the one created later for the Function, but
       * right now we just don't create the node, it's simpler.
       *)
      let env = 
        if static && kind = E.Prototype
        then env
          (* todo: when prototype and in .c, then it's probably a forward
           * decl that we could just skip?
           *)
        else add_node_and_edge_if_defs_mode env (replace s name, kind) typ
      in
      if kind <> E.Prototype 
      then type_ env (TFunction def.f_type);

      let xs = snd def.f_type +> Common.map_filter (fun x -> 
        (match x.p_name with None -> None  | Some x -> Some (Ast.str_of_name x))
      ) in
      let env = { env with locals = ref xs } in
      if env.phase = Uses
      then stmts env def.f_body

  | Global v -> 
      let { v_name = name; v_type = t; v_storage = sto; v_init = eopt } = v in
      let s = Ast.str_of_name name in
      let kind = 
        match sto with
        | Extern -> E.GlobalExtern 
        (* when have 'int x = 1;' in a header, it's actually the def.
         * less: print a warning asking to mv in a .c
         *)
        | _ when eopt <> None && kind_file env = Header -> E.Global
        (* less: print a warning; they should put extern decl *)
        | _ when kind_file env = Header -> E.GlobalExtern
        | DefaultStorage | Static -> E.Global
      in
      let static = sto =*= Static && kind_file env =*= Source in

      let s = if static then new_str_if_defs env s else s in
      let typ = Some v.v_type in
      let env = add_node_and_edge_if_defs_mode env (replace s name, kind) typ in
     
      if kind <> E.GlobalExtern 
      then type_ env t;
      if env.phase = Uses
      then Common2.opt (expr env) eopt

  | StructDef { s_name = name; s_kind = kind; s_flds = flds } -> 
      let s = Ast.str_of_name name in
      let prefix = match kind with Struct -> "S__" | Union -> "U__" in
      let env = 
        add_node_and_edge_if_defs_mode env (add_prefix prefix name, E.Type)None
      in
      
      if env.phase = Defs then begin
          (* this is used for InitListExpr *)
        let fields = flds +> Common.map_filter (function
          | { fld_name = Some name; _ } -> Some (Ast.str_of_name name)
          | _ -> None
        )
        in
        Hashtbl.replace env.fields (prefix ^ s) fields
      end;

      flds +> List.iter (fun { fld_name = nameopt; fld_type = t; } ->
        (match nameopt with
        | Some name -> 
            let typ = Some t in
            let env = add_node_and_edge_if_defs_mode env (name, E.Field) typ in
            type_ env t
        | None ->
            (* TODO: kencc: anon substruct, invent anon? *)
            (* (spf "F__anon__%s" (str_of_angle_loc env loc), E.Field) None *)
            type_ env t
        )
      )
        
  | EnumDef (name, xs) ->
      let env = 
        add_node_and_edge_if_defs_mode env (add_prefix "E__" name, E.Type) None
      in
      xs +> List.iter (fun (name, eopt) ->
        let s = Ast.str_of_name name in
        let s = if kind_file env =*= Source then new_str_if_defs env s else s in
        let env = 
          add_node_and_edge_if_defs_mode env (replace s name, E.Constant) None
        in
        if env.phase = Uses
        then Common2.opt (expr env) eopt
      )

    (* I am not sure about the namespaces, so I prepend strings *)
  | TypeDef (name, t) -> 
      let s = Ast.str_of_name name in
      if env.phase = Defs 
      then begin
        if Hashtbl.mem env.typedefs s
        then
          let old = Hashtbl.find env.typedefs s in
          if (Meta_ast_c.vof_any (Type old) =*= (Meta_ast_c.vof_any (Type t)))
          then ()
          else env.pr2_and_log (spf "conflicting typedefs for %s, %s <> %s" 
                                  s (Common.dump old) (Common.dump t))
          (* todo: if are in Source, then maybe can add in local_typedefs *)
          else Hashtbl.add env.typedefs s t
      end;
      let typ = Some t in
      let _env = 
        add_node_and_edge_if_defs_mode env (add_prefix "T__" name,E.Type) typ in
      (* type_ env typ; *)
      ()

  (* less: should analyze if s has the form "..." and not <> and
   * build appropriate link? but need to find the real File
   * corresponding to the string, so may need some -I
   *)
  | Include _ -> ()
 

and toplevels env xs = List.iter (toplevel env) xs

and define_body env v =
  match v with
  | CppExpr e -> expr env e
  | CppStmt st -> stmt env st

(* ---------------------------------------------------------------------- *)
(* Stmt *)
(* ---------------------------------------------------------------------- *)

(* Mostly go through without doing anything; stmts do not use
 * any entities (expressions do).
 *)
and stmt env = function
  | ExprSt e -> expr env e
  | Block xs -> stmts env xs
  | Asm e -> exprs env e
  | If (e, st1, st2) ->
      expr env e;
      stmts env [st1; st2]
  | Switch (e, xs) ->
      expr env e;
      cases env xs
  | While (e, st) | DoWhile (st, e) -> 
      expr env e;
      stmt env st
  | For (e1, e2, e3, st) ->
      Common2.opt (expr env) e1;
      Common2.opt (expr env) e2;
      Common2.opt (expr env) e3;
      stmt env st
  | Return eopt ->
      Common2.opt (expr env) eopt;
  | Continue | Break -> ()
  | Label (_name, st) ->
      stmt env st
  | Goto _name ->
      ()

  | Vars xs ->
      xs +> List.iter (fun x ->
        let { v_name = n; v_type = t; v_storage = sto; v_init = eopt } = x in
        if sto <> Extern
        then begin
          env.locals :=  (Ast.str_of_name n)::!(env.locals);
          type_ env t;
        end;
        (* todo: actually there is a potential in_assign here
         * if set a value for the variable in rest
         *)
        Common2.opt (expr env) eopt
      )

 and case env = function
   | Case (e, xs) -> 
       expr env e;
       stmts env xs
   | Default xs ->
       stmts env xs

and stmts env xs = List.iter (stmt env) xs

and cases env xs = List.iter (case env) xs

(* ---------------------------------------------------------------------- *)
(* Expr *)
(* ---------------------------------------------------------------------- *)
(* can assume we are in Uses phase *)
and expr env = function
  | Int _ | Float _ | Char _ -> ()
  | String _  -> ()
 
  (* Note that you should go here only when it's a constant. You should
   * catch the use of Id in other contexts before. For instance you
   * should match on Id in Call, etc so that this code
   * is executed really as a last resort, which usually means when
   * there is the use of a constant.
   *)
  | Id name ->
      let s = Ast.str_of_name name in
      (match () with
      | _ when List.mem s !(env.locals) -> ()
      | _ when looks_like_macro name ->
          add_use_edge env (name, E.Constant)
      | _ ->
          add_use_edge env (name, E.Global)  
      )

  | Call (e, es) -> 
      (match e with
      | Id name ->
          if looks_like_macro name
          then add_use_edge env (name, E.Macro)
          else add_use_edge env (name, E.Function)
      | _ -> expr env e
      );
      exprs env es
  | Assign (_, e1, e2) -> exprs env [e1; e2]
  | ArrayAccess (e1, e2) -> exprs env [e1; e2]
  (* todo: determine type of e and make appropriate use link *)
  | RecordAccess (e, _name) -> expr env e

  | Cast (t, e) -> 
      type_ env t;
      expr env e

  | Postfix (e, _op) | Infix (e, _op) -> expr env e
  | Unary (e, _op) -> expr env e
  | Binary (e1, _op, e2) -> exprs env [e1;e2]

  | CondExpr (e1, e2, e3) -> exprs env [e1;e2;e3]
  | Sequence (e1, e2) -> exprs env [e1;e2]

  | ArrayInit xs -> exprs env xs
  (* todo: add deps on field *)
  | RecordInit xs -> xs +> List.map snd +> exprs env

  | SizeOf x ->
      (match x with
      | Left e -> expr env e
      | Right t -> type_ env t
      )
  | GccConstructor (t, e) ->
      type_ env t;
      expr env e


and exprs env xs = List.iter (expr env) xs

(* ---------------------------------------------------------------------- *)
(* Types *)
(* ---------------------------------------------------------------------- *)

and type_ env typ =
  if env.phase = Uses && env.conf.types_dependencies 
  then begin
    let t = final_type env typ in
    let rec aux t = 
      match t with
      | TBase _ -> ()
      | TStructName (Struct, name) -> 
          add_use_edge env (add_prefix "S__" name, E.Type)
      | TStructName (Union, name) -> 
          add_use_edge env (add_prefix "U__" name, E.Type)
      | TEnumName name -> 
          add_use_edge env (add_prefix "E__" name, E.Type)
      | TTypeName name ->
          if env.conf.typedefs_dependencies
          then add_use_edge env (add_prefix "T__" name, E.Type)
          else
            let s = Ast.str_of_name name in
            if Hashtbl.mem env.typedefs s
            then 
              let t' = (Hashtbl.find env.typedefs s) in
              (* right now 'typedef enum { ... } X' results in X being
               * typedefed to ... itself
               *)
              if t' = t
              then add_use_edge env (add_prefix "T__" name, E.Type)
              (* should be done in expand_typedefs *)
              else raise Impossible
            else env.pr2_and_log ("typedef not found:" ^ s)

      | TPointer x | TArray x -> aux x
      | TFunction (t, xs) ->
        aux t;
        xs +> List.iter (fun p -> aux p.p_type)
    in
    aux t
  end

(*****************************************************************************)
(* Main entry point *)
(*****************************************************************************)

let build ?(verbose=true) root files =
  let g = G.create () in
  G.create_initial_hierarchy g;

  let chan = open_out (Filename.concat root "pfff.log") in

  (* file -> (string, string) Hashtbl *)
  let local_renames_of_files = Hashtbl.create 101 in
  (* less: we could also have a local_typedefs_of_files to avoid conflicts *)

  let conf = {
    types_dependencies = true;
    fields_dependencies = true;

    typedefs_dependencies = false;
    propagate_deps_def_to_decl = false;
  } in

  let env = {
    g;
    phase = Defs;
    current = G.pb;
    ctx = P.NoCtx;
    c_file_readable = "__filled_later__";
    conf;
    in_assign = false;
    local_rename = Hashtbl.create 0; (* will come from local_renames_of_files*)
    dupes = Hashtbl.create 101;
    typedefs = Hashtbl.create 101;
    fields = Hashtbl.create 101;
    locals = ref [];
    log = (fun s -> output_string chan (s ^ "\n"); flush chan;);
    pr2_and_log = (fun s ->
      (*if verbose then *)
      pr2 s;
      output_string chan (s ^ "\n"); flush chan;
    );
  } in


  (* step1: creating the nodes and 'Has' edges, the defs *)
  env.pr2_and_log "\nstep1: extract defs";
  files +> Console.progress ~show:verbose (fun k ->
    List.iter (fun file ->
      k();
      let ast = parse ~show_parse_error:true file in
      let readable = Common.readable ~root file in
      let local_rename = Hashtbl.create 101 in
      Hashtbl.add local_renames_of_files file local_rename;
      extract_defs_uses { env with 
        phase = Defs; 
        c_file_readable = readable;
        local_rename = local_rename;
      } ast
   ));

  (* step2: creating the 'Use' edges *)
  env.pr2_and_log "\nstep2: extract Uses";
  files +> Console.progress ~show:verbose (fun k ->
    List.iter (fun file ->
      k();
      let ast = parse ~show_parse_error:false file in
      let readable = Common.readable ~root file in
      extract_defs_uses { env with 
        phase = Uses; 
        c_file_readable = readable;
        local_rename = Hashtbl.find local_renames_of_files file;
      } ast
    ));

  env.pr2_and_log "\nstep3: adjusting";
  if conf.propagate_deps_def_to_decl
  then propagate_users_of_functions_globals_types_to_prototype_extern_typedefs g;
  G.remove_empty_nodes g [G.not_found; G.dupe; G.pb];

  g
