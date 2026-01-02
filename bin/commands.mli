(** CLI command implementations for Migris. *)

(** Create a new migration file

    @param name Migration name (description part of filename)
    @return Unit on success, raises exception on failure
*)
val create : string -> unit Lwt.t

(** Run all pending migrations

    @param migrations_dir Directory containing migration files
    @param verbose Enable SQL logging when true
    @param database_url Database connection URL
    @return Unit on success, raises exception on failure
*)
val migrate : string -> bool -> string -> unit Lwt.t

(** Create the database

    @param database_url Database connection URL
    @return Unit on success, raises exception on failure
*)
val init : string -> unit Lwt.t

(** Create database and run migrations

    @param migrations_dir Directory containing migration files
    @param verbose Enable SQL logging when true
    @param database_url Database connection URL
    @return Unit on success, raises exception on failure
*)
val setup : string -> bool -> string -> unit Lwt.t

(** Drop the database

    @param database_url Database connection URL
    @return Unit on success, raises exception on failure
*)
val drop : string -> unit Lwt.t

(** Drop and recreate database with migrations

    @param migrations_dir Directory containing migration files
    @param verbose Enable SQL logging when true
    @param database_url Database connection URL
    @return Unit on success, raises exception on failure
*)
val reset : string -> bool -> string -> unit Lwt.t

(** Rollback migrations

    @param migrations_dir Directory containing migration files
    @param step Number of migrations to rollback (None = 1)
    @param to_version Rollback to specific version (None = step-based)
    @param all Rollback all migrations when true
    @param verbose Enable SQL logging when true
    @param database_url Database connection URL
    @return Unit on success, raises exception on failure
*)
val rollback : string -> int option -> int64 option -> bool -> bool -> string -> unit Lwt.t

(** Show migration status

    @param migrations_dir Directory containing migration files
    @param database_url Database connection URL
    @return Unit on success, raises exception on failure
*)
val status : string -> string -> unit Lwt.t
