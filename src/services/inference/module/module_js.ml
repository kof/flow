(**
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(* This module is the entry point of the typechecker. It sets up subtyping
   constraints for every expression, statement, and declaration form in a
   JavaScript AST; the subtyping constraints are themselves solved in module
   Flow_js. It also manages environments, including not only the maintenance of
   scope information for every function (pushing/popping scopes, looking up
   variables) but also flow-sensitive information about local variables at every
   point inside a function (and when to narrow or widen their types). *)

open Hh_json
open Utils_js

type mode =
  | ModuleMode_Checked
  | ModuleMode_Weak
  | ModuleMode_Unchecked

type error =
  | ModuleDuplicateProviderError of {
      module_name: string;
      provider: File_key.t;
      conflict: File_key.t;
    }

let choose_provider_and_warn_about_duplicates =
  let warn_duplicate_providers m current modules errmap =
    List.fold_left
      (fun acc f ->
        let w =
          ModuleDuplicateProviderError { module_name = m; provider = current; conflict = f }
        in
        FilenameMap.add
          f
          (match FilenameMap.get f acc with
          | Some errset -> w :: errset
          | None -> [w])
          acc)
      errmap
      modules
  in
  fun m errmap providers fallback ->
    let (definitions, implementations) = List.partition Files.has_flow_ext providers in
    match (implementations, definitions) with
    (* If there are no definitions or implementations, use the fallback *)
    | ([], []) -> (fallback (), errmap)
    (* Else if there are no definitions, use the first implementation *)
    | (impl :: dup_impls, []) -> (impl, warn_duplicate_providers m impl dup_impls errmap)
    (* Else use the first definition *)
    | ([], defn :: dup_defns) -> (defn, warn_duplicate_providers m defn dup_defns errmap)
    (* Don't complain about the first implementation being a duplicate *)
    | (impl :: dup_impls, defn :: dup_defns) ->
      let errmap =
        errmap
        |> warn_duplicate_providers m impl dup_impls
        |> warn_duplicate_providers m defn dup_defns
      in
      (defn, errmap)

(**
 * A set of module.name_mapper config entry allows users to specify regexp
 * matcher strings each with a template string in order to map the names of a
 * dependency in a JS file to another name before trying to resolve it.
 *
 * The user can specify any number of these mappers, but the one that gets
 * applied to any given module name is the first one whose name matches the
 * regexp string. For the node module system, we go a step further and only
 * choose candidates that match the string *and* are a valid, resolvable path.
 *)
let module_name_candidates ~options =
  Module_hashtables.memoize_with_module_name_candidates_cache ~f:(fun name ->
      let mappers = Options.module_name_mappers options in
      let root = Options.root options |> Path.to_string |> Sys_utils.normalize_filename_dir_sep in
      let map_name mapped_names (regexp, template) =
        let new_name =
          name
          (* First we apply the mapper *)
          |> Str.global_replace regexp template
          (* Then we replace the PROJECT_ROOT placeholder. This works like
           * Str.global_replace except it ignores things that look like
           * backreferences, like \1 *)
          |> Str.split_delim Files.project_root_token
          |> String.concat root
        in
        if new_name = name then
          mapped_names
        else
          new_name :: mapped_names
      in
      List.rev (name :: List.fold_left map_name [] mappers))

let add_package filename = function
  | Ok package -> Module_heaps.Package_heap_mutator.add_package_json filename package
  | Error _ -> Module_heaps.Package_heap_mutator.add_error filename

let package_incompatible ~reader filename ast =
  let new_package = Package_json.parse ast in
  let old_package = Module_heaps.Reader.get_package ~reader filename in
  match (old_package, new_package) with
  | (None, Ok _) -> true (* didn't exist before, found a new one *)
  | (None, Error _) -> false (* didn't exist before, new one is invalid *)
  | (Some (Error ()), Error _) -> false (* was invalid before, still invalid *)
  | (Some (Error ()), Ok _) -> true (* was invalid before, new one is valid *)
  | (Some (Ok _), Error _) -> true (* existed before, new one is invalid *)
  | (Some (Ok old_package), Ok new_package) -> old_package <> new_package

type resolution_acc = {
  mutable paths: SSet.t;
  mutable errors: Error_message.t list;
}

(* Specification of a module system. Currently this signature is sufficient to
   model both Haste and Node, but should be further generalized. *)
module type MODULE_SYSTEM = sig
  (* Given a file and docblock info, make the name of the module it exports. *)
  val exported_module : Options.t -> File_key.t -> Docblock.t -> Modulename.t

  (* Given a file and a reference in it to an imported module, make the name of
     the module it refers to. If given an optional reference to an accumulator,
     record paths that were looked up but not found during resolution. *)
  val imported_module :
    options:Options.t ->
    reader:Abstract_state_reader.t ->
    SSet.t ->
    File_key.t ->
    ALoc.t Nel.t ->
    ?resolution_acc:resolution_acc ->
    string ->
    Modulename.t

  (* for a given module name, choose a provider from among a set of
    files with that exported name. also check for duplicates and
    generate warnings, as dictated by module system rules. *)
  val choose_provider :
    string ->
    (* module name *)
    FilenameSet.t ->
    (* set of candidate provider files *)
    (* map from files to error sets (accumulator) *)
    error list FilenameMap.t ->
    (* file, error map (accumulator) *)
    File_key.t * error list FilenameMap.t
end

(****************** Node module system *********************)

(* TODO this exists only until we start resolving files using
   NameHeap. unfortunately that will require more refactoring
   than it should, since imported_module is currently called
   during local inference, and simply storing raw module names
   in cx.required et al and looking them up at merge time appears
   to violate some well-hidden private agreements. TODO *)

(* only purpose here is to guarantee a case-sensitive file exists
   and try to keep it from being too horrendously expensive *)

let case_sensitive = not (Sys.file_exists (String.uppercase_ascii (Sys.getcwd ())))

(* map of dirs to file lists *)

(** TODO [perf]: investigate whether this takes too much memory **)
let files_in_dir = ref SMap.empty

(* called from Types_js.typecheck, so we rebuild every time *)
let clear_filename_cache () = files_in_dir := SMap.empty

(* case-sensitive dir_exists  *)
let rec dir_exists dir =
  (try Sys.is_directory dir && (case_sensitive || file_exists dir) with _ -> false)

(* when system is case-insensitive, do our own file exists check *)
and file_exists path =
  (* case doesn't matter for "/", ".", "..." and these serve as a base-case for
   * case-insensitive filesystems *)
  let dir = Filename.dirname path in
  if
    case_sensitive
    || path = Filename.current_dir_name
    || path = Filename.parent_dir_name
    || path = dir
  then
    Sys.file_exists path
  else
    let files =
      match SMap.get dir !files_in_dir with
      | Some files -> files
      | None ->
        let files =
          if dir_exists dir then
            SSet.of_list (Array.to_list (Sys.readdir dir))
          else
            SSet.empty
        in
        files_in_dir := SMap.add dir files !files_in_dir;
        files
    in
    SSet.mem (Filename.basename path) files

let resolve_symlinks path = Path.to_string (Path.make path)

(* Every <file>.js can be imported by its path, so it effectively exports a
   module by the name <file>.js. Every <file>.js.flow shadows the corresponding
   <file>.js, so it effectively exports a module by the name <file>.js. *)
let eponymous_module file =
  Modulename.Filename
    (match Files.chop_flow_ext file with
    | Some file -> file
    | None -> file)

(*******************************)

exception Module_resolver_fatal of string

exception Invalid_resolution

module External = struct
  let external_status = ref true

  let external_channels = ref None

  let get_external_channels resolver =
    (* Create the channels if they don't exists *)
    if !external_status && !external_channels = None then (
      let program = Path.to_string resolver in
      if not (Sys.file_exists program) then
        external_status := false
      else
        let (child_r, parent_w) = Unix.pipe () in
        let (parent_r, child_w) = Unix.pipe () in
        (* Don't leak these fds *)
        List.iter Unix.set_close_on_exec [parent_w; parent_r];

        let channels = (Unix.out_channel_of_descr parent_w, Unix.in_channel_of_descr parent_r) in
        try
          ignore (Unix.create_process program [|program|] child_r child_w Unix.stderr);
          List.iter Unix.close [child_r; child_w];
          external_channels := Some channels
        with Unix.Unix_error (_, _, _) ->
          Hh_logger.info "Failed to create module resolver";
          List.iter Unix.close [child_r; child_w; parent_r; parent_w]
    );

    !external_channels

  let resolve_import opts f r =
    match Options.module_resolver opts with
    | None -> None
    | Some resolver ->
      let issuer = File_key.to_string f in
      let payload = json_to_string (JSON_Array [JSON_String r; JSON_String issuer]) in
      (match get_external_channels resolver with
      | None -> None
      | Some (out_channel, in_channel) ->
        let response_data =
          try
            output_string out_channel (payload ^ "\n");
            Pervasives.flush out_channel;

            let response_text = input_line in_channel in
            json_of_string response_text
          with exn ->
            let exn = Exception.wrap exn in
            let () = Hh_logger.fatal ~exn "Failed to talk to the module resolver" in
            let exn_str = Printf.sprintf "Exception %s" (Exception.get_ctor_string exn) in
            raise (Module_resolver_fatal exn_str)
        in
        let resolution =
          match response_data with
          | JSON_Null -> None
          | JSON_Array items ->
            begin
              match items with
              | [error; resolution] ->
                begin
                  match error with
                  | JSON_Null ->
                    begin
                      match resolution with
                      | JSON_Null -> None
                      | JSON_String r -> Some (resolve_symlinks r)
                      | _ -> raise Invalid_resolution
                    end
                  | _ -> None
                end
              | _ -> raise Invalid_resolution
            end
          | _ -> raise Invalid_resolution
        in
        (match resolution with
        | None -> None
        | Some r ->
          let file_options = Options.file_options opts in
          if not (Files.is_ignored file_options r) then
            Some r
          else
            None))
end

(*******************************)

module Node = struct
  let exported_module _ file _ = eponymous_module file

  let record_path path = function
    | None -> ()
    | Some resolution_acc -> resolution_acc.paths <- SSet.add path resolution_acc.paths

  let path_if_exists =
    let path_exists ~file_options path =
      file_exists path && (not (Files.is_ignored file_options path)) && not (dir_exists path)
    in
    fun ~file_options resolution_acc path ->
      let path = resolve_symlinks path in
      let declaration_path = path ^ Files.flow_ext in
      if path_exists ~file_options declaration_path || path_exists ~file_options path then
        Some path
      else (
        record_path path resolution_acc;
        None
      )

  let path_if_exists_with_file_exts ~file_options resolution_acc path file_exts =
    lazy_seq
      ( file_exts
      |> Core_list.map ~f:(fun ext ->
             lazy (path_if_exists ~file_options resolution_acc (path ^ ext))) )

  let parse_main
      ~reader ~root ~file_options (loc : ALoc.t) resolution_acc package_filename file_exts =
    let package_filename = resolve_symlinks package_filename in
    if (not (file_exists package_filename)) || Files.is_ignored file_options package_filename then
      None
    else
      let package =
        match Module_heaps.Reader_dispatcher.get_package ~reader package_filename with
        | Some (Ok package) -> package
        | Some (Error ()) ->
          (* invalid, but we already raised an error when building PackageHeap *)
          Package_json.empty
        | None ->
          let msg =
            let is_included = Files.is_included file_options package_filename in
            let project_root_str = Path.to_string root in
            let is_contained_in_root = Files.is_prefix project_root_str package_filename in
            let package_relative_to_root =
              spf
                "<<PROJECT_ROOT>>%s%s"
                Filename.dir_sep
                (Files.relative_path project_root_str package_filename)
            in
            if is_included || is_contained_in_root then
              Error_message.(EInternal (loc, PackageHeapNotFound package_relative_to_root))
            else
              Error_message.EModuleOutsideRoot (loc, package_relative_to_root)
          in
          begin
            match resolution_acc with
            | Some resolution_acc -> resolution_acc.errors <- msg :: resolution_acc.errors
            | None -> ()
          end;
          Package_json.empty
      in
      let dir = Filename.dirname package_filename in
      match Package_json.main package with
      | None -> None
      | Some file ->
        let path = Files.normalize_path dir file in
        let path_w_index = Filename.concat path "index" in
        lazy_seq
          [ lazy (path_if_exists ~file_options resolution_acc path);
            lazy (path_if_exists_with_file_exts ~file_options resolution_acc path file_exts);
            lazy
              (path_if_exists_with_file_exts ~file_options resolution_acc path_w_index file_exts)
          ]

  let resolve_relative ~options ~reader ((loc : ALoc.t), _) ?resolution_acc root_path rel_path =
    let file_options = Options.file_options options in
    let path = Files.normalize_path root_path rel_path in
    if Files.is_flow_file ~options:file_options path then
      path_if_exists ~file_options resolution_acc path
    else
      let path_w_index = Filename.concat path "index" in
      (* We do not try resource file extensions here. So while you can write
       * require('foo') to require foo.js, it should never resolve to foo.css
       *)
      let file_exts = SSet.elements (Files.module_file_exts file_options) in
      let root = Options.root options in
      lazy_seq
        [ lazy (path_if_exists_with_file_exts ~file_options resolution_acc path file_exts);
          lazy
            (parse_main
               ~reader
               ~root
               ~file_options
               loc
               resolution_acc
               (Filename.concat path "package.json")
               file_exts);
          lazy (path_if_exists_with_file_exts ~file_options resolution_acc path_w_index file_exts)
        ]

  let rec node_module ~options ~reader node_modules_containers file loc resolution_acc dir r =
    let file_options = Options.file_options options in
    lazy_seq
      [ lazy
          ( if SSet.mem dir node_modules_containers then
            lazy_seq
              ( Files.node_resolver_dirnames file_options
              |> Core_list.map ~f:(fun dirname ->
                     lazy
                       (resolve_relative
                          ~options
                          ~reader
                          loc
                          ?resolution_acc
                          dir
                          (spf "%s%s%s" dirname Filename.dir_sep r))) )
          else
            None );
        lazy
          (let parent_dir = Filename.dirname dir in
           if dir = parent_dir then
             None
           else
             node_module
               ~options
               ~reader
               node_modules_containers
               file
               loc
               resolution_acc
               (Filename.dirname dir)
               r) ]

  let absolute r = Str.string_match Files.absolute_path_regexp r 0

  let explicitly_relative r =
    Str.string_match Files.current_dir_name r 0 || Str.string_match Files.parent_dir_name r 0

  let resolve_import ~options ~reader node_modules_containers f loc ?resolution_acc import_str =
    let file = File_key.to_string f in
    let dir = Filename.dirname file in
    if explicitly_relative import_str || absolute import_str then
      resolve_relative ~options ~reader loc ?resolution_acc dir import_str
    else
      node_module ~options ~reader node_modules_containers f loc resolution_acc dir import_str

  let imported_module ~options ~reader node_modules_containers file loc ?resolution_acc import_str
      =
    let candidates = module_name_candidates ~options import_str in
    let rec choose_candidate = function
      | [] -> None
      | candidate :: candidates ->
        let resolved =
          resolve_import
            ~options
            ~reader
            node_modules_containers
            file
            loc
            ?resolution_acc
            candidate
        in
        (match resolved with
        | None -> choose_candidate candidates
        | Some _ as result -> result)
    in
    match choose_candidate candidates with
    | Some str ->
      let options = Options.file_options options in
      eponymous_module (Files.filename_from_string ~options str)
    | None -> Modulename.String import_str

  (* in node, file names are module names, as guaranteed by
     our implementation of exported_name, so anything but a
     singleton provider set is craziness. *)
  let choose_provider m files errmap =
    let files = FilenameSet.elements files in
    let fallback () = failwith (spf "internal error: empty provider set for module %S" m) in
    choose_provider_and_warn_about_duplicates m errmap files fallback
end

(****************** Haste module system *********************)

module Haste : MODULE_SYSTEM = struct
  let short_module_name_of = function
    | File_key.Builtins -> assert false
    | File_key.LibFile file
    | File_key.SourceFile file
    | File_key.JsonFile file
    | File_key.ResourceFile file ->
      Filename.basename file |> Filename.chop_extension

  let is_mock =
    let mock_path = Str.regexp ".*/__mocks__/.*" in
    function
    | File_key.Builtins -> false
    | File_key.LibFile file
    | File_key.SourceFile file
    | File_key.JsonFile file
    | File_key.ResourceFile file ->
      (* Standardize \ to / in path for Windows *)
      let file = Sys_utils.normalize_filename_dir_sep file in
      Str.string_match mock_path file 0

  let expand_project_root_token options str =
    Files.expand_project_root_token_to_regexp ~root:(Options.root options) str

  let is_haste_file =
    let matched_haste_paths_whitelist options name =
      List.exists
        (fun r -> Str.string_match (expand_project_root_token options r) name 0)
        (Options.haste_paths_whitelist options)
    in
    let matched_haste_paths_blacklist options name =
      List.exists
        (fun r -> Str.string_match (expand_project_root_token options r) name 0)
        (Options.haste_paths_blacklist options)
    in
    fun options name ->
      matched_haste_paths_whitelist options name
      && not (matched_haste_paths_blacklist options name)

  let haste_name =
    let reduce_name name (regexp, template) = Str.global_replace regexp template name in
    (fun options name -> List.fold_left reduce_name name (Options.haste_name_reducers options))

  let exported_module options file info =
    match file with
    | File_key.SourceFile _ ->
      if is_mock file then
        Modulename.String (short_module_name_of file)
      else if Options.haste_use_name_reducers options then
        (* Standardize \ to / in path for Windows *)
        let normalized_file_name =
          Sys_utils.normalize_filename_dir_sep (File_key.to_string file)
        in
        if is_haste_file options normalized_file_name then
          Modulename.String (haste_name options normalized_file_name)
        else
          Modulename.Filename file
      else (
        match Docblock.providesModule info with
        | Some m -> Modulename.String m
        | None -> Modulename.Filename file
      )
    | _ ->
      (* Lib files, resource files, etc don't have any fancy haste name *)
      Modulename.Filename file

  let expanded_name ~reader r =
    match Str.split_delim (Str.regexp_string "/") r with
    | [] -> None
    | package_name :: rest ->
      Module_heaps.Reader_dispatcher.get_package_directory ~reader package_name
      |> Option.map ~f:(fun package -> Files.construct_path package rest)

  (* similar to Node resolution, with possible special cases *)
  let resolve_import ~options ~reader node_modules_containers f loc ?resolution_acc r =
    let file = File_key.to_string f in
    lazy_seq
      [ lazy (External.resolve_import options f r);
        lazy (Node.resolve_import ~options ~reader node_modules_containers f loc ?resolution_acc r);
        lazy
          (match expanded_name ~reader r with
          | Some r ->
            Node.resolve_relative ~options ~reader loc ?resolution_acc (Filename.dirname file) r
          | None -> None) ]

  let imported_module
      ~options ~reader node_modules_containers file loc ?resolution_acc imported_name =
    let candidates = module_name_candidates ~options imported_name in
    (*
     * In Haste, we don't have an autoritative list of all valid module names
     * until after all modules have been sweeped (because the module name is
     * specified in the contents of the file). So, unlike the node module
     * system, we can't run through the list of mapped module names and only
     * choose the first one that is valid.
     *
     * Therefore, for the Haste module system, we simply always pick the first
     * matching candidate (rather than the first *valid* matching candidate).
     *)
    let chosen_candidate = List.hd candidates in
    let resolved =
      resolve_import
        ~options
        ~reader
        node_modules_containers
        file
        loc
        ?resolution_acc
        chosen_candidate
    in
    match resolved with
    | Some name ->
      let options = Options.file_options options in
      eponymous_module (Files.filename_from_string ~options name)
    | None -> Modulename.String chosen_candidate

  (* in haste, many files may provide the same module. here we're also
     supporting the notion of mock modules - allowed duplicates used as
     fallbacks. we prefer the non-mock if it exists, otherwise choose an
     arbitrary mock, if any exist. if multiple non-mock providers exist,
     we pick one arbitrarily and issue duplicate module warnings for the
     rest. *)
  let choose_provider m files errmap =
    match FilenameSet.elements files with
    | [] -> failwith (spf "internal error: empty provider set for module %S" m)
    | [f] -> (f, errmap)
    | files ->
      let (mocks, non_mocks) = List.partition is_mock files in
      let fallback () = List.hd mocks in
      choose_provider_and_warn_about_duplicates m errmap non_mocks fallback
end

(****************** module system switch *********************)

(* Switch between module systems, based on environment. We could eventually use
   functors, but that seems like overkill at this point. *)

let module_system = ref None

(* TODO: is it premature optimization to memoize this? how bad is doing the
   Hashtbl.find each time? *)
let get_module_system opts =
  match !module_system with
  | Some system -> system
  | None ->
    let module M =
    ( val match Options.module_system opts with
          | Options.Node -> (module Node : MODULE_SYSTEM)
          | Options.Haste -> (module Haste : MODULE_SYSTEM) )
    in
    let system = (module M : MODULE_SYSTEM) in
    module_system := Some system;
    system

let exported_module ~options file info =
  let module M = (val get_module_system options) in
  M.exported_module options file info

let imported_module ~options ~reader ~node_modules_containers file loc ?resolution_acc r =
  let module M = (val get_module_system options) in
  M.imported_module ~options ~reader node_modules_containers file loc ?resolution_acc r

let imported_modules ~options ~reader node_modules_containers file require_loc =
  (* Resolve all reqs relative to the given cx. Accumulate dependent paths in
     resolution_acc. Return the map of reqs to their resolved names, and the set
     containing the resolved names. *)
  let resolution_acc = { paths = SSet.empty; errors = [] } in
  let resolved_modules =
    SMap.fold
      (fun mref loc acc ->
        let m =
          imported_module file loc mref ~options ~reader ~node_modules_containers ~resolution_acc
        in
        SMap.add mref m acc)
      require_loc
      SMap.empty
  in
  (resolved_modules, resolution_acc)

let choose_provider ~options m files errmap =
  let module M = (val get_module_system options) in
  M.choose_provider m files errmap

(******************)
(***** public *****)
(******************)

(* Look up cached resolved module. *)
let find_resolved_module ~reader ~audit file r =
  let { Module_heaps.resolved_modules; _ } =
    Module_heaps.Reader_dispatcher.get_resolved_requires_unsafe ~reader ~audit file
  in
  SMap.find_unsafe r resolved_modules

let checked_file ~reader ~audit f =
  let info = f |> Module_heaps.Reader_dispatcher.get_info_unsafe ~reader ~audit in
  info.Module_heaps.checked

(* TODO [perf]: measure size and possibly optimize *)
(* Extract and process information from context. In particular, resolve
   references to required modules in a file, and record the results.  *)
let resolved_requires_of ~options ~reader node_modules_containers f require_loc =
  let (resolved_modules, { paths; errors }) =
    imported_modules ~options ~reader node_modules_containers f require_loc
  in
  (errors, Module_heaps.mk_resolved_requires ~resolved_modules ~phantom_dependents:paths)

let add_parsed_resolved_requires ~mutator ~reader ~options ~node_modules_containers file =
  let file_sig =
    Parsing_heaps.Mutator_reader.get_file_sig_unsafe ~reader file |> File_sig.abstractify_locs
  in
  let require_loc = File_sig.With_ALoc.(require_loc_map file_sig.module_sig) in
  let (errors, resolved_requires) =
    let reader = Abstract_state_reader.Mutator_state_reader reader in
    resolved_requires_of ~options ~reader node_modules_containers file require_loc
  in
  let resolved_requires_changed =
    Module_heaps.Resolved_requires_mutator.add_resolved_requires mutator file resolved_requires
  in
  let errorset =
    List.fold_left
      (fun acc msg ->
        Flow_error.ErrorSet.add
          (Flow_error.error_of_msg ~trace_reasons:[] ~source_file:file msg)
          acc)
      Flow_error.ErrorSet.empty
      errors
  in
  (resolved_requires_changed, errorset)

(* Repick providers for modules that are exported by new and changed files, or
   were provided by changed and deleted files.

   For deleted files, their exported modules, if in old modules, will pick a
   new provider, or be left with no provider.

   For changed files, their exported modules, if in old modules, may pick
   the same provider (i.e., the changed file) or a new provider (a different
   file). If not in old modules, they may pick a new provider (i.e., the
   changed file) or the same provider (a different file).

   For new files, their exported modules may pick a new provider (i.e., the new
   file) or the same provider (a different file).

   Suppose that:
   new_or_changed is a list of parsed / unparsed file names.
   old_modules is a set of removed module names.

   Modules provided by parsed / unparsed files may or may not have a
   provider. Modules named in old_modules definitely do not have a
   provider. Together, they are considered "dirty" modules. Providers for dirty
   modules must be repicked.

   Files that depend on the subset of dirty modules that either have changed
   providers or are provided by changed files will be rechecked.

   Preconditions:
   1. all files in new_or_changed have entries in InfoHeap (true if
   we're properly calling add_parsed_info and add_unparsed_info for every
   parsed / unparsed file before calling commit_modules)
   2. all modules not mentioned in old_modules, but provided by one or more
   files in InfoHeap, have some provider registered in NameHeap.
   (However, the current provider may not be the one we now want,
   given newly parsed / unparsed files.)
   3. conversely all modules in old_modules lack a provider in NameHeap.

   Postconditions:
   1. all modules provided by at least 1 file in InfoHeap have a provider
   registered in NameHeap, and it's the provider we want according to our
   precedence and scoping rules.

   We make use of a shadow map in the master process which maintains
   a view of what's going on in NameHeap and InfoHeap, mapping module
   names to sets of filenames of providers.
   TODO: this shadow map is probably a perf bottleneck, get rid of it.

   Algorithm here:

   1. Calculate repick set:
   (a) add all removed modules to the set of modules to repick a provider for.
   (b) add the modules provided by all parsed / unparsed files to the repick set.

   2. Commit providers for dirty modules:
   (a) For each module in the repick set, pick a winner from its available
   providers. if it's different than the current provider, or if there is no
   current provider, add the new provider to the list to be registered.
   (b) remove the unregistered modules from NameHeap
   (c) register the new providers in NameHeap
*)
let commit_modules ~transaction ~workers ~options ~reader ~is_init new_or_changed dirty_modules =
  let debug = Options.is_debug_mode options in
  let mutator = Module_heaps.Commit_modules_mutator.create transaction is_init in
  (* prep for registering new mappings in NameHeap *)
  let (to_remove, providers, to_replace, errmap, changed_modules) =
    List.fold_left
      (fun (rem, prov, rep, errmap, diff) (m, f_opt) ->
        match Module_hashtables.Mutator_reader.find_in_all_providers_unsafe ~reader m with
        | ps when FilenameSet.is_empty ps ->
          if debug then prerr_endlinef "no remaining providers: %S" (Modulename.to_string m);
          (Modulename.Set.add m rem, prov, rep, errmap, Modulename.Set.add m diff)
        | ps ->
          (* incremental: install empty error sets here for provider candidates.
         this will have the effect of resetting downstream errors for these
         files, when the returned error map is used by our caller.
         IMPORTANT: since each file may (does) provide more than one module,
         files may already have acquired errors earlier in this fold, so we
         must only add an empty entry if no entry is already present
      *)
          let errmap =
            FilenameSet.fold
              (fun f acc ->
                match FilenameMap.get f acc with
                | Some _ -> acc
                | None -> FilenameMap.add f [] acc)
              ps
              errmap
          in
          (* now choose provider for m *)
          let (p, errmap) = choose_provider ~options (Modulename.to_string m) ps errmap in
          (* register chosen provider in NameHeap *)
          (match f_opt with
          | Some f ->
            if f = p then (
              (* When can this happen? Say m pointed to f before, a different file
             f' that provides m changed (so m is not in old_modules), but f
             continues to be the chosen provider = p (winning over f'). *)
              if debug then
                prerr_endlinef
                  "unchanged provider: %S -> %s"
                  (Modulename.to_string m)
                  (File_key.to_string p);
              let diff =
                if FilenameSet.mem p new_or_changed then
                  Modulename.Set.add m diff
                else
                  diff
              in
              (rem, prov, rep, errmap, diff)
            ) else (
              (* When can this happen? Say m pointed to f before, a different file
             f' that provides m changed (so m is not in old_modules), and
             now f' becomes the chosen provider = p (winning over f). *)
              if debug then
                prerr_endlinef
                  "new provider: %S -> %s replaces %s"
                  (Modulename.to_string m)
                  (File_key.to_string p)
                  (File_key.to_string f);
              let diff = Modulename.Set.add m diff in
              (rem, p :: prov, (m, p) :: rep, errmap, diff)
            )
          | None ->
            (* When can this happen? Either m pointed to a file that used to
             provide m and changed or got deleted (causing m to be in
             old_modules), or m didn't have a provider before. *)
            if debug then
              prerr_endlinef
                "initial provider %S -> %s"
                (Modulename.to_string m)
                (File_key.to_string p);
            let diff = Modulename.Set.add m diff in
            (rem, p :: prov, (m, p) :: rep, errmap, diff)))
      (Modulename.Set.empty, [], [], FilenameMap.empty, Modulename.Set.empty)
      dirty_modules
  in
  let%lwt () =
    Module_heaps.Commit_modules_mutator.remove_and_replace mutator ~workers ~to_remove ~to_replace
  in
  if debug then prerr_endlinef "*** done committing modules ***";
  Lwt.return (providers, changed_modules, errmap)

let get_files ~reader ~audit filename module_name =
  (module_name, Module_heaps.Reader_dispatcher.get_file ~reader ~audit module_name)
  ::
  (let f_module = eponymous_module filename in
   if f_module = module_name then
     []
   else
     [(f_module, Module_heaps.Reader_dispatcher.get_file ~reader ~audit f_module)])

let get_files_unsafe ~reader ~audit filename module_name =
  (module_name, Module_heaps.Mutator_reader.get_file_unsafe ~reader ~audit module_name)
  ::
  (let f_module = eponymous_module filename in
   if f_module = module_name then
     []
   else
     [(f_module, Module_heaps.Mutator_reader.get_file_unsafe ~reader ~audit f_module)])

let calc_modules_helper ~reader workers files =
  MultiWorkerLwt.call
    workers
    ~job:
      (List.fold_left (fun acc file ->
           match Module_heaps.Mutator_reader.get_info ~reader ~audit:Expensive.ok file with
           | Some info ->
             let { Module_heaps.module_name; _ } = info in
             (file, get_files_unsafe ~reader ~audit:Expensive.ok file module_name) :: acc
           | None -> acc))
    ~neutral:[]
    ~merge:List.rev_append
    ~next:(MultiWorkerLwt.next workers (FilenameSet.elements files))

(* Given a set of files which are unchanged, return the set of modules which those files provide *)
let calc_unchanged_modules ~reader workers unchanged =
  let%lwt old_file_module_assoc = calc_modules_helper ~reader workers unchanged in
  let unchanged_modules =
    List.fold_left
      (fun unchanged_modules (file, module_provider_assoc) ->
        List.fold_left
          (fun unchanged_modules (module_name, provider) ->
            if provider = file then
              Modulename.Set.add module_name unchanged_modules
            else
              unchanged_modules)
          unchanged_modules
          module_provider_assoc)
      Modulename.Set.empty
      old_file_module_assoc
  in
  Lwt.return unchanged_modules

(* Calculate the set of modules whose current providers are changed or deleted files.

   Possibilities:
   1. file is current registered module provider for a given module name
   2. file is not current provider, but record is still registered
   3. file isn't in the map at all. This means file is new.
   We return the set of module names whose current providers are the same as the
   given files (#1). This is the set commit_modules expects as its second
   argument.

   NOTE: The notion of "current provider" is murky, since every file at least
   provides its eponymous module. So we also include it in the returned set.

   TODO: Does a .flow file also provide its eponymous module? Or does it provide
   the eponymous module of the file it shadows?
*)
let calc_old_modules =
  let calc_from_module_assocs ~all_providers_mutator ~options old_file_module_assoc =
    (* files may or may not be registered as module providers.
       when they are, we need to clear their registrations *)
    let old_modules =
      List.fold_left
        (fun old_modules (file, module_provider_assoc) ->
          List.fold_left
            (fun old_modules (module_name, provider) ->
              Module_hashtables.All_providers_mutator.remove_provider
                all_providers_mutator
                file
                module_name;
              if provider = file then
                (module_name, Some provider) :: old_modules
              else
                old_modules)
            old_modules
            module_provider_assoc)
        []
        old_file_module_assoc
    in
    let debug = Options.is_debug_mode options in
    if debug then
      prerr_endlinef "*** old modules (changed and deleted files) %d ***" (List.length old_modules);

    (* return *)
    old_modules
  in
  fun workers ~all_providers_mutator ~options ~reader new_or_changed_or_deleted ->
    let%lwt old_file_module_assoc =
      calc_modules_helper ~reader workers new_or_changed_or_deleted
    in
    Lwt.return (calc_from_module_assocs ~all_providers_mutator ~options old_file_module_assoc)

module IntroduceFiles : sig
  val introduce_files :
    mutator:Module_heaps.Introduce_files_mutator.t ->
    reader:Mutator_state_reader.t ->
    all_providers_mutator:Module_hashtables.All_providers_mutator.t ->
    workers:MultiWorkerLwt.worker list option ->
    options:Options.t ->
    parsed:File_key.t list ->
    unparsed:(File_key.t * Docblock.t) list ->
    (Modulename.t * File_key.t option) list Lwt.t

  val introduce_files_from_saved_state :
    mutator:Module_heaps.Introduce_files_mutator.t ->
    all_providers_mutator:Module_hashtables.All_providers_mutator.t ->
    workers:MultiWorkerLwt.worker list option ->
    options:Options.t ->
    parsed:(File_key.t * Module_heaps.info) list ->
    unparsed:(File_key.t * Module_heaps.info) list ->
    (Modulename.t * File_key.t option) list Lwt.t
end = struct
  (* Before and after inference, we add per-file module info to the shared heap
     from worker processes. Note that we wait to choose providers until inference
     is complete. *)
  let add_parsed_info ~mutator ~reader ~options file =
    let force_check = Options.all options in
    let docblock = Parsing_heaps.Mutator_reader.get_docblock_unsafe ~reader file in
    let module_name = exported_module ~options file docblock in
    let checked = force_check || Docblock.is_flow docblock in
    let info = { Module_heaps.module_name; checked; parsed = true } in
    Module_heaps.Introduce_files_mutator.add_info mutator file info;
    (file, module_name)

  (* We need to track files that have failed to parse. This begins with
     adding tracking records for unparsed files to InfoHeap. They never
     become providers - the process of committing modules happens after
     parsed files are finished with local inference. But since we guess
     the module names of unparsed files, we're able to tell whether an
     unparsed file has been required/imported.
   *)
  let add_unparsed_info ~mutator ~options (file, docblock) =
    let force_check = Options.all options in
    let module_name = exported_module ~options file docblock in
    let checked =
      force_check
      || File_key.is_lib_file file
      || Docblock.is_flow docblock
      || Docblock.isDeclarationFile docblock
    in
    let info = { Module_heaps.module_name; checked; parsed = false } in
    Module_heaps.Introduce_files_mutator.add_info mutator file info;
    (file, module_name)

  let calc_new_modules ~all_providers_mutator ~options file_module_assoc =
    (* all modules provided by newly parsed / unparsed files must be repicked *)
    let new_modules =
      List.fold_left
        (fun new_modules (file, module_opt_provider_assoc) ->
          List.fold_left
            (fun new_modules (module_, opt_provider) ->
              Module_hashtables.All_providers_mutator.add_provider
                all_providers_mutator
                file
                module_;
              (module_, opt_provider) :: new_modules)
            new_modules
            module_opt_provider_assoc)
        []
        file_module_assoc
    in
    let debug = Options.is_debug_mode options in
    if debug then
      prerr_endlinef "*** new modules (new and changed files) %d ***" (List.length new_modules);

    new_modules

  let introduce_files_generic
      ~add_parsed_info
      ~add_unparsed_info
      ~reader
      ~all_providers_mutator
      ~workers
      ~options
      ~parsed
      ~unparsed =
    (* add tracking modules for unparsed files *)
    let%lwt unparsed_file_module_assoc =
      MultiWorkerLwt.call
        workers
        ~job:
          (List.fold_left (fun file_module_assoc unparsed_file ->
               let (filename, m) = add_unparsed_info ~options unparsed_file in
               (filename, get_files ~reader ~audit:Expensive.ok filename m) :: file_module_assoc))
        ~neutral:[]
        ~merge:List.rev_append
        ~next:(MultiWorkerLwt.next workers unparsed)
    in
    (* create info for parsed files *)
    let%lwt parsed_file_module_assoc =
      MultiWorkerLwt.call
        workers
        ~job:
          (List.fold_left (fun file_module_assoc parsed_file ->
               let (filename, m) = add_parsed_info ~options parsed_file in
               (filename, get_files ~reader ~audit:Expensive.ok filename m) :: file_module_assoc))
        ~neutral:[]
        ~merge:List.rev_append
        ~next:(MultiWorkerLwt.next workers parsed)
    in
    let new_file_module_assoc =
      List.rev_append parsed_file_module_assoc unparsed_file_module_assoc
    in
    Lwt.return (calc_new_modules ~all_providers_mutator ~options new_file_module_assoc)

  let introduce_files ~mutator ~reader =
    let add_parsed_info = add_parsed_info ~mutator ~reader in
    let reader = Abstract_state_reader.Mutator_state_reader reader in
    let add_unparsed_info = add_unparsed_info ~mutator in
    introduce_files_generic ~add_parsed_info ~add_unparsed_info ~reader

  let introduce_files_from_saved_state ~mutator =
    let add_info_from_saved_state ~options:_ (filename, info) =
      Module_heaps.Introduce_files_mutator.add_info mutator filename info;
      (filename, info.Module_heaps.module_name)
    in
    let reader = Abstract_state_reader.State_reader (State_reader.create ()) in
    introduce_files_generic
      ~add_parsed_info:add_info_from_saved_state
      ~add_unparsed_info:add_info_from_saved_state
      ~reader
end

let introduce_files = IntroduceFiles.introduce_files

let introduce_files_from_saved_state = IntroduceFiles.introduce_files_from_saved_state
