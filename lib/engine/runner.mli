type migration_record = { version : int64; created_at : string }

type execution_result =
  | Success of Migration.t
  | Failure of Migration.t * Types.error

type rollback_strategy = Step of int | To of int64 | All

(** {1 The schema_migrations table}

    Every operation takes an optional [?table] (default {!default_table}) naming
    the table that tracks applied migrations. *)

val default_table : string

val validate_table_name : string -> (unit, Types.error) result
(** Validate that a table name is a safe SQL identifier (it is interpolated into
    queries, not bound as a parameter). *)

val ensure_migrations_table :
  ?table:string ->
  Dialect.t ->
  Types.db_conn ->
  (unit, [> Caqti_error.t ]) Lwt_result.t
(** Create the migrations table if absent and add the [checksum] column to
    pre-existing tables that lack it (dialect-aware). Idempotent. *)

val table_exists :
  ?table:string ->
  Dialect.t ->
  Types.db_conn ->
  (bool, [> Caqti_error.t ]) Lwt_result.t
(** Whether the migrations-tracking table exists, without creating it. Used by
    read-only operations so they do not alter the schema. *)

val is_applied :
  ?table:string ->
  Types.db_conn ->
  int64 ->
  (bool, [> Caqti_error.t ]) Lwt_result.t

val get_applied_versions :
  ?table:string ->
  Types.db_conn ->
  (int64 list, [> Caqti_error.t ]) Lwt_result.t

val get_applied_records :
  ?table:string ->
  Dialect.t ->
  Types.db_conn ->
  (migration_record list, [> Caqti_error.t ]) Lwt_result.t
(** Get all applied migrations with timestamps, sorted chronologically
    (dialect-aware) *)

val get_applied_checksums :
  ?table:string ->
  Types.db_conn ->
  ((int64 * string option) list, [> Caqti_error.t ]) Lwt_result.t
(** Get all applied (version, checksum) pairs, sorted chronologically. The
    checksum is [None] for rows recorded before checksums were tracked. *)

val get_latest_version :
  ?table:string ->
  Types.db_conn ->
  (int64 option, [> Caqti_error.t ]) Lwt_result.t

(** {2 Internal Operations}

    The following functions are exposed for testing purposes. They should not be
    used directly in application code. *)

val add_migration :
  ?table:string ->
  Types.db_conn ->
  int64 ->
  string option ->
  (unit, [> Caqti_error.t ]) Lwt_result.t
(** Add a migration (mark as applied) with its checksum. Internal - use
    run_migration. *)

val remove_migration :
  ?table:string ->
  Types.db_conn ->
  int64 ->
  (unit, [> Caqti_error.t ]) Lwt_result.t
(** Remove a migration record (for rollback). Internal - use rollback_migration
    instead. *)

val is_success : execution_result -> bool
val migration_of_result : execution_result -> Migration.t
val error_of_result : execution_result -> Types.error option

val run_until_failure :
  step:('a -> 'b Lwt.t) -> is_ok:('b -> bool) -> 'a list -> 'b list Lwt.t
(** Run [step] over each item in order, stopping after the first result for
    which [is_ok] is false (that failing result is still included). Shared
    sequential engine; callers supply a [step] that may add timing or output. *)

val pending_migrations :
  ?table:string ->
  ?migrations_dir:string ->
  Types.db_conn ->
  (Migration.t list, Types.error) Lwt_result.t
(** All migrations on disk minus those already applied. Fails with [OutOfOrder]
    if a pending migration predates the latest applied one. *)

val applied_migrations :
  ?table:string ->
  ?migrations_dir:string ->
  Types.db_conn ->
  (Migration.t list, Types.error) Lwt_result.t
(** Migrations that are both recorded as applied and present on disk, in
    chronological order. *)

val rollback_targets :
  ?table:string ->
  ?migrations_dir:string ->
  Types.db_conn ->
  rollback_strategy ->
  (Migration.t list, Types.error) Lwt_result.t

val validate :
  ?table:string ->
  ?migrations_dir:string ->
  Types.db_conn ->
  (unit, Types.error) Lwt_result.t
(** Validate applied migrations against the files on disk: detects an applied
    migration whose file is missing ([AppliedFileMissing]) or whose contents
    changed since it was applied ([ChecksumMismatch]). Rows recorded before
    checksums were tracked are skipped. *)

val run_migration :
  ?verbose:bool ->
  ?table:string ->
  Types.db_conn ->
  Migration.t ->
  execution_result Lwt.t
(** Execute a migration's up SQL within a transaction, recording its checksum.
    Returns Success on success, Failure on error (transaction rolled back). *)

val run_migrations :
  ?verbose:bool ->
  ?table:string ->
  Types.db_conn ->
  Migration.t list ->
  execution_result list Lwt.t

val run_pending :
  ?verbose:bool ->
  ?table:string ->
  Types.db_conn ->
  string ->
  (execution_result list, Types.error) Lwt_result.t

val rollback_migration :
  ?verbose:bool ->
  ?table:string ->
  Types.db_conn ->
  Migration.t ->
  execution_result Lwt.t
(** Execute a migration's down SQL (rollback) within a transaction. On failure,
    transaction is rolled back automatically. *)

val rollback_step :
  ?verbose:bool ->
  ?table:string ->
  ?migrations_dir:string ->
  Types.db_conn ->
  int ->
  (execution_result list, Types.error) Lwt_result.t

val rollback_to :
  ?verbose:bool ->
  ?table:string ->
  ?migrations_dir:string ->
  Types.db_conn ->
  int64 ->
  (execution_result list, Types.error) Lwt_result.t

val rollback_all :
  ?verbose:bool ->
  ?table:string ->
  ?migrations_dir:string ->
  Types.db_conn ->
  (execution_result list, Types.error) Lwt_result.t
