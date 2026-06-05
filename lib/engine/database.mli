val get_hostname : Uri.t -> (string, Types.error) result
val get_port : Uri.t -> (int, Types.error) result
val get_database : Uri.t -> (string, Types.error) result
val get_database_url : unit -> (string, Types.error) result

val redact_url : string -> string
(** Replace the password in a connection URL with a fixed [*****] mask for safe
    display (does not reveal the password length). *)

val connect_db : string -> (Types.db_conn, Types.error) result Lwt.t
(** Connect to database using connection string. Returns a single connection
    (use for one-off operations or transactions). *)

val with_db :
  string -> (Types.db_conn -> 'a Lwt.t) -> ('a, Types.error) Lwt_result.t

val get_admin_database_url : Dialect.t -> Uri.t -> (string, Types.error) result
(** Build connection URL for admin database (dialect-aware). Used for
    creating/dropping databases.
    @param dialect Database dialect type
    @param uri Parsed database URL
    @return Admin database connection URL *)

val create_database : string -> (unit, Types.error) Lwt_result.t
(** Create database if it doesn't exist (dialect-aware). For SQLite: Database
    file created on first connection. For PostgreSQL/MariaDB: Uses admin
    database to execute CREATE DATABASE. *)

val drop_database : string -> (unit, Types.error) Lwt_result.t
(** Drop database if it exists (dialect-aware). For SQLite: Deletes the database
    file. For PostgreSQL/MariaDB: Uses admin database to execute DROP DATABASE.
*)
