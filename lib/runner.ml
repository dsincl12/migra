(** Migration execution engine with transaction support. *)

open Caqti_request.Infix
open Caqti_type.Std

type execution_result =
  | Success of Migration.t
  | Failure of Migration.t * Types.error

let is_success = function
  | Success _ -> true
  | Failure _ -> false

let migration_of_result = function
  | Success m -> m
  | Failure (m, _) -> m

let error_of_result = function
  | Success _ -> None
  | Failure (_, err) -> Some err

let log_verbose verbose msg =
  if verbose then
    Lwt_io.eprintlf "[VERBOSE] %s" msg
  else
    Lwt.return_unit

(** {1 Schema Migrations Table Management}

    Internal functions for managing the [schema_migrations] table,
    which tracks which migrations have been applied to the database.

    {2 Database Schema}

    The [schema_migrations] table has the following structure:
    {v
      CREATE TABLE schema_migrations (
        version BIGINT PRIMARY KEY,
        created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
      )
    v}

    - [version]: 14-digit timestamp (YYYYMMDDHHMMSS) identifying the migration
    - [created_at]: Timestamp when the migration was applied

    {2 Transaction Safety}

    These operations should always be called within transactions
    to ensure atomicity between SQL execution and version recording.
*)

open Lwt.Infix

type migration_record = {
  version : int64;
  created_at : string;
}

let create_table_query =
  (unit ->. unit)
  {sql|
    CREATE TABLE IF NOT EXISTS schema_migrations (
      version BIGINT PRIMARY KEY,
      created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  |sql}

let migration_exists_query =
  (int64 ->? int64)
  {sql|
    SELECT version FROM schema_migrations WHERE version = ?
  |sql}

let get_all_versions_query =
  (unit ->* int64)
  {sql|
    SELECT version FROM schema_migrations ORDER BY version ASC
  |sql}

let get_all_records_query =
  (unit ->* t2 int64 string)
  {sql|
    SELECT version, created_at::text FROM schema_migrations ORDER BY version ASC
  |sql}

let insert_migration_query =
  (int64 ->. unit)
  {sql|
    INSERT INTO schema_migrations (version) VALUES (?)
  |sql}

let delete_migration_query =
  (int64 ->. unit)
  {sql|
    DELETE FROM schema_migrations WHERE version = ?
  |sql}

let get_latest_version_query =
  (unit ->? int64)
  {sql|
    SELECT version FROM schema_migrations ORDER BY version DESC LIMIT 1
  |sql}

let ensure_migrations_table (db : Types.db_conn) : (unit, [> Caqti_error.t]) Lwt_result.t =
  let module Db = (val db : Caqti_lwt.CONNECTION) in
  Db.exec create_table_query ()

let is_applied (db : Types.db_conn) (version : int64) : (bool, [> Caqti_error.t]) Lwt_result.t =
  let module Db = (val db : Caqti_lwt.CONNECTION) in
  Db.find_opt migration_exists_query version >|= function
  | Ok (Some _) -> Ok true
  | Ok None -> Ok false
  | Error e -> Error e

let get_applied_versions (db : Types.db_conn) : (int64 list, [> Caqti_error.t]) Lwt_result.t =
  let module Db = (val db : Caqti_lwt.CONNECTION) in
  Db.collect_list get_all_versions_query ()

let get_applied_records (db : Types.db_conn) : (migration_record list, [> Caqti_error.t]) Lwt_result.t =
  let module Db = (val db : Caqti_lwt.CONNECTION) in
  let open Lwt.Infix in
  Db.collect_list get_all_records_query () >|= function
  | Ok rows ->
      Ok (List.map (fun (version, created_at) -> { version; created_at }) rows)
  | Error e -> Error e

let add_migration (db : Types.db_conn) (version : int64) : (unit, [> Caqti_error.t]) Lwt_result.t =
  let module Db = (val db : Caqti_lwt.CONNECTION) in
  Db.exec insert_migration_query version

let remove_migration (db : Types.db_conn) (version : int64) : (unit, [> Caqti_error.t]) Lwt_result.t =
  let module Db = (val db : Caqti_lwt.CONNECTION) in
  Db.exec delete_migration_query version

let get_latest_version (db : Types.db_conn) : (int64 option, [> Caqti_error.t]) Lwt_result.t =
  let module Db = (val db : Caqti_lwt.CONNECTION) in
  Db.find_opt get_latest_version_query ()

(** Execute raw SQL within a connection
    Handles multi-statement SQL by splitting and executing each statement
*)
let execute_sql ?(verbose = false) (db : Types.db_conn) (sql : string) : (unit, [> Caqti_error.t]) Lwt_result.t =
  let module Db = (val db : Caqti_lwt.CONNECTION) in
  let open Lwt.Infix in

  (* Split SQL into individual statements *)
  let statements = Sql_parser.split_sql sql in

  (* Execute each statement *)
  let rec exec_all = function
    | [] -> Lwt_result.return ()
    | stmt :: rest ->
        log_verbose verbose (Printf.sprintf "Executing SQL: %s" (String.sub stmt 0 (min 60 (String.length stmt)) ^ (if String.length stmt > 60 then "..." else ""))) >>= fun () ->
        let query = (unit ->. unit) ~oneshot:true stmt in
        Db.exec query () >>= fun result ->
        match result with
        | Error e -> Lwt.return_error e
        | Ok () -> exec_all rest
  in
  exec_all statements

(** Execute a single migration within a transaction
    On success: SQL is executed and version is recorded
    On failure: transaction rolls back, nothing is recorded
*)
let run_migration ?(verbose = false) (db : Types.db_conn) (migration : Migration.t) : execution_result Lwt.t =
  (* Read the up SQL content from the migration file *)
  (* Note: File read errors return immediately WITHOUT starting a transaction.
     SQL execution errors occur WITHIN a transaction and trigger rollback. *)
  match Migration.read_up_sql migration with
  | Error err ->
      (* File read error - return immediately without touching DB *)
      Lwt.return (Failure (migration, err))
  | Ok sql_content ->
      (* Execute within a transaction *)
      let module Db = (val db : Caqti_lwt.CONNECTION) in
      let open Lwt.Syntax in

      (* Helper to convert Caqti errors and rollback *)
      let fail_with_rollback context e =
        let* () = log_verbose verbose (Printf.sprintf "Rolling back transaction: %s" context) in
        let* _ = Db.rollback () in
        let err = Types.of_caqti_error ~context e in
        Lwt.return (Failure (migration, err))
      in

      (* Use monadic bind to flatten nested matching *)
      let* () = log_verbose verbose (Printf.sprintf "Starting migration %Ld" migration.Migration.version) in
      let* start_result = Db.start () in
      match start_result with
      | Error e -> fail_with_rollback "start transaction" e
      | Ok () ->
          let* () = log_verbose verbose "Executing migration SQL" in
          let* sql_result = execute_sql ~verbose db sql_content in
          match sql_result with
          | Error e -> fail_with_rollback "execute migration SQL" e
          | Ok () ->
              let* () = log_verbose verbose (Printf.sprintf "Recording migration version %Ld in schema_migrations" migration.Migration.version) in
              let* add_result = add_migration db migration.Migration.version in
              match add_result with
              | Error e -> fail_with_rollback "record migration" e
              | Ok () ->
                  let* () = log_verbose verbose "Committing transaction" in
                  let* commit_result = Db.commit () in
                  match commit_result with
                  | Error e -> fail_with_rollback "commit transaction" e
                  | Ok () ->
                      let* () = log_verbose verbose (Printf.sprintf "Migration %Ld completed successfully" migration.Migration.version) in
                      Lwt.return (Success migration)

(** Rollback a single migration within a transaction
    On success: down SQL is executed and version is removed from schema_migrations
    On failure: transaction rolls back, nothing is changed
*)
let rollback_migration ?(verbose = false) (db : Types.db_conn) (migration : Migration.t) : execution_result Lwt.t =
  (* Read the down SQL content from the migration file *)
  match Migration.read_down_sql migration with
  | Error err ->
      (* File read error or missing down section - return immediately *)
      Lwt.return (Failure (migration, err))
  | Ok sql_content ->
      (* Execute within a transaction *)
      let module Db = (val db : Caqti_lwt.CONNECTION) in
      let open Lwt.Syntax in

      (* Helper to convert Caqti errors and rollback *)
      let fail_with_rollback context e =
        let* () = log_verbose verbose (Printf.sprintf "Rolling back transaction: %s" context) in
        let* _ = Db.rollback () in
        let err = Types.of_caqti_error ~context e in
        Lwt.return (Failure (migration, err))
      in

      (* Use monadic bind to flatten nested matching *)
      let* () = log_verbose verbose (Printf.sprintf "Starting rollback of migration %Ld" migration.Migration.version) in
      let* start_result = Db.start () in
      match start_result with
      | Error e -> fail_with_rollback "start transaction" e
      | Ok () ->
          let* () = log_verbose verbose "Executing rollback SQL" in
          let* sql_result = execute_sql ~verbose db sql_content in
          match sql_result with
          | Error e -> fail_with_rollback "execute rollback SQL" e
          | Ok () ->
              let* () = log_verbose verbose (Printf.sprintf "Removing migration version %Ld from schema_migrations" migration.Migration.version) in
              let* remove_result = remove_migration db migration.Migration.version in
              match remove_result with
              | Error e -> fail_with_rollback "remove migration record" e
              | Ok () ->
                  let* () = log_verbose verbose "Committing transaction" in
                  let* commit_result = Db.commit () in
                  match commit_result with
                  | Error e -> fail_with_rollback "commit transaction" e
                  | Ok () ->
                      let* () = log_verbose verbose (Printf.sprintf "Rollback of migration %Ld completed successfully" migration.Migration.version) in
                      Lwt.return (Success migration)

(** Execute multiple migrations in order
    Stops at the first failure and returns all results
*)
let run_migrations ?(verbose = false) (db : Types.db_conn) (migrations : Migration.t list) : execution_result list Lwt.t =
  let open Lwt.Syntax in

  let rec run_all acc = function
    | [] -> Lwt.return (List.rev acc)
    | migration :: rest ->
        let* result = run_migration ~verbose db migration in
        (match result with
         | Success _ ->
             run_all (result :: acc) rest
         | Failure _ ->
             (* Stop on first failure *)
             Lwt.return (List.rev (result :: acc)))
  in

  run_all [] migrations

(** Run all pending migrations
    1. Discovers all migration files
    2. Gets applied versions from database
    3. Identifies pending migrations
    4. Executes pending migrations in order
*)
let run_pending ?(verbose = false) (db : Types.db_conn) (migrations_dir : string)
    : (execution_result list, Types.error) Lwt_result.t =
  let open Lwt.Infix in

  (* Discover all migration files *)
  match Discovery.find_migrations ~dir:migrations_dir () with
  | Error err -> Lwt.return_error err
  | Ok all_migrations ->
      (* Get applied versions from database *)
      get_applied_versions db >>= function
      | Error caqti_err ->
          Lwt.return_error (Types.of_caqti_error ~context:"get applied versions" caqti_err)
      | Ok applied_versions ->
          (* Find pending migrations *)
          let pending = Discovery.find_pending applied_versions all_migrations in

          (* Execute pending migrations *)
          run_migrations ~verbose db pending >|= fun results ->
          Ok results

(** Rollback multiple migrations in reverse chronological order
    Stops at the first failure and returns all results
*)
let rollback_migrations ?(verbose = false) (db : Types.db_conn) (migrations : Migration.t list) : execution_result list Lwt.t =
  let open Lwt.Syntax in

  (* Sort migrations in reverse chronological order (newest first) *)
  let sorted = List.sort (fun a b -> Int64.compare b.Migration.version a.Migration.version) migrations in

  let rec rollback_all acc = function
    | [] -> Lwt.return (List.rev acc)
    | migration :: rest ->
        let* result = rollback_migration ~verbose db migration in
        (match result with
         | Success _ ->
             rollback_all (result :: acc) rest
         | Failure _ ->
             (* Stop on first failure *)
             Lwt.return (List.rev (result :: acc)))
  in

  rollback_all [] sorted

(** Rollback the last N migrations
    1. Gets applied versions from database
    2. Finds the N most recent migrations
    3. Rolls them back in reverse chronological order
*)
let rollback_step ?(verbose = false) ?(migrations_dir = Discovery.default_migrations_dir) (db : Types.db_conn) (step : int)
    : (execution_result list, Types.error) Lwt_result.t =
  let open Lwt.Infix in

  if step <= 0 then
    Lwt.return_error (Types.DatabaseError (Types.ParseError "Step must be a positive number"))
  else
    (* Get applied versions from database *)
    get_applied_versions db >>= function
    | Error caqti_err ->
        Lwt.return_error (Types.of_caqti_error ~context:"Failed to get applied versions" caqti_err)
    | Ok [] -> Lwt.return_ok []
    | Ok applied_versions ->
        (* Discover all migration files *)
        match Discovery.find_migrations ~dir:migrations_dir () with
        | Error err -> Lwt.return_error err
        | Ok all_migrations ->
            (* Filter to only applied migrations *)
            let applied_set = List.fold_left
              (fun set v -> Discovery.Int64Set.add v set)
              Discovery.Int64Set.empty
              applied_versions
              in
              let applied_migrations = List.filter
                (fun m -> Discovery.Int64Set.mem m.Migration.version applied_set)
                all_migrations
              in

              (* Sort in reverse chronological order and take N *)
              let sorted = List.sort (fun a b -> Int64.compare b.Migration.version a.Migration.version) applied_migrations in
              let to_rollback = List.filteri (fun i _ -> i < step) sorted in

              (* Rollback migrations *)
              rollback_migrations ~verbose db to_rollback >|= fun results ->
              Ok results

(** Rollback to a specific version (exclusive)
    Rolls back all migrations newer than the specified version
*)
let rollback_to ?(verbose = false) ?(migrations_dir = Discovery.default_migrations_dir) (db : Types.db_conn) (target_version : int64)
    : (execution_result list, Types.error) Lwt_result.t =
  let open Lwt.Infix in

  (* Get applied versions from database *)
  get_applied_versions db >>= function
  | Error caqti_err ->
      Lwt.return_error (Types.of_caqti_error ~context:"Failed to get applied versions" caqti_err)
  | Ok applied_versions ->
      (* Discover all migration files *)
      match Discovery.find_migrations ~dir:migrations_dir () with
      | Error err -> Lwt.return_error err
      | Ok all_migrations ->
          (* Filter to only applied migrations newer than target *)
          let applied_set = List.fold_left
            (fun set v -> Discovery.Int64Set.add v set)
            Discovery.Int64Set.empty
            applied_versions
          in
          let to_rollback = List.filter
            (fun m ->
              Discovery.Int64Set.mem m.Migration.version applied_set &&
              Int64.compare m.Migration.version target_version > 0)
            all_migrations
          in

          match to_rollback with
          | [] -> Lwt.return_ok []
          | _ ->
              (* Rollback migrations *)
              rollback_migrations ~verbose db to_rollback >|= fun results ->
              Ok results

let rollback_all ?(verbose = false) ?(migrations_dir = Discovery.default_migrations_dir) (db : Types.db_conn)
    : (execution_result list, Types.error) Lwt_result.t =
  let open Lwt.Infix in

  (* Get applied versions from database *)
  get_applied_versions db >>= function
  | Error caqti_err ->
      Lwt.return_error (Types.of_caqti_error ~context:"Failed to get applied versions" caqti_err)
  | Ok [] -> Lwt.return_ok []
  | Ok applied_versions ->
      (* Discover all migration files *)
      match Discovery.find_migrations ~dir:migrations_dir () with
      | Error err -> Lwt.return_error err
      | Ok all_migrations ->
          (* Filter to only applied migrations *)
          let applied_set = List.fold_left
            (fun set v -> Discovery.Int64Set.add v set)
            Discovery.Int64Set.empty
            applied_versions
          in
          let applied_migrations = List.filter
            (fun m -> Discovery.Int64Set.mem m.Migration.version applied_set)
            all_migrations
          in

          (* Rollback all migrations *)
          rollback_migrations ~verbose db applied_migrations >|= fun results ->
          Ok results
