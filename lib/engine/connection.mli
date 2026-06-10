(** Establishing database connections and the URL/credential plumbing behind it.
    Internal to [migra]; public lifecycle helpers live in {!Database}. *)

val get_hostname : Uri.t -> (string, Types.error) result
val get_port : Uri.t -> (int, Types.error) result
val get_database : Uri.t -> (string, Types.error) result

val is_missing_driver_error : string -> bool
(** Whether a Caqti error message indicates the database driver for the URL's
    scheme is not installed (as opposed to a connection failure that merely
    mentions something "not found"). Exposed for testing. *)

val connect_db : string -> (Types.db_conn, Types.error) result Lwt.t
(** Connect to database using connection string. Returns a single connection
    (use for one-off operations or transactions). *)

val with_db :
  string -> (Types.db_conn -> 'a Lwt.t) -> ('a, Types.error) Lwt_result.t
(** Connect, run [f] with the connection, then disconnect. Exceptions raised by
    [f] are converted to error results. *)

val get_admin_database_url : Dialect.t -> Uri.t -> (string, Types.error) result
(** Build the admin-database connection URL (dialect-aware), used for
    creating/dropping databases. *)

val with_admin_connection :
  Dialect.t ->
  string ->
  (Types.db_conn -> string -> (unit, Types.error) Lwt_result.t) ->
  (unit, Types.error) Lwt_result.t
(** Connect to the admin database for the URL's dialect and run [f] with the
    connection and the target database name, disconnecting afterwards. Server
    dialects only. *)
