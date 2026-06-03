(** CLI command implementations for Migra. *)

open Lwt.Infix
open Migra

(** Connect to database, initialize the [table], run [f]; returns an exit code.
    [f] itself returns the exit code for the successful-connection case. *)
let with_initialized_db ?(table = Runner.default_table) database_url (f : Types.db_conn -> int Lwt.t) : int Lwt.t =
  match Runner.validate_table_name table with
  | Error err ->
      Lwt_io.eprintlf "Error: %s" (Types.show_error err) >>= fun () -> Lwt.return 1
  | Ok () ->
  match Dialect.detect_from_url database_url with
  | Error msg ->
      Lwt_io.eprintlf "Invalid DATABASE_URL: %s" msg >>= fun () ->
      Lwt.return 1
  | Ok dialect ->
      Database.with_db database_url (fun db ->
        Lwt.bind (Runner.ensure_migrations_table ~table dialect db) (function
        | Error err ->
            Lwt_io.eprintlf "Failed to initialize database: %s"
              (Caqti_error.show err) >>= fun () ->
            Lwt.return 1
        | Ok () -> f db)
  ) >>= function
  | Ok code -> Lwt.return code
  | Error err ->
      Lwt_io.eprintlf "Error: %s" (Types.show_error err) >>= fun () ->
      Lwt.return 1

let migration_filename (m : Migration.t) : string =
  Filename.basename m.file_path

let run_migration_with_progress ?(verbose = false) ?(table = Runner.default_table) db (migration : Migration.t) : Runner.execution_result Lwt.t =
  let filename = migration_filename migration in
  Lwt_io.printlf "== Running %s" filename >>= fun () ->
  let start_time = Unix.gettimeofday () in
  Runner.run_migration ~verbose ~table db migration >>= fun result ->
  let elapsed = Unix.gettimeofday () -. start_time in
  (match result with
   | Runner.Success migration ->
       Lwt_io.printlf "== Migrated %Ld in %.3fs\n" migration.version elapsed >>= fun () ->
       Lwt.return result
   | Runner.Failure (migration, err) ->
       Lwt_io.eprintlf "** Migration %Ld failed: %s" migration.version (Types.show_error err) >>= fun () ->
       Lwt.return result)

let rollback_migration_with_progress ?(verbose = false) ?(table = Runner.default_table) db (migration : Migration.t) : Runner.execution_result Lwt.t =
  let filename = migration_filename migration in
  Lwt_io.printlf "== Rolling back %s" filename >>= fun () ->
  let start_time = Unix.gettimeofday () in
  Runner.rollback_migration ~verbose ~table db migration >>= fun result ->
  let elapsed = Unix.gettimeofday () -. start_time in
  (match result with
   | Runner.Success migration ->
       Lwt_io.printlf "== Rolled back %Ld in %.3fs\n" migration.version elapsed >>= fun () ->
       Lwt.return result
   | Runner.Failure (migration, err) ->
       Lwt_io.eprintlf "** Rollback %Ld failed: %s" migration.version (Types.show_error err) >>= fun () ->
       Lwt.return result)

(** Run multiple migrations with progress, stopping on first failure.
    Shares Runner's sequential engine; the progress-printing per-migration
    action is the [step]. *)
let run_migrations_with_progress ?(verbose = false) ?(table = Runner.default_table) db migrations : Runner.execution_result list Lwt.t =
  Runner.run_until_failure
    ~step:(run_migration_with_progress ~verbose ~table db)
    ~is_ok:Runner.is_success
    migrations

let rollback_migrations_with_progress ?(verbose = false) ?(table = Runner.default_table) db migrations : Runner.execution_result list Lwt.t =
  let sorted = List.sort (fun a b ->
    Int64.compare b.Migration.version a.Migration.version) migrations in
  Runner.run_until_failure
    ~step:(rollback_migration_with_progress ~verbose ~table db)
    ~is_ok:Runner.is_success
    sorted

let code_of_results results =
  if List.exists (fun r -> not (Runner.is_success r)) results then 1 else 0

let announce_dialect verbose database_url =
  if verbose then
    match Dialect.detect_from_url database_url with
    | Ok dialect -> Lwt_io.eprintlf "[INFO] Using %s database" (Dialect.to_string dialect)
    | Error _ -> Lwt.return_unit
  else
    Lwt.return_unit

let generate name =
  let version = Migration.generate_version () in
  let filename = Printf.sprintf "%Ld_%s.sql" version name in
  let migrations_dir = "migrations" in

  match Discovery.ensure_migrations_dir ~dir:migrations_dir () with
  | Error err ->
      Lwt_io.eprintlf "Error: %s" (Types.show_error err) >>= fun () ->
      Lwt.return 1
  | Ok () ->
      let filepath = Filename.concat migrations_dir filename in
      (* Never clobber an existing file: two `generate`s in the same second
         would otherwise overwrite the first (and any edits) with the template. *)
      if Sys.file_exists filepath then
        Lwt_io.eprintlf "Error: migration file already exists: %s" filepath >>= fun () ->
        Lwt.return 1
      else
        let template =
"-- +migrate up

-- +migrate down

" in
        Lwt_io.with_file ~mode:Lwt_io.Output filepath (fun oc ->
          Lwt_io.write oc template
        ) >>= fun () ->
        Lwt_io.printlf "Creating %s" filepath >>= fun () ->
        Lwt.return 0

let print_plan verb (migrations : Migration.t list) =
  Lwt_io.printlf "Would %s %d migration(s):" verb (List.length migrations) >>= fun () ->
  Lwt_list.iter_s (fun (m : Migration.t) ->
    Lwt_io.printlf "  %Ld  %s" m.Migration.version m.Migration.description) migrations
  >>= fun () -> Lwt.return 0

let migrate migrations_dir table dry_run verbose database_url =
  announce_dialect verbose database_url >>= fun () ->
  with_initialized_db ~table database_url (fun db ->
    (* Refuse to migrate if an applied migration was modified or went missing. *)
    Runner.validate ~table ~migrations_dir db >>= function
    | Error err ->
        Lwt_io.eprintlf "Error: %s" (Types.show_error err) >>= fun () ->
        Lwt.return 1
    | Ok () ->
        Runner.pending_migrations ~table ~migrations_dir db >>= function
        | Error err ->
            Lwt_io.eprintlf "Error: %s" (Types.show_error err) >>= fun () ->
            Lwt.return 1
        | Ok [] ->
            Lwt_io.printl "No pending migrations" >>= fun () ->
            Lwt.return 0
        | Ok pending when dry_run -> print_plan "apply" pending
        | Ok pending ->
            run_migrations_with_progress ~verbose ~table db pending >>= fun results ->
            Lwt.return (code_of_results results)
  )

let init database_url =
  let uri = Uri.of_string database_url in
  match Database.get_database uri with
  | Error err ->
      Lwt_io.eprintlf "Error: %s" (Types.show_error err) >>= fun () ->
      Lwt.return 1
  | Ok db_name ->
      Lwt_io.printlf "Creating database: %s" db_name >>= fun () ->
      Database.create_database database_url >>= function
      | Error err ->
          Lwt_io.eprintlf "Failed to create database: %s" (Types.show_error err) >>= fun () ->
          Lwt.return 1
      | Ok () ->
          Lwt_io.printlf "Database '%s' created successfully" db_name >>= fun () ->
          Lwt.return 0

let setup migrations_dir table verbose database_url =
  announce_dialect verbose database_url >>= fun () ->
  let uri = Uri.of_string database_url in
  match Database.get_database uri with
  | Error err ->
      Lwt_io.eprintlf "Error: %s" (Types.show_error err) >>= fun () ->
      Lwt.return 1
  | Ok db_name ->
      Lwt_io.printlf "Creating database: %s" db_name >>= fun () ->
      Database.create_database database_url >>= function
      | Error err ->
          Lwt_io.eprintlf "Failed to create database: %s" (Types.show_error err) >>= fun () ->
          Lwt.return 1
      | Ok () ->
          Lwt_io.printlf "Database '%s' ready\n" db_name >>= fun () ->
          with_initialized_db ~table database_url (fun db ->
            Runner.pending_migrations ~table ~migrations_dir db >>= function
            | Error err ->
                Lwt_io.eprintlf "Error: %s" (Types.show_error err) >>= fun () ->
                Lwt.return 1
            | Ok [] ->
                Lwt_io.printl "No pending migrations" >>= fun () ->
                Lwt_io.printl "Setup complete!" >>= fun () ->
                Lwt.return 0
            | Ok pending ->
                run_migrations_with_progress ~verbose ~table db pending >>= fun results ->
                match code_of_results results with
                | 0 -> Lwt_io.printl "Setup complete!" >>= fun () -> Lwt.return 0
                | code -> Lwt.return code
          )

let drop database_url =
  let uri = Uri.of_string database_url in
  match Database.get_database uri with
  | Error err ->
      Lwt_io.eprintlf "Error: %s" (Types.show_error err) >>= fun () ->
      Lwt.return 1
  | Ok db_name ->
      Lwt_io.printlf "Dropping database: %s" db_name >>= fun () ->
      Database.drop_database database_url >>= function
      | Error err ->
          Lwt_io.eprintlf "Failed to drop database: %s" (Types.show_error err) >>= fun () ->
          Lwt.return 1
      | Ok () ->
          Lwt_io.printlf "Database '%s' dropped successfully" db_name >>= fun () ->
          Lwt.return 0

let reset migrations_dir table verbose database_url =
  announce_dialect verbose database_url >>= fun () ->
  let uri = Uri.of_string database_url in
  match Database.get_database uri with
  | Error err ->
      Lwt_io.eprintlf "Error: %s" (Types.show_error err) >>= fun () ->
      Lwt.return 1
  | Ok db_name ->
      Lwt_io.printlf "Resetting database: %s\n" db_name >>= fun () ->
      (* Step 1: Drop database *)
      Lwt_io.printl "Dropping database..." >>= fun () ->
      Database.drop_database database_url >>= function
      | Error err ->
          Lwt_io.eprintlf "Failed to drop database: %s" (Types.show_error err) >>= fun () ->
          Lwt.return 1
      | Ok () ->
          Lwt_io.printlf "Database '%s' dropped\n" db_name >>= fun () ->
          (* Step 2: Create database *)
          Lwt_io.printl "Creating database..." >>= fun () ->
          Database.create_database database_url >>= function
          | Error err ->
              Lwt_io.eprintlf "Failed to create database: %s" (Types.show_error err) >>= fun () ->
              Lwt.return 1
          | Ok () ->
              Lwt_io.printlf "Database '%s' created\n" db_name >>= fun () ->
              (* Step 3: Run migrations *)
              with_initialized_db ~table database_url (fun db ->
                Runner.pending_migrations ~table ~migrations_dir db >>= function
                | Error err ->
                    Lwt_io.eprintlf "Error: %s" (Types.show_error err) >>= fun () ->
                    Lwt.return 1
                | Ok [] ->
                    Lwt_io.printl "No pending migrations" >>= fun () ->
                    Lwt_io.printl "Reset complete!" >>= fun () ->
                    Lwt.return 0
                | Ok pending ->
                    run_migrations_with_progress ~verbose ~table db pending >>= fun results ->
                    match code_of_results results with
                    | 0 -> Lwt_io.printl "Reset complete!" >>= fun () -> Lwt.return 0
                    | code -> Lwt.return code
              )

let rollback migrations_dir table step to_version all dry_run verbose database_url =
  announce_dialect verbose database_url >>= fun () ->
  (* Map the CLI flags to a rollback strategy: --all wins, then --to, else --step (default 1). *)
  let strategy =
    if all then Runner.All
    else match to_version with
      | Some target -> Runner.To target
      | None -> Runner.Step (Option.value step ~default:1)
  in
  with_initialized_db ~table database_url (fun db ->
    Runner.rollback_targets ~table ~migrations_dir db strategy >>= function
    | Error err ->
        Lwt_io.eprintlf "Error: %s" (Types.show_error err) >>= fun () ->
        Lwt.return 1
    | Ok [] ->
        Lwt_io.printl "No migrations to rollback" >>= fun () ->
        Lwt.return 0
    | Ok to_rollback when dry_run ->
        (* show them in the order they would be rolled back (newest first) *)
        let ordered = List.sort (fun a b ->
          Int64.compare b.Migration.version a.Migration.version) to_rollback in
        print_plan "roll back" ordered
    | Ok to_rollback ->
        rollback_migrations_with_progress ~verbose ~table db to_rollback >>= fun results ->
        Lwt.return (code_of_results results)
  )

let redo migrations_dir table step verbose database_url =
  announce_dialect verbose database_url >>= fun () ->
  let n = Option.value step ~default:1 in
  with_initialized_db ~table database_url (fun db ->
    Runner.rollback_targets ~table ~migrations_dir db (Runner.Step n) >>= function
    | Error err ->
        Lwt_io.eprintlf "Error: %s" (Types.show_error err) >>= fun () ->
        Lwt.return 1
    | Ok [] ->
        Lwt_io.printl "No migrations to redo" >>= fun () ->
        Lwt.return 0
    | Ok targets ->
        rollback_migrations_with_progress ~verbose ~table db targets >>= fun rolled_back ->
        if List.exists (fun r -> not (Runner.is_success r)) rolled_back then
          Lwt.return 1
        else
          Runner.pending_migrations ~table ~migrations_dir db >>= function
          | Error err ->
              Lwt_io.eprintlf "Error: %s" (Types.show_error err) >>= fun () ->
              Lwt.return 1
          | Ok pending ->
              run_migrations_with_progress ~verbose ~table db pending >>= fun results ->
              Lwt.return (code_of_results results)
  )

let status migrations_dir table database_url =
  with_initialized_db ~table database_url (fun db ->
    Runner.get_applied_versions ~table db >>= function
    | Error err ->
        Lwt_io.eprintlf "Failed to get applied migrations: %s"
          (Caqti_error.show err) >>= fun () ->
        Lwt.return 1
    | Ok applied_versions ->
        (* Build set for O(1) lookup *)
        let applied_set = Discovery.applied_set_of_list applied_versions in

        (* Find all migrations *)
        match Discovery.find_migrations ~dir:migrations_dir () with
        | Error msg ->
            Lwt_io.eprintlf "Error: %s" (Types.show_error msg) >>= fun () ->
            Lwt.return 1
        | Ok migrations ->
            Lwt_io.printlf "\nDatabase: %s\n" (Database.redact_url database_url) >>= fun () ->

            (* Print table header *)
            Lwt_io.printl "  Status    Migration ID    Migration Name" >>= fun () ->
            Lwt_io.printl "--------------------------------------------------" >>= fun () ->

            (* Print all migrations in chronological order *)
            (match migrations with
            | [] -> Lwt_io.printl "  (no migrations found)"
            | _ ->
                Lwt_list.iter_s (fun migration ->
                  let is_applied = Discovery.Int64Set.mem
                    migration.Migration.version applied_set in
                  let status = if is_applied then "up" else "down" in
                  Lwt_io.printlf "  %-8s  %Ld  %s"
                    status
                    migration.Migration.version
                    migration.Migration.description
                ) migrations) >>= fun () ->
            Lwt.return 0
  )
