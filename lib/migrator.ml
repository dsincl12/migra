open Lwt.Infix
module Runner = Migra_engine.Runner
module Discovery = Migra_engine.Discovery
module Dialect = Migra_engine.Dialect
module Migration = Migra_engine.Migration

(* Reference Logging so it is linked in and its load-time logger setup runs.
   setup is idempotent (it no-ops if a reporter is already installed). *)
let () = Migra_engine.Logging.setup ()

type config = {
  database_url : string;
  migrations_dir : string;
  verbose : bool;
  table : string;
}

let default_table = Runner.default_table

(** Build a {!config}, defaulting [migrations_dir] to "migrations", [verbose] to
    false, and [table] to "schema_migrations". Preferred over the record
    literal. *)
let make ?(migrations_dir = Discovery.default_migrations_dir) ?(verbose = false)
    ?(table = Runner.default_table) ~database_url () : config =
  { database_url; migrations_dir; verbose; table }

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

let succeeded (r : operation_result) : bool = r.failure_count = 0

(** Progress events emitted by {!run}/{!rollback}/{!redo} via [?on_event],
    letting a caller (e.g. a CLI) report progress as each migration runs. *)
type event =
  | Applying of int64 * string
  | Applied of migration_result
  | Rolling_back of int64 * string
  | Rolled_back of migration_result

let no_event (_ : event) = Lwt.return_unit

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

(* Reuse Runner's strategy type so values pass straight to Runner.rollback_targets. *)
type rollback_strategy = Runner.rollback_strategy =
  | Step of int
  | To of int64
  | All

(** Connect, ensure the schema_migrations table exists, then run [f] with the
    dialect and connection; the connection is always disconnected afterwards.

    Every failure that prevents running migrations - bad URL, connection
    failure, or table setup - is returned as a structured [Error], never raised
    and never stringified. [f]'s own result is propagated unchanged. *)
let with_initialized_db ~(table : string) database_url
    (f : Dialect.t -> Types.db_conn -> ('a, Types.error) Lwt_result.t) :
    ('a, Types.error) Lwt_result.t =
  match Runner.validate_table_name table with
  | Error err -> Lwt.return_error err
  | Ok () -> (
      match Dialect.detect_from_url database_url with
      | Error msg ->
          Lwt.return_error (Types.DatabaseError (Types.UrlParseError msg))
      | Ok dialect -> (
          Migra_engine.Database.connect_db database_url >>= function
          | Error err -> Lwt.return_error err
          | Ok db ->
              let module Db = (val db : Caqti_lwt.CONNECTION) in
              Lwt.finalize
                (fun () ->
                  Runner.ensure_migrations_table ~table dialect db >>= function
                  | Error err ->
                      Lwt.return_error
                        (Types.of_caqti_error
                           ~context:"ensure schema_migrations table" err)
                  | Ok () -> f dialect db)
                (fun () -> Db.disconnect ())))

let to_migration_result (runner_result : Runner.execution_result)
    (elapsed : float) : migration_result =
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

let timed (op : Migration.t -> Runner.execution_result Lwt.t)
    (migration : Migration.t) : migration_result Lwt.t =
  let start_time = Unix.gettimeofday () in
  op migration >>= fun result ->
  Lwt.return (to_migration_result result (Unix.gettimeofday () -. start_time))

let run_migration_timed ?(verbose = false) ?(table = Runner.default_table) db =
  timed (Runner.run_migration ~verbose ~table db)

let rollback_migration_timed ?(verbose = false) ?(table = Runner.default_table)
    db =
  timed (Runner.rollback_migration ~verbose ~table db)

(** Run multiple migrations, stopping on first failure. Same sequential engine
    as Runner, with the timed result as the step. *)
let run_migrations_internal ?(verbose = false) ?(table = Runner.default_table)
    ?(on_event = no_event) db migrations : migration_result list Lwt.t =
  Runner.run_until_failure
    ~step:(fun m ->
      on_event (Applying (m.Migration.version, m.Migration.description))
      >>= fun () ->
      run_migration_timed ~verbose ~table db m >>= fun result ->
      on_event (Applied result) >>= fun () -> Lwt.return result)
    ~is_ok:(fun r -> r.success)
    migrations

let rollback_migrations_internal ?(verbose = false)
    ?(table = Runner.default_table) ?(on_event = no_event) db migrations :
    migration_result list Lwt.t =
  let sorted =
    List.sort
      (fun a b -> Int64.compare b.Migration.version a.Migration.version)
      migrations
  in
  Runner.run_until_failure
    ~step:(fun m ->
      on_event (Rolling_back (m.Migration.version, m.Migration.description))
      >>= fun () ->
      rollback_migration_timed ~verbose ~table db m >>= fun result ->
      on_event (Rolled_back result) >>= fun () -> Lwt.return result)
    ~is_ok:(fun r -> r.success)
    sorted

let make_operation_result (results : migration_result list) : operation_result =
  let success_count = List.filter (fun r -> r.success) results |> List.length in
  let failure_count =
    List.filter (fun r -> not r.success) results |> List.length
  in
  { migrations = results; success_count; failure_count }

let run ?(on_event = no_event) (config : config) =
  with_initialized_db ~table:config.table config.database_url
    (fun _dialect db ->
      (* Refuse to migrate if an already-applied migration was modified or its
       file went missing. *)
      Runner.validate ~table:config.table ~migrations_dir:config.migrations_dir
        db
      >>= function
      | Error err -> Lwt.return_error err
      | Ok () -> (
          Runner.pending_migrations ~table:config.table
            ~migrations_dir:config.migrations_dir db
          >>= function
          | Error err -> Lwt.return_error err
          | Ok pending ->
              run_migrations_internal ~verbose:config.verbose
                ~table:config.table ~on_event db pending
              >>= fun results -> Lwt.return_ok (make_operation_result results)))

let run_or_error ?(on_event = no_event) (config : config) :
    (operation_result, Types.error) Lwt_result.t =
  run ~on_event config >>= function
  | Error _ as e -> Lwt.return e
  | Ok result when succeeded result -> Lwt.return_ok result
  | Ok result ->
      let failed =
        List.find_opt
          (fun (r : migration_result) -> not r.success)
          result.migrations
      in
      let err =
        match failed with
        | Some r ->
            Types.MigrationError
              (Types.ExecutionFailed
                 (r.version, Option.value ~default:"unknown error" r.error))
        | None -> Types.DiscoveryError "a migration failed"
      in
      Lwt.return_error err

let rollback ?(on_event = no_event) (config : config) strategy =
  with_initialized_db ~table:config.table config.database_url
    (fun _dialect db ->
      (* Refuse to roll back if an applied migration was modified or its file
       went missing: a modified file means the down SQL no longer matches what
       was applied, and a missing file is silently dropped by target selection
       otherwise. *)
      Runner.validate ~table:config.table ~migrations_dir:config.migrations_dir
        db
      >>= function
      | Error err -> Lwt.return_error err
      | Ok () -> (
          Runner.rollback_targets ~table:config.table
            ~migrations_dir:config.migrations_dir db strategy
          >>= function
          | Error err -> Lwt.return_error err
          | Ok to_rollback ->
              rollback_migrations_internal ~verbose:config.verbose
                ~table:config.table ~on_event db to_rollback
              >>= fun results -> Lwt.return_ok (make_operation_result results)))

let redo ?(on_event = no_event) ?(step = 1) (config : config) =
  with_initialized_db ~table:config.table config.database_url
    (fun _dialect db ->
      (* Same drift guard as rollback/run: redo rolls back then re-applies, so a
       modified or missing applied migration must stop it before either step. *)
      Runner.validate ~table:config.table ~migrations_dir:config.migrations_dir
        db
      >>= function
      | Error err -> Lwt.return_error err
      | Ok () -> (
          Runner.rollback_targets ~table:config.table
            ~migrations_dir:config.migrations_dir db (Runner.Step step)
          >>= function
          | Error err -> Lwt.return_error err
          | Ok targets -> (
              rollback_migrations_internal ~verbose:config.verbose
                ~table:config.table ~on_event db targets
              >>= fun rolled_back ->
              if List.exists (fun r -> not r.success) rolled_back then
                (* a rollback failed: report it rather than re-applying on a bad state *)
                Lwt.return_ok (make_operation_result rolled_back)
              else
                Runner.pending_migrations ~table:config.table
                  ~migrations_dir:config.migrations_dir db
                >>= function
                | Error err -> Lwt.return_error err
                | Ok pending ->
                    run_migrations_internal ~verbose:config.verbose
                      ~table:config.table ~on_event db pending
                    >>= fun results ->
                    Lwt.return_ok (make_operation_result results))))

let status (cfg : config) =
  with_initialized_db ~table:cfg.table cfg.database_url (fun dialect db ->
      Runner.get_applied_records ~table:cfg.table dialect db >>= function
      | Error err ->
          Lwt.return_error
            (Types.of_caqti_error ~context:"get applied migrations" err)
      | Ok applied_records -> (
          let applied_map =
            List.fold_left
              (fun acc record ->
                (record.Runner.version, record.Runner.created_at) :: acc)
              [] applied_records
          in
          let applied_set =
            Discovery.applied_set_of_list
              (List.map (fun r -> r.Runner.version) applied_records)
          in

          match Discovery.find_migrations ~dir:cfg.migrations_dir () with
          | Error err -> Lwt.return_error err
          | Ok migrations ->
              let on_disk_statuses =
                List.map
                  (fun m ->
                    let applied =
                      Discovery.Int64Set.mem m.Migration.version applied_set
                    in
                    let applied_at =
                      if applied then
                        List.assoc_opt m.Migration.version applied_map
                      else None
                    in
                    {
                      version = m.version;
                      description = m.description;
                      applied;
                      applied_at;
                    })
                  migrations
              in

              (* Surface drift: a row recorded as applied whose file is no longer
                 on disk would otherwise vanish from the status listing,
                 understating the applied count. Include it explicitly. *)
              let on_disk_versions =
                Discovery.applied_set_of_list
                  (List.map (fun m -> m.Migration.version) migrations)
              in
              let missing_file_statuses =
                List.filter_map
                  (fun record ->
                    if
                      Discovery.Int64Set.mem record.Runner.version
                        on_disk_versions
                    then None
                    else
                      Some
                        {
                          version = record.Runner.version;
                          description = "(migration file missing)";
                          applied = true;
                          applied_at =
                            List.assoc_opt record.Runner.version applied_map;
                        })
                  applied_records
              in

              let statuses =
                List.sort
                  (fun a b -> Int64.compare a.version b.version)
                  (on_disk_statuses @ missing_file_statuses)
              in

              let pending_count =
                List.filter (fun s -> not s.applied) statuses |> List.length
              in
              let applied_count =
                List.filter (fun s -> s.applied) statuses |> List.length
              in

              Lwt.return_ok
                {
                  database_url = cfg.database_url;
                  migrations = statuses;
                  pending_count;
                  applied_count;
                }))

(* version + description of each migration in a list, for dry-run plans *)
let to_plan ms =
  List.map (fun m -> (m.Migration.version, m.Migration.description)) ms

let pending_plan (config : config) =
  with_initialized_db ~table:config.table config.database_url
    (fun _dialect db ->
      Runner.pending_migrations ~table:config.table
        ~migrations_dir:config.migrations_dir db
      >|= Result.map to_plan)

let rollback_plan (config : config) strategy =
  with_initialized_db ~table:config.table config.database_url
    (fun _dialect db ->
      Runner.rollback_targets ~table:config.table
        ~migrations_dir:config.migrations_dir db strategy
      >|= Result.map to_plan)

let migration_template = "-- +migrate up\n\n\n-- +migrate down\n\n"

let generate ?(migrations_dir = Discovery.default_migrations_dir)
    (name : string) : (string, Types.error) result =
  match Discovery.ensure_migrations_dir ~dir:migrations_dir () with
  | Error err -> Error err
  | Ok () -> (
      let filename =
        Migration.make_filename (Migration.generate_version ()) name
      in
      let filepath = Filename.concat migrations_dir filename in
      if Sys.file_exists filepath then
        Error (Types.FileError (Types.AlreadyExists filepath))
      else
        try
          let oc = open_out filepath in
          output_string oc migration_template;
          close_out oc;
          Ok filepath
        with e -> Error (Types.FileError (Types.ReadError (filepath, e))))
