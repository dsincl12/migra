(** The public migration API: run, roll back, redo, inspect, and generate
    migrations. This is the high-level entry point; database lifecycle helpers
    live in {!Migra.Database}, and the implementation in the internal
    [migra.engine] library.

    {b Example usage:}

    {[
    let config =
      Migrator.make ~database_url:"postgresql://localhost/myapp" ()
    in
    Lwt_main.run (Migrator.run config) |> function
    | Ok result when Migrator.succeeded result ->
        Printf.printf "Applied %d migration(s)\n" result.success_count
    | Ok result ->
        Printf.eprintf "%d migration(s) failed\n" result.failure_count;
        exit 1
    | Error e ->
        Printf.eprintf "Could not migrate: %s\n" (Types.show_error e);
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
    literal:
    {[
    Migrator.make ~database_url ()
    ]} *)

val default_table : string
(** The default migrations-tracking table name ("schema_migrations"). *)

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

(** Progress events emitted by {!run}/{!rollback}/{!redo} via [?on_event]. *)
type event =
  | Applying of int64 * string  (** version, description: about to apply *)
  | Applied of migration_result  (** finished applying *)
  | Rolling_back of int64 * string
      (** version, description: about to roll back *)
  | Rolled_back of migration_result  (** finished rolling back *)

(** {1 Core Operations} *)

val run :
  ?on_event:(event -> unit Lwt.t) ->
  config ->
  (operation_result, Types.error) Lwt_result.t
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

val run_or_error :
  ?on_event:(event -> unit Lwt.t) ->
  config ->
  (operation_result, Types.error) Lwt_result.t
(** Like {!run}, but a migration whose SQL fails is returned as [Error]
    ([MigrationError (ExecutionFailed (version, message))]) rather than [Ok]
    with [failure_count > 0]. Convenient for the common startup path where any
    failure should abort; on success the [operation_result] is returned
    unchanged. *)

(** Rollback strategy (an alias of {!Migra_engine.Runner.rollback_strategy}) *)
type rollback_strategy = Migra_engine.Runner.rollback_strategy =
  | Step of int  (** Rollback last N migrations *)
  | To of int64  (** Rollback to specific version (exclusive) *)
  | All  (** Rollback all migrations *)

val rollback :
  ?on_event:(event -> unit Lwt.t) ->
  config ->
  rollback_strategy ->
  (operation_result, Types.error) Lwt_result.t
(** Rollback migrations according to strategy.

    Executes down SQL for selected migrations in reverse chronological order.
    Stops at the first failure. [Ok]/[Error] follow the same rule as {!run}:
    [Error] means the rollback could not be started; a failed down-migration
    surfaces as [Ok] with [failure_count > 0] (see {!succeeded}).

    Like {!run}, applied migrations are validated against the files on disk
    first: an [Error] is returned for drift (a modified or missing applied
    migration file) rather than rolling back with down SQL that no longer
    matches what was applied.

    @param config Migration configuration
    @param strategy Rollback strategy
    @return Operation result with per-migration outcomes *)

val redo :
  ?on_event:(event -> unit Lwt.t) ->
  ?step:int ->
  config ->
  (operation_result, Types.error) Lwt_result.t
(** Roll back the last [step] applied migrations (default 1) and re-apply all
    pending migrations. Returns the result of the re-apply; if a rollback fails,
    returns that failing result instead and does not re-apply. Like {!run} and
    {!rollback}, returns [Error] for drift (a modified or missing applied
    migration file) before rolling back or re-applying anything. *)

val status : config -> (status_result, Types.error) Lwt_result.t
(** Get current migration status.

    Returns information about all migrations (applied and pending) with
    timestamps for applied migrations. A migration recorded as applied whose
    file is no longer on disk is still included (counted as applied, described
    as ["(migration file missing)"]) so the drift is visible rather than
    silently understating the applied count.

    @param config Migration configuration
    @return Status result with all migrations *)

val generate : ?migrations_dir:string -> string -> (string, Types.error) result
(** Create a new timestamped migration file [<version>_<name>.sql] in
    [migrations_dir] (created if absent) and return its path. Fails with
    [AlreadyExists] if such a file already exists. *)

(** {1 Plans (for previewing / dry runs)} *)

val pending_plan : config -> ((int64 * string) list, Types.error) Lwt_result.t
(** The (version, description) of each migration {!run} would apply. *)

val rollback_plan :
  config ->
  rollback_strategy ->
  ((int64 * string) list, Types.error) Lwt_result.t
(** The (version, description) of each migration {!rollback} would undo. *)
