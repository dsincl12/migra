(** Migration file discovery and filtering. *)

module Int64Set = Set.Make (Int64)

let default_migrations_dir = "migrations"

let applied_set_of_list (versions : int64 list) : Int64Set.t =
  List.fold_left
    (fun set version -> Int64Set.add version set)
    Int64Set.empty versions

let has_sql_extension (filename : string) : bool =
  String.ends_with ~suffix:".sql" (String.lowercase_ascii filename)

(** A well-formed migration filename: exactly what {!Migration.from_file}
    accepts. Defined in terms of the parser so the two can never disagree. *)
let is_migration_file (filename : string) : bool =
  Result.is_ok (Migration.from_file filename)

(** A [.sql] file whose name starts with a digit clearly intends to be a
    timestamped migration; if it then fails to parse it is an error, not
    something to silently skip. Files that don't look like migration attempts
    (README.md, helpers.sql, ...) are ignored. *)
let looks_like_migration (filename : string) : bool =
  has_sql_extension filename
  && String.length filename > 0
  &&
  let c = filename.[0] in
  c >= '0' && c <= '9'

let read_directory (dir_path : string) : (string list, Types.error) result =
  try
    if not (Sys.file_exists dir_path) then
      Error
        (Types.DiscoveryError
           (Printf.sprintf "Migrations directory does not exist: %s" dir_path))
    else if not (Sys.is_directory dir_path) then
      Error
        (Types.DiscoveryError
           (Printf.sprintf "Path is not a directory: %s" dir_path))
    else
      let files = Sys.readdir dir_path |> Array.to_list in
      Ok files
  with e ->
    Error
      (Types.DiscoveryError
         (Printf.sprintf "Error reading directory %s: %s" dir_path
            (Printexc.to_string e)))

(** Find the first pair of migrations sharing a version. Assumes the list is
    sorted by version, so duplicates are adjacent. *)
let rec first_duplicate_version = function
  | (a : Migration.t) :: (b :: _ as rest) ->
      if Int64.equal a.Migration.version b.Migration.version then Some (a, b)
      else first_duplicate_version rest
  | _ -> None

let find_migrations ?(dir = default_migrations_dir) () :
    (Migration.t list, Types.error) result =
  match read_directory dir with
  | Error e -> Error e
  | Ok files -> (
      (* Parse every .sql file: a malformed file whose name looks like a
         migration (see looks_like_migration) is an error; others are ignored. *)
      let rec parse_all acc = function
        | [] -> Ok (List.rev acc)
        | filename :: rest -> (
            if not (has_sql_extension filename) then parse_all acc rest
            else
              match Migration.from_file (Filename.concat dir filename) with
              | Ok migration -> parse_all (migration :: acc) rest
              | Error err ->
                  if looks_like_migration filename then Error err
                  else parse_all acc rest)
      in

      match parse_all [] files with
      | Error e -> Error e
      | Ok migrations -> (
          let sorted = List.sort Migration.compare migrations in
          (* Two files with the same version would corrupt apply/pending
             tracking (applying one marks the version, silently hiding the
             other), so reject the ambiguity up front. *)
          match first_duplicate_version sorted with
          | Some (a, b) ->
              Error
                (Types.MigrationError
                   (Types.VersionConflict
                      (a.Migration.version, a.file_path, b.file_path)))
          | None -> Ok sorted))

(** All migrations currently on disk in [dir], parsed best-effort: files that
    are not migrations (or fail to parse) are skipped rather than erroring, and
    no duplicate or out-of-order check is applied. Generation uses this to spot
    a name or version clash without being blocked by an unrelated problem
    already present in the directory. *)
let existing_migrations ?(dir = default_migrations_dir) () :
    (Migration.t list, Types.error) result =
  match read_directory dir with
  | Error e -> Error e
  | Ok files ->
      Ok
        (List.filter_map
           (fun filename ->
             if has_sql_extension filename then
               Result.to_option
                 (Migration.from_file (Filename.concat dir filename))
             else None)
           files)

(** Find pending migrations (not yet applied) Takes a list of applied versions
    and all discovered migrations, returns migrations that haven't been applied
    yet. *)
let find_pending (applied_versions : int64 list)
    (all_migrations : Migration.t list) : Migration.t list =
  let applied_set = applied_set_of_list applied_versions in

  List.filter
    (fun (migration : Migration.t) ->
      not (Int64Set.mem migration.Migration.version applied_set))
    all_migrations

let find_by_version (migrations : Migration.t list) (version : int64) :
    Migration.t option =
  List.find_opt
    (fun (m : Migration.t) -> Int64.equal m.Migration.version version)
    migrations

let ensure_migrations_dir ?(dir = default_migrations_dir) () :
    (unit, Types.error) result =
  try
    if not (Sys.file_exists dir) then begin
      Unix.mkdir dir 0o755;
      Ok ()
    end
    else if Sys.is_directory dir then Ok ()
    else
      Error
        (Types.DiscoveryError
           (Printf.sprintf "Path exists but is not a directory: %s" dir))
  with e ->
    Error
      (Types.DiscoveryError
         (Printf.sprintf "Error creating migrations directory %s: %s" dir
            (Printexc.to_string e)))
