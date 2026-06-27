(** Migra CLI entry point. *)

open Cmdliner
open Lwt.Infix

(* Run an Lwt command that yields an exit code, then exit with it.
   Exiting here - after the event loop has fully settled - lets resource
   finalizers (e.g. Database.with_db's disconnect) run before the process ends,
   which a mid-callback [exit] would skip. *)
let run_lwt (f : unit -> int Lwt.t) =
  let code =
    Lwt_main.run
      (Lwt.catch
         (fun () -> f ())
         (fun exn ->
           Lwt_io.eprintlf "Error: %s" (Printexc.to_string exn) >>= fun () ->
           Lwt.return 1))
  in
  exit code

(* Get database URL or exit with error *)
let require_database_url () =
  match Migra.Database.get_database_url () with
  | Ok url -> url
  | Error err ->
      Printf.eprintf "Error: %s\n" (Migra.Types.show_error err);
      Printf.eprintf "Please set DATABASE_URL or pass --database-url\n";
      Printf.eprintf
        "Example: export DATABASE_URL=\"postgresql://user@localhost:5432/myapp\"\n";
      exit 1

(* Resolve the connection URL: the --database-url flag takes precedence over the
   DATABASE_URL environment variable. *)
let resolve_database_url = function
  | Some url -> url
  | None -> require_database_url ()

(* Shared --database-url option *)
let db_url_arg =
  Arg.(
    value
    & opt (some string) None
    & info [ "D"; "database-url" ] ~docv:"URL"
        ~doc:"Connection URL (overrides the DATABASE_URL environment variable)")

(* Shared --dry-run flag *)
let dry_run_arg =
  Arg.(
    value & flag
    & info [ "dry-run" ]
        ~doc:"Show what would happen without changing the database")

(* Shared --table option: name of the migrations-tracking table *)
let table_arg =
  Arg.(
    value
    & opt string Migra.Migrator.default_table
    & info [ "t"; "table" ] ~docv:"NAME"
        ~doc:
          "Name of the migrations-tracking table (default: schema_migrations)")

(* Shared --dir option *)
let migrations_dir_arg =
  Arg.(
    value & opt string "migrations"
    & info [ "d"; "dir" ] ~docv:"DIR"
        ~doc:"Migrations directory (default: migrations)")

(* Shared --verbose flag *)
let verbose_arg =
  Arg.(
    value & flag
    & info [ "v"; "verbose" ] ~doc:"Show SQL statements and transaction details")

(* Shared --step option *)
let step_arg =
  Arg.(
    value
    & opt (some int) None
    & info [ "step" ] ~docv:"N" ~doc:"Number of migrations (default: 1)")

(* Generate command *)
let generate_cmd =
  let name =
    Arg.(
      required
      & pos 0 (some string) None
      & info [] ~docv:"NAME" ~doc:"Migration name")
  in
  let run migrations_dir name =
    run_lwt (fun () -> Commands.generate migrations_dir name)
  in
  let doc = "Generate a new migration file" in
  let info = Cmd.info "generate" ~doc in
  Cmd.v info Term.(const run $ migrations_dir_arg $ name)

(* Migrate command *)
let migrate_cmd =
  let run migrations_dir table dry_run verbose db_url =
    run_lwt (fun () ->
        Commands.migrate migrations_dir table dry_run verbose
          (resolve_database_url db_url))
  in
  let info = Cmd.info "migrate" ~doc:"Run all pending migrations" in
  Cmd.v info
    Term.(
      const run $ migrations_dir_arg $ table_arg $ dry_run_arg $ verbose_arg
      $ db_url_arg)

(* Init command *)
let init_cmd =
  let run db_url =
    run_lwt (fun () -> Commands.init (resolve_database_url db_url))
  in
  let info = Cmd.info "init" ~doc:"Create the database" in
  Cmd.v info Term.(const run $ db_url_arg)

(* Setup command *)
let setup_cmd =
  let run migrations_dir table verbose db_url =
    run_lwt (fun () ->
        Commands.setup migrations_dir table verbose
          (resolve_database_url db_url))
  in
  let info = Cmd.info "setup" ~doc:"Create the database and run migrations" in
  Cmd.v info
    Term.(const run $ migrations_dir_arg $ table_arg $ verbose_arg $ db_url_arg)

(* Drop command *)
let drop_cmd =
  let run db_url =
    run_lwt (fun () -> Commands.drop (resolve_database_url db_url))
  in
  let info = Cmd.info "drop" ~doc:"Drop the database" in
  Cmd.v info Term.(const run $ db_url_arg)

(* Reset command *)
let reset_cmd =
  let run migrations_dir table verbose db_url =
    run_lwt (fun () ->
        Commands.reset migrations_dir table verbose
          (resolve_database_url db_url))
  in
  let info =
    Cmd.info "reset" ~doc:"Drop the database and recreate it with migrations"
  in
  Cmd.v info
    Term.(const run $ migrations_dir_arg $ table_arg $ verbose_arg $ db_url_arg)

(* Rollback command *)
let rollback_cmd =
  let to_version =
    Arg.(
      value
      & opt (some int64) None
      & info [ "to" ] ~docv:"VERSION"
          ~doc:"Rollback to specific version (exclusive)")
  in
  let all =
    Arg.(value & flag & info [ "all" ] ~doc:"Rollback all migrations")
  in
  let run migrations_dir table step to_version all dry_run verbose db_url =
    run_lwt (fun () ->
        Commands.rollback migrations_dir table step to_version all dry_run
          verbose
          (resolve_database_url db_url))
  in
  let info = Cmd.info "rollback" ~doc:"Rollback migrations" in
  Cmd.v info
    Term.(
      const run $ migrations_dir_arg $ table_arg $ step_arg $ to_version $ all
      $ dry_run_arg $ verbose_arg $ db_url_arg)

(* Redo command *)
let redo_cmd =
  let run migrations_dir table step verbose db_url =
    run_lwt (fun () ->
        Commands.redo migrations_dir table step verbose
          (resolve_database_url db_url))
  in
  let info =
    Cmd.info "redo"
      ~doc:"Roll back the last migration(s), then run all pending migrations"
  in
  Cmd.v info
    Term.(
      const run $ migrations_dir_arg $ table_arg $ step_arg $ verbose_arg
      $ db_url_arg)

(* Status command *)
let status_cmd =
  let run migrations_dir table db_url =
    run_lwt (fun () ->
        Commands.status migrations_dir table (resolve_database_url db_url))
  in
  let info = Cmd.info "status" ~doc:"Show migration status" in
  Cmd.v info Term.(const run $ migrations_dir_arg $ table_arg $ db_url_arg)

(* The version stamped into the build by dune from the package version in
   dune-project (and VCS info), so it never has to be hand-edited here. It is
   [None] only in unusual builds with no version info; fall back to "dev" then. *)
let version =
  match Build_info.V1.version () with
  | Some v -> Build_info.V1.Version.to_string v
  | None -> "dev"

(* Main command group *)
let main_cmd =
  let doc = "Simple database migration tool for OCaml" in
  let sdocs = Manpage.s_common_options in
  let info = Cmd.info "migra" ~version ~doc ~sdocs in
  Cmd.group info
    [
      generate_cmd;
      drop_cmd;
      init_cmd;
      migrate_cmd;
      redo_cmd;
      reset_cmd;
      rollback_cmd;
      setup_cmd;
      status_cmd;
    ]

(* Entry point. Configure logging here (opt-in) rather than as a library
   load-time side effect, so linking Migra never hijacks an application's own
   logging - only the CLI installs a reporter. *)
let () =
  Migra.Logging.setup ();
  exit (Cmd.eval main_cmd)
