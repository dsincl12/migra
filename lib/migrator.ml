
open Lwt.Infix

(* Force loading of Logging module to auto-initialize logger *)
let () = ignore (Logging.setup)

type config = {
  database_url : string;
  migrations_dir : string;
  verbose : bool;
}

type migration_result = {
  version : int64;
  description : string;
  success : bool;
  error : string option;
  elapsed_seconds : float option;
}

type operation_result = {
  migrations : migration_result list;
  success_count : int;
  failure_count : int;
}

type migration_status = {
  version : int64;
  description : string;
  applied : bool;
  applied_at : string option;
}

type status_result = {
  database_url : string;
  migrations : migration_status list;
  pending_count : int;
  applied_count : int;
}

type rollback_strategy =
  | Step of int
  | To of int64
  | All

(** Connect to database, initialize schema, run function
    The callback function receives both the database connection and dialect *)
let with_initialized_db database_url f =
  match Dialect.detect_from_url database_url with
  | Error msg -> Lwt.fail_with msg
  | Ok dialect ->
      Database.with_db database_url (fun db ->
        Runner.ensure_migrations_table dialect db >>= function
        | Error err -> Lwt.fail_with (Caqti_error.show err)
        | Ok () ->
            f dialect db >>= function
            | Ok result -> Lwt.return result
            | Error err -> Lwt.fail_with (Types.show_error err)
      )

let to_migration_result (runner_result : Runner.execution_result) (elapsed : float) : migration_result =
  match runner_result with
  | Runner.Success migration ->
      {
        version = migration.version;
        description = migration.description;
        success = true;
        error = None;
        elapsed_seconds = Some elapsed;
      }
  | Runner.Failure (migration, err) ->
      {
        version = migration.version;
        description = migration.description;
        success = false;
        error = Some (Types.show_error err);
        elapsed_seconds = Some elapsed;
      }

let run_migration_timed ?(verbose = false) db (migration : Migration.t) : migration_result Lwt.t =
  let start_time = Unix.gettimeofday () in
  Runner.run_migration ~verbose db migration >>= fun result ->
  let elapsed = Unix.gettimeofday () -. start_time in
  Lwt.return (to_migration_result result elapsed)

let rollback_migration_timed ?(verbose = false) db (migration : Migration.t) : migration_result Lwt.t =
  let start_time = Unix.gettimeofday () in
  Runner.rollback_migration ~verbose db migration >>= fun result ->
  let elapsed = Unix.gettimeofday () -. start_time in
  Lwt.return (to_migration_result result elapsed)

let run_migrations_internal ?(verbose = false) db migrations : migration_result list Lwt.t =
  let rec run_all acc = function
    | [] -> Lwt.return (List.rev acc)
    | migration :: rest ->
        run_migration_timed ~verbose db migration >>= fun result ->
        if result.success then
          run_all (result :: acc) rest
        else
          Lwt.return (List.rev (result :: acc))
  in
  run_all [] migrations

let rollback_migrations_internal ?(verbose = false) db migrations : migration_result list Lwt.t =
  (* Sort in reverse chronological order *)
  let sorted = List.sort (fun a b ->
    Int64.compare b.Migration.version a.Migration.version) migrations in
  let rec rollback_all acc = function
    | [] -> Lwt.return (List.rev acc)
    | migration :: rest ->
        rollback_migration_timed ~verbose db migration >>= fun result ->
        if result.success then
          rollback_all (result :: acc) rest
        else
          Lwt.return (List.rev (result :: acc))
  in
  rollback_all [] sorted

let make_operation_result (results : migration_result list) : operation_result =
  let success_count = List.filter (fun r -> r.success) results |> List.length in
  let failure_count = List.filter (fun r -> not r.success) results |> List.length in
  { migrations = results; success_count; failure_count }

let run (config : config) =
  with_initialized_db config.database_url (fun _dialect db ->
    match Discovery.find_migrations ~dir:config.migrations_dir () with
    | Error err -> Lwt.return_error err
    | Ok all_migrations ->
        Runner.get_applied_versions db >>= function
        | Error err ->
            Lwt.return_error (Types.of_caqti_error ~context:"get applied versions" err)
        | Ok applied_versions ->
            let pending = Discovery.find_pending applied_versions all_migrations in
            if List.length pending = 0 then
              Lwt.return_ok (make_operation_result [])
            else
              run_migrations_internal ~verbose:config.verbose db pending >>= fun results ->
              Lwt.return_ok (make_operation_result results)
  )

let rollback (config : config) strategy =
  with_initialized_db config.database_url (fun _dialect db ->
    Runner.get_applied_versions db >>= function
    | Error err ->
        Lwt.return_error (Types.of_caqti_error ~context:"get applied versions" err)
    | Ok applied_versions ->
        if List.length applied_versions = 0 then
          Lwt.return_ok (make_operation_result [])
        else
          match Discovery.find_migrations ~dir:config.migrations_dir () with
          | Error err -> Lwt.return_error err
          | Ok all_migrations ->
              let applied_set = Discovery.applied_set_of_list applied_versions in
              let applied_migrations = List.filter
                (fun m -> Discovery.Int64Set.mem m.Migration.version applied_set)
                all_migrations in

              let to_rollback = match strategy with
                | All -> applied_migrations
                | To target ->
                    List.filter (fun m ->
                      Int64.compare m.Migration.version target > 0)
                      applied_migrations
                | Step n ->
                    let sorted = List.sort (fun a b ->
                      Int64.compare b.Migration.version a.Migration.version)
                      applied_migrations in
                    List.filteri (fun i _ -> i < n) sorted
              in

              if List.length to_rollback = 0 then
                Lwt.return_ok (make_operation_result [])
              else
                rollback_migrations_internal ~verbose:config.verbose db to_rollback >>= fun results ->
                Lwt.return_ok (make_operation_result results)
  )

let status (cfg : config) =
  with_initialized_db cfg.database_url (fun dialect db ->
    Runner.get_applied_records dialect db >>= function
    | Error err ->
        Lwt.return_error (Types.of_caqti_error ~context:"get applied migrations" err)
    | Ok applied_records ->
        let applied_map = List.fold_left
          (fun acc record -> (record.Runner.version, record.Runner.created_at) :: acc)
          [] applied_records in
        let applied_set = Discovery.applied_set_of_list
          (List.map (fun r -> r.Runner.version) applied_records) in

        match Discovery.find_migrations ~dir:cfg.migrations_dir () with
        | Error err -> Lwt.return_error err
        | Ok migrations ->
            let statuses = List.map (fun m ->
              let applied = Discovery.Int64Set.mem m.Migration.version applied_set in
              let applied_at =
                if applied then
                  List.assoc_opt m.Migration.version applied_map
                else
                  None
              in
              { version = m.version;
                description = m.description;
                applied;
                applied_at }
            ) migrations in

            let pending_count = List.filter (fun s -> not s.applied) statuses |> List.length in
            let applied_count = List.filter (fun s -> s.applied) statuses |> List.length in

            Lwt.return_ok {
              database_url = cfg.database_url;
              migrations = statuses;
              pending_count;
              applied_count;
            }
  )
