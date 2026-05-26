
type db_conn = (module Caqti_lwt.CONNECTION)

type file_error =
  | FileNotFound of string
  | InvalidFormat of string
  | ReadError of string * exn

type db_error =
  | ConnectionFailed of string * Caqti_error.t
  | QueryFailed of string * Caqti_error.t
  | TransactionFailed of string * Caqti_error.t
  | DatabaseNotFound of string
  | UrlParseError of string
  | ValidationError of string

type migration_error =
  | MissingSection of string * string  (* file, section *)
  | EmptySection of string * string
  | ParseError of file_error
  | VersionConflict of int64 * string * string  (* version, file_a, file_b *)

type error =
  | FileError of file_error
  | DatabaseError of db_error
  | MigrationError of migration_error
  | DiscoveryError of string

let of_caqti_error ~context (err : Caqti_error.t) : error =
  DatabaseError (QueryFailed (context, err))

let rec show_error = function
  | FileError err -> show_file_error err
  | DatabaseError err -> show_db_error err
  | MigrationError err -> show_migration_error err
  | DiscoveryError msg -> Printf.sprintf "Discovery error: %s" msg

and show_file_error = function
  | FileNotFound path -> Printf.sprintf "File not found: %s" path
  | InvalidFormat msg -> Printf.sprintf "Invalid format: %s" msg
  | ReadError (path, exn) ->
      Printf.sprintf "Error reading file %s: %s" path (Printexc.to_string exn)

and show_db_error = function
  | ConnectionFailed (context, err) ->
      Printf.sprintf "Database connection failed (%s): %s" context
        (Caqti_error.show err)
  | QueryFailed (context, err) ->
      Printf.sprintf "Query failed (%s): %s" context (Caqti_error.show err)
  | TransactionFailed (context, err) ->
      Printf.sprintf "Transaction failed (%s): %s" context
        (Caqti_error.show err)
  | DatabaseNotFound name ->
      Printf.sprintf "Database not found: %s" name
  | UrlParseError msg -> Printf.sprintf "URL parse error: %s" msg
  | ValidationError msg -> Printf.sprintf "Validation error: %s" msg

and show_migration_error = function
  | MissingSection (file, section) ->
      Printf.sprintf "Missing %s section in file: %s" section file
  | EmptySection (file, section) ->
      Printf.sprintf "Empty %s section in file: %s" section file
  | ParseError err -> show_file_error err
  | VersionConflict (version, file_a, file_b) ->
      Printf.sprintf "Migration version %Ld is duplicated by two files: %s and %s"
        version file_a file_b
