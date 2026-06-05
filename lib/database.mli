(** Public database lifecycle and connection-URL helpers. *)

val create_database : string -> (unit, Types.error) Lwt_result.t
(** Create the database named in [url] if it does not already exist. For SQLite
    this is a no-op (the file is created on first connection). *)

val drop_database : string -> (unit, Types.error) Lwt_result.t
(** Drop the database named in [url] if it exists. For SQLite this deletes the
    database file. *)

val database_name : string -> (string, Types.error) result
(** The database name taken from a connection URL's path. *)

val get_database_url : unit -> (string, Types.error) result
(** Read [DATABASE_URL] from the environment. *)

val redact_url : string -> string
(** Replace the password in a connection URL with a fixed mask, for display. *)
