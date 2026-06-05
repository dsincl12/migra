(** CLI command implementations for Migra. *)

open Lwt.Infix
open Migra

let config ~migrations_dir ~table ~verbose database_url : Migrator.config =
  Migrator.make ~database_url ~migrations_dir ~table ~verbose ()

let fail_error err =
  Lwt_io.eprintlf "Error: %s" (Types.show_error err) >>= fun () -> Lwt.return 1

let code_of_result (r : Migrator.operation_result) =
  if Migrator.succeeded r then 0 else 1

let report verb (r : Migrator.migration_result) =
  match r.error with
  | None ->
      Lwt_io.printlf "== %s %Ld in %.3fs\n" verb r.version
        (Option.value r.elapsed_seconds ~default:0.)
  | Some e -> Lwt_io.eprintlf "** %Ld failed: %s" r.version e

let print_event : Migrator.event -> unit Lwt.t = function
  | Migrator.Applying (v, name) -> Lwt_io.printlf "== Applying %Ld %s" v name
  | Migrator.Rolling_back (v, name) ->
      Lwt_io.printlf "== Rolling back %Ld %s" v name
  | Migrator.Applied r -> report "Applied" r
  | Migrator.Rolled_back r -> report "Rolled back" r

let print_plan verb (plan : (int64 * string) list) =
  Lwt_io.printlf "Would %s %d migration(s):" verb (List.length plan)
  >>= fun () ->
  Lwt_list.iter_s (fun (v, name) -> Lwt_io.printlf "  %Ld  %s" v name) plan
  >>= fun () -> Lwt.return 0

let generate name =
  match Migrator.generate name with
  | Ok path -> Lwt_io.printlf "Creating %s" path >>= fun () -> Lwt.return 0
  | Error err -> fail_error err

let migrate migrations_dir table dry_run verbose database_url =
  let cfg = config ~migrations_dir ~table ~verbose database_url in
  if dry_run then
    Migrator.pending_plan cfg >>= function
    | Error err -> fail_error err
    | Ok [] -> Lwt_io.printl "No pending migrations" >>= fun () -> Lwt.return 0
    | Ok plan -> print_plan "apply" plan
  else
    Migrator.run ~on_event:print_event cfg >>= function
    | Error err -> fail_error err
    | Ok r ->
        if r.Migrator.migrations = [] then
          Lwt_io.printl "No pending migrations" >>= fun () -> Lwt.return 0
        else Lwt.return (code_of_result r)

let init database_url =
  match Database.database_name database_url with
  | Error err -> fail_error err
  | Ok name -> (
      Lwt_io.printlf "Creating database: %s" name >>= fun () ->
      Database.create_database database_url >>= function
      | Error err ->
          Lwt_io.eprintlf "Failed to create database: %s" (Types.show_error err)
          >>= fun () -> Lwt.return 1
      | Ok () ->
          Lwt_io.printlf "Database '%s' created successfully" name >>= fun () ->
          Lwt.return 0)

let setup migrations_dir table verbose database_url =
  let cfg = config ~migrations_dir ~table ~verbose database_url in
  match Database.database_name database_url with
  | Error err -> fail_error err
  | Ok name -> (
      Lwt_io.printlf "Creating database: %s" name >>= fun () ->
      Database.create_database database_url >>= function
      | Error err ->
          Lwt_io.eprintlf "Failed to create database: %s" (Types.show_error err)
          >>= fun () -> Lwt.return 1
      | Ok () -> (
          Lwt_io.printlf "Database '%s' ready\n" name >>= fun () ->
          Migrator.run ~on_event:print_event cfg >>= function
          | Error err -> fail_error err
          | Ok r ->
              if Migrator.succeeded r then
                Lwt_io.printl "Setup complete!" >>= fun () -> Lwt.return 0
              else Lwt.return 1))

let drop database_url =
  match Database.database_name database_url with
  | Error err -> fail_error err
  | Ok name -> (
      Lwt_io.printlf "Dropping database: %s" name >>= fun () ->
      Database.drop_database database_url >>= function
      | Error err ->
          Lwt_io.eprintlf "Failed to drop database: %s" (Types.show_error err)
          >>= fun () -> Lwt.return 1
      | Ok () ->
          Lwt_io.printlf "Database '%s' dropped successfully" name >>= fun () ->
          Lwt.return 0)

let reset migrations_dir table verbose database_url =
  let cfg = config ~migrations_dir ~table ~verbose database_url in
  match Database.database_name database_url with
  | Error err -> fail_error err
  | Ok name -> (
      Lwt_io.printlf "Resetting database: %s\n" name >>= fun () ->
      Lwt_io.printl "Dropping database..." >>= fun () ->
      Database.drop_database database_url >>= function
      | Error err ->
          Lwt_io.eprintlf "Failed to drop database: %s" (Types.show_error err)
          >>= fun () -> Lwt.return 1
      | Ok () -> (
          Lwt_io.printl "Creating database..." >>= fun () ->
          Database.create_database database_url >>= function
          | Error err ->
              Lwt_io.eprintlf "Failed to create database: %s"
                (Types.show_error err)
              >>= fun () -> Lwt.return 1
          | Ok () -> (
              Migrator.run ~on_event:print_event cfg >>= function
              | Error err -> fail_error err
              | Ok r ->
                  if Migrator.succeeded r then
                    Lwt_io.printl "Reset complete!" >>= fun () -> Lwt.return 0
                  else Lwt.return 1)))

let rollback migrations_dir table step to_version all dry_run verbose
    database_url =
  let cfg = config ~migrations_dir ~table ~verbose database_url in
  let strategy =
    if all then Migrator.All
    else
      match to_version with
      | Some target -> Migrator.To target
      | None -> Migrator.Step (Option.value step ~default:1)
  in
  if dry_run then
    Migrator.rollback_plan cfg strategy >>= function
    | Error err -> fail_error err
    | Ok [] ->
        Lwt_io.printl "No migrations to rollback" >>= fun () -> Lwt.return 0
    | Ok plan ->
        (* show them in the order they would be rolled back (newest first) *)
        let ordered = List.sort (fun (a, _) (b, _) -> Int64.compare b a) plan in
        print_plan "roll back" ordered
  else
    Migrator.rollback ~on_event:print_event cfg strategy >>= function
    | Error err -> fail_error err
    | Ok r ->
        if r.Migrator.migrations = [] then
          Lwt_io.printl "No migrations to rollback" >>= fun () -> Lwt.return 0
        else Lwt.return (code_of_result r)

let redo migrations_dir table step verbose database_url =
  let cfg = config ~migrations_dir ~table ~verbose database_url in
  Migrator.redo ?step ~on_event:print_event cfg >>= function
  | Error err -> fail_error err
  | Ok r ->
      if r.Migrator.migrations = [] then
        Lwt_io.printl "No migrations to redo" >>= fun () -> Lwt.return 0
      else Lwt.return (code_of_result r)

let status migrations_dir table database_url =
  let cfg = config ~migrations_dir ~table ~verbose:false database_url in
  Migrator.status cfg >>= function
  | Error err ->
      Lwt_io.eprintlf "Failed to get status: %s" (Types.show_error err)
      >>= fun () -> Lwt.return 1
  | Ok st ->
      Lwt_io.printlf "\nDatabase: %s\n"
        (Database.redact_url st.Migrator.database_url)
      >>= fun () ->
      Lwt_io.printl "  Status    Migration ID    Migration Name" >>= fun () ->
      Lwt_io.printl "--------------------------------------------------"
      >>= fun () ->
      (match st.Migrator.migrations with
        | [] -> Lwt_io.printl "  (no migrations found)"
        | ms ->
            Lwt_list.iter_s
              (fun (m : Migrator.migration_status) ->
                let s = if m.applied then "up" else "down" in
                Lwt_io.printlf "  %-8s  %Ld  %s" s m.version m.description)
              ms)
      >>= fun () -> Lwt.return 0
