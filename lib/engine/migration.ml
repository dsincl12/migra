(** Migration file representation and parsing. *)

type t = { version : int64; description : string; file_path : string }

(* Stamp versions in UTC ([gmtime]) rather than local time so the value is
   independent of the developer's timezone and DST: two machines generating a
   migration at the same instant agree, and a local DST shift cannot produce a
   stamp that trips the out-of-order check against a teammate's migration. *)
let generate_version () : int64 =
  let d = Unix.gettimeofday () in
  let tm = Unix.gmtime d in
  let timestamp_str =
    Printf.sprintf "%04d%02d%02d%02d%02d%02d" (tm.Unix.tm_year + 1900)
      (tm.Unix.tm_mon + 1) tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min
      tm.Unix.tm_sec
  in
  Int64.of_string timestamp_str

(** A version stamp is exactly 14 ASCII decimal digits (YYYYMMDDHHMMSS). We
    validate the digits explicitly: [Int64.of_string] would otherwise accept a
    leading [-]/[+], [0x]/[0o]/[0b] prefixes, and [_] separators, letting bogus
    or negative versions slip in. *)
let is_version_stamp (s : string) : bool =
  String.length s = 14 && String.for_all (fun c -> c >= '0' && c <= '9') s

let has_sql_suffix (rest : string) : bool =
  String.ends_with ~suffix:".sql" (String.lowercase_ascii rest)

let invalid_filename filename =
  Types.MigrationError
    (Types.ParseError
       (Types.InvalidFormat
          (Printf.sprintf
             "Invalid migration filename '%s' (expected exactly 14 digits then \
              '_<description>.sql', e.g. 20240115120000_create_users.sql)"
             filename)))

(** Parse version from filename Filename format: YYYYMMDDHHMMSS_description.sql
    Example: 20240115120000_create_users.sql -> 20240115120000 *)
let parse_version (filename : string) : (int64, Types.error) result =
  let basename = Filename.basename filename in
  match String.index_opt basename '_' with
  | Some 14 when is_version_stamp (String.sub basename 0 14) ->
      Ok (Int64.of_string (String.sub basename 0 14))
      (* safe: exactly 14 digits *)
  | _ -> Error (invalid_filename filename)

(** Parse description from filename Filename format:
    YYYYMMDDHHMMSS_description.sql Example: 20240115120000_create_users.sql ->
    create_users *)
let parse_description (filename : string) : (string, Types.error) result =
  let basename = Filename.basename filename in
  match String.index_opt basename '_' with
  | Some 14 when is_version_stamp (String.sub basename 0 14) ->
      let rest = String.sub basename 15 (String.length basename - 15) in
      if has_sql_suffix rest then
        let desc = String.sub rest 0 (String.length rest - 4) in
        if String.length desc = 0 then
          Error
            (Types.MigrationError
               (Types.ParseError
                  (Types.InvalidFormat
                     (Printf.sprintf
                        "Migration description cannot be empty: '%s'" filename))))
        else Ok desc
      else
        Error
          (Types.MigrationError
             (Types.ParseError
                (Types.InvalidFormat
                   (Printf.sprintf
                      "Migration file must have a .sql extension: '%s'" filename))))
  | _ -> Error (invalid_filename filename)

let from_file (file_path : string) : (t, Types.error) result =
  match parse_version file_path with
  | Error e -> Error e
  | Ok version -> (
      match parse_description file_path with
      | Error e -> Error e
      | Ok description -> Ok { version; description; file_path })

let read_sql (migration : t) : (string, Types.error) result =
  match
    try Ok (In_channel.with_open_text migration.file_path In_channel.input_all)
    with e -> Error e
  with
  | Ok content -> Ok content
  | Error exn ->
      Error (Types.FileError (Types.ReadError (migration.file_path, exn)))

(** MD5 checksum (hex) of the migration file's full contents, used to detect
    whether a migration file was modified after it was applied. This is
    change-detection, not a security check. *)
let checksum (migration : t) : (string, Types.error) result =
  match read_sql migration with
  | Error e -> Error e
  | Ok content -> Ok (Digest.to_hex (Digest.string content))

(** Parse a section from migration file content Returns the content between a
    section marker and the next section or EOF *)
let parse_section (content : string) (section : string) : string option =
  let lines = String.split_on_char '\n' content in

  let section_marker = "-- +migrate " ^ section in
  (* Match the marker exactly (after trimming) so that requesting section "up"
     does not also match "-- +migrate upgrade" or similar. *)
  let rec find_section_start = function
    | [] -> None
    | line :: rest ->
        if String.trim line = section_marker then Some rest
        else find_section_start rest
  in

  match find_section_start lines with
  | None -> None
  | Some section_lines ->
      (* Collect lines until next section marker or EOF - use cons for O(1) *)
      let rec collect_until_next_section acc = function
        | [] -> List.rev acc
        | line :: rest ->
            let line_trimmed = String.trim line in
            if String.starts_with ~prefix:"-- +migrate " line_trimmed then
              List.rev acc
            else collect_until_next_section (line :: acc) rest
      in
      let section_content = collect_until_next_section [] section_lines in
      let joined = String.concat "\n" section_content in

      Some (String.trim joined)

(** Read a named section's SQL ("up"/"down"), erroring if it is missing or
    empty. *)
let read_section_sql (migration : t) (section : string) :
    (string, Types.error) result =
  match read_sql migration with
  | Error e -> Error e
  | Ok content -> (
      match parse_section content section with
      | None ->
          Error
            (Types.MigrationError
               (Types.MissingSection (migration.file_path, section)))
      | Some sql ->
          if String.trim sql = "" then
            Error
              (Types.MigrationError
                 (Types.EmptySection (migration.file_path, section)))
          else Ok sql)

let read_up_sql (migration : t) : (string, Types.error) result =
  read_section_sql migration "up"

let read_down_sql (migration : t) : (string, Types.error) result =
  read_section_sql migration "down"

let make_filename (version : int64) (description : string) : string =
  Printf.sprintf "%Ld_%s.sql" version description

let compare (a : t) (b : t) : int = Int64.compare a.version b.version

let to_string (migration : t) : string =
  Printf.sprintf "[%Ld] %s" migration.version migration.description
