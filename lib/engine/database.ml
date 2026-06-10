(** Database lifecycle (create/drop) and connection-URL display helpers.

    Connection establishment and URL/credential parsing now live in
    {!Connection}; the aliases below re-export the pieces external callers and
    tests still reach for and will be dropped when the 2.0 merge curates this
    module's interface. *)

open Lwt.Infix
open Caqti_request.Infix
open Caqti_type.Std

let get_hostname = Connection.get_hostname
let get_port = Connection.get_port
let get_database = Connection.get_database
let is_missing_driver_error = Connection.is_missing_driver_error
let connect_db = Connection.connect_db
let with_db = Connection.with_db
let get_admin_database_url = Connection.get_admin_database_url

(** The database name for display and lifecycle messages, derived from the
    connection URL. For PostgreSQL/MariaDB this is the URL path with its leading
    ['/'] removed. For SQLite, whose "name" is really a filesystem path (or
    [:memory:]), it is the path exactly as Caqti will open it, so URLs such as
    [sqlite3:./dev.db] are accepted rather than rejected for "invalid path
    format". *)
let database_name (url : string) : (string, Types.error) result =
  match Dialect.detect_from_url url with
  | Error msg -> Error (Types.DatabaseError (Types.UrlParseError msg))
  | Ok Dialect.SQLite ->
      let path = Uri.path (Uri.of_string (Dialect.normalize_url url)) in
      if String.length path = 0 then
        Error
          (Types.DatabaseError
             (Types.UrlParseError
                "Could not parse SQLite database path from URL (empty path)"))
      else Ok path
  | Ok (Dialect.PostgreSQL | Dialect.MariaDB) ->
      Connection.get_database (Uri.of_string url)

(** Replace the password in a connection URL with a fixed [*****] mask for safe
    display and logging. URLs without a password (or SQLite paths) are returned
    unchanged. The mask is a fixed width so it does not reveal the password
    length.

    The substitution goes via an alphanumeric placeholder because
    [Uri.to_string] would percent-encode the [*] characters directly. *)
let redact_url (url : string) : string =
  let uri = Uri.of_string url in
  match Uri.password uri with
  | None -> url
  | Some _ -> (
      let token = "MIGRAPWREDACTED0" in
      let s = Uri.to_string (Uri.with_password uri (Some token)) in
      let tl = String.length token in
      let rec find i =
        if i + tl > String.length s then None
        else if String.sub s i tl = token then Some i
        else find (i + 1)
      in
      match find 0 with
      | None -> s
      | Some i ->
          String.sub s 0 i ^ "*****"
          ^ String.sub s (i + tl) (String.length s - i - tl))

let get_database_url () : (string, Types.error) result =
  match Sys.getenv_opt "DATABASE_URL" with
  | Some url -> Ok url
  | None ->
      Error
        (Types.DatabaseError
           (Types.UrlParseError "DATABASE_URL environment variable not set"))

(** Create database if it doesn't exist (dialect-aware)

    For SQLite: Database file will be created automatically on first connection.
    For PostgreSQL/MariaDB: Connects to admin database to execute CREATE
    DATABASE.

    Note: For server-based databases, this function checks existence then
    creates, which has a small race window. If two processes call this
    simultaneously, one may fail. This is acceptable for typical use cases
    (development workflows).

    @param database_url Database connection URL
    @return Ok () or error *)
let create_database (database_url : string) : (unit, Types.error) Lwt_result.t =
  (* Detect database dialect from URL *)
  match Dialect.detect_from_url database_url with
  | Error msg ->
      Lwt.return_error (Types.DatabaseError (Types.UrlParseError msg))
  | Ok dialect ->
      let module D = (val Dialect.get_dialect dialect : Dialect.DIALECT) in
      if dialect = Dialect.SQLite then
        (* SQLite has no server-side database to create: a file-backed database
           is created automatically on first connection, and :memory: needs
           nothing. Either way there is no work to do here. *)
        Lwt.return_ok ()
      else
        Connection.with_admin_connection dialect database_url (fun db db_name ->
            let module Conn = (val db : Caqti_lwt.CONNECTION) in
            let check_query = (string ->! bool) D.database_exists_sql in
            Conn.find check_query db_name >>= function
            | Error err ->
                Lwt.return_error
                  (Types.DatabaseError
                     (Types.QueryFailed ("check database existence", err)))
            | Ok true -> Lwt.return_ok ()
            | Ok false -> (
                let create_query =
                  (unit ->. unit) (D.create_database_sql db_name)
                in
                Conn.exec create_query () >>= function
                | Error err ->
                    Lwt.return_error
                      (Types.DatabaseError
                         (Types.QueryFailed ("create database", err)))
                | Ok () -> Lwt.return_ok ()))

(** Drop database if it exists (dialect-aware)

    For SQLite: Deletes the database file from the filesystem. For
    PostgreSQL/MariaDB: Connects to admin database to execute DROP DATABASE.

    @param database_url Database connection URL
    @return Ok () or error *)
let drop_database (database_url : string) : (unit, Types.error) Lwt_result.t =
  (* Detect database dialect from URL *)
  match Dialect.detect_from_url database_url with
  | Error msg ->
      Lwt.return_error (Types.DatabaseError (Types.UrlParseError msg))
  | Ok dialect ->
      let module D = (val Dialect.get_dialect dialect : Dialect.DIALECT) in
      if dialect = Dialect.SQLite then
        let normalized_url = Dialect.normalize_url database_url in
        let uri = Uri.of_string normalized_url in
        let path = Uri.path uri in
        if path = ":memory:" then Lwt.return_ok ()
        else
          Lwt.catch
            (fun () ->
              if Sys.file_exists path then
                Lwt_unix.unlink path >|= fun () -> Ok ()
              else Lwt.return_ok ())
            (fun exn ->
              Lwt.return_error
                (Types.DatabaseError
                   (Types.ValidationError
                      (Printf.sprintf "Failed to delete SQLite file: %s"
                         (Printexc.to_string exn)))))
      else
        Connection.with_admin_connection dialect database_url (fun db db_name ->
            let module Conn = (val db : Caqti_lwt.CONNECTION) in
            let drop_query = (unit ->. unit) (D.drop_database_sql db_name) in
            Conn.exec drop_query () >>= function
            | Error err ->
                Lwt.return_error
                  (Types.DatabaseError
                     (Types.QueryFailed ("drop database", err)))
            | Ok () -> Lwt.return_ok ())
