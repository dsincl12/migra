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

(** Build connection URL for postgres (admin) database
    Used for creating/dropping databases
*)
let get_admin_database_url (uri : Uri.t) : (string, Types.error) result =
  match get_hostname uri with
  | Error err -> Error err
  | Ok host ->
      let userinfo = Uri.userinfo uri in
      let port = match Uri.port uri with Some p -> p | None -> 5432 in
      let user_part = match userinfo with
        | Some info ->
            (* Handle user:pass or just user *)
            (match String.index_opt info ':' with
             | Some idx -> String.sub info 0 idx
             | None -> info)
        | None -> ""
      in
      let uri_str =
        if String.length user_part > 0 then
          Printf.sprintf "postgresql://%s@%s:%d/postgres" user_part host port
        else
          Printf.sprintf "postgresql://%s:%d/postgres" host port
      in
      Ok uri_str

(** Create database if it doesn't exist
    Connects to the default 'postgres' database to execute CREATE DATABASE

    Note: This function checks existence then creates, which has a small
    race window. If two processes call this simultaneously, one may fail.
    This is acceptable for typical use cases (development workflows).
*)
let create_database (database_url : string) : (unit, Types.error) Lwt_result.t =
  let uri = Uri.of_string database_url in

  (* Extract database name *)
  match get_database uri with
  | Error err -> Lwt.return_error err
  | Ok db_name ->
      (* Get connection URL for postgres database *)
      match get_admin_database_url uri with
      | Error err -> Lwt.return_error err
      | Ok postgres_url ->
          (* Connect to postgres database *)
          connect_db postgres_url >>= function
          | Error err -> Lwt.return_error err
          | Ok db ->
              let module Conn = (val db : Caqti_lwt.CONNECTION) in

              (* Check if database already exists *)
              let check_query =
                (string ->! bool)
                "SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname = $1)"
              in

              Conn.find check_query db_name >>= function
              | Error err ->
                  Lwt.return_error (Types.DatabaseError (Types.QueryFailed ("check database existence", err)))
              | Ok exists ->
                  if exists then
                    Lwt.return_ok ()  (* Database already exists, nothing to do *)
                  else
                    (* Create the database
                       Note: We use Printf.sprintf here because PostgreSQL doesn't support
                       parameterized database names in CREATE DATABASE. The db_name comes
                       from our own URI parsing, so it's safe. *)
                    let create_query =
                      (unit ->. unit)
                      (Printf.sprintf "CREATE DATABASE %s" db_name)
                    in

                    Conn.exec create_query () >>= function
                    | Error err ->
                        Lwt.return_error (Types.DatabaseError (Types.QueryFailed ("create database", err)))
                    | Ok () ->
                        Lwt.return_ok ()

(** Drop database if it exists
    Connects to the default 'postgres' database to execute DROP DATABASE
*)
let drop_database (database_url : string) : (unit, Types.error) Lwt_result.t =
  let uri = Uri.of_string database_url in

  (* Extract database name *)
  match get_database uri with
  | Error err -> Lwt.return_error err
  | Ok db_name ->
      (* Get connection URL for postgres database *)
      match get_admin_database_url uri with
      | Error err -> Lwt.return_error err
      | Ok postgres_url ->
          (* Connect to postgres database *)
          connect_db postgres_url >>= function
          | Error err -> Lwt.return_error err
          | Ok db ->
              let module Conn = (val db : Caqti_lwt.CONNECTION) in

              (* Drop the database
                 Note: We use Printf.sprintf here because PostgreSQL doesn't support
                 parameterized database names in DROP DATABASE. The db_name comes
                 from our own URI parsing, so it's safe. *)
              let drop_query =
                (unit ->. unit)
                (Printf.sprintf "DROP DATABASE IF EXISTS %s" db_name)
              in

              Conn.exec drop_query () >>= function
              | Error err ->
                  Lwt.return_error (Types.DatabaseError (Types.QueryFailed ("drop database", err)))
              | Ok () ->
                  Lwt.return_ok ()
