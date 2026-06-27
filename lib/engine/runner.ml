(** Migration execution engine with transaction support. *)

open Lwt.Infix
open Caqti_request.Infix
open Caqti_type.Std

let src = Logs.Src.create "migra.runner" ~doc:"Migration runner"

module Log = (val Logs.src_log src : Logs.LOG)

type migration_record = { version : int64; created_at : string }

type execution_result =
  | Success of Migration.t
  | Failure of Migration.t * Types.error

let is_success = function Success _ -> true | Failure _ -> false
let migration_of_result = function Success m -> m | Failure (m, _) -> m

let error_of_result = function
  | Success _ -> None
  | Failure (_, err) -> Some err

let log_verbose verbose msg =
  if verbose then Logs_lwt.info (fun m -> m "%s" msg) else Lwt.return_unit

(** {1 The schema_migrations table}

    The table tracking applied migrations. Its name defaults to
    [schema_migrations] but is configurable; every operation below takes an
    optional [?table]. The table has columns:
    {v
      version    BIGINT PRIMARY KEY   -- 14-digit YYYYMMDDHHMMSS
      created_at TIMESTAMP            -- when applied (DB default)
      checksum   TEXT                 -- MD5 of the migration file when applied
    v}
    The queries interpolate the (validated) table name, so they are built
    per-call as [~oneshot] requests rather than cached module-level values. *)

let default_table = "schema_migrations"

(** Validate that [table] is a safe SQL identifier: it is interpolated into DDL
    and queries (not bound as a parameter), so it must not allow injection. An
    optional schema qualifier ([schema.table]) is permitted. *)
let validate_table_name (table : string) : (unit, Types.error) result =
  let ok c =
    (c >= 'a' && c <= 'z')
    || (c >= 'A' && c <= 'Z')
    || (c >= '0' && c <= '9')
    || c = '_'
  in
  let ok_first c =
    (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c = '_'
  in
  (* A valid identifier segment: non-empty, starting with a letter or '_', the
     rest letters/digits/'_'. The schema qualifier is at most one '.', so each
     side must be a valid segment; this rejects "public.", "a..b", and "a.b.c",
     which would otherwise pass and surface as a database parse error rather
     than a clean ValidationError. *)
  let valid_segment s = s <> "" && ok_first s.[0] && String.for_all ok s in
  let valid =
    match String.split_on_char '.' table with
    | [ name ] -> valid_segment name
    | [ schema; name ] -> valid_segment schema && valid_segment name
    | _ -> false
  in
  if valid then Ok ()
  else
    Error
      (Types.DatabaseError
         (Types.ValidationError
            (Printf.sprintf
               "Invalid migrations table name %S: use letters, digits, and '_' \
                (not starting with a digit), optionally as a single \
                'schema.table' qualifier"
               table)))

(* Per-call query builders (table name interpolated; values still bound). *)
let exists_query table =
  (int64 ->? int64) ~oneshot:true
    (Printf.sprintf "SELECT version FROM %s WHERE version = ?" table)

let all_versions_query table =
  (unit ->* int64) ~oneshot:true
    (Printf.sprintf "SELECT version FROM %s ORDER BY version ASC" table)

let all_records_query dialect table =
  let module D = (val Dialect.get_dialect dialect : Dialect.DIALECT) in
  (unit ->* t2 int64 string)
    ~oneshot:true
    (Printf.sprintf "SELECT version, %s FROM %s ORDER BY version ASC"
       (D.timestamp_to_string "created_at")
       table)

let all_checksums_query table =
  (unit ->* t2 int64 (option string))
    ~oneshot:true
    (Printf.sprintf "SELECT version, checksum FROM %s ORDER BY version ASC"
       table)

let insert_query table =
  (t2 int64 (option string) ->. unit)
    ~oneshot:true
    (Printf.sprintf "INSERT INTO %s (version, checksum) VALUES (?, ?)" table)

let delete_query table =
  (int64 ->. unit) ~oneshot:true
    (Printf.sprintf "DELETE FROM %s WHERE version = ?" table)

let latest_query table =
  (unit ->? int64) ~oneshot:true
    (Printf.sprintf "SELECT version FROM %s ORDER BY version DESC LIMIT 1" table)

(** Create the migrations table if absent, and add the [checksum] column to
    tables created by older versions that lack it (dialect-aware). *)
let ensure_migrations_table ?(table = default_table) (dialect : Dialect.t)
    (db : Types.db_conn) : (unit, [> Caqti_error.t ]) Lwt_result.t =
  let module Db = (val db : Caqti_lwt.CONNECTION) in
  let columns =
    "version BIGINT PRIMARY KEY, created_at TIMESTAMP NOT NULL DEFAULT \
     CURRENT_TIMESTAMP, checksum TEXT"
  in
  let create_ddl =
    match dialect with
    | Dialect.MariaDB ->
        Printf.sprintf "CREATE TABLE IF NOT EXISTS %s (%s) ENGINE=InnoDB" table
          columns
    | Dialect.PostgreSQL | Dialect.SQLite ->
        Printf.sprintf "CREATE TABLE IF NOT EXISTS %s (%s)" table columns
  in
  (* Backfill the checksum column for tables created before it existed. *)
  let add_checksum_column () =
    match dialect with
    | Dialect.PostgreSQL | Dialect.MariaDB ->
        Db.exec
          ((unit ->. unit) ~oneshot:true
             (Printf.sprintf
                "ALTER TABLE %s ADD COLUMN IF NOT EXISTS checksum TEXT" table))
          ()
    | Dialect.SQLite -> (
        let has_col =
          (unit ->! int) ~oneshot:true
            (Printf.sprintf
               "SELECT COUNT(*) FROM pragma_table_info('%s') WHERE name = \
                'checksum'"
               table)
        in
        Db.find has_col () >>= function
        | Error e -> Lwt.return_error e
        | Ok 0 ->
            Db.exec
              ((unit ->. unit) ~oneshot:true
                 (Printf.sprintf "ALTER TABLE %s ADD COLUMN checksum TEXT" table))
              ()
        | Ok _ -> Lwt_result.return ())
  in
  Db.exec ((unit ->. unit) ~oneshot:true create_ddl) () >>= function
  | Error e -> Lwt.return_error e
  | Ok () -> add_checksum_column ()

(** Whether the migrations-tracking table already exists, without creating it.
    Used by read-only operations (status, dry-run plans) so they never alter the
    schema. Dialect-aware; for a [schema.table] name the schema is matched too.
*)
let table_exists ?(table = default_table) (dialect : Dialect.t)
    (db : Types.db_conn) : (bool, [> Caqti_error.t ]) Lwt_result.t =
  let module Db = (val db : Caqti_lwt.CONNECTION) in
  match dialect with
  | Dialect.SQLite ->
      Db.find
        ((string ->! bool) ~oneshot:true
           "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type IN \
            ('table','view') AND name = ?)")
        table
  | Dialect.PostgreSQL | Dialect.MariaDB -> (
      match String.index_opt table '.' with
      | Some i ->
          let schema = String.sub table 0 i in
          let name = String.sub table (i + 1) (String.length table - i - 1) in
          Db.find
            ((t2 string string ->! bool)
               ~oneshot:true
               "SELECT EXISTS(SELECT 1 FROM information_schema.tables WHERE \
                table_schema = ? AND table_name = ?)")
            (schema, name)
      | None ->
          Db.find
            ((string ->! bool) ~oneshot:true
               "SELECT EXISTS(SELECT 1 FROM information_schema.tables WHERE \
                table_name = ?)")
            table)

let is_applied ?(table = default_table) (db : Types.db_conn) (version : int64) :
    (bool, [> Caqti_error.t ]) Lwt_result.t =
  let module Db = (val db : Caqti_lwt.CONNECTION) in
  Db.find_opt (exists_query table) version >|= function
  | Ok (Some _) -> Ok true
  | Ok None -> Ok false
  | Error e -> Error e

let get_applied_versions ?(table = default_table) (db : Types.db_conn) :
    (int64 list, [> Caqti_error.t ]) Lwt_result.t =
  let module Db = (val db : Caqti_lwt.CONNECTION) in
  Db.collect_list (all_versions_query table) ()

(** Get all applied migrations with timestamps, sorted chronologically
    (dialect-aware) *)
let get_applied_records ?(table = default_table) (dialect : Dialect.t)
    (db : Types.db_conn) :
    (migration_record list, [> Caqti_error.t ]) Lwt_result.t =
  let module Db = (val db : Caqti_lwt.CONNECTION) in
  Db.collect_list (all_records_query dialect table) () >|= function
  | Ok rows ->
      Ok (List.map (fun (version, created_at) -> { version; created_at }) rows)
  | Error e -> Error e

(** Get all applied (version, checksum) pairs, sorted chronologically.
    [checksum] is [None] for rows recorded before checksums were tracked. *)
let get_applied_checksums ?(table = default_table) (db : Types.db_conn) :
    ((int64 * string option) list, [> Caqti_error.t ]) Lwt_result.t =
  let module Db = (val db : Caqti_lwt.CONNECTION) in
  Db.collect_list (all_checksums_query table) ()

let get_latest_version ?(table = default_table) (db : Types.db_conn) :
    (int64 option, [> Caqti_error.t ]) Lwt_result.t =
  let module Db = (val db : Caqti_lwt.CONNECTION) in
  Db.find_opt (latest_query table) ()

let add_migration ?(table = default_table) (db : Types.db_conn)
    (version : int64) (checksum : string option) :
    (unit, [> Caqti_error.t ]) Lwt_result.t =
  let module Db = (val db : Caqti_lwt.CONNECTION) in
  Db.exec (insert_query table) (version, checksum)

let remove_migration ?(table = default_table) (db : Types.db_conn)
    (version : int64) : (unit, [> Caqti_error.t ]) Lwt_result.t =
  let module Db = (val db : Caqti_lwt.CONNECTION) in
  Db.exec (delete_query table) version

(** Execute raw SQL within a connection. Handles multi-statement SQL by
    splitting and executing each statement.

    Each statement is sent as a {b literal} query ([Caqti_query.L]) rather than
    through Caqti's query-template parser, so characters Caqti would otherwise
    interpret as parameter placeholders - ['?'], ['$1'], and PostgreSQL
    dollar-quoting ['$$'] - are passed through untouched. This is what lets
    migrations contain stored-procedure/trigger bodies and literal ['?']/['$'].

    Splitting is dialect-aware: MySQL/MariaDB use backslash string escapes,
    PostgreSQL and SQLite do not (detected from the connection's driver). *)
let execute_sql ?(verbose = false) (db : Types.db_conn) (sql : string) :
    (unit, [> Caqti_error.t ]) Lwt_result.t =
  let module Db = (val db : Caqti_lwt.CONNECTION) in
  let backslash_escapes =
    match Caqti_driver_info.dialect_tag Db.driver_info with
    | `Mysql -> true
    | _ -> false
  in
  (* Backslash escapes and the [DELIMITER] directive are both MySQL/MariaDB
     features, enabled together only for that driver. *)
  let statements =
    Sql_parser.split_sql ~backslash_escapes ~allow_delimiter:backslash_escapes
      sql
  in

  (* Send the statement as a literal query (no placeholder parsing). *)
  let exec_one stmt =
    let request =
      Caqti_request.create ~oneshot:true Caqti_type.unit Caqti_type.unit
        Caqti_mult.zero (fun _ -> Caqti_query.L stmt)
    in
    Db.exec request ()
  in

  let rec exec_all = function
    | [] -> Lwt_result.return ()
    | stmt :: rest -> (
        log_verbose verbose
          (Printf.sprintf "Executing SQL: %s"
             (String.sub stmt 0 (min 60 (String.length stmt))
             ^ if String.length stmt > 60 then "..." else ""))
        >>= fun () ->
        exec_one stmt >>= fun result ->
        match result with
        | Error e -> Lwt.return_error e
        | Ok () -> exec_all rest)
  in
  exec_all statements

(** Run one migration's SQL inside a transaction and update [schema_migrations].

    [read_sql] selects the section to run (up for apply, down for rollback) and
    [record] updates the table (insert for apply, delete for rollback); [action]
    only labels log messages. The shape is the same for both directions: BEGIN
    -> run SQL -> update table -> COMMIT, and any failure rolls the transaction
    back so nothing is recorded.

    The rollback guarantee holds on PostgreSQL and SQLite but is subject to
    known per-dialect limits (see the Transactions notes in the README):
    MySQL/MariaDB DDL implicitly commits, a [COMMIT]/[BEGIN] inside the
    migration's own SQL ends this transaction early, and PostgreSQL rejects
    statements that return rows.

    File-read errors return [Failure] immediately, before any transaction. *)
let run_in_transaction ?(verbose = false)
    ~(read_sql : Migration.t -> (string, Types.error) result)
    ~(record :
       Types.db_conn -> int64 -> (unit, [> Caqti_error.t ]) Lwt_result.t)
    ~(action : string) (db : Types.db_conn) (migration : Migration.t) :
    execution_result Lwt.t =
  match read_sql migration with
  | Error err -> Lwt.return (Failure (migration, err))
  | Ok sql_content -> (
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
        let* () =
          log_verbose verbose
            (Printf.sprintf "Rolling back transaction: %s" context)
        in
        let* rollback_result = Db.rollback () in
        match rollback_result with
        | Ok () ->
            Lwt.return (Failure (migration, Types.of_caqti_error ~context e))
        | Error rollback_err ->
            Lwt.return
              (Failure
                 ( migration,
                   Types.DatabaseError
                     (Types.ValidationError
                        (Printf.sprintf
                           "%s failed (%s); the subsequent ROLLBACK also \
                            failed (%s) - the database may be in an \
                            inconsistent state"
                           context (Caqti_error.show e)
                           (Caqti_error.show rollback_err))) ))
      in

      let* () =
        log_verbose verbose
          (Printf.sprintf "Starting %s of migration %Ld" action version)
      in
      let* start_result = Db.start () in
      match start_result with
      | Error e -> fail_no_transaction "start transaction" e
      | Ok () -> (
          let* () =
            log_verbose verbose (Printf.sprintf "Executing %s SQL" action)
          in
          let* sql_result = execute_sql ~verbose db sql_content in
          match sql_result with
          | Error e ->
              fail_with_rollback (Printf.sprintf "execute %s SQL" action) e
          | Ok () -> (
              let* () =
                log_verbose verbose
                  (Printf.sprintf "Updating schema_migrations for %Ld" version)
              in
              let* record_result = record db version in
              match record_result with
              | Error e -> fail_with_rollback "update schema_migrations" e
              | Ok () -> (
                  let* () = log_verbose verbose "Committing transaction" in
                  let* commit_result = Db.commit () in
                  match commit_result with
                  | Error e -> fail_with_rollback "commit transaction" e
                  | Ok () ->
                      let* () =
                        log_verbose verbose
                          (Printf.sprintf
                             "%s of migration %Ld completed successfully" action
                             version)
                      in
                      Lwt.return (Success migration)))))

(** Execute a migration's up SQL within a transaction, recording the version and
    its checksum. The file is read once up front - yielding both the checksum
    and the SQL to run - so a file-read error fails before any transaction is
    started and the recorded checksum matches exactly the SQL that was executed.
*)
let run_migration ?(verbose = false) ?(table = default_table)
    (db : Types.db_conn) (migration : Migration.t) : execution_result Lwt.t =
  match Migration.read_up_sql_with_checksum migration with
  | Error err -> Lwt.return (Failure (migration, err))
  | Ok (up_sql, checksum) ->
      run_in_transaction ~verbose
        ~read_sql:(fun _ -> Ok up_sql)
        ~record:(fun db version ->
          add_migration ~table db version (Some checksum))
        ~action:"migration" db migration

(** Run [step] over each item in order, accumulating results and stopping after
    the first result for which [is_ok] returns false (that failing result is
    still included). This is the shared sequential-execution engine behind both
    migrate and rollback, parameterized over the per-item action so callers can
    layer on timing or progress output. *)
let run_until_failure ~(step : 'a -> 'b Lwt.t) ~(is_ok : 'b -> bool)
    (items : 'a list) : 'b list Lwt.t =
  let open Lwt.Syntax in
  let rec loop acc = function
    | [] -> Lwt.return (List.rev acc)
    | x :: rest ->
        let* result = step x in
        if is_ok result then loop (result :: acc) rest
        else Lwt.return (List.rev (result :: acc))
  in
  loop [] items

let run_migrations ?(verbose = false) ?(table = default_table)
    (db : Types.db_conn) (migrations : Migration.t list) :
    execution_result list Lwt.t =
  run_until_failure
    ~step:(run_migration ~verbose ~table db)
    ~is_ok:is_success migrations

(** An out-of-order problem: a pending migration older than the latest applied.
*)
let out_of_order_problem (applied_versions : int64 list)
    (pending : Migration.t list) : Types.error option =
  match applied_versions with
  | [] -> None
  | _ -> (
      let latest =
        List.fold_left
          (fun a v -> if Int64.compare v a > 0 then v else a)
          Int64.min_int applied_versions
      in
      match
        List.find_opt
          (fun m -> Int64.compare m.Migration.version latest < 0)
          pending
      with
      | Some m ->
          Some
            (Types.MigrationError
               (Types.OutOfOrder (m.Migration.version, latest)))
      | None -> None)

(** Compute the pending migrations: all migrations on disk minus those already
    recorded as applied. Fails with [OutOfOrder] if a pending migration predates
    the latest applied one (applying it would rewrite history). *)
let pending_migrations ?(table = default_table)
    ?(migrations_dir = Discovery.default_migrations_dir) (db : Types.db_conn) :
    (Migration.t list, Types.error) Lwt_result.t =
  match Discovery.find_migrations ~dir:migrations_dir () with
  | Error err -> Lwt.return_error err
  | Ok all_migrations -> (
      get_applied_versions ~table db >>= function
      | Error caqti_err ->
          Lwt.return_error
            (Types.of_caqti_error ~context:"get applied versions" caqti_err)
      | Ok applied_versions -> (
          let pending =
            Discovery.find_pending applied_versions all_migrations
          in
          match out_of_order_problem applied_versions pending with
          | Some err -> Lwt.return_error err
          | None -> Lwt.return_ok pending))

let run_pending ?(verbose = false) ?(table = default_table) (db : Types.db_conn)
    (migrations_dir : string) :
    (execution_result list, Types.error) Lwt_result.t =
  pending_migrations ~table ~migrations_dir db >>= function
  | Error err -> Lwt.return_error err
  | Ok pending ->
      run_migrations ~verbose ~table db pending >|= fun results -> Ok results

(** Validate applied migrations against the files on disk:
    - a recorded version with no file -> [AppliedFileMissing]
    - a file whose checksum differs from the recorded one -> [ChecksumMismatch]
      Rows recorded before checksums were tracked (NULL checksum) are skipped.
      Returns the first problem found, or [Ok ()] if all are consistent. *)
let validate ?(table = default_table)
    ?(migrations_dir = Discovery.default_migrations_dir) (db : Types.db_conn) :
    (unit, Types.error) Lwt_result.t =
  get_applied_checksums ~table db >>= function
  | Error e ->
      Lwt.return_error
        (Types.of_caqti_error ~context:"read applied checksums" e)
  | Ok applied -> (
      match Discovery.find_migrations ~dir:migrations_dir () with
      | Error err -> Lwt.return_error err
      | Ok all ->
          let rec check = function
            | [] -> Lwt.return_ok ()
            | (version, stored) :: rest -> (
                match
                  List.find_opt
                    (fun m -> Int64.equal m.Migration.version version)
                    all
                with
                | None ->
                    Lwt.return_error
                      (Types.MigrationError (Types.AppliedFileMissing version))
                | Some m -> (
                    match stored with
                    | None ->
                        check rest (* pre-checksum row: nothing to compare *)
                    | Some stored_cs -> (
                        match Migration.checksum m with
                        | Error err -> Lwt.return_error err
                        | Ok cur ->
                            if String.equal cur stored_cs then check rest
                            else
                              Lwt.return_error
                                (Types.MigrationError
                                   (Types.ChecksumMismatch
                                      (version, m.Migration.file_path))))))
          in
          check applied)

(** Execute a migration's down SQL within a transaction, removing the version.
*)
let rollback_migration ?(verbose = false) ?(table = default_table)
    (db : Types.db_conn) (migration : Migration.t) : execution_result Lwt.t =
  run_in_transaction ~verbose ~read_sql:Migration.read_down_sql
    ~record:(fun db version -> remove_migration ~table db version)
    ~action:"rollback" db migration

(** Rollback multiple migrations in reverse chronological order. Stops at the
    first failure and returns all results. *)
let rollback_migrations ?(verbose = false) ?(table = default_table)
    (db : Types.db_conn) (migrations : Migration.t list) :
    execution_result list Lwt.t =
  let sorted =
    List.sort
      (fun a b -> Int64.compare b.Migration.version a.Migration.version)
      migrations
  in
  run_until_failure
    ~step:(rollback_migration ~verbose ~table db)
    ~is_ok:is_success sorted

type rollback_strategy = Step of int | To of int64 | All

(** The migrations that are both recorded as applied and present on disk, in
    chronological order. Shared by rollback selection and status reporting. *)
let applied_migrations ?(table = default_table)
    ?(migrations_dir = Discovery.default_migrations_dir) (db : Types.db_conn) :
    (Migration.t list, Types.error) Lwt_result.t =
  get_applied_versions ~table db >>= function
  | Error caqti_err ->
      Lwt.return_error
        (Types.of_caqti_error ~context:"Failed to get applied versions"
           caqti_err)
  | Ok applied_versions -> (
      match Discovery.find_migrations ~dir:migrations_dir () with
      | Error err -> Lwt.return_error err
      | Ok all_migrations ->
          let applied_set = Discovery.applied_set_of_list applied_versions in
          Lwt.return_ok
            (List.filter
               (fun m -> Discovery.Int64Set.mem m.Migration.version applied_set)
               all_migrations))

let rollback_targets ?(table = default_table)
    ?(migrations_dir = Discovery.default_migrations_dir) (db : Types.db_conn)
    (strategy : rollback_strategy) :
    (Migration.t list, Types.error) Lwt_result.t =
  match strategy with
  | Step n when n <= 0 ->
      Lwt.return_error
        (Types.DatabaseError
           (Types.ValidationError "Step must be a positive number"))
  | _ -> (
      applied_migrations ~table ~migrations_dir db >>= function
      | Error err -> Lwt.return_error err
      | Ok applied ->
          let targets =
            match strategy with
            | All -> applied
            | To target ->
                List.filter
                  (fun m -> Int64.compare m.Migration.version target > 0)
                  applied
            | Step n ->
                List.sort
                  (fun a b ->
                    Int64.compare b.Migration.version a.Migration.version)
                  applied
                |> List.filteri (fun i _ -> i < n)
          in
          Lwt.return_ok targets)

(** Select rollback targets for [strategy] then roll them back (reverse order).
*)
let run_rollback ?(verbose = false) ?(table = default_table)
    ?(migrations_dir = Discovery.default_migrations_dir) (db : Types.db_conn)
    (strategy : rollback_strategy) :
    (execution_result list, Types.error) Lwt_result.t =
  rollback_targets ~table ~migrations_dir db strategy >>= function
  | Error err -> Lwt.return_error err
  | Ok targets ->
      rollback_migrations ~verbose ~table db targets >|= fun results ->
      Ok results

let rollback_step ?(verbose = false) ?(table = default_table)
    ?(migrations_dir = Discovery.default_migrations_dir) (db : Types.db_conn)
    (step : int) : (execution_result list, Types.error) Lwt_result.t =
  run_rollback ~verbose ~table ~migrations_dir db (Step step)

let rollback_to ?(verbose = false) ?(table = default_table)
    ?(migrations_dir = Discovery.default_migrations_dir) (db : Types.db_conn)
    (target_version : int64) : (execution_result list, Types.error) Lwt_result.t
    =
  run_rollback ~verbose ~table ~migrations_dir db (To target_version)

let rollback_all ?(verbose = false) ?(table = default_table)
    ?(migrations_dir = Discovery.default_migrations_dir) (db : Types.db_conn) :
    (execution_result list, Types.error) Lwt_result.t =
  run_rollback ~verbose ~table ~migrations_dir db All
