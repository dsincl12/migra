
type migration_record = {
  version : int64;
  created_at : string;
}

type execution_result =
  | Success of Migration.t
  | Failure of Migration.t * Types.error

type rollback_strategy =
  | Step of int
  | To of int64
  | All

(** Create the schema_migrations table if it doesn't exist (dialect-aware).
    Idempotent - safe to call multiple times. *)
val ensure_migrations_table : Dialect.t -> Types.db_conn -> (unit, [> Caqti_error.t]) Lwt_result.t

val is_applied : Types.db_conn -> int64 -> (bool, [> Caqti_error.t]) Lwt_result.t

val get_applied_versions : Types.db_conn -> (int64 list, [> Caqti_error.t]) Lwt_result.t

val get_applied_records : Dialect.t -> Types.db_conn -> (migration_record list, [> Caqti_error.t]) Lwt_result.t

val get_latest_version : Types.db_conn -> (int64 option, [> Caqti_error.t]) Lwt_result.t

(** {2 Internal Operations}

    The following functions are exposed for testing purposes.
    They should not be used directly in application code. *)

val add_migration : Types.db_conn -> int64 -> (unit, [> Caqti_error.t]) Lwt_result.t

val remove_migration : Types.db_conn -> int64 -> (unit, [> Caqti_error.t]) Lwt_result.t

val is_success : execution_result -> bool

val migration_of_result : execution_result -> Migration.t

val error_of_result : execution_result -> Types.error option

(** Run [step] over each item in order, stopping after the first result for
    which [is_ok] is false (that failing result is still included). Shared
    sequential engine; callers supply a [step] that may add timing or output. *)
val run_until_failure : step:('a -> 'b Lwt.t) -> is_ok:('b -> bool) -> 'a list -> 'b list Lwt.t

val pending_migrations : ?migrations_dir:string -> Types.db_conn -> (Migration.t list, Types.error) Lwt_result.t

(** Migrations that are both recorded as applied and present on disk, in
    chronological order. *)
val applied_migrations : ?migrations_dir:string -> Types.db_conn -> (Migration.t list, Types.error) Lwt_result.t

val rollback_targets : ?migrations_dir:string -> Types.db_conn -> rollback_strategy -> (Migration.t list, Types.error) Lwt_result.t

(** Execute a migration's up SQL within a transaction.
    Returns Success on successful execution, Failure on error.
    On failure, transaction is rolled back automatically. *)
val run_migration : ?verbose:bool -> Types.db_conn -> Migration.t -> execution_result Lwt.t

(** Execute a list of migrations in order.
    Returns execution results for each migration.
    Stops on first failure. *)
val run_migrations : ?verbose:bool -> Types.db_conn -> Migration.t list -> execution_result list Lwt.t

(** Discover and run pending migrations.
    Returns execution results for each migration attempted. *)
val run_pending : ?verbose:bool -> Types.db_conn -> string -> (execution_result list, Types.error) Lwt_result.t

(** Execute a migration's down SQL (rollback) within a transaction.
    Returns Success on successful rollback, Failure on error.
    On failure, transaction is rolled back automatically. *)
val rollback_migration : ?verbose:bool -> Types.db_conn -> Migration.t -> execution_result Lwt.t

(** Rollback N most recent migrations.
    Returns execution results for each migration rolled back. *)
val rollback_step : ?verbose:bool -> ?migrations_dir:string -> Types.db_conn -> int -> (execution_result list, Types.error) Lwt_result.t

(** Rollback all migrations newer than target version (exclusive).
    Target version remains applied, newer ones are rolled back. *)
val rollback_to : ?verbose:bool -> ?migrations_dir:string -> Types.db_conn -> int64 -> (execution_result list, Types.error) Lwt_result.t

val rollback_all : ?verbose:bool -> ?migrations_dir:string -> Types.db_conn -> (execution_result list, Types.error) Lwt_result.t
