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

(** Build connection URL for postgres (admin) database.
    Used for creating/dropping databases. *)
val get_admin_database_url : Uri.t -> (string, Types.error) result

(** Create database if it doesn't exist.
    Connects to the default 'postgres' database to execute CREATE DATABASE. *)
val create_database : string -> (unit, Types.error) Lwt_result.t

(** Drop database if it exists.
    Connects to the default 'postgres' database to execute DROP DATABASE. *)
val drop_database : string -> (unit, Types.error) Lwt_result.t
