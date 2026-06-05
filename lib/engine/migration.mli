type t = { version : int64; description : string; file_path : string }

val generate_version : unit -> int64
val parse_version : string -> (int64, Types.error) result
val parse_description : string -> (string, Types.error) result

val from_file : string -> (t, Types.error) result
(** Create a migration record from a file path. Returns Error if the filename
    doesn't match the expected format. *)

val parse_section : string -> string -> string option
(** Parse a section from migration file content. Extracts content between a
    section marker (e.g., "-- +migrate up") and the next section. Section
    matching is case-insensitive. *)

val read_up_sql : t -> (string, Types.error) result
(** Read the up migration SQL from a migration file. Parses the content between
    [-- +migrate up] and the next section marker. *)

val read_down_sql : t -> (string, Types.error) result
(** Read the down migration SQL from a migration file. Parses the content
    between [-- +migrate down] and the next section marker. *)

val checksum : t -> (string, Types.error) result
(** MD5 checksum (hex) of the migration file's full contents, for detecting
    whether a migration was modified after being applied. *)

val make_filename : int64 -> string -> string
(** Generate migration filename from version and description. Format:
    [YYYYMMDDHHMMSS_description.sql] *)

val compare : t -> t -> int
val to_string : t -> string
