(** Migration execution and inspection API.

    This module provides a minimal interface for running database migrations
    programmatically. It focuses on migration execution and status inspection.

    {b Scope:}
    - Run pending migrations
    - Rollback applied migrations
    - Inspect migration status

    {b Not included:}
    - Database lifecycle (create/drop databases) - use CLI commands
    - Migration file generation - use CLI commands

    {b Example usage:}

    {[
    let config =
      Migrator.
        {
          database_url = "postgresql://localhost/myapp";
          migrations_dir = "db/migrations";
          verbose = false;
        }
    in

    Lwt_main.run (Migrator.run config) |> function
    | Ok result ->
        Printf.printf "Ran %d migrations successfully\n" result.success_count
    | Error msg ->
        Printf.eprintf "Migration failed: %s\n" msg;
        exit 1
    ]} *)

(** {1 Configuration} *)

type config = {
  database_url : string;  (** Database connection URL *)
  migrations_dir : string;  (** Directory containing .sql migration files *)
  verbose : bool;  (** Enable SQL statement logging *)
  table : string;  (** Name of the migrations-tracking table *)
}
(** Migration configuration *)

val make :
  ?migrations_dir:string ->
  ?verbose:bool ->
  ?table:string ->
  database_url:string ->
  unit ->
  config
(** Build a {!config}. [migrations_dir] defaults to ["migrations"], [verbose] to
    [false], and [table] to ["schema_migrations"]. Preferred over the record
    literal: {[ Migrator.make ~database_url () ]} *)

(** {1 Results} *)

type migration_result = {
  version : int64;  (** Migration version (timestamp) *)
  description : string;  (** Migration description from filename *)
  success : bool;  (** Whether migration succeeded *)
  error : string option;  (** Error message if failed *)
  elapsed_seconds : float option;  (** Execution time in seconds *)
}
(** Result of executing a single migration *)

type operation_result = {
  migrations : migration_result list;  (** Individual migration results *)
  success_count : int;  (** Number of successful migrations *)
  failure_count : int;  (** Number of failed migrations *)
}
(** Result of a migration operation (run/rollback) *)

val succeeded : operation_result -> bool
(** [true] when no migration in the operation failed ([failure_count = 0]).
    Since {!run}/{!rollback} return [Ok] even when an individual migration's SQL
    fails, check this to decide overall success. *)

type migration_status = {
  version : int64;  (** Migration version *)
  description : string;  (** Migration description *)
  applied : bool;  (** Whether migration has been applied *)
  applied_at : string option;  (** Timestamp when applied (if applied) *)
}
(** Status of a single migration *)

type status_result = {
  database_url : string;  (** Database connection URL *)
  migrations : migration_status list;  (** All migrations with status *)
  pending_count : int;  (** Number of pending migrations *)
  applied_count : int;  (** Number of applied migrations *)
}
(** Database migration status *)

(** {1 Core Operations} *)

val run : config -> (operation_result, Types.error) Lwt_result.t
(** Run all pending migrations.

    Discovers migrations in the configured directory, identifies which ones
    haven't been applied yet, and executes them in chronological order. Stops at
    the first failure.

    [Error] is returned only when migrations could not be run at all (bad URL,
    connection failure, or schema-table setup). If migrations ran but one's SQL
    failed, the result is still [Ok] with [failure_count > 0] - use {!succeeded}
    to check overall success.

    @param config Migration configuration
    @return Operation result with per-migration outcomes *)

(** Rollback strategy (an alias of {!Runner.rollback_strategy}) *)
type rollback_strategy = Runner.rollback_strategy =
  | Step of int  (** Rollback last N migrations *)
  | To of int64  (** Rollback to specific version (exclusive) *)
  | All  (** Rollback all migrations *)

val rollback :
  config -> rollback_strategy -> (operation_result, Types.error) Lwt_result.t
(** Rollback migrations according to strategy.

    Executes down SQL for selected migrations in reverse chronological order.
    Stops at the first failure. [Ok]/[Error] follow the same rule as {!run}:
    [Error] means the rollback could not be started; a failed down-migration
    surfaces as [Ok] with [failure_count > 0] (see {!succeeded}).

    @param config Migration configuration
    @param strategy Rollback strategy
    @return Operation result with per-migration outcomes *)

val redo : ?step:int -> config -> (operation_result, Types.error) Lwt_result.t
(** Roll back the last [step] applied migrations (default 1) and re-apply all
    pending migrations. Returns the result of the re-apply; if a rollback fails,
    returns that failing result instead and does not re-apply. *)

val status : config -> (status_result, Types.error) Lwt_result.t
(** Get current migration status.

    Returns information about all migrations (applied and pending) with
    timestamps for applied migrations.

    @param config Migration configuration
    @return Status result with all migrations *)
