(**
 * Copyright (c) 2013-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Core_result
open ServerEnv
open Utils_js
open Lsp

let status_log errors =
  if Errors.ErrorSet.is_empty errors
    then Hh_logger.info "Status: OK"
    else Hh_logger.info "Status: Error";
  flush stdout

let convert_errors ~errors ~warnings =
  if Errors.ErrorSet.is_empty errors && Errors.ErrorSet.is_empty warnings then
    ServerProt.Response.NO_ERRORS
  else
    ServerProt.Response.ERRORS {errors; warnings}

let get_status genv env client_root =
  let server_root = Options.root genv.options in
  let lazy_stats = Rechecker.get_lazy_stats genv env in
  let status_response =
    if server_root <> client_root then begin
      ServerProt.Response.DIRECTORY_MISMATCH {
        ServerProt.Response.server=server_root;
        ServerProt.Response.client=client_root
      }
    end else begin
      (* collate errors by origin *)
      let errors, warnings, _ = ErrorCollator.get env in
      let warnings = if Options.should_include_warnings genv.options
        then warnings
        else Errors.ErrorSet.empty
      in

      (* TODO: check status.directory *)
      status_log errors;
      FlowEventLogger.status_response
        ~num_errors:(Errors.ErrorSet.cardinal errors);
      convert_errors errors warnings
    end
  in
  status_response, lazy_stats

let autocomplete ~options ~workers ~env ~profiling file_input =
  let path, content = match file_input with
    | File_input.FileName _ -> failwith "Not implemented"
    | File_input.FileContent (_, content) ->
        File_input.filename_of_file_input file_input, content
  in
  let state = Autocomplete_js.autocomplete_set_hooks () in
  let path = File_key.SourceFile path in
  let%lwt check_contents_result =
    Types_js.basic_check_contents ~options ~workers ~env ~profiling content path
  in
  let%lwt autocomplete_result =
    map_error ~f:(fun str -> str, None) check_contents_result
    %>>= (fun (cx, info, file_sig, _) ->
      Profiling_js.with_timer_lwt profiling ~timer:"GetResults" ~f:(fun () ->
        try_with_json (fun () ->
          Lwt.return (AutocompleteService_js.autocomplete_get_results cx file_sig state info)
        )
      )
    )
  in
  let results, json_data_to_log = split_result autocomplete_result in
  Autocomplete_js.autocomplete_unset_hooks ();
  Lwt.return (results, json_data_to_log)

let check_file ~options ~workers ~env ~profiling ~force file_input =
  let file = File_input.filename_of_file_input file_input in
  match file_input with
  | File_input.FileName _ -> failwith "Not implemented"
  | File_input.FileContent (_, content) ->
      let should_check =
        if force then
          true
        else
          let (_, docblock) = Parsing_service_js.(
            parse_docblock docblock_max_tokens (File_key.SourceFile file) content)
          in
          Docblock.is_flow docblock
      in
      if should_check then
        let file = File_key.SourceFile file in
        let%lwt _, errors, warnings =
          Types_js.typecheck_contents ~options ~workers ~env ~profiling content file
        in
        Lwt.return (convert_errors ~errors ~warnings)
      else
        Lwt.return (ServerProt.Response.NOT_COVERED)

let infer_type
    ~(options: Options.t)
    ~(workers: MultiWorkerLwt.worker list option)
    ~(env: ServerEnv.env ref)
    ~(profiling: Profiling_js.running)
    ((file_input, line, col, verbose, expand_aliases):
      (File_input.t * int * int * Verbose.t option * bool))
  : ((Loc.t * Ty.t option, string) Core_result.t * Hh_json.json option) Lwt.t =
  let file = File_input.filename_of_file_input file_input in
  let file = File_key.SourceFile file in
  let options = { options with Options.opt_verbose = verbose } in
  match File_input.content_of_file_input file_input with
  | Error e -> Lwt.return (Error e, None)
  | Ok content ->
    let%lwt result = try_with_json (fun () ->
      Type_info_service.type_at_pos ~options ~workers ~env ~profiling ~expand_aliases
        file content line col
    ) in
    Lwt.return (split_result result)

let dump_types ~options ~workers ~env ~profiling file_input =
  let file = File_input.filename_of_file_input file_input in
  let file = File_key.SourceFile file in
  File_input.content_of_file_input file_input
  %>>= fun content ->
    try_with begin fun () ->
      Type_info_service.dump_types ~options ~workers ~env ~profiling file content
    end

let coverage ~options ~workers ~env ~profiling ~force file_input =
  let file = File_input.filename_of_file_input file_input in
  let file = File_key.SourceFile file in
  File_input.content_of_file_input file_input
  %>>= fun content ->
    try_with begin fun () ->
      Type_info_service.coverage ~options ~workers ~env ~profiling ~force file content
    end

let get_cycle ~env fn =
  (* Re-calculate SCC *)
  let parsed = !env.ServerEnv.files in
  let dependency_graph = !env.ServerEnv.dependency_graph in
  Lwt.return (
    let components = Sort_js.topsort ~roots:parsed dependency_graph in

    (* Get component for target file *)
    let component = List.find (Nel.mem fn) components in

    (* Restrict dep graph to only in-cycle files *)
    let subgraph = Nel.fold_left (fun acc f ->
      Option.fold (FilenameMap.get f dependency_graph) ~init:acc ~f:(fun acc deps ->
        let subdeps = FilenameSet.filter (fun f -> Nel.mem f component) deps in
        if FilenameSet.is_empty subdeps
        then acc
        else FilenameMap.add f subdeps acc
      )
    ) FilenameMap.empty component in

    (* Convert from map/set to lists for serialization to client. *)
    let subgraph = FilenameMap.fold (fun f dep_fs acc ->
      let f = File_key.to_string f in
      let dep_fs = FilenameSet.fold (fun dep_f acc ->
        (File_key.to_string dep_f)::acc
      ) dep_fs [] in
      (f, dep_fs)::acc
    ) subgraph [] in

    Ok subgraph
  )

let suggest ~options ~workers ~env ~profiling file_input =
  let file = File_input.filename_of_file_input file_input in
  let file = File_key.SourceFile file in
  File_input.content_of_file_input file_input
  %>>= fun content -> try_with (fun _ ->
    let%lwt result =
      Type_info_service.suggest ~options ~workers ~env ~profiling file content
    in
    match result with
    | Ok (tc_errors, tc_warnings, suggest_warnings, annotated_program) ->
      Lwt.return (Ok (ServerProt.Response.Suggest_Ok {
        tc_errors; tc_warnings; suggest_warnings; annotated_program
      }))
    | Error errors ->
      Lwt.return (Ok (ServerProt.Response.Suggest_Error errors))
  )

(* NOTE: currently, not only returns list of annotations, but also writes a
   timestamped file with annotations *)
let port = Port_service_js.port_files

let find_module ~options (moduleref, filename) =
  let file = File_key.SourceFile filename in
  let loc = {Loc.none with Loc.source = Some file} in
  let module_name = Module_js.imported_module
    ~options ~node_modules_containers:!Files.node_modules_containers
    file (Nel.one loc) moduleref in
  Module_heaps.get_file ~audit:Expensive.warn module_name

let gen_flow_files ~options env files =
  let errors, warnings, _ = ErrorCollator.get env in
  let warnings = if Options.should_include_warnings options
    then warnings
    else Errors.ErrorSet.empty
  in
  let result = if Errors.ErrorSet.is_empty errors
    then begin
      let (flow_files, non_flow_files, error) =
        List.fold_left (fun (flow_files, non_flow_files, error) file ->
          if error <> None then (flow_files, non_flow_files, error) else
          match file with
          | File_input.FileContent _ ->
            let error_msg = "This command only works with file paths." in
            let error =
              Some (ServerProt.Response.GenFlowFiles_UnexpectedError error_msg)
            in
            (flow_files, non_flow_files, error)
          | File_input.FileName fn ->
            let file = File_key.SourceFile fn in
            let checked =
              let open Module_heaps in
              match get_info file ~audit:Expensive.warn with
              | Some info -> info.checked
              | None -> false
            in
            if checked
            then file::flow_files, non_flow_files, error
            else flow_files, file::non_flow_files, error
        ) ([], [], None) files
      in
      begin match error with
      | Some e -> Error e
      | None ->
        try
          let flow_file_cxs = List.map (fun file ->
            let component = Nel.one file in
            let { Merge_service.cx; _ } = Merge_service.merge_strict_context ~options component in
            cx
          ) flow_files in

          (* Non-@flow files *)
          let result_contents = non_flow_files |> List.map (fun file ->
            (File_key.to_string file, ServerProt.Response.GenFlowFiles_NonFlowFile)
          ) in

          (* Codegen @flow files *)
          let result_contents = List.fold_left2 (fun results file cx ->
            let file_path = File_key.to_string file in
            try
              let code = FlowFileGen.flow_file cx in
              (file_path, ServerProt.Response.GenFlowFiles_FlowFile code)::results
            with exn ->
              failwith (spf "%s: %s" file_path (Printexc.to_string exn))
          ) result_contents flow_files flow_file_cxs in

          Ok result_contents
        with exn -> Error (
          ServerProt.Response.GenFlowFiles_UnexpectedError (Printexc.to_string exn)
        )
      end
    end else
      Error (ServerProt.Response.GenFlowFiles_TypecheckError {errors; warnings})
  in
  result

let convert_find_refs_result
    (result: FindRefsTypes.find_refs_ok)
    : ServerProt.Response.find_refs_success =
  Option.map result ~f:begin fun (name, refs) ->
    (name, List.map snd refs)
  end

let find_refs ~genv ~env ~profiling (file_input, line, col, global, multi_hop) =
  let%lwt result, json =
    FindRefs_js.find_refs ~genv ~env ~profiling ~file_input ~line ~col ~global ~multi_hop
  in
  let result = Core_result.map result ~f:convert_find_refs_result in
  Lwt.return (result, json)

(* This returns result, json_data_to_log, where json_data_to_log is the json data from
 * getdef_get_result which we end up using *)
let get_def ~options ~workers ~env ~profiling position =
  GetDef_js.get_def ~options ~workers ~env ~profiling ~depth:0 position

let module_name_of_string ~options module_name_str =
  let file_options = Options.file_options options in
  let path = Path.to_string (Path.make module_name_str) in
  if Files.is_flow_file ~options:file_options path
  then Modulename.Filename (File_key.SourceFile path)
  else Modulename.String module_name_str

let get_imports ~options module_names =
  let add_to_results (map, non_flow) module_name_str =
    let module_name = module_name_of_string ~options module_name_str in
    match Module_heaps.get_file ~audit:Expensive.warn module_name with
    | Some file ->
      (* We do not process all modules which are stored in our module
       * database. In case we do not process a module its requirements
       * are not kept track of. To avoid confusing results we notify the
       * client that these modules have not been processed.
       *)
      let { Module_heaps.checked; _ } =
        Module_heaps.get_info_unsafe ~audit:Expensive.warn file in
      if checked then
        let { Module_heaps.resolved_modules; _ } =
          Module_heaps.get_resolved_requires_unsafe ~audit:Expensive.warn file in
        let fsig = Parsing_heaps.get_file_sig_unsafe file in
        let requires = File_sig.(require_loc_map fsig.module_sig) in
        let mlocs = SMap.fold (fun mref locs acc ->
          let m = SMap.find_unsafe mref resolved_modules in
          Modulename.Map.add m locs acc
        ) requires Modulename.Map.empty in
        (SMap.add module_name_str mlocs map, non_flow)
      else
        (map, SSet.add module_name_str non_flow)
    | None ->
      (* We simply ignore non existent modules *)
      (map, non_flow)
  in
  (* Our result is a tuple. The first element is a map from module names to
   * modules imported by them and their locations of import. The second
   * element is a set of modules which are not marked for processing by
   * flow. *)
  List.fold_left add_to_results (SMap.empty, SSet.empty) module_names

let save_state ~saved_state_filename ~genv ~env =
  try_with (fun () ->
    let%lwt () = Saved_state.save ~saved_state_filename ~genv ~env:!env in
    Lwt.return (Ok ())
  )

let handle_ephemeral_deferred_unsafe
  genv env (request_id, { ServerProt.Request.client_logging_context=_; command; }) =
  let env = ref env in
  let respond msg =
    MonitorRPC.respond_to_request ~request_id ~response:msg

  in
  let options = genv.ServerEnv.options in
  let workers = genv.ServerEnv.workers in
  Hh_logger.debug "Request: %s" (ServerProt.Request.to_string command);
  MonitorRPC.status_update ~event:ServerStatus.Handling_request_start;
  let should_print_summary = Options.should_profile genv.options in
  let%lwt profiling, json_data =
    Profiling_js.with_profiling_lwt ~label:"Command" ~should_print_summary begin fun profiling ->
      match command with
      | ServerProt.Request.AUTOCOMPLETE fn ->
          let%lwt result, json_data = autocomplete ~options ~workers ~env ~profiling fn in
          ServerProt.Response.AUTOCOMPLETE result
          |> respond;
          Lwt.return json_data
      | ServerProt.Request.CHECK_FILE (fn, verbose, force, include_warnings) ->
          let options = { options with Options.
            opt_verbose = verbose;
            opt_include_warnings = options.Options.opt_include_warnings || include_warnings;
          } in
          let%lwt response = check_file ~options ~workers ~env ~force ~profiling fn in
          ServerProt.Response.CHECK_FILE response
          |> respond;
          Lwt.return None
      | ServerProt.Request.COVERAGE (fn, force) ->
          let%lwt response = coverage ~options ~workers ~env ~profiling ~force fn in
          ServerProt.Response.COVERAGE response
          |> respond;
          Lwt.return None
      | ServerProt.Request.CYCLE fn ->
          let file_options = Options.file_options options in
          let fn = Files.filename_from_string ~options:file_options fn in
          let%lwt response = get_cycle ~env fn in
          ServerProt.Response.CYCLE response
          |> respond;
          Lwt.return None
      | ServerProt.Request.DUMP_TYPES (fn) ->
          let%lwt response = dump_types ~options ~workers ~env ~profiling fn in
          ServerProt.Response.DUMP_TYPES response
          |> respond;
          Lwt.return None
      | ServerProt.Request.FIND_MODULE (moduleref, filename) ->
          ServerProt.Response.FIND_MODULE (
            find_module ~options (moduleref, filename): File_key.t option
          ) |> respond;
          Lwt.return None
      | ServerProt.Request.FIND_REFS (fn, line, char, global, multi_hop) ->
          let%lwt result, json_data =
            find_refs ~genv ~env ~profiling (fn, line, char, global, multi_hop) in
          ServerProt.Response.FIND_REFS result |> respond;
          Lwt.return json_data
      | ServerProt.Request.FORCE_RECHECK _ ->
          failwith "force-recheck cannot be deferred"
      | ServerProt.Request.GEN_FLOW_FILES (files, include_warnings) ->
          let options = { options with Options.
            opt_include_warnings = options.Options.opt_include_warnings || include_warnings;
          } in
          ServerProt.Response.GEN_FLOW_FILES (
            gen_flow_files ~options !env files: ServerProt.Response.gen_flow_files_response
          ) |> respond;
          Lwt.return None
      | ServerProt.Request.GET_DEF (fn, line, char) ->
          let%lwt result, json_data = get_def ~options ~workers ~env ~profiling (fn, line, char) in
          ServerProt.Response.GET_DEF result
          |> respond;
          Lwt.return json_data
      | ServerProt.Request.GET_IMPORTS module_names ->
          ServerProt.Response.GET_IMPORTS (
            get_imports ~options module_names: ServerProt.Response.get_imports_response
          ) |> respond;
          Lwt.return None
      | ServerProt.Request.INFER_TYPE (fn, line, char, verbose, expand_aliases) ->
          let%lwt result, json_data =
            infer_type ~options ~workers ~env ~profiling
              (fn, line, char, verbose, expand_aliases)
          in
          ServerProt.Response.INFER_TYPE result
          |> respond;
          Lwt.return json_data
      | ServerProt.Request.PORT (files) ->
          ServerProt.Response.PORT (port files: ServerProt.Response.port_response)
          |> respond;
          Lwt.return None
      | ServerProt.Request.REFACTOR (file_input, line, col, refactor_variant) ->
          let open ServerProt.Response in
          let%lwt result =
            Refactor_js.refactor ~genv ~env ~profiling ~file_input ~line ~col ~refactor_variant
          in
          let result =
            result
            |> Core_result.map ~f:(Option.map ~f:(fun refactor_edits -> {refactor_edits}))
          in
          REFACTOR (result)
          |> respond;
          Lwt.return None
      | ServerProt.Request.STATUS (client_root, include_warnings) ->
          let genv = {genv with
            options = let open Options in {genv.options with
              opt_include_warnings = genv.options.opt_include_warnings || include_warnings
            }
          } in
          let status_response, lazy_stats = get_status genv !env client_root in
          respond (ServerProt.Response.STATUS {status_response; lazy_stats});
          begin match status_response with
            | ServerProt.Response.DIRECTORY_MISMATCH {ServerProt.Response.server; client} ->
                Hh_logger.fatal "Status: Error";
                Hh_logger.fatal "server_dir=%s, client_dir=%s"
                  (Path.to_string server)
                  (Path.to_string client);
                Hh_logger.fatal "flow server is not listening to the same directory. Exiting.";
                FlowExitStatus.(exit Server_client_directory_mismatch)
            | _ -> ()
          end;
          Lwt.return None
      | ServerProt.Request.SUGGEST fn ->
          let%lwt result = suggest ~options ~workers ~env ~profiling fn in
          ServerProt.Response.SUGGEST result
          |> respond;
          Lwt.return None
      | ServerProt.Request.SAVE_STATE out ->
          let%lwt result = save_state ~saved_state_filename:out ~genv ~env in
          ServerProt.Response.SAVE_STATE result
          |> respond;
          Lwt.return None
    end
  in
  let event = ServerStatus.(Finishing_up {
    duration = Profiling_js.get_profiling_duration profiling;
    info = CommandSummary (ServerProt.Request.to_string command)}) in
  MonitorRPC.status_update ~event;
  Lwt.return (!env, profiling, json_data)

let wrap_ephemeral_handler handler genv arg (request_id, command) =
  try%lwt
    let%lwt ret, profiling, json_data = handler genv arg (request_id, command) in
    FlowEventLogger.ephemeral_command_success
      ?json_data
      ~client_context:command.ServerProt.Request.client_logging_context
      ~profiling;
    Lwt.return ret
  with exn ->
    let backtrace = String.trim (Printexc.get_backtrace ()) in
    let exn_str = Printf.sprintf
      "%s%s%s"
      (Printexc.to_string exn)
      (if backtrace = "" then "" else "\n")
      backtrace in
    Hh_logger.error
      "Uncaught exception while handling a request (%s): %s"
      (ServerProt.Request.to_string command.ServerProt.Request.command)
      exn_str;
    FlowEventLogger.ephemeral_command_failure
      ~client_context:command.ServerProt.Request.client_logging_context
      ~json_data:(Hh_json.JSON_Object [ "exn", Hh_json.JSON_String exn_str ]);
    MonitorRPC.request_failed ~request_id ~exn_str;
    Lwt.return arg
let handle_ephemeral_deferred = wrap_ephemeral_handler handle_ephemeral_deferred_unsafe

let should_handle_immediately { ServerProt.Request.client_logging_context=_; command; } =
  match command with
    | ServerProt.Request.FORCE_RECHECK _ ->
      true

    | ServerProt.Request.AUTOCOMPLETE _
    | ServerProt.Request.CHECK_FILE _
    | ServerProt.Request.COVERAGE _
    | ServerProt.Request.CYCLE _
    | ServerProt.Request.DUMP_TYPES _
    | ServerProt.Request.FIND_MODULE _
    | ServerProt.Request.FIND_REFS _
    | ServerProt.Request.GEN_FLOW_FILES _
    | ServerProt.Request.GET_DEF _
    | ServerProt.Request.GET_IMPORTS _
    | ServerProt.Request.INFER_TYPE _
    | ServerProt.Request.PORT _
    | ServerProt.Request.REFACTOR _
    | ServerProt.Request.STATUS _
    | ServerProt.Request.SUGGEST _
    | ServerProt.Request.SAVE_STATE _ ->
      false

(* A few commands need to be handled immediately, as soon as they arrive from the monitor. An
 * `env` is NOT available, since we don't have the server's full attention *)
let handle_ephemeral_immediately_unsafe
    genv () (request_id, { ServerProt.Request.client_logging_context=_; command; }) =
  let respond msg =
    MonitorRPC.respond_to_request ~request_id ~response:msg

  in
  Hh_logger.debug "Request: %s" (ServerProt.Request.to_string command);
  MonitorRPC.status_update ~event:ServerStatus.Handling_request_start;
  let should_print_summary = Options.should_profile genv.options in
  let%lwt profiling, json_data =
    Profiling_js.with_profiling_lwt ~label:"Command" ~should_print_summary begin fun profiling ->
      match command with
      | ServerProt.Request.FORCE_RECHECK { files; focus; profile; } ->
        let fileset = SSet.of_list files in
          let push = ServerMonitorListenerState.(
            if focus then push_files_to_focus else push_files_to_recheck
          ) in

          if profile
          then begin
            let wait_for_recheck_thread, wakener = Lwt.task () in
            push ~callback:(fun profiling -> Lwt.wakeup wakener profiling) fileset;
            let%lwt recheck_profiling = wait_for_recheck_thread in
            respond (ServerProt.Response.FORCE_RECHECK recheck_profiling);
            Option.iter recheck_profiling ~f:(fun recheck_profiling ->
              Profiling_js.merge ~from:recheck_profiling ~into:profiling
            );
            Lwt.return None
          end else begin
            (* If we're not profiling the recheck, then respond immediately *)
            respond (ServerProt.Response.FORCE_RECHECK None);
            push fileset;
            Lwt.return None
          end
      | ServerProt.Request.AUTOCOMPLETE _
      | ServerProt.Request.CHECK_FILE _
      | ServerProt.Request.COVERAGE _
      | ServerProt.Request.CYCLE _
      | ServerProt.Request.DUMP_TYPES _
      | ServerProt.Request.FIND_MODULE _
      | ServerProt.Request.FIND_REFS _
      | ServerProt.Request.GEN_FLOW_FILES _
      | ServerProt.Request.GET_DEF _
      | ServerProt.Request.GET_IMPORTS _
      | ServerProt.Request.INFER_TYPE _
      | ServerProt.Request.PORT _
      | ServerProt.Request.REFACTOR _
      | ServerProt.Request.STATUS _
      | ServerProt.Request.SUGGEST _
      | ServerProt.Request.SAVE_STATE _ ->
          failwith (spf "Command %s must be deferred" (ServerProt.Request.to_string command))
    end
  in
  let event = ServerStatus.(Finishing_up {
    duration = Profiling_js.get_profiling_duration profiling;
    info = CommandSummary (ServerProt.Request.to_string command)}) in
  MonitorRPC.status_update ~event;
  Lwt.return ((), profiling, json_data)

let handle_ephemeral_immediately = wrap_ephemeral_handler handle_ephemeral_immediately_unsafe

let handle_ephemeral genv (request_id, command) =
  if should_handle_immediately command
  then handle_ephemeral_immediately genv () (request_id, command)
  else begin
    ServerMonitorListenerState.push_new_workload
      (fun env -> handle_ephemeral_deferred genv env (request_id, command));
    Lwt.return_unit
  end
let did_open genv env client (files: (string*string) Nel.t) : ServerEnv.env Lwt.t =
  let options = genv.ServerEnv.options in
  begin match Persistent_connection.client_did_open env.connections client ~files with
  | None -> Lwt.return env (* No new files were opened, so do nothing *)
  | Some (connections, client) ->
    let env = {env with connections} in

    match Options.lazy_mode options with
    | Some Options.LAZY_MODE_IDE ->
      (* LAZY_MODE_IDE is a lazy mode which infers the focused files based on what the IDE
       * opens. So when an IDE opens a new file, that file is now focused.
       *
       * If the newly opened file was previously unchecked or checked as a dependency, then
       * we will do a new recheck.
       *
       * If the newly opened file was already checked, then we'll just send the errors to
       * the client
       *)
      let filenames = Nel.map (fun (fn, _content) -> fn) files in
      let%lwt env, triggered_recheck = Lazy_mode_utils.focus_and_check genv env filenames in
      if not triggered_recheck then begin
        (* This open doesn't trigger a recheck, but we'll still send down the errors *)
        let errors, warnings, _ = ErrorCollator.get_with_separate_warnings env in
        Persistent_connection.send_errors_if_subscribed ~client ~errors ~warnings
      end;
      Lwt.return env
    | Some Options.LAZY_MODE_FILESYSTEM
    | None ->
      (* In filesystem lazy mode or in non-lazy mode, the only thing we need to do when
       * a new file is opened is to send the errors to the client *)
      let errors, warnings, _ = ErrorCollator.get_with_separate_warnings env in
      Persistent_connection.send_errors_if_subscribed ~client ~errors ~warnings;
      Lwt.return env
    end

let did_close _genv env client (filenames: string Nel.t) : ServerEnv.env Lwt.t =
  begin match Persistent_connection.client_did_close env.connections client ~filenames with
    | None -> Lwt.return env (* No new files were closed, so do nothing *)
    | Some (connections, client) ->
      let errors, warnings, _ = ErrorCollator.get_with_separate_warnings env in
      Persistent_connection.send_errors_if_subscribed ~client ~errors ~warnings;
      Lwt.return {env with connections}
  end


let with_error
    ?(stack: Utils.callstack option)
    ~(reason: string)
    (metadata: Persistent_connection_prot.metadata)
  : Persistent_connection_prot.metadata =
  let open Persistent_connection_prot in
  let local_stack = Printexc.get_callstack 100 |> Printexc.raw_backtrace_to_string in
  let stack = Option.value stack ~default:(Utils.Callstack local_stack) in
  let error_info = Some (ExpectedError, reason, stack) in
  { metadata with error_info }

let keyvals_of_json (json: Hh_json.json option) : (string * Hh_json.json) list =
  match json with
  | None -> []
  | Some (Hh_json.JSON_Object keyvals) -> keyvals
  | Some json -> ["json_data", json]

let with_data
    ~(extra_data: Hh_json.json option)
    (metadata: Persistent_connection_prot.metadata)
  : Persistent_connection_prot.metadata =
  let open Persistent_connection_prot in
  let extra_data = metadata.extra_data @ (keyvals_of_json extra_data)
  in
  { metadata with extra_data }

type persistent_handling_result =
  (** IdeResponse means that handle_persistent_unsafe is responsible for sending
     the message to the client, and handle_persistent is responsible for logging. *)
  | IdeResponse of (
      ServerEnv.env * Hh_json.json option,
      ServerEnv.env * Persistent_connection_prot.error_info
    ) result
  (** LspResponse means that handle_persistent is responsible for sending the
     message (if needed) to the client, and lspCommand is responsible for logging. *)
  | LspResponse of (
      ServerEnv.env * Lsp.lsp_message option * Persistent_connection_prot.metadata,
      ServerEnv.env * Persistent_connection_prot.metadata
    ) result


(** handle_persistent_unsafe:
   either this method returns Ok (and optionally returns some logging data),
   or it returns Error for some well-understood reason string,
   or it might raise/Lwt.fail, indicating a misunderstood coding bug. *)
let handle_persistent_unsafe genv env client profiling msg : persistent_handling_result Lwt.t =
  let open Persistent_connection_prot in
  let options = genv.ServerEnv.options in
  let workers = genv.ServerEnv.workers in

  match msg with
  | Subscribe ->
      let current_errors, current_warnings, _ = ErrorCollator.get_with_separate_warnings env in
      let new_connections = Persistent_connection.subscribe_client
        ~clients:env.connections ~client ~current_errors ~current_warnings
      in
      Lwt.return (IdeResponse (Ok ({ env with connections = new_connections }, None)))

  | Autocomplete (file_input, id) ->
      let env = ref env in
      let%lwt results, json_data = autocomplete ~options ~workers ~env ~profiling file_input in
      let wrapped = AutocompleteResult (results, id) in
      Persistent_connection.send_message wrapped client;
      Lwt.return (IdeResponse (Ok (!env, json_data)))

  | DidOpen filenames ->
    Persistent_connection.send_message Persistent_connection_prot.DidOpenAck client;
    let files = Nel.map (fun fn -> (fn, "%%Legacy IDE has no content")) filenames in
    let%lwt env = did_open genv env client files in
    Lwt.return (IdeResponse (Ok (env, None)))

  | LspToServer (NotificationMessage (DidOpenNotification params), metadata) ->
    let open Lsp.DidOpen in
    let open TextDocumentItem in
    let content = params.textDocument.text in
    let fn = params.textDocument.uri |> Lsp_helpers.lsp_uri_to_path in
    let%lwt env = did_open genv env client (Nel.one (fn, content)) in
    Lwt.return (LspResponse (Ok (env, None, metadata)))

  | LspToServer (NotificationMessage (DidChangeNotification params), metadata) ->
    let open Lsp.DidChange in
    let open VersionedTextDocumentIdentifier in
    let open Persistent_connection in
    let fn = params.textDocument.uri |> Lsp_helpers.lsp_uri_to_path in
    begin match client_did_change env.connections client fn params.contentChanges with
      | Ok (connections, _client) ->
        Lwt.return (LspResponse (Ok ({ env with connections; }, None, metadata)))
      | Error (reason, stack) ->
        Lwt.return (LspResponse (Error (env, with_error metadata ~reason ~stack)))
    end

  | LspToServer (NotificationMessage (DidSaveNotification _params), metadata) ->
    Lwt.return (LspResponse (Ok (env, None, metadata)))

  | Persistent_connection_prot.DidClose filenames ->
    Persistent_connection.send_message Persistent_connection_prot.DidCloseAck client;
    let%lwt env = did_close genv env client filenames in
    Lwt.return (IdeResponse (Ok (env, None)))

  | LspToServer (NotificationMessage (DidCloseNotification params), metadata) ->
    let open Lsp.DidClose in
    let open TextDocumentIdentifier in
    let fn = params.textDocument.uri |> Lsp_helpers.lsp_uri_to_path in
    let%lwt env = did_close genv env client (Nel.one fn) in
    Lwt.return (LspResponse (Ok (env, None, metadata)))

  | LspToServer (RequestMessage (id, DefinitionRequest params), metadata) ->
    let env = ref env in
    let open TextDocumentPositionParams in
    let (file, line, char) = Flow_lsp_conversions.lsp_DocumentPosition_to_flow params ~client in
    let%lwt (result, extra_data) =
      get_def ~options ~workers ~env ~profiling (file, line, char) in
    let metadata = with_data ~extra_data metadata in
    begin match result with
      | Ok loc ->
        let default_uri = params.textDocument.TextDocumentIdentifier.uri in
        let location = Flow_lsp_conversions.loc_to_lsp_with_default ~default_uri loc in
        let definition_location = { Lsp.DefinitionLocation.location; title = None } in
        let response = ResponseMessage (id, DefinitionResult [definition_location]) in
        Lwt.return (LspResponse (Ok (!env, Some response, metadata)))
      | Error reason ->
        Lwt.return (LspResponse (Error (!env, with_error metadata ~reason)))
    end

  | LspToServer (RequestMessage (id, HoverRequest params), metadata) ->
    let open TextDocumentPositionParams in
    let env = ref env in
    let (file, line, char) = Flow_lsp_conversions.lsp_DocumentPosition_to_flow params ~client in
    let verbose = None in (* if Some, would write to server logs *)
    let%lwt result, extra_data =
      infer_type ~options ~workers ~env ~profiling (file, line, char, verbose, false)
    in
    let metadata = with_data ~extra_data metadata in
    begin match result with
      | Ok (loc, content) ->
        (* loc may be the 'none' location; content may be None. *)
        (* If both are none then we'll return null; otherwise we'll return a hover *)
        let default_uri = params.textDocument.TextDocumentIdentifier.uri in
        let location = Flow_lsp_conversions.loc_to_lsp_with_default ~default_uri loc in
        let range = if loc = Loc.none then None else Some location.Lsp.Location.range in
        let contents = match content with
          | None -> [MarkedString "?"]
          | Some content -> [MarkedCode ("flow", Ty_printer.string_of_t content)] in
        let r = match range, content with
          | None, None -> None
          | _, _ -> Some {Lsp.Hover.contents; range;} in
        let response = ResponseMessage (id, HoverResult r) in
        Lwt.return (LspResponse (Ok (!env, Some response, metadata)))
      | Error reason ->
        Lwt.return (LspResponse (Error (!env, with_error metadata ~reason)))
    end

  | LspToServer (RequestMessage (id, CompletionRequest params), metadata) ->
    let env = ref env in
    let open Completion in
    let (file, line, char) = Flow_lsp_conversions.lsp_DocumentPosition_to_flow params.loc ~client in
    let fn_content = match file with
      | File_input.FileContent (fn, content) ->
        Ok (fn, content)
      | File_input.FileName fn ->
        try
          Ok (Some fn, Sys_utils.cat fn)
        with e ->
          let stack = Printexc.get_backtrace () in
          Error (Printexc.to_string e, Utils.Callstack stack)
    in
    begin match fn_content with
      | Error (reason, stack) ->
        Lwt.return (LspResponse (Error (!env, with_error metadata ~reason ~stack)))
      | Ok (fn, content) ->
        let content_with_token = AutocompleteService_js.add_autocomplete_token content line char in
        let file_with_token = File_input.FileContent (fn, content_with_token) in
        let%lwt result, extra_data =
          autocomplete ~options ~workers ~env ~profiling file_with_token
        in
        let metadata = with_data ~extra_data metadata in
        begin match result with
          | Ok items ->
            let items = List.map Flow_lsp_conversions.flow_completion_to_lsp items in
            let r = CompletionResult { Lsp.Completion.isIncomplete = false; items; } in
            let response = ResponseMessage (id, r) in
            Lwt.return (LspResponse (Ok (!env, Some response, metadata)))
          | Error reason ->
            Lwt.return (LspResponse (Error (!env, with_error metadata ~reason)))
        end
    end

  | LspToServer (RequestMessage (id, DocumentHighlightRequest params), metadata) ->
    let env = ref env in
    let (file, line, char) = Flow_lsp_conversions.lsp_DocumentPosition_to_flow params ~client in
    let global, multi_hop = false, false in (* multi_hop implies global *)
    let%lwt result, extra_data =
      find_refs ~genv ~env ~profiling (file, line, char, global, multi_hop)
    in
    let metadata = with_data ~extra_data metadata in
    begin match result with
      | Ok (Some (_name, locs)) ->
        (* All the locs are implicitly in the same file, because global=false. *)
        let loc_to_highlight loc = { DocumentHighlight.
          range = Flow_lsp_conversions.loc_to_lsp_range loc;
          kind = Some DocumentHighlight.Text;
        } in
        let r = DocumentHighlightResult (List.map loc_to_highlight locs) in
        let response = ResponseMessage (id, r) in
        Lwt.return (LspResponse (Ok (!env, Some response, metadata)))
      | Ok (None) ->
        (* e.g. if it was requested on a place that's not even an identifier *)
        let r = DocumentHighlightResult [] in
        let response = ResponseMessage (id, r) in
        Lwt.return (LspResponse (Ok (!env, Some response, metadata)))
      | Error reason ->
        Lwt.return (LspResponse (Error (!env, with_error metadata ~reason)))
    end

  | LspToServer (RequestMessage (id, TypeCoverageRequest params), metadata) ->
    let env = ref env in
    let textDocument = params.TypeCoverage.textDocument in
    let file = Flow_lsp_conversions.lsp_DocumentIdentifier_to_flow ~client textDocument in
    (* if it isn't a flow file (i.e. lacks a @flow directive) then we won't do anything *)
    let fkey = File_key.SourceFile (File_input.filename_of_file_input file) in
    let content = File_input.content_of_file_input file in
    let is_flow = match content with
      | Ok content ->
        let (_, docblock) = Parsing_service_js.(parse_docblock docblock_max_tokens fkey content) in
        Docblock.is_flow docblock
      | Error _ -> false in
    let%lwt result = if is_flow then
      let force = false in (* 'true' makes it report "unknown" for all exprs in non-flow files *)
      coverage ~options ~workers ~env ~profiling ~force file
    else
      Lwt.return (Ok [])
    in
    begin match is_flow, result with
      | false, _ ->
        let range = {start={line=0; character=0;}; end_={line=1; character=0;};} in
        let r = TypeCoverageResult { TypeCoverage.
          coveredPercent = 0;
          uncoveredRanges = [{TypeCoverage.range; message=None;}];
          defaultMessage = "Use @flow to get type coverage for this file";
        } in
        let response = ResponseMessage (id, r) in
        Lwt.return (LspResponse (Ok (!env, Some response, metadata)))
      | true, Ok (all_locs) ->
        (* Figure out the percentages *)
        let accum_coverage (covered, total) (_loc, is_covered) =
          (covered + if is_covered then 1 else 0), total + 1 in
        let covered, total = Core_list.fold all_locs ~init:(0,0) ~f:accum_coverage in
        let coveredPercent = if total = 0 then 100 else 100 * covered / total in
        (* Figure out each individual uncovered span *)
        let uncovereds = Core_list.filter_map all_locs ~f:(fun (loc, is_covered) ->
          if is_covered then None else Some loc) in
        (* Imagine a tree of uncovered spans based on range inclusion. *)
        (* This sorted list is a pre-order flattening of that tree. *)
        let sorted = Core_list.sort uncovereds ~cmp:(fun a b -> Pervasives.compare
          (a.Loc.start.Loc.offset, a.Loc._end.Loc.offset)
          (b.Loc.start.Loc.offset, b.Loc._end.Loc.offset)) in
        (* We can use that sorted list to remove any span which contains another, so *)
        (* the user only sees actionable reports of the smallest causes of untypedness. *)
        (* The algorithm: accept a range if its immediate successor isn't contained by it. *)
        let f (candidate, acc) loc =
          if Loc.contains candidate loc then (loc, acc) else (loc, candidate :: acc) in
        let singles = match sorted with
          | [] -> []
          | (first::_) ->
            let (final_candidate, singles) = Core_list.fold sorted ~init:(first,[]) ~f in
            final_candidate :: singles in
        (* Convert to LSP *)
        let loc_to_lsp loc =
          { TypeCoverage.range=Flow_lsp_conversions.loc_to_lsp_range loc; message=None; } in
        let uncoveredRanges = Core_list.map singles ~f:loc_to_lsp in
        (* Send the results! *)
        let r = TypeCoverageResult { TypeCoverage.
          coveredPercent;
          uncoveredRanges;
          defaultMessage = "Un-type checked code. Consider adding type annotations.";
        } in
        let response = ResponseMessage (id, r) in
        Lwt.return (LspResponse (Ok (!env, Some response, metadata)))
      | true, Error reason ->
        Lwt.return (LspResponse (Error (!env, with_error metadata ~reason)))
    end

  | LspToServer (RequestMessage (id, FindReferencesRequest params), metadata) ->
    let open FindReferences in
    let env = ref env in
    let { loc; context = { includeDeclaration=_; includeIndirectReferences=multi_hop } } = params in
    (* TODO: respect includeDeclaration *)
    let (file, line, char) = Flow_lsp_conversions.lsp_DocumentPosition_to_flow loc ~client in
    let global = true in
    let%lwt result, extra_data =
      find_refs ~genv ~env ~profiling (file, line, char, global, multi_hop)
    in
    let metadata = with_data ~extra_data metadata in
    begin match result with
      | Ok (Some (_name, locs)) ->
        let lsp_locs = Core_list.fold locs ~init:(Ok []) ~f:(fun acc loc ->
          let location = Flow_lsp_conversions.loc_to_lsp loc in
          Core_result.combine location acc ~ok:List.cons ~err:(fun e _ -> e)) in
        begin match lsp_locs with
        | Ok lsp_locs ->
          let response = ResponseMessage (id, FindReferencesResult lsp_locs) in
          Lwt.return (LspResponse (Ok (!env, Some response, metadata)))
        | Error reason ->
          Lwt.return (LspResponse (Error (!env, with_error metadata ~reason)))
        end
      | Ok (None) ->
        (* e.g. if it was requested on a place that's not even an identifier *)
        let r = FindReferencesResult [] in
        let response = ResponseMessage (id, r) in
        Lwt.return (LspResponse (Ok (!env, Some response, metadata)))
      | Error reason ->
        Lwt.return (LspResponse (Error (!env, with_error metadata ~reason)))
    end

  | LspToServer (RequestMessage (id, RenameRequest params), metadata) ->
    let env = ref env in
    let { Rename.textDocument; position; newName } = params in
    let file_input = Flow_lsp_conversions.lsp_DocumentIdentifier_to_flow textDocument ~client in
    let (line, col) = Flow_lsp_conversions.lsp_position_to_flow position in
    let refactor_variant = ServerProt.Request.RENAME newName in
    let%lwt result =
      Refactor_js.refactor ~genv ~env ~profiling ~file_input ~line ~col ~refactor_variant
    in
    let edits_to_response (edits: (Loc.t * string) list) =
      (* Extract the path from each edit and convert into a map from file to edits for that file *)
      let file_to_edits: ((Loc.t * string) list SMap.t, string) result =
        List.fold_left begin fun map edit ->
          map >>= begin fun map ->
            let (loc, _) = edit in
            let uri = Flow_lsp_conversions.file_key_to_uri Loc.(loc.source) in
            uri >>| begin fun uri ->
              let lst = Option.value ~default:[] (SMap.get uri map) in
              (* This reverses the list *)
              SMap.add uri (edit::lst) map
            end
          end
        end (Ok SMap.empty) edits
        (* Reverse the lists to restore the original order *)
        >>| SMap.map (List.rev)
      in
      (* Convert all of the edits to LSP edits *)
      let file_to_textedits: (TextEdit.t list SMap.t, string) result =
        file_to_edits >>| SMap.map (List.map Flow_lsp_conversions.flow_edit_to_textedit)
      in
      let workspace_edit: (WorkspaceEdit.t, string) result =
        file_to_textedits >>| fun file_to_textedits ->
        { WorkspaceEdit.changes = file_to_textedits }
      in
      match workspace_edit with
        | Ok x ->
          let response = ResponseMessage (id, RenameResult x) in
          LspResponse (Ok (!env, Some response, metadata))
        | Error reason ->
          LspResponse (Error (!env, with_error metadata ~reason))
    in
    Lwt.return begin match result with
      | Ok (Some edits) -> edits_to_response edits
      | Ok None -> edits_to_response []
      | Error reason ->
        LspResponse (Error (!env, with_error metadata ~reason))
    end

  | LspToServer (RequestMessage (id, RageRequest), metadata) ->
    let root = Path.to_string genv.ServerEnv.options.Options.opt_root in
    let items = [] in
    (* genv: lazy-mode options *)
    let lazy_mode = genv.options.Options.opt_lazy_mode in
    let data = Printf.sprintf "lazy_mode=%s\n"
      (Option.value_map lazy_mode ~default:"None" ~f:Options.lazy_mode_to_string) in
    let items = { Lsp.Rage.title = None; data; } :: items in
    (* env: checked files *)
    let data = Printf.sprintf "%s\n\n%s\n"
      (CheckedSet.debug_counts_to_string env.checked_files)
      (CheckedSet.debug_to_string ~limit:200 env.checked_files) in
    let items = { Lsp.Rage.title = Some (root ^ ":env.checked_files"); data; } :: items in
    (* env: dependency graph *)
    let dependency_to_string (file, deps) =
      let file = File_key.to_string file in
      let deps = Utils_js.FilenameSet.elements deps
        |> List.map File_key.to_string
        |> ListUtils.first_upto_n 20 (fun t -> Some (Printf.sprintf " ...%d more" t))
        |> String.concat "," in
      file ^ ":" ^ deps ^ "\n" in
    let dependencies = Utils_js.FilenameMap.bindings env.ServerEnv.dependency_graph
      |> List.map dependency_to_string
      |> ListUtils.first_upto_n 200 (fun t -> Some (Printf.sprintf "[shown 200/%d]\n" t))
      |> String.concat "" in
    let data = "DEPENDENCIES:\n" ^ dependencies in
    let items = { Lsp.Rage.title = Some (root ^ ":env.dependencies"); data; } :: items in
    (* env: errors *)
    let errors, warnings, _ = ErrorCollator.get env in
    let json = Errors.Json_output.json_of_errors_with_context ~strip_root:None ~stdin_file:None
      ~suppressed_errors:[] ~errors ~warnings () in
    let data = "ERRORS:\n" ^ (Hh_json.json_to_multiline json) in
    let items = { Lsp.Rage.title = Some (root ^ ":env.errors"); data; } :: items in
    (* done! *)
    let response = ResponseMessage (id, RageResult items) in
    Lwt.return (LspResponse (Ok (env, Some response, metadata)))

  | LspToServer (unhandled, metadata) ->
    let reason = Printf.sprintf "not implemented: %s" (Lsp_fmt.message_name_to_string unhandled) in
    Lwt.return (LspResponse (Error (env, with_error metadata ~reason)))


let handle_persistent
    (genv: ServerEnv.genv)
    (env: ServerEnv.env)
    (client_id: Persistent_connection.Prot.client_id)
    (request: Persistent_connection_prot.request)
  : ServerEnv.env Lwt.t =
  let open Persistent_connection_prot in
  Hh_logger.debug "Persistent request: %s" (string_of_request request);
  MonitorRPC.status_update ~event:ServerStatus.Handling_request_start;

  match Persistent_connection.get_client env.connections client_id with
  | None ->
    Hh_logger.error "Unknown persistent client %d. Maybe connection went away?" client_id;
    Lwt.return env
  | Some client -> begin
    let client_context = Persistent_connection.get_logging_context client in
    let should_print_summary = Options.should_profile genv.options in
    let wall_start = Unix.gettimeofday () in

    let%lwt profiling, result = Profiling_js.with_profiling_lwt
      ~label:"Command" ~should_print_summary
      (fun profiling ->
        try%lwt
          handle_persistent_unsafe genv env client profiling request
        with e ->
          let stack = Utils.Callstack (Printexc.get_backtrace ()) in
          let reason = Printexc.to_string e in
          let error_info = (UnexpectedError, reason, stack) in
          begin match request with
            | LspToServer (_, metadata) ->
              Lwt.return (LspResponse (Error (env, {metadata with error_info=Some error_info})))
            | _ ->
              Lwt.return (IdeResponse (Error (env, error_info)))
          end)
    in

    (* we'll send this "Finishing_up" event only after sending the LSP response *)
    let event = ServerStatus.(Finishing_up {
      duration = Profiling_js.get_profiling_duration profiling;
      info = CommandSummary (string_of_request request)}) in

    let server_profiling = Some profiling in
    let server_logging_context = Some (FlowEventLogger.get_context ()) in

    match result with
    | LspResponse (Ok (env, lsp_response, metadata)) ->
      let metadata = {metadata with server_profiling; server_logging_context; } in
      let response = LspFromServer (lsp_response, metadata) in
      Persistent_connection.send_message response client;
      MonitorRPC.status_update ~event;
      Lwt.return env

    | LspResponse (Error (env, metadata)) ->
      let metadata = {metadata with server_profiling; server_logging_context; } in
      let (_, reason, Utils.Callstack stack) = Option.value_exn metadata.error_info in
      let e = Failure reason in
      let lsp_response = match request with
        | LspToServer (RequestMessage (id, _), _) ->
          Some (ResponseMessage (id, ErrorResult (e, stack)))
        | LspToServer _ ->
          let open LogMessage in
          let (code, reason, _original_data) = Lsp_fmt.get_error_info e in
          let text = (Printf.sprintf "%s [%i]\n%s" reason code stack) in
          Some (NotificationMessage (TelemetryNotification
            {type_=MessageType.ErrorMessage; message=text;}))
        | _ -> None in
      let response = LspFromServer (lsp_response, metadata) in
      Persistent_connection.send_message response client;
      MonitorRPC.status_update ~event;
      Lwt.return env

    | IdeResponse (Ok (env, extra_data)) ->
      let request = json_of_request request |> Hh_json.json_to_string in
      let extra_data = keyvals_of_json extra_data in
      FlowEventLogger.persistent_command_success
        ~server_logging_context:None ~extra_data
        ~persistent_context:None ~persistent_delay:None ~request ~client_context
        ~server_profiling ~client_duration:None ~wall_start ~error:None;
      MonitorRPC.status_update ~event;
      Lwt.return env

    | IdeResponse (Error (env, (ExpectedError, reason, stack))) ->
      let request = json_of_request request |> Hh_json.json_to_string in
      FlowEventLogger.persistent_command_success
        ~server_logging_context:None ~extra_data:[]
        ~persistent_context:None ~persistent_delay:None ~request ~client_context
        ~server_profiling ~client_duration:None ~wall_start ~error:(Some (reason, stack));
      MonitorRPC.status_update ~event;
      Lwt.return env

    | IdeResponse (Error (env, (UnexpectedError, reason, stack))) ->
      let request = json_of_request request |> Hh_json.json_to_string in
      FlowEventLogger.persistent_command_failure
        ~server_logging_context:None ~extra_data:[]
        ~persistent_context:None ~persistent_delay:None ~request ~client_context
        ~server_profiling ~client_duration:None ~wall_start ~error:(reason, stack);
      Hh_logger.error "Uncaught exception handling persistent request (%s): %s" request reason;
      MonitorRPC.status_update ~event;
      Lwt.return env
  end
