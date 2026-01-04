(** CLI command implementations for Migra. *)

open Lwt.Infix
open Migra

let with_initialized_db database_url f =
  (* Detect dialect from database_url *)
  match Dialect.detect_from_url database_url with
  | Error msg ->
      Lwt_io.eprintlf "Invalid DATABASE_URL: %s" msg >>= fun () ->
      exit 1
  | Ok dialect ->
      Database.with_db database_url (fun db ->
        Lwt.bind (Runner.ensure_migrations_table dialect db) (function
        | Error err ->
            Lwt_io.eprintlf "Failed to initialize database: %s"
              (Caqti_error.show err) >>= fun () ->
            exit 1
        | Ok () -> f db)
  ) >>= function
  | Ok result -> Lwt.return result
  | Error err ->
      Lwt_io.eprintlf "Error: %s" (Types.show_error err) >>= fun () ->
      exit 1

let migration_filename (m : Migration.t) : string =
  Filename.basename m.file_path

let run_migration_with_progress ?(verbose = false) db (migration : Migration.t) : Runner.execution_result Lwt.t =
  let filename = migration_filename migration in
  Lwt_io.printlf "== Running %s" filename >>= fun () ->
  let start_time = Unix.gettimeofday () in
  Runner.run_migration ~verbose db migration >>= fun result ->
  let elapsed = Unix.gettimeofday () -. start_time in
  (match result with
   | Runner.Success migration ->
       Lwt_io.printlf "== Migrated %Ld in %.3fs\n" migration.version elapsed >>= fun () ->
       Lwt.return result
   | Runner.Failure (migration, err) ->
       Lwt_io.eprintlf "** Migration %Ld failed: %s" migration.version (Types.show_error err) >>= fun () ->
       Lwt.return result)

let rollback_migration_with_progress ?(verbose = false) db (migration : Migration.t) : Runner.execution_result Lwt.t =
  let filename = migration_filename migration in
  Lwt_io.printlf "== Rolling back %s" filename >>= fun () ->
  let start_time = Unix.gettimeofday () in
  Runner.rollback_migration ~verbose db migration >>= fun result ->
  let elapsed = Unix.gettimeofday () -. start_time in
  (match result with
   | Runner.Success migration ->
       Lwt_io.printlf "== Rolled back %Ld in %.3fs\n" migration.version elapsed >>= fun () ->
       Lwt.return result
   | Runner.Failure (migration, err) ->
       Lwt_io.eprintlf "** Rollback %Ld failed: %s" migration.version (Types.show_error err) >>= fun () ->
       Lwt.return result)

let run_migrations_with_progress ?(verbose = false) db migrations : Runner.execution_result list Lwt.t =
  let rec run_all acc = function
    | [] -> Lwt.return (List.rev acc)
    | migration :: rest ->
        run_migration_with_progress ~verbose db migration >>= fun result ->
        (match result with
         | Runner.Success _ ->
             run_all (result :: acc) rest
         | Runner.Failure _ ->
             Lwt.return (List.rev (result :: acc)))
  in
  run_all [] migrations

let rollback_migrations_with_progress ?(verbose = false) db migrations : Runner.execution_result list Lwt.t =
  (* Sort in reverse chronological order (newest first) *)
  let sorted = List.sort (fun a b ->
    Int64.compare b.Migration.version a.Migration.version) migrations in
  let rec rollback_all acc = function
    | [] -> Lwt.return (List.rev acc)
    | migration :: rest ->
        rollback_migration_with_progress ~verbose db migration >>= fun result ->
        (match result with
         | Runner.Success _ ->
             rollback_all (result :: acc) rest
         | Runner.Failure _ ->
             Lwt.return (List.rev (result :: acc)))
  in
  rollback_all [] sorted

let create name =
  let version = Migration.generate_version () in
  let filename = Printf.sprintf "%Ld_%s.sql" version name in
  let migrations_dir = "migrations" in

  (* Ensure migrations directory exists *)
  (match Discovery.ensure_migrations_dir ~dir:migrations_dir () with
   | Ok () -> Lwt.return_unit
   | Error err -> Lwt.fail_with (Types.show_error err)) >>= fun () ->

  (* Create migration file with up/down template *)
  let filepath = Filename.concat migrations_dir filename in
  let template =
"-- +migrate up

-- +migrate down

" in
  Lwt_io.with_file ~mode:Lwt_io.Output filepath (fun oc ->
    Lwt_io.write oc template
  ) >>= fun () ->

  Lwt_io.printlf "Creating %s" filepath

let migrate migrations_dir verbose database_url =
  (* Show database type in verbose mode *)
  (if verbose then
    match Dialect.detect_from_url database_url with
    | Ok dialect ->
        Lwt_io.eprintlf "[INFO] Using %s database" (Dialect.to_string dialect)
    | Error _ ->
        Lwt.return_unit  (* Error will be caught by with_initialized_db *)
  else
    Lwt.return_unit) >>= fun () ->
  with_initialized_db database_url (fun db ->
    (* Discover all migrations *)
    match Discovery.find_migrations ~dir:migrations_dir () with
    | Error err ->
        Lwt_io.eprintlf "Error: %s" (Types.show_error err) >>= fun () ->
        exit 1
    | Ok all_migrations ->
        (* Get applied versions *)
        Runner.get_applied_versions db >>= function
        | Error err ->
            Lwt_io.eprintlf "Error: %s" (Caqti_error.show err) >>= fun () ->
            exit 1
        | Ok applied_versions ->
            let pending = Discovery.find_pending applied_versions all_migrations in
            match pending with
            | [] ->
                Lwt_io.printl "No pending migrations"
            | _ ->
                run_migrations_with_progress ~verbose db pending >>= fun results ->
                let failed = List.filter (fun r -> not (Runner.is_success r)) results in
                if List.length failed > 0 then exit 1 else Lwt.return_unit
  )

let init database_url =
  let uri = Uri.of_string database_url in
  match Database.get_database uri with
  | Error err ->
      Lwt_io.eprintlf "Error: %s" (Types.show_error err) >>= fun () ->
      exit 1
  | Ok db_name ->
      Lwt_io.printlf "Creating database: %s" db_name >>= fun () ->
      Database.create_database database_url >>= function
      | Error err ->
          Lwt_io.eprintlf "Failed to create database: %s" (Types.show_error err) >>= fun () ->
          exit 1
      | Ok () ->
          Lwt_io.printlf "Database '%s' created successfully" db_name >>= fun () ->
          Lwt_io.printl "\nRun 'migra migrate' to apply migrations"

let setup migrations_dir verbose database_url =
  (* Show database type in verbose mode *)
  let verbose_output =
    if verbose then
      match Dialect.detect_from_url database_url with
      | Ok dialect ->
          Lwt_io.eprintlf "[INFO] Using %s database" (Dialect.to_string dialect)
      | Error _ ->
          Lwt.return_unit  (* Error will be caught later *)
    else
      Lwt.return_unit
  in
  verbose_output >>= fun () ->
  let uri = Uri.of_string database_url in
  match Database.get_database uri with
  | Error err ->
      Lwt_io.eprintlf "Error: %s" (Types.show_error err) >>= fun () ->
      exit 1
  | Ok db_name ->
      Lwt_io.printlf "Creating database: %s" db_name >>= fun () ->
      Database.create_database database_url >>= function
      | Error err ->
          Lwt_io.eprintlf "Failed to create database: %s" (Types.show_error err) >>= fun () ->
          exit 1
      | Ok () ->
          Lwt_io.printlf "Database '%s' ready\n" db_name >>= fun () ->
          with_initialized_db database_url (fun db ->
            (* Discover all migrations *)
            match Discovery.find_migrations ~dir:migrations_dir () with
            | Error err ->
                Lwt_io.eprintlf "Error: %s" (Types.show_error err) >>= fun () ->
                exit 1
            | Ok all_migrations ->
                (* Get applied versions *)
                Runner.get_applied_versions db >>= function
                | Error err ->
                    Lwt_io.eprintlf "Error: %s" (Caqti_error.show err) >>= fun () ->
                    exit 1
                | Ok applied_versions ->
                    let pending = Discovery.find_pending applied_versions all_migrations in
                    match pending with
                    | [] ->
                        Lwt_io.printl "No pending migrations" >>= fun () ->
                        Lwt_io.printl "\nSetup complete! Create migrations with 'migra create <name>'"
                    | _ ->
                        run_migrations_with_progress ~verbose db pending >>= fun results ->
                        let failed = List.filter (fun r -> not (Runner.is_success r)) results in
                        if List.length failed > 0 then
                          exit 1
                        else
                          Lwt_io.printl "Setup complete!"
          )

let drop database_url =
  let uri = Uri.of_string database_url in
  match Database.get_database uri with
  | Error err ->
      Lwt_io.eprintlf "Error: %s" (Types.show_error err) >>= fun () ->
      exit 1
  | Ok db_name ->
      Lwt_io.printlf "Dropping database: %s" db_name >>= fun () ->
      Database.drop_database database_url >>= function
      | Error err ->
          Lwt_io.eprintlf "Failed to drop database: %s" (Types.show_error err) >>= fun () ->
          exit 1
      | Ok () ->
          Lwt_io.printlf "Database '%s' dropped successfully" db_name

let reset migrations_dir verbose database_url =
  (* Show database type in verbose mode *)
  let verbose_output =
    if verbose then
      match Dialect.detect_from_url database_url with
      | Ok dialect ->
          Lwt_io.eprintlf "[INFO] Using %s database" (Dialect.to_string dialect)
      | Error _ ->
          Lwt.return_unit  (* Error will be caught later *)
    else
      Lwt.return_unit
  in
  verbose_output >>= fun () ->
  let uri = Uri.of_string database_url in
  match Database.get_database uri with
  | Error err ->
      Lwt_io.eprintlf "Error: %s" (Types.show_error err) >>= fun () ->
      exit 1
  | Ok db_name ->
      Lwt_io.printlf "Resetting database: %s\n" db_name >>= fun () ->
      (* Step 1: Drop database *)
      Lwt_io.printl "Dropping database..." >>= fun () ->
      Database.drop_database database_url >>= function
      | Error err ->
          Lwt_io.eprintlf "Failed to drop database: %s" (Types.show_error err) >>= fun () ->
          exit 1
      | Ok () ->
          Lwt_io.printlf "Database '%s' dropped\n" db_name >>= fun () ->
          (* Step 2: Create database *)
          Lwt_io.printl "Creating database..." >>= fun () ->
          Database.create_database database_url >>= function
          | Error err ->
              Lwt_io.eprintlf "Failed to create database: %s" (Types.show_error err) >>= fun () ->
              exit 1
          | Ok () ->
              Lwt_io.printlf "Database '%s' created\n" db_name >>= fun () ->
              (* Step 3: Run migrations *)
              with_initialized_db database_url (fun db ->
                (* Discover all migrations *)
                match Discovery.find_migrations ~dir:migrations_dir () with
                | Error err ->
                    Lwt_io.eprintlf "Error: %s" (Types.show_error err) >>= fun () ->
                    exit 1
                | Ok all_migrations ->
                    (* Get applied versions (should be empty after reset) *)
                    Runner.get_applied_versions db >>= function
                    | Error err ->
                        Lwt_io.eprintlf "Error: %s" (Caqti_error.show err) >>= fun () ->
                        exit 1
                    | Ok applied_versions ->
                        let pending = Discovery.find_pending applied_versions all_migrations in
                        match pending with
                        | [] ->
                            Lwt_io.printl "No pending migrations" >>= fun () ->
                            Lwt_io.printl "\nReset complete! Create migrations with 'migra create <name>'"
                        | _ ->
                            run_migrations_with_progress ~verbose db pending >>= fun results ->
                            let failed = List.filter (fun r -> not (Runner.is_success r)) results in
                            if List.length failed > 0 then
                              exit 1
                            else
                              Lwt_io.printl "Reset complete!"
              )

let rollback migrations_dir step to_version all verbose database_url =
  (* Show database type in verbose mode *)
  (if verbose then
    match Dialect.detect_from_url database_url with
    | Ok dialect ->
        Lwt_io.eprintlf "[INFO] Using %s database" (Dialect.to_string dialect)
    | Error _ ->
        Lwt.return_unit  (* Error will be caught by with_initialized_db *)
  else
    Lwt.return_unit) >>= fun () ->
  with_initialized_db database_url (fun db ->
    (* Get applied versions *)
    Runner.get_applied_versions db >>= function
    | Error err ->
        Lwt_io.eprintlf "Error: %s" (Caqti_error.show err) >>= fun () ->
        exit 1
    | Ok applied_versions ->
        match applied_versions with
        | [] -> Lwt_io.printl "No migrations to rollback"
        | _ ->
            (* Discover all migrations *)
            match Discovery.find_migrations ~dir:migrations_dir () with
            | Error err ->
                Lwt_io.eprintlf "Error: %s" (Types.show_error err) >>= fun () ->
                exit 1
            | Ok all_migrations ->
                (* Build set of applied versions *)
                let applied_set = Discovery.applied_set_of_list applied_versions in
                let applied_migrations = List.filter
                  (fun m -> Discovery.Int64Set.mem m.Migration.version applied_set)
                  all_migrations in

                (* Determine which migrations to rollback based on mode *)
                let to_rollback =
                  if all then
                    applied_migrations
                  else match to_version with
                  | Some target ->
                      List.filter (fun m ->
                        Int64.compare m.Migration.version target > 0)
                        applied_migrations
                  | None ->
                      let n = Option.value step ~default:1 in
                      let sorted = List.sort (fun a b ->
                        Int64.compare b.Migration.version a.Migration.version)
                        applied_migrations in
                      List.filteri (fun i _ -> i < n) sorted
                in

                match to_rollback with
                | [] -> Lwt_io.printl "No migrations to rollback"
                | _ ->
                    rollback_migrations_with_progress ~verbose db to_rollback >>= fun results ->
                    let failed = List.filter (fun r -> not (Runner.is_success r)) results in
                    if List.length failed > 0 then exit 1 else Lwt.return_unit
  )

let status migrations_dir database_url =
  with_initialized_db database_url (fun db ->
    Runner.get_applied_versions db >>= function
    | Error err ->
        Lwt_io.eprintlf "Failed to get applied migrations: %s"
          (Caqti_error.show err) >>= fun () ->
        exit 1
    | Ok applied_versions ->
        (* Build set for O(1) lookup *)
        let applied_set = Discovery.applied_set_of_list applied_versions in

        (* Find all migrations *)
        match Discovery.find_migrations ~dir:migrations_dir () with
        | Error msg ->
            Lwt_io.eprintlf "Error: %s" (Types.show_error msg) >>= fun () ->
            exit 1
        | Ok migrations ->
            Lwt_io.printlf "\nDatabase: %s\n" database_url >>= fun () ->

            (* Print table header *)
            Lwt_io.printl "  Status    Migration ID    Migration Name" >>= fun () ->
            Lwt_io.printl "--------------------------------------------------" >>= fun () ->

            (* Print all migrations in chronological order *)
            match migrations with
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
                ) migrations
  )
