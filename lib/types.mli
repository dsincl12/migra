(** Shared type definitions *)

(** Database connection type - a first-class Caqti connection module *)
type db_conn = (module Caqti_lwt.CONNECTION)

(** {1 Error Types} *)

(** File-related errors *)
type file_error =
  | FileNotFound of string
  | InvalidFormat of string
  | ReadError of string * exn

(** Database-related errors *)
type db_error =
  | ConnectionFailed of string * Caqti_error.t
  | QueryFailed of string * Caqti_error.t
  | TransactionFailed of string * Caqti_error.t
  | DatabaseNotFound of string
  | UrlParseError of string
  | ValidationError of string

(** Migration-specific errors *)
type migration_error =
  | MissingSection of string * string  (** file, section *)
  | EmptySection of string * string
  | ParseError of file_error
  | VersionConflict of int64 * string * string  (** version, file_a, file_b *)
  | ChecksumMismatch of int64 * string  (** version, file: applied file was modified *)
  | AppliedFileMissing of int64         (** version recorded as applied but no file *)
  | OutOfOrder of int64 * int64         (** pending version, latest applied version *)

(** Top-level error type for all Migra operations *)
type error =
  | FileError of file_error
  | DatabaseError of db_error
  | MigrationError of migration_error
  | DiscoveryError of string

(** Convert a Caqti error to our error type *)
val of_caqti_error : context:string -> Caqti_error.t -> error

(** Convert error to human-readable message *)
val show_error : error -> string
