(** CLI command implementations for Migra. *)

(** Generate a new migration file

    @param name Migration name (description part of filename)
    @return Exit code: 0 on success, 1 on failure
*)
val generate : string -> int Lwt.t

(** Run all pending migrations

    @param migrations_dir Directory containing migration files
    @param table Name of the migrations-tracking table
    @param dry_run Print the pending migrations without applying them
    @param verbose Enable SQL logging when true
    @param database_url Database connection URL
    @return Exit code: 0 on success, 1 on failure
*)
val migrate : string -> string -> bool -> bool -> string -> int Lwt.t

(** Create the database

    @param database_url Database connection URL
    @return Exit code: 0 on success, 1 on failure
*)
val init : string -> int Lwt.t

(** Create database and run migrations

    @param migrations_dir Directory containing migration files
    @param table Name of the migrations-tracking table
    @param verbose Enable SQL logging when true
    @param database_url Database connection URL
    @return Exit code: 0 on success, 1 on failure
*)
val setup : string -> string -> bool -> string -> int Lwt.t

(** Drop the database

    @param database_url Database connection URL
    @return Exit code: 0 on success, 1 on failure
*)
val drop : string -> int Lwt.t

(** Drop and recreate database with migrations

    @param migrations_dir Directory containing migration files
    @param table Name of the migrations-tracking table
    @param verbose Enable SQL logging when true
    @param database_url Database connection URL
    @return Exit code: 0 on success, 1 on failure
*)
val reset : string -> string -> bool -> string -> int Lwt.t

(** Rollback migrations

    @param migrations_dir Directory containing migration files
    @param table Name of the migrations-tracking table
    @param step Number of migrations to rollback (None = 1)
    @param to_version Rollback to specific version (None = step-based)
    @param all Rollback all migrations when true
    @param dry_run Print the migrations that would be rolled back, without doing it
    @param verbose Enable SQL logging when true
    @param database_url Database connection URL
    @return Exit code: 0 on success, 1 on failure
*)
val rollback : string -> string -> int option -> int64 option -> bool -> bool -> bool -> string -> int Lwt.t

(** Roll back the last N migrations and re-apply all pending migrations

    @param migrations_dir Directory containing migration files
    @param table Name of the migrations-tracking table
    @param step Number of migrations to redo (None = 1)
    @param verbose Enable SQL logging when true
    @param database_url Database connection URL
    @return Exit code: 0 on success, 1 on failure
*)
val redo : string -> string -> int option -> bool -> string -> int Lwt.t

(** Show migration status

    @param migrations_dir Directory containing migration files
    @param table Name of the migrations-tracking table
    @param database_url Database connection URL
    @return Exit code: 0 on success, 1 on failure
*)
val status : string -> string -> string -> int Lwt.t
