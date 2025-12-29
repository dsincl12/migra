(** Migration file representation and parsing. *)

type t = {
  version : int64;
  description : string;
  file_path : string;
}

let generate_version () : int64 =
  let d = Unix.gettimeofday () in
  let tm = Unix.localtime d in
  let timestamp_str = Printf.sprintf "%04d%02d%02d%02d%02d%02d"
    (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1)
    tm.Unix.tm_mday
    tm.Unix.tm_hour
    tm.Unix.tm_min
    tm.Unix.tm_sec
  in
  Int64.of_string timestamp_str

(** Parse version from filename
    Filename format: YYYYMMDDHHMMSS_description.sql
    Example: 20240115120000_create_users.sql -> 20240115120000
*)
let parse_version (filename : string) : (int64, Types.error) result =
  (* Extract just the filename from path *)
  let basename = Filename.basename filename in
  (* Find the first underscore *)
  match String.index_opt basename '_' with
  | Some idx when idx = 14 ->
      let version_str = String.sub basename 0 14 in
      (match Int64.of_string_opt version_str with
       | Some v -> Ok v
       | None -> Error (Types.MigrationError (Types.ParseError (Types.InvalidFormat
           (Printf.sprintf "Invalid version number '%s' in filename '%s' (must be 14 digits)" version_str filename)))))
  | _ -> Error (Types.MigrationError (Types.ParseError (Types.InvalidFormat
      (Printf.sprintf "Invalid migration filename format: '%s' (expected YYYYMMDDHHMMSS_description.sql)" filename))))

(** Parse description from filename
    Filename format: YYYYMMDDHHMMSS_description.sql
    Example: 20240115120000_create_users.sql -> create_users
*)
let parse_description (filename : string) : (string, Types.error) result =
  let basename = Filename.basename filename in
  match String.index_opt basename '_' with
  | Some idx when idx = 14 ->
      (* Extract between underscore and .sql extension *)
      let rest = String.sub basename (idx + 1) (String.length basename - idx - 1) in
      if String.ends_with ~suffix:".sql" rest then
        let desc = String.sub rest 0 (String.length rest - 4) in
        if String.length desc = 0 then
          Error (Types.MigrationError (Types.ParseError (Types.InvalidFormat
            (Printf.sprintf "Migration description cannot be empty: '%s'" filename))))
        else
          Ok desc
      else
        Error (Types.MigrationError (Types.ParseError (Types.InvalidFormat
          (Printf.sprintf "Migration file must have .sql extension: '%s'" filename))))
  | _ -> Error (Types.MigrationError (Types.ParseError (Types.InvalidFormat
      (Printf.sprintf "Invalid migration filename format: '%s' (expected YYYYMMDDHHMMSS_description.sql)" filename))))

let from_file (file_path : string) : (t, Types.error) result =
  match parse_version file_path with
  | Error e -> Error e
  | Ok version ->
      match parse_description file_path with
      | Error e -> Error e
      | Ok description -> Ok { version; description; file_path }

let read_sql (migration : t) : (string, Types.error) result =
  match
    try Ok (In_channel.with_open_text migration.file_path In_channel.input_all)
    with e -> Error e
  with
  | Ok content -> Ok content
  | Error exn -> Error (Types.FileError (Types.ReadError (migration.file_path, exn)))

(** Parse a section from migration file content
    Returns the content between a section marker and the next section or EOF
*)
let parse_section (content : string) (section : string) : string option =
  let lines = String.split_on_char '\n' content in

  (* Find the section start using recursive search *)
  let section_marker = "-- +migrate " ^ section in
  let rec find_section_start = function
    | [] -> None
    | line :: rest ->
        let line_trimmed = String.trim line in
        if String.starts_with ~prefix:section_marker line_trimmed then
          Some rest
        else
          find_section_start rest
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
            else
              collect_until_next_section (line :: acc) rest
      in
      let section_content = collect_until_next_section [] section_lines in
      (* Join lines and trim whitespace *)
      let joined = String.concat "\n" section_content in
      Some (String.trim joined)

let read_up_sql (migration : t) : (string, Types.error) result =
  match read_sql migration with
  | Error e -> Error e
  | Ok content ->
      match parse_section content "up" with
      | None -> Error (Types.MigrationError (Types.MissingSection (migration.file_path, "up")))
      | Some sql ->
          if String.trim sql = "" then
            Error (Types.MigrationError (Types.EmptySection (migration.file_path, "up")))
          else
            Ok sql

let read_down_sql (migration : t) : (string, Types.error) result =
  match read_sql migration with
  | Error e -> Error e
  | Ok content ->
      match parse_section content "down" with
      | None -> Error (Types.MigrationError (Types.MissingSection (migration.file_path, "down")))
      | Some sql ->
          if String.trim sql = "" then
            Error (Types.MigrationError (Types.EmptySection (migration.file_path, "down")))
          else
            Ok sql

let make_filename (version : int64) (description : string) : string =
  Printf.sprintf "%Ld_%s.sql" version description

let compare (a : t) (b : t) : int =
  Int64.compare a.version b.version

let to_string (migration : t) : string =
  Printf.sprintf "[%Ld] %s" migration.version migration.description
