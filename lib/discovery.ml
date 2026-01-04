(** Migration file discovery and filtering. *)

module Int64Set = Set.Make(Int64)

let default_migrations_dir = "migrations"

let applied_set_of_list (versions : int64 list) : Int64Set.t =
  List.fold_left (fun set version ->
    Int64Set.add version set
  ) Int64Set.empty versions

let is_migration_file (filename : string) : bool =
  String.ends_with ~suffix:".sql" filename &&
  String.length filename > 18 && (* At least 14 digits + _ + 1 char + .sql *)
  (try
    let version_part = String.sub filename 0 14 in
    let _ = Int64.of_string version_part in
    filename.[14] = '_'
   with _ -> false)

let read_directory (dir_path : string) : (string list, Types.error) result =
  try
    if not (Sys.file_exists dir_path) then
      Error (Types.DiscoveryError (Printf.sprintf "Migrations directory does not exist: %s" dir_path))
    else if not (Sys.is_directory dir_path) then
      Error (Types.DiscoveryError (Printf.sprintf "Path is not a directory: %s" dir_path))
    else
      let files = Sys.readdir dir_path |> Array.to_list in
      Ok files
  with e ->
    Error (Types.DiscoveryError (Printf.sprintf "Error reading directory %s: %s" dir_path (Printexc.to_string e)))

let find_migrations ?(dir = default_migrations_dir) () : (Migration.t list, Types.error) result =
  match read_directory dir with
  | Error e -> Error e
  | Ok files ->
      let migration_files =
        files
        |> List.filter is_migration_file
        |> List.map (fun f -> Filename.concat dir f)
      in

      let rec parse_all acc = function
        | [] -> Ok (List.rev acc)
        | file :: rest ->
            match Migration.from_file file with
            | Ok migration -> parse_all (migration :: acc) rest
            | Error err -> Error err
      in

      match parse_all [] migration_files with
      | Error e -> Error e
      | Ok migrations ->
          let sorted = List.sort Migration.compare migrations in
          Ok sorted

(** Find pending migrations (not yet applied)
    Takes a list of applied versions and all discovered migrations,
    returns migrations that haven't been applied yet.
*)
let find_pending (applied_versions : int64 list) (all_migrations : Migration.t list) : Migration.t list =
  let applied_set = applied_set_of_list applied_versions in

  List.filter (fun (migration : Migration.t) ->
    not (Int64Set.mem migration.Migration.version applied_set)
  ) all_migrations

let find_by_version (migrations : Migration.t list) (version : int64) : Migration.t option =
  List.find_opt (fun (m : Migration.t) -> Int64.equal m.Migration.version version) migrations

let ensure_migrations_dir ?(dir = default_migrations_dir) () : (unit, Types.error) result =
  try
    if not (Sys.file_exists dir) then begin
      Unix.mkdir dir 0o755;
      Ok ()
    end else if Sys.is_directory dir then
      Ok ()
    else
      Error (Types.DiscoveryError (Printf.sprintf "Path exists but is not a directory: %s" dir))
  with e ->
    Error (Types.DiscoveryError (Printf.sprintf "Error creating migrations directory %s: %s" dir (Printexc.to_string e)))
