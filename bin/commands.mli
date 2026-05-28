(** CLI command implementations for Migra. *)

(** Generate a new migration file

    @param name Migration name (description part of filename)
    @return Exit code: 0 on success, 1 on failure
*)
val generate : string -> int Lwt.t

(** Run all pending migrations

    @param migrations_dir Directory containing migration files
    @param verbose Enable SQL logging when true
    @param database_url Database connection URL
    @return Exit code: 0 on success, 1 on failure
*)
val migrate : string -> bool -> string -> int Lwt.t

(** Create the database

    @param database_url Database connection URL
    @return Exit code: 0 on success, 1 on failure
*)
val init : string -> int Lwt.t

(** Create database and run migrations

    @param migrations_dir Directory containing migration files
    @param verbose Enable SQL logging when true
    @param database_url Database connection URL
    @return Exit code: 0 on success, 1 on failure
*)
val setup : string -> bool -> string -> int Lwt.t

(** Drop the database

    @param database_url Database connection URL
    @return Exit code: 0 on success, 1 on failure
*)
val drop : string -> int Lwt.t

(** Drop and recreate database with migrations

    @param migrations_dir Directory containing migration files
    @param verbose Enable SQL logging when true
    @param database_url Database connection URL
    @return Exit code: 0 on success, 1 on failure
*)
val reset : string -> bool -> string -> int Lwt.t

(** Rollback migrations

    @param migrations_dir Directory containing migration files
    @param step Number of migrations to rollback (None = 1)
    @param to_version Rollback to specific version (None = step-based)
    @param all Rollback all migrations when true
    @param verbose Enable SQL logging when true
    @param database_url Database connection URL
    @return Exit code: 0 on success, 1 on failure
*)
val rollback : string -> int option -> int64 option -> bool -> bool -> string -> int Lwt.t

(** Show migration status

    @param migrations_dir Directory containing migration files
    @param database_url Database connection URL
    @return Exit code: 0 on success, 1 on failure
*)
val status : string -> string -> int Lwt.t
