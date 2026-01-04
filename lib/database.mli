(** Database connection and configuration utilities *)

(** Parse hostname from DATABASE_URL *)
val get_hostname : Uri.t -> (string, Types.error) result

(** Parse port from DATABASE_URL *)
val get_port : Uri.t -> (int, Types.error) result

(** Parse database name from DATABASE_URL path *)
val get_database : Uri.t -> (string, Types.error) result

(** Get DATABASE_URL from environment *)
val get_database_url : unit -> (string, Types.error) result

(** Connect to database using connection string.
    Returns a single connection (use for one-off operations or transactions). *)
val connect_db : string -> (Types.db_conn, Types.error) result Lwt.t

(** Connect to database and execute a function, then close connection *)
val with_db : string -> (Types.db_conn -> 'a Lwt.t) -> ('a, Types.error) Lwt_result.t

(** Build connection URL for admin database (dialect-aware).
    Used for creating/dropping databases.
    @param dialect Database dialect type
    @param uri Parsed database URL
    @return Admin database connection URL *)
val get_admin_database_url : Dialect.t -> Uri.t -> (string, Types.error) result

(** Create database if it doesn't exist (dialect-aware).
    For SQLite: Database file created on first connection.
    For PostgreSQL/MariaDB: Uses admin database to execute CREATE DATABASE. *)
val create_database : string -> (unit, Types.error) Lwt_result.t

(** Drop database if it exists (dialect-aware).
    For SQLite: Deletes the database file.
    For PostgreSQL/MariaDB: Uses admin database to execute DROP DATABASE. *)
val drop_database : string -> (unit, Types.error) Lwt_result.t
