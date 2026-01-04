(** Migra CLI entry point. *)

open Cmdliner
open Lwt.Infix

(* Helper to run Lwt tasks *)
let run_lwt f =
  Lwt_main.run (
    Lwt.catch
      (fun () -> f ())
      (fun exn ->
        Lwt_io.eprintlf "Error: %s" (Printexc.to_string exn) >>= fun () ->
        exit 1
      )
  )

(* Get database URL or exit with error *)
let require_database_url () =
  match Migra.Database.get_database_url () with
  | Ok url -> url
  | Error err ->
      Printf.eprintf "Error: %s\n" (Migra.Types.show_error err);
      Printf.eprintf "Please set DATABASE_URL environment variable\n";
      Printf.eprintf "Example: export DATABASE_URL=\"postgresql://user@localhost:5432/myapp\"\n";
      exit 1

(* Create command *)
let create_cmd =
  let name = Arg.(required & pos 0 (some string) None & info [] ~docv:"NAME" ~doc:"Migration name") in
  let run name = run_lwt (fun () -> Commands.create name) in
  let doc = "Create a new migration file" in
  let info = Cmd.info "create" ~doc in
  Cmd.v info Term.(const run $ name)

(* Migrate command *)
let migrate_cmd =
  let migrations_dir =
    Arg.(value & opt string "migrations" & info ["d"; "dir"] ~docv:"DIR"
      ~doc:"Migrations directory (default: migrations)")
  in
  let verbose =
    Arg.(value & flag & info ["v"; "verbose"] ~doc:"Show SQL statements and transaction details")
  in
  let run migrations_dir verbose =
    run_lwt (fun () -> Commands.migrate migrations_dir verbose (require_database_url ()))
  in
  let doc = "Run all pending migrations" in
  let info = Cmd.info "migrate" ~doc in
  Cmd.v info Term.(const run $ migrations_dir $ verbose)

(* Init command *)
let init_cmd =
  let run () =
    run_lwt (fun () -> Commands.init (require_database_url ()))
  in
  let doc = "Create the database" in
  let info = Cmd.info "init" ~doc in
  Cmd.v info Term.(const run $ const ())

(* Setup command *)
let setup_cmd =
  let migrations_dir =
    Arg.(value & opt string "migrations" & info ["d"; "dir"] ~docv:"DIR"
      ~doc:"Migrations directory (default: migrations)")
  in
  let verbose =
    Arg.(value & flag & info ["v"; "verbose"] ~doc:"Show SQL statements and transaction details")
  in
  let run migrations_dir verbose =
    run_lwt (fun () -> Commands.setup migrations_dir verbose (require_database_url ()))
  in
  let doc = "Create the database and run migrations" in
  let info = Cmd.info "setup" ~doc in
  Cmd.v info Term.(const run $ migrations_dir $ verbose)

(* Drop command *)
let drop_cmd =
  let run () =
    run_lwt (fun () -> Commands.drop (require_database_url ()))
  in
  let doc = "Drop the database" in
  let info = Cmd.info "drop" ~doc in
  Cmd.v info Term.(const run $ const ())

(* Reset command *)
let reset_cmd =
  let migrations_dir =
    Arg.(value & opt string "migrations" & info ["d"; "dir"] ~docv:"DIR"
      ~doc:"Migrations directory (default: migrations)")
  in
  let verbose =
    Arg.(value & flag & info ["v"; "verbose"] ~doc:"Show SQL statements and transaction details")
  in
  let run migrations_dir verbose =
    run_lwt (fun () -> Commands.reset migrations_dir verbose (require_database_url ()))
  in
  let doc = "Drop the database and recreate it with migrations" in
  let info = Cmd.info "reset" ~doc in
  Cmd.v info Term.(const run $ migrations_dir $ verbose)

(* Rollback command *)
let rollback_cmd =
  let migrations_dir =
    Arg.(value & opt string "migrations" & info ["d"; "dir"] ~docv:"DIR"
      ~doc:"Migrations directory (default: migrations)")
  in
  let step =
    Arg.(value & opt (some int) None & info ["step"] ~docv:"N"
      ~doc:"Rollback N migrations (default: 1)")
  in
  let to_version =
    Arg.(value & opt (some int64) None & info ["to"] ~docv:"VERSION"
      ~doc:"Rollback to specific version (exclusive)")
  in
  let all =
    Arg.(value & flag & info ["all"] ~doc:"Rollback all migrations")
  in
  let verbose =
    Arg.(value & flag & info ["v"; "verbose"] ~doc:"Show SQL statements and transaction details")
  in
  let run migrations_dir step to_version all verbose =
    run_lwt (fun () ->
      Commands.rollback migrations_dir step to_version all verbose (require_database_url ())
    )
  in
  let doc = "Rollback migrations" in
  let info = Cmd.info "rollback" ~doc in
  Cmd.v info Term.(const run $ migrations_dir $ step $ to_version $ all $ verbose)

(* Status command *)
let status_cmd =
  let migrations_dir =
    Arg.(value & opt string "migrations" & info ["d"; "dir"] ~docv:"DIR"
      ~doc:"Migrations directory (default: migrations)")
  in
  let run migrations_dir =
    run_lwt (fun () -> Commands.status migrations_dir (require_database_url ()))
  in
  let doc = "Show migration status" in
  let info = Cmd.info "status" ~doc in
  Cmd.v info Term.(const run $ migrations_dir)

(* Main command group *)
let main_cmd =
  let doc = "Simple database migration tool for OCaml" in
  let sdocs = Manpage.s_common_options in
  let info = Cmd.info "migra" ~version:"0.1.0" ~doc ~sdocs in
  Cmd.group info [create_cmd; drop_cmd; init_cmd; migrate_cmd; reset_cmd; rollback_cmd; setup_cmd; status_cmd]

(* Entry point *)
let () = exit (Cmd.eval main_cmd)
