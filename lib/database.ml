(** Database connection and configuration utilities. *)

open Lwt.Infix
open Caqti_request.Infix
open Caqti_type.Std

let get_hostname (uri : Uri.t) : (string, Types.error) result =
  match Uri.host uri with
  | Some host -> Ok host
  | None -> Error (Types.DatabaseError (Types.ParseError "Could not parse host from DATABASE_URL"))

let get_port (uri : Uri.t) : (int, Types.error) result =
  match Uri.port uri with
  | Some port -> Ok port
  | None -> Error (Types.DatabaseError (Types.ParseError "Could not parse port from DATABASE_URL"))

let get_database (uri : Uri.t) : (string, Types.error) result =
  let path = Uri.path uri in
  if String.length path = 0 then
    Error (Types.DatabaseError (Types.ParseError "Could not parse database from DATABASE_URL (empty path)"))
  else
    match path.[0] with
    | '/' ->
        let db_name = String.sub path 1 (String.length path - 1) in
        if String.length db_name = 0 then
          Error (Types.DatabaseError (Types.ParseError "Could not parse database from DATABASE_URL (empty database name)"))
        else
          Ok db_name
    | _ -> Error (Types.DatabaseError (Types.ParseError "Could not parse database from DATABASE_URL (invalid path format)"))

let get_database_url () : (string, Types.error) result =
  match Sys.getenv_opt "DATABASE_URL" with
  | Some url -> Ok url
  | None -> Error (Types.DatabaseError (Types.ParseError "DATABASE_URL environment variable not set"))

(** Connect to database using connection string
    Returns a single connection (use for one-off operations or transactions)
*)
let connect_db (database_url : string) : ((Types.db_conn, Types.error) result) Lwt.t =
  Caqti_lwt_unix.connect (Uri.of_string database_url) >|= function
  | Ok conn -> Ok (conn :> Types.db_conn)
  | Error err -> Error (Types.DatabaseError (Types.ConnectionFailed ("connect_db", err)))

(** Connect to database and execute a function, then close connection

    Exceptions raised by [f] are caught and converted to error results.
    The error message includes the exception trace for debugging.

    @param database_url Database connection URL
    @param f Function to execute with database connection
    @return Result of [f] or error message
*)
let with_db (database_url : string) (f : Types.db_conn -> 'a Lwt.t) : ('a, Types.error) Lwt_result.t =
  connect_db database_url >>= function
  | Error err -> Lwt.return_error err
  | Ok db ->
      Lwt.catch
        (fun () -> f db >|= fun result -> Ok result)
        (fun exn -> Lwt.return_error (Types.DatabaseError (Types.ParseError (Printexc.to_string exn))))

(** Build connection URL for admin database (dialect-aware)
    Used for creating/dropping databases

    @param dialect Database dialect type
    @param uri Parsed database URL
    @return Admin database connection URL or error
*)
let get_admin_database_url (dialect : Dialect.t) (uri : Uri.t) : (string, Types.error) result =
  let module D = (val Dialect.get_dialect dialect : Dialect.DIALECT) in

  match D.admin_database with
  | None -> Error (Types.DatabaseError (Types.ParseError "This database type does not support admin database connections"))
  | Some admin_db ->
      match get_hostname uri with
      | Error err -> Error err
      | Ok host ->
          let userinfo = Uri.userinfo uri in
          let port = match Uri.port uri with
            | Some p -> p
            | None -> Option.value D.default_port ~default:5432
          in
          let user_part = match userinfo with
            | Some info ->
                (* Handle user:pass or just user *)
                (match String.index_opt info ':' with
                 | Some idx -> String.sub info 0 idx
                 | None -> info)
            | None -> ""
          in
          let scheme = match dialect with
            | Dialect.PostgreSQL -> "postgresql"
            | Dialect.MariaDB -> "mariadb"
            | Dialect.SQLite -> "sqlite3"
          in
          let uri_str =
            if String.length user_part > 0 then
              Printf.sprintf "%s://%s@%s:%d/%s" scheme user_part host port admin_db
            else
              Printf.sprintf "%s://%s:%d/%s" scheme host port admin_db
          in
          Ok uri_str

(** Create database if it doesn't exist (dialect-aware)

    For SQLite: Database file will be created automatically on first connection.
    For PostgreSQL/MariaDB: Connects to admin database to execute CREATE DATABASE.

    Note: For server-based databases, this function checks existence then creates,
    which has a small race window. If two processes call this simultaneously, one
    may fail. This is acceptable for typical use cases (development workflows).

    @param database_url Database connection URL
    @return Ok () or error
*)
let create_database (database_url : string) : (unit, Types.error) Lwt_result.t =
  (* Detect database dialect from URL *)
  match Dialect.detect_from_url database_url with
  | Error msg -> Lwt.return_error (Types.DatabaseError (Types.ParseError msg))
  | Ok dialect ->
      let module D = (val Dialect.get_dialect dialect : Dialect.DIALECT) in

      (* SQLite: file will be created by Caqti on first connect *)
      if dialect = Dialect.SQLite then
        let uri = Uri.of_string database_url in
        let path = Uri.path uri in
        if path = ":memory:" then
          Lwt.return_ok ()  (* In-memory DB, always succeeds *)
        else
          Lwt.return_ok ()  (* File will be created by Caqti on first connect *)
      else
        (* Server-based databases: use admin connection *)
        let uri = Uri.of_string database_url in
        match get_database uri with
        | Error err -> Lwt.return_error err
        | Ok db_name ->
            match get_admin_database_url dialect uri with
            | Error err -> Lwt.return_error err
            | Ok admin_url ->
                connect_db admin_url >>= function
                | Error err -> Lwt.return_error err
                | Ok db ->
                    let module Conn = (val db : Caqti_lwt.CONNECTION) in

                    (* Check if database exists *)
                    let check_query = (string ->! bool) D.database_exists_sql in
                    Conn.find check_query db_name >>= function
                    | Error err ->
                        Lwt.return_error (Types.DatabaseError (Types.QueryFailed ("check database existence", err)))
                    | Ok exists ->
                        if exists then
                          Lwt.return_ok ()
                        else
                          let create_query = (unit ->. unit) (D.create_database_sql db_name) in
                          Conn.exec create_query () >>= function
                          | Error err ->
                              Lwt.return_error (Types.DatabaseError (Types.QueryFailed ("create database", err)))
                          | Ok () ->
                              Lwt.return_ok ()

(** Drop database if it exists (dialect-aware)

    For SQLite: Deletes the database file from the filesystem.
    For PostgreSQL/MariaDB: Connects to admin database to execute DROP DATABASE.

    @param database_url Database connection URL
    @return Ok () or error
*)
let drop_database (database_url : string) : (unit, Types.error) Lwt_result.t =
  (* Detect database dialect from URL *)
  match Dialect.detect_from_url database_url with
  | Error msg -> Lwt.return_error (Types.DatabaseError (Types.ParseError msg))
  | Ok dialect ->
      let module D = (val Dialect.get_dialect dialect : Dialect.DIALECT) in

      (* SQLite: delete the file *)
      if dialect = Dialect.SQLite then
        let uri = Uri.of_string database_url in
        let path = Uri.path uri in
        if path = ":memory:" then
          Lwt.return_ok ()  (* In-memory DB, nothing to drop *)
        else
          (* Delete SQLite file if it exists *)
          Lwt.catch
            (fun () ->
              if Sys.file_exists path then
                Lwt_unix.unlink path >|= fun () -> Ok ()
              else
                Lwt.return_ok ()
            )
            (fun exn ->
              Lwt.return_error (Types.DatabaseError (Types.ParseError
                (Printf.sprintf "Failed to delete SQLite file: %s" (Printexc.to_string exn))))
            )
      else
        (* Server-based databases *)
        let uri = Uri.of_string database_url in
        match get_database uri with
        | Error err -> Lwt.return_error err
        | Ok db_name ->
            match get_admin_database_url dialect uri with
            | Error err -> Lwt.return_error err
            | Ok admin_url ->
                connect_db admin_url >>= function
                | Error err -> Lwt.return_error err
                | Ok db ->
                    let module Conn = (val db : Caqti_lwt.CONNECTION) in
                    let drop_query = (unit ->. unit) (D.drop_database_sql db_name) in
                    Conn.exec drop_query () >>= function
                    | Error err ->
                        Lwt.return_error (Types.DatabaseError (Types.QueryFailed ("drop database", err)))
                    | Ok () ->
                        Lwt.return_ok ()
