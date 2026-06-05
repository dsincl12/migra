(** Run pending migrations at application startup. *)

let resolve_url () =
  if Array.length Sys.argv > 1 then Sys.argv.(1)
  else
    match Migra.Database.get_database_url () with
    | Ok url -> url
    | Error e ->
        prerr_endline (Migra.Types.show_error e);
        exit 1

let () =
  let database_url = resolve_url () in
  let migrations_dir =
    if Array.length Sys.argv > 2 then Sys.argv.(2) else "migrations"
  in
  let config = Migra.Migrator.make ~database_url ~migrations_dir () in
  match Lwt_main.run (Migra.Migrator.run config) with
  | Error e ->
      Printf.eprintf "migration error: %s\n" (Migra.Types.show_error e);
      exit 1
  | Ok r when not (Migra.Migrator.succeeded r) ->
      Printf.eprintf "%d migration(s) failed\n" r.failure_count;
      exit 1
  | Ok r -> Printf.printf "applied %d migration(s)\n" r.success_count
