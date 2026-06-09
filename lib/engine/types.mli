type db_conn = (module Caqti_lwt.CONNECTION)

type file_error =
  | InvalidFormat of string
  | ReadError of string * exn
  | WriteError of string * exn
  | AlreadyExists of string

type db_error =
  | ConnectionFailed of string * Caqti_error.t
  | QueryFailed of string * Caqti_error.t
  | UrlParseError of string
  | ValidationError of string

type migration_error =
  | MissingSection of string * string
  | EmptySection of string * string
  | ParseError of file_error
  | VersionConflict of int64 * string * string
  | ChecksumMismatch of int64 * string
  | AppliedFileMissing of int64
  | OutOfOrder of int64 * int64
  | ExecutionFailed of int64 * string

type error =
  | FileError of file_error
  | DatabaseError of db_error
  | MigrationError of migration_error
  | DiscoveryError of string

val of_caqti_error : context:string -> Caqti_error.t -> error
val show_error : error -> string
