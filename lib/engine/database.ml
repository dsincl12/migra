(** Database connection and configuration utilities. *)

open Lwt.Infix
open Caqti_request.Infix
open Caqti_type.Std

let get_hostname (uri : Uri.t) : (string, Types.error) result =
  match Uri.host uri with
  | Some host -> Ok host
  | None ->
      Error
        (Types.DatabaseError
           (Types.UrlParseError "Could not parse host from DATABASE_URL"))

let get_port (uri : Uri.t) : (int, Types.error) result =
  match Uri.port uri with
  | Some port -> Ok port
  | None ->
      Error
        (Types.DatabaseError
           (Types.UrlParseError "Could not parse port from DATABASE_URL"))

let get_database (uri : Uri.t) : (string, Types.error) result =
  let path = Uri.path uri in
  if String.length path = 0 then
    Error
      (Types.DatabaseError
         (Types.UrlParseError
            "Could not parse database from DATABASE_URL (empty path)"))
  else
    match path.[0] with
    | '/' ->
        let db_name = String.sub path 1 (String.length path - 1) in
        if String.length db_name = 0 then
          Error
            (Types.DatabaseError
               (Types.UrlParseError
                  "Could not parse database from DATABASE_URL (empty database \
                   name)"))
        else Ok db_name
    | _ ->
        Error
          (Types.DatabaseError
             (Types.UrlParseError
                "Could not parse database from DATABASE_URL (invalid path \
                 format)"))

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
      get_database (Uri.of_string url)

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

(** Check if [haystack] contains [needle]. Pure scan - avoids the [Str] library,
    whose global match state is not safe under Lwt's concurrent scheduling. *)
let string_contains (haystack : string) (needle : string) : bool =
  let hl = String.length haystack and nl = String.length needle in
  if nl = 0 then true
  else if nl > hl then false
  else
    let rec loop i =
      if i > hl - nl then false
      else if String.sub haystack i nl = needle then true
      else loop (i + 1)
    in
    loop 0

(** Whether [err_msg] is Caqti's "no driver installed for this scheme" error, as
    opposed to a connection-time failure that merely happens to contain "not
    found" (a missing host, role, or database). We require the word "driver" so
    a bare "not found" no longer masquerades as a missing-driver error and
    replaces the real message with install instructions. *)
let is_missing_driver_error (err_msg : string) : bool =
  string_contains err_msg "suitable driver"
  || (string_contains err_msg "driver" && string_contains err_msg "not found")

(** Build a helpful "driver not installed" message for [database_url]'s scheme.
    Assumes the failure is a missing-driver error (see
    {!is_missing_driver_error}). *)
let missing_driver_message (database_url : string) : string =
  let scheme =
    Uri.of_string database_url |> Uri.scheme |> Option.value ~default:"unknown"
  in
  let driver_name, install_cmd =
    match scheme with
    | "postgresql" | "postgres" ->
        ("PostgreSQL", "opam install caqti-driver-postgresql")
    | "mariadb" | "mysql" ->
        ("MariaDB/MySQL", "opam install caqti-driver-mariadb")
    | "sqlite3" -> ("SQLite", "opam install caqti-driver-sqlite3")
    | other -> (other, Printf.sprintf "Unknown database scheme: %s" other)
  in
  Printf.sprintf
    "No database driver found for '%s://'\n\n\
     The %s driver is not installed. To fix this:\n\
    \  %s\n\n\
     Available drivers:\n\
    \  - caqti-driver-postgresql  (for postgresql://)\n\
    \  - caqti-driver-mariadb     (for mariadb://, mysql://)\n\
    \  - caqti-driver-sqlite3     (for sqlite3://)"
    scheme driver_name install_cmd

(** A well-formed URL authority has at most one ['@'] (separating credentials
    from host). More than one strongly suggests an unencoded ['@'] in the
    password, which makes the URL parse with the wrong host. *)
let likely_unencoded_credentials (url : string) : bool =
  String.fold_left (fun n c -> if c = '@' then n + 1 else n) 0 url > 1

(** Connect to database using connection string Returns a single connection (use
    for one-off operations or transactions) *)
let connect_db (database_url : string) :
    (Types.db_conn, Types.error) result Lwt.t =
  let normalized_url = Dialect.normalize_url database_url in
  Caqti_lwt_unix.connect (Uri.of_string normalized_url) >|= function
  | Ok conn -> Ok (conn :> Types.db_conn)
  | Error err ->
      if is_missing_driver_error (Caqti_error.show err) then
        Error
          (Types.DatabaseError
             (Types.ValidationError (missing_driver_message database_url)))
      else if likely_unencoded_credentials database_url then
        Error
          (Types.DatabaseError
             (Types.ValidationError
                (Printf.sprintf
                   "%s\n\n\
                    Hint: the connection URL contains more than one '@'. If \
                    your username or password contains '@' (or ':' '/' '?' \
                    '#'), percent-encode it - e.g. '@' becomes '%%40' - \
                    otherwise it is misread as the host."
                   (Caqti_error.show err))))
      else
        Error (Types.DatabaseError (Types.ConnectionFailed ("connect_db", err)))

(** Connect to database and execute a function, then close connection

    Exceptions raised by [f] are caught and converted to error results. The
    error message includes the exception trace for debugging.

    @param database_url Database connection URL
    @param f Function to execute with database connection
    @return Result of [f] or error message *)
let with_db (database_url : string) (f : Types.db_conn -> 'a Lwt.t) :
    ('a, Types.error) Lwt_result.t =
  connect_db database_url >>= function
  | Error err -> Lwt.return_error err
  | Ok db ->
      let module Db = (val db : Caqti_lwt.CONNECTION) in
      Lwt.finalize
        (fun () ->
          Lwt.catch
            (fun () -> f db >|= fun result -> Ok result)
            (fun exn ->
              Lwt.return_error
                (Types.DatabaseError
                   (Types.ValidationError
                      (Printf.sprintf "Unexpected error: %s"
                         (Printexc.to_string exn))))))
        (fun () -> Db.disconnect ())

(** Build connection URL for admin database (dialect-aware) Used for
    creating/dropping databases

    @param dialect Database dialect type
    @param uri Parsed database URL
    @return Admin database connection URL or error *)
let get_admin_database_url (dialect : Dialect.t) (uri : Uri.t) :
    (string, Types.error) result =
  let module D = (val Dialect.get_dialect dialect : Dialect.DIALECT) in
  match D.admin_database with
  | None ->
      Error
        (Types.DatabaseError
           (Types.ValidationError
              "This database type does not support admin database connections"))
  | Some admin_db -> (
      match get_hostname uri with
      | Error err -> Error err
      | Ok _host ->
          (* Derive the admin URL by transforming the original URI rather than
             rebuilding it from parts, so userinfo (including the password),
             query parameters (e.g. sslmode), and IPv6 host bracketing are
             preserved. *)
          let scheme =
            match dialect with
            | Dialect.PostgreSQL -> "postgresql"
            | Dialect.MariaDB -> "mariadb"
            | Dialect.SQLite -> "sqlite3"
          in
          let port =
            match Uri.port uri with
            | Some p -> p
            | None -> Option.value D.default_port ~default:5432
          in
          let admin_uri = Uri.with_scheme uri (Some scheme) in
          let admin_uri = Uri.with_port admin_uri (Some port) in
          let admin_uri = Uri.with_path admin_uri ("/" ^ admin_db) in
          Ok (Uri.to_string admin_uri))

(** Connect to the admin database for [database_url]'s dialect and run [f] with
    the connection and the target database name, disconnecting afterwards. For
    server dialects only (SQLite has no admin database). *)
let with_admin_connection (dialect : Dialect.t) (database_url : string)
    (f : Types.db_conn -> string -> (unit, Types.error) Lwt_result.t) :
    (unit, Types.error) Lwt_result.t =
  let uri = Uri.of_string database_url in
  match get_database uri with
  | Error err -> Lwt.return_error err
  | Ok db_name when String.contains db_name '/' ->
      (* A '/' is not a valid character in a database/schema name; it means the
         URL path has an extra segment. Reject it rather than splicing it into
         CREATE/DROP DATABASE. *)
      Lwt.return_error
        (Types.DatabaseError
           (Types.UrlParseError
              (Printf.sprintf
                 "Invalid database name %S: a database name cannot contain '/' \
                  (check the path in your DATABASE_URL)"
                 db_name)))
  | Ok db_name -> (
      match get_admin_database_url dialect uri with
      | Error err -> Lwt.return_error err
      | Ok admin_url -> (
          connect_db admin_url >>= function
          | Error err -> Lwt.return_error err
          | Ok db ->
              let module Conn = (val db : Caqti_lwt.CONNECTION) in
              Lwt.finalize
                (fun () -> f db db_name)
                (fun () -> Conn.disconnect ())))

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
        with_admin_connection dialect database_url (fun db db_name ->
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
        with_admin_connection dialect database_url (fun db db_name ->
            let module Conn = (val db : Caqti_lwt.CONNECTION) in
            let drop_query = (unit ->. unit) (D.drop_database_sql db_name) in
            Conn.exec drop_query () >>= function
            | Error err ->
                Lwt.return_error
                  (Types.DatabaseError
                     (Types.QueryFailed ("drop database", err)))
            | Ok () -> Lwt.return_ok ())
