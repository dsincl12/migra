
open Lwt.Infix

(* Reference Logging so it is linked in and its load-time logger setup runs.
   setup is idempotent (it no-ops if a reporter is already installed). *)
let () = Logging.setup ()

type config = {
  database_url : string;
  migrations_dir : string;
  verbose : bool;
  table : string;
}

(** Build a {!config}, defaulting [migrations_dir] to "migrations", [verbose] to
    false, and [table] to "schema_migrations". Preferred over the record literal. *)
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
    (f : Dialect.t -> Types.db_conn -> ('a, Types.error) Lwt_result.t)
    : ('a, Types.error) Lwt_result.t =
  match Runner.validate_table_name table with
  | Error err -> Lwt.return_error err
  | Ok () ->
  match Dialect.detect_from_url database_url with
  | Error msg -> Lwt.return_error (Types.DatabaseError (Types.UrlParseError msg))
  | Ok dialect ->
      Database.connect_db database_url >>= function
      | Error err -> Lwt.return_error err
      | Ok db ->
          let module Db = (val db : Caqti_lwt.CONNECTION) in
          Lwt.finalize
            (fun () ->
              Runner.ensure_migrations_table ~table dialect db >>= function
              | Error err ->
                  Lwt.return_error
                    (Types.of_caqti_error ~context:"ensure schema_migrations table" err)
              | Ok () -> f dialect db)
            (fun () -> Db.disconnect ())

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

let timed (op : Migration.t -> Runner.execution_result Lwt.t) (migration : Migration.t) : migration_result Lwt.t =
  let start_time = Unix.gettimeofday () in
  op migration >>= fun result ->
  Lwt.return (to_migration_result result (Unix.gettimeofday () -. start_time))

let run_migration_timed ?(verbose = false) ?(table = Runner.default_table) db =
  timed (Runner.run_migration ~verbose ~table db)

let rollback_migration_timed ?(verbose = false) ?(table = Runner.default_table) db =
  timed (Runner.rollback_migration ~verbose ~table db)

(** Run multiple migrations, stopping on first failure.
    Same sequential engine as Runner, with the timed result as the step. *)
let run_migrations_internal ?(verbose = false) ?(table = Runner.default_table) db migrations : migration_result list Lwt.t =
  Runner.run_until_failure
    ~step:(run_migration_timed ~verbose ~table db)
    ~is_ok:(fun r -> r.success)
    migrations

let rollback_migrations_internal ?(verbose = false) ?(table = Runner.default_table) db migrations : migration_result list Lwt.t =
  let sorted = List.sort (fun a b ->
    Int64.compare b.Migration.version a.Migration.version) migrations in
  Runner.run_until_failure
    ~step:(rollback_migration_timed ~verbose ~table db)
    ~is_ok:(fun r -> r.success)
    sorted

let make_operation_result (results : migration_result list) : operation_result =
  let success_count = List.filter (fun r -> r.success) results |> List.length in
  let failure_count = List.filter (fun r -> not r.success) results |> List.length in
  { migrations = results; success_count; failure_count }

let run (config : config) =
  with_initialized_db ~table:config.table config.database_url (fun _dialect db ->
    (* Refuse to migrate if an already-applied migration was modified or its
       file went missing. *)
    Runner.validate ~table:config.table ~migrations_dir:config.migrations_dir db >>= function
    | Error err -> Lwt.return_error err
    | Ok () ->
        Runner.pending_migrations ~table:config.table ~migrations_dir:config.migrations_dir db >>= function
        | Error err -> Lwt.return_error err
        | Ok pending ->
            run_migrations_internal ~verbose:config.verbose ~table:config.table db pending >>= fun results ->
            Lwt.return_ok (make_operation_result results)
  )

let rollback (config : config) strategy =
  with_initialized_db ~table:config.table config.database_url (fun _dialect db ->
    Runner.rollback_targets ~table:config.table ~migrations_dir:config.migrations_dir db strategy >>= function
    | Error err -> Lwt.return_error err
    | Ok to_rollback ->
        rollback_migrations_internal ~verbose:config.verbose ~table:config.table db to_rollback >>= fun results ->
        Lwt.return_ok (make_operation_result results)
  )

let status (cfg : config) =
  with_initialized_db ~table:cfg.table cfg.database_url (fun dialect db ->
    Runner.get_applied_records ~table:cfg.table dialect db >>= function
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
