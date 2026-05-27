(** Migration execution engine with transaction support. *)

open Lwt.Infix
open Caqti_request.Infix
open Caqti_type.Std

let src = Logs.Src.create "migra.runner" ~doc:"Migration runner"
module Log = (val Logs.src_log src : Logs.LOG)

type migration_record = {
  version : int64;
  created_at : string;
}

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
    Logs_lwt.info (fun m -> m "%s" msg)
  else
    Lwt.return_unit

(** {1 SQL Queries}

    Prepared Caqti queries for schema_migrations table operations.
*)

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

let get_all_records_query (dialect : Dialect.t) =
  let module D = (val Dialect.get_dialect dialect : Dialect.DIALECT) in
  let timestamp_expr = D.timestamp_to_string "created_at" in
  let sql = Printf.sprintf
    "SELECT version, %s FROM schema_migrations ORDER BY version ASC"
    timestamp_expr
  in
  (unit ->* t2 int64 string) sql

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

(** {1 Schema Migrations Table Management}

    Functions for managing the [schema_migrations] table,
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

let ensure_migrations_table (dialect : Dialect.t) (db : Types.db_conn) : (unit, [> Caqti_error.t]) Lwt_result.t =
  let module Db = (val db : Caqti_lwt.CONNECTION) in
  let module D = (val Dialect.get_dialect dialect : Dialect.DIALECT) in

  let ddl = match D.schema_migrations_ddl with
    | Some custom_ddl -> custom_ddl
    | None -> {sql|
        CREATE TABLE IF NOT EXISTS schema_migrations (
          version BIGINT PRIMARY KEY,
          created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
        )
      |sql}
  in

  let query = (unit ->. unit) ddl in
  Db.exec query ()

let is_applied (db : Types.db_conn) (version : int64) : (bool, [> Caqti_error.t]) Lwt_result.t =
  let module Db = (val db : Caqti_lwt.CONNECTION) in
  Db.find_opt migration_exists_query version >|= function
  | Ok (Some _) -> Ok true
  | Ok None -> Ok false
  | Error e -> Error e

let get_applied_versions (db : Types.db_conn) : (int64 list, [> Caqti_error.t]) Lwt_result.t =
  let module Db = (val db : Caqti_lwt.CONNECTION) in
  Db.collect_list get_all_versions_query ()

let get_applied_records (dialect : Dialect.t) (db : Types.db_conn) : (migration_record list, [> Caqti_error.t]) Lwt_result.t =
  let module Db = (val db : Caqti_lwt.CONNECTION) in
  let query = get_all_records_query dialect in
  Db.collect_list query () >|= function
  | Ok rows ->
      Ok (List.map (fun (version, created_at) -> { version; created_at }) rows)
  | Error e -> Error e

let get_latest_version (db : Types.db_conn) : (int64 option, [> Caqti_error.t]) Lwt_result.t =
  let module Db = (val db : Caqti_lwt.CONNECTION) in
  Db.find_opt get_latest_version_query ()

let add_migration (db : Types.db_conn) (version : int64) : (unit, [> Caqti_error.t]) Lwt_result.t =
  let module Db = (val db : Caqti_lwt.CONNECTION) in
  Db.exec insert_migration_query version

let remove_migration (db : Types.db_conn) (version : int64) : (unit, [> Caqti_error.t]) Lwt_result.t =
  let module Db = (val db : Caqti_lwt.CONNECTION) in
  Db.exec delete_migration_query version

(** Execute raw SQL within a connection.
    Handles multi-statement SQL by splitting and executing each statement.

    Each statement is sent as a {b literal} query ([Caqti_query.L]) rather than
    through Caqti's query-template parser, so characters Caqti would otherwise
    interpret as parameter placeholders - ['?'], ['$1'], and PostgreSQL
    dollar-quoting ['$$'] - are passed through untouched. This is what lets
    migrations contain stored-procedure/trigger bodies and literal ['?']/['$'].

    Splitting is dialect-aware: MySQL/MariaDB use backslash string escapes,
    PostgreSQL and SQLite do not (detected from the connection's driver). *)
let execute_sql ?(verbose = false) (db : Types.db_conn) (sql : string) : (unit, [> Caqti_error.t]) Lwt_result.t =
  let module Db = (val db : Caqti_lwt.CONNECTION) in

  let backslash_escapes =
    match Caqti_driver_info.dialect_tag Db.driver_info with
    | `Mysql -> true
    | _ -> false
  in
  let statements = Sql_parser.split_sql ~backslash_escapes sql in

  (* Send the statement as a literal query (no placeholder parsing). *)
  let exec_one stmt =
    let request =
      Caqti_request.create
        ~oneshot:true
        Caqti_type.unit Caqti_type.unit Caqti_mult.zero
        (fun _ -> Caqti_query.L stmt)
    in
    Db.exec request ()
  in

  let rec exec_all = function
    | [] -> Lwt_result.return ()
    | stmt :: rest ->
        log_verbose verbose (Printf.sprintf "Executing SQL: %s" (String.sub stmt 0 (min 60 (String.length stmt)) ^ (if String.length stmt > 60 then "..." else ""))) >>= fun () ->
        exec_one stmt >>= fun result ->
        match result with
        | Error e -> Lwt.return_error e
        | Ok () -> exec_all rest
  in
  exec_all statements

(** Run one migration's SQL inside a transaction and update [schema_migrations].

    [read_sql] selects the section to run (up for apply, down for rollback) and
    [record] updates the table (insert for apply, delete for rollback); [action]
    only labels log messages. The shape is the same for both directions:
    BEGIN -> run SQL -> update table -> COMMIT, and any failure rolls the
    transaction back so nothing is recorded.

    File-read errors return [Failure] immediately, before any transaction. *)
let run_in_transaction ?(verbose = false)
    ~(read_sql : Migration.t -> (string, Types.error) result)
    ~(record : Types.db_conn -> int64 -> (unit, [> Caqti_error.t]) Lwt_result.t)
    ~(action : string)
    (db : Types.db_conn) (migration : Migration.t) : execution_result Lwt.t =
  match read_sql migration with
  | Error err ->
      Lwt.return (Failure (migration, err))
  | Ok sql_content ->
      let module Db = (val db : Caqti_lwt.CONNECTION) in
      let open Lwt.Syntax in
      let version = migration.Migration.version in

      (* No transaction is open yet (e.g. BEGIN itself failed): report directly,
         do not issue a ROLLBACK against a non-existent transaction. *)
      let fail_no_transaction context e =
        Lwt.return (Failure (migration, Types.of_caqti_error ~context e))
      in
      (* A step inside the transaction failed: roll back. If the ROLLBACK also
         fails the database state is unknown, so surface that rather than
         silently swallowing it and claiming "nothing was applied". *)
      let fail_with_rollback context e =
        let* () = log_verbose verbose (Printf.sprintf "Rolling back transaction: %s" context) in
        let* rollback_result = Db.rollback () in
        match rollback_result with
        | Ok () -> Lwt.return (Failure (migration, Types.of_caqti_error ~context e))
        | Error rollback_err ->
            Lwt.return (Failure (migration, Types.DatabaseError (Types.ValidationError
              (Printf.sprintf
                 "%s failed (%s); the subsequent ROLLBACK also failed (%s) - \
                  the database may be in an inconsistent state"
                 context (Caqti_error.show e) (Caqti_error.show rollback_err)))))
      in

      let* () = log_verbose verbose (Printf.sprintf "Starting %s of migration %Ld" action version) in
      let* start_result = Db.start () in
      match start_result with
      | Error e -> fail_no_transaction "start transaction" e
      | Ok () ->
          let* () = log_verbose verbose (Printf.sprintf "Executing %s SQL" action) in
          let* sql_result = execute_sql ~verbose db sql_content in
          match sql_result with
          | Error e -> fail_with_rollback (Printf.sprintf "execute %s SQL" action) e
          | Ok () ->
              let* () = log_verbose verbose (Printf.sprintf "Updating schema_migrations for %Ld" version) in
              let* record_result = record db version in
              match record_result with
              | Error e -> fail_with_rollback "update schema_migrations" e
              | Ok () ->
                  let* () = log_verbose verbose "Committing transaction" in
                  let* commit_result = Db.commit () in
                  match commit_result with
                  | Error e -> fail_with_rollback "commit transaction" e
                  | Ok () ->
                      let* () = log_verbose verbose (Printf.sprintf "%s of migration %Ld completed successfully" action version) in
                      Lwt.return (Success migration)

let run_migration ?(verbose = false) (db : Types.db_conn) (migration : Migration.t) : execution_result Lwt.t =
  run_in_transaction ~verbose ~read_sql:Migration.read_up_sql
    ~record:add_migration ~action:"migration" db migration

(** Run [step] over each item in order, accumulating results and stopping
    after the first result for which [is_ok] returns false (that failing
    result is still included). This is the shared sequential-execution engine
    behind both migrate and rollback, parameterized over the per-item action so
    callers can layer on timing or progress output. *)
let run_until_failure ~(step : 'a -> 'b Lwt.t) ~(is_ok : 'b -> bool) (items : 'a list) : 'b list Lwt.t =
  let open Lwt.Syntax in
  let rec loop acc = function
    | [] -> Lwt.return (List.rev acc)
    | x :: rest ->
        let* result = step x in
        if is_ok result then loop (result :: acc) rest
        else Lwt.return (List.rev (result :: acc))
  in
  loop [] items

let run_migrations ?(verbose = false) (db : Types.db_conn) (migrations : Migration.t list) : execution_result list Lwt.t =
  run_until_failure ~step:(run_migration ~verbose db) ~is_ok:is_success migrations

(** Compute the pending migrations: all migrations on disk minus those already
    recorded as applied in the database. Shared by [run_pending] and the
    higher-level migrate APIs. *)
let pending_migrations ?(migrations_dir = Discovery.default_migrations_dir) (db : Types.db_conn)
    : (Migration.t list, Types.error) Lwt_result.t =
  match Discovery.find_migrations ~dir:migrations_dir () with
  | Error err -> Lwt.return_error err
  | Ok all_migrations ->
      get_applied_versions db >>= function
      | Error caqti_err ->
          Lwt.return_error (Types.of_caqti_error ~context:"get applied versions" caqti_err)
      | Ok applied_versions ->
          Lwt.return_ok (Discovery.find_pending applied_versions all_migrations)

let run_pending ?(verbose = false) (db : Types.db_conn) (migrations_dir : string)
    : (execution_result list, Types.error) Lwt_result.t =
  pending_migrations ~migrations_dir db >>= function
  | Error err -> Lwt.return_error err
  | Ok pending -> run_migrations ~verbose db pending >|= fun results -> Ok results

let rollback_migration ?(verbose = false) (db : Types.db_conn) (migration : Migration.t) : execution_result Lwt.t =
  run_in_transaction ~verbose ~read_sql:Migration.read_down_sql
    ~record:remove_migration ~action:"rollback" db migration

(** Rollback multiple migrations in reverse chronological order.
    Stops at the first failure and returns all results. *)
let rollback_migrations ?(verbose = false) (db : Types.db_conn) (migrations : Migration.t list) : execution_result list Lwt.t =
  let sorted = List.sort (fun a b -> Int64.compare b.Migration.version a.Migration.version) migrations in
  run_until_failure ~step:(rollback_migration ~verbose db) ~is_ok:is_success sorted

type rollback_strategy =
  | Step of int
  | To of int64
  | All

(** The migrations that are both recorded as applied and present on disk,
    in chronological order. Shared by rollback selection and status reporting. *)
let applied_migrations ?(migrations_dir = Discovery.default_migrations_dir) (db : Types.db_conn)
    : (Migration.t list, Types.error) Lwt_result.t =
  get_applied_versions db >>= function
  | Error caqti_err ->
      Lwt.return_error (Types.of_caqti_error ~context:"Failed to get applied versions" caqti_err)
  | Ok applied_versions ->
      match Discovery.find_migrations ~dir:migrations_dir () with
      | Error err -> Lwt.return_error err
      | Ok all_migrations ->
          let applied_set = Discovery.applied_set_of_list applied_versions in
          Lwt.return_ok
            (List.filter
               (fun m -> Discovery.Int64Set.mem m.Migration.version applied_set)
               all_migrations)

let rollback_targets ?(migrations_dir = Discovery.default_migrations_dir) (db : Types.db_conn)
    (strategy : rollback_strategy) : (Migration.t list, Types.error) Lwt_result.t =
  match strategy with
  | Step n when n <= 0 ->
      Lwt.return_error (Types.DatabaseError (Types.ValidationError "Step must be a positive number"))
  | _ ->
      applied_migrations ~migrations_dir db >>= function
      | Error err -> Lwt.return_error err
      | Ok applied ->
          let targets = match strategy with
            | All -> applied
            | To target ->
                List.filter
                  (fun m -> Int64.compare m.Migration.version target > 0)
                  applied
            | Step n ->
                List.sort
                  (fun a b -> Int64.compare b.Migration.version a.Migration.version)
                  applied
                |> List.filteri (fun i _ -> i < n)
          in
          Lwt.return_ok targets

let run_rollback ?(verbose = false) ?(migrations_dir = Discovery.default_migrations_dir)
    (db : Types.db_conn) (strategy : rollback_strategy)
    : (execution_result list, Types.error) Lwt_result.t =
  rollback_targets ~migrations_dir db strategy >>= function
  | Error err -> Lwt.return_error err
  | Ok targets -> rollback_migrations ~verbose db targets >|= fun results -> Ok results

let rollback_step ?(verbose = false) ?(migrations_dir = Discovery.default_migrations_dir) (db : Types.db_conn) (step : int)
    : (execution_result list, Types.error) Lwt_result.t =
  run_rollback ~verbose ~migrations_dir db (Step step)

let rollback_to ?(verbose = false) ?(migrations_dir = Discovery.default_migrations_dir) (db : Types.db_conn) (target_version : int64)
    : (execution_result list, Types.error) Lwt_result.t =
  run_rollback ~verbose ~migrations_dir db (To target_version)

let rollback_all ?(verbose = false) ?(migrations_dir = Discovery.default_migrations_dir) (db : Types.db_conn)
    : (execution_result list, Types.error) Lwt_result.t =
  run_rollback ~verbose ~migrations_dir db All
