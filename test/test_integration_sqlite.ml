open Lwt.Infix
open Test_helpers

let with_sqlite_file prefix f =
  let timestamp = Unix.time () |> int_of_float in
  let random = Random.int 10000 in
  let db_file =
    Printf.sprintf "/tmp/migra_test_%s_%d_%d.db" prefix timestamp random
  in
  let db_url = Printf.sprintf "sqlite3://%s" db_file in

  Lwt.finalize
    (fun () -> f db_url db_file)
    (fun () ->
      if Sys.file_exists db_file then Lwt_unix.unlink db_file
      else Lwt.return_unit)

let with_sqlite_memory f =
  let db_url = "sqlite3://:memory:" in
  f db_url

let with_db db_url f =
  Migra_engine.Database.connect_db db_url >>= function
  | Error err ->
      Lwt.fail_with
        (Printf.sprintf "Failed to connect: %s" (Migra.Types.show_error err))
  | Ok db -> f db

let test_sqlite_file_creation () =
  with_sqlite_file "file_create" (fun db_url db_file ->
      Alcotest.(check bool)
        "SQLite file doesn't exist initially" false (Sys.file_exists db_file);

      with_db db_url (fun db ->
          Alcotest.(check bool)
            "SQLite file created on connect" true (Sys.file_exists db_file);

          Migra_engine.Runner.ensure_migrations_table
            Migra_engine.Dialect.SQLite db
          >>= function
          | Error err ->
              Alcotest.fail
                (Printf.sprintf "ensure_migrations_table failed: %s"
                   (Caqti_error.show err))
          | Ok () -> Lwt.return_unit))

let test_sqlite_create_database () =
  with_sqlite_file "create_db" (fun db_url db_file ->
      Migra_engine.Database.create_database db_url >>= function
      | Error err ->
          Alcotest.fail
            (Printf.sprintf "create_database failed: %s"
               (Migra.Types.show_error err))
      | Ok () ->
          with_db db_url (fun _db ->
              Alcotest.(check bool)
                "SQLite file exists after connect" true
                (Sys.file_exists db_file);
              Lwt.return_unit))

let test_sqlite_drop_database () =
  with_sqlite_file "drop_db" (fun db_url db_file ->
      with_db db_url (fun _db -> Lwt.return_unit) >>= fun () ->
      Alcotest.(check bool) "SQLite file exists" true (Sys.file_exists db_file);

      Migra_engine.Database.drop_database db_url >>= function
      | Error err ->
          Alcotest.fail
            (Printf.sprintf "drop_database failed: %s"
               (Migra.Types.show_error err))
      | Ok () ->
          Alcotest.(check bool)
            "SQLite file deleted after drop" false (Sys.file_exists db_file);
          Lwt.return_unit)

let test_sqlite_schema_table () =
  with_sqlite_file "schema_table" (fun db_url _db_file ->
      with_db db_url (fun db ->
          Migra_engine.Runner.ensure_migrations_table
            Migra_engine.Dialect.SQLite db
          >>= function
          | Error err ->
              Alcotest.fail
                (Printf.sprintf "ensure_migrations_table failed: %s"
                   (Caqti_error.show err))
          | Ok () -> (
              Migra_engine.Runner.get_applied_versions db >>= function
              | Error err ->
                  Alcotest.fail
                    (Printf.sprintf "get_applied_versions failed: %s"
                       (Caqti_error.show err))
              | Ok versions ->
                  Alcotest.(check int)
                    "Empty versions list" 0 (List.length versions);
                  Lwt.return_unit)))

let test_sqlite_schema_idempotent () =
  with_sqlite_file "schema_idem" (fun db_url _db_file ->
      with_db db_url (fun db ->
          Migra_engine.Runner.ensure_migrations_table
            Migra_engine.Dialect.SQLite db
          >>= function
          | Error err ->
              Alcotest.fail
                (Printf.sprintf "First ensure_migrations_table failed: %s"
                   (Caqti_error.show err))
          | Ok () -> (
              Migra_engine.Runner.ensure_migrations_table
                Migra_engine.Dialect.SQLite db
              >>= function
              | Error err ->
                  Alcotest.fail
                    (Printf.sprintf "Second ensure_migrations_table failed: %s"
                       (Caqti_error.show err))
              | Ok () -> Lwt.return_unit)))

let test_sqlite_migration_operations () =
  with_sqlite_file "migration_ops" (fun db_url _db_file ->
      with_db db_url (fun db ->
          Migra_engine.Runner.ensure_migrations_table
            Migra_engine.Dialect.SQLite db
          >>= function
          | Error err ->
              Alcotest.fail
                (Printf.sprintf "ensure_migrations_table failed: %s"
                   (Caqti_error.show err))
          | Ok () -> (
              let version = 20240115120000L in

              Migra_engine.Runner.is_applied db version >>= function
              | Error err ->
                  Alcotest.fail
                    (Printf.sprintf "is_applied failed: %s"
                       (Caqti_error.show err))
              | Ok applied -> (
                  Alcotest.(check bool)
                    "Version not applied initially" false applied;

                  Migra_engine.Runner.add_migration db version None >>= function
                  | Error err ->
                      Alcotest.fail
                        (Printf.sprintf "add_migration failed: %s"
                           (Caqti_error.show err))
                  | Ok () -> (
                      Migra_engine.Runner.is_applied db version >>= function
                      | Error err ->
                          Alcotest.fail
                            (Printf.sprintf "is_applied after add failed: %s"
                               (Caqti_error.show err))
                      | Ok applied -> (
                          Alcotest.(check bool)
                            "Version applied after add" true applied;

                          Migra_engine.Runner.remove_migration db version
                          >>= function
                          | Error err ->
                              Alcotest.fail
                                (Printf.sprintf "remove_migration failed: %s"
                                   (Caqti_error.show err))
                          | Ok () -> (
                              Migra_engine.Runner.is_applied db version
                              >>= function
                              | Error err ->
                                  Alcotest.fail
                                    (Printf.sprintf
                                       "is_applied after remove failed: %s"
                                       (Caqti_error.show err))
                              | Ok applied ->
                                  Alcotest.(check bool)
                                    "Version not applied after remove" false
                                    applied;
                                  Lwt.return_unit)))))))

let test_sqlite_get_records () =
  with_sqlite_file "get_records" (fun db_url _db_file ->
      with_db db_url (fun db ->
          Migra_engine.Runner.ensure_migrations_table
            Migra_engine.Dialect.SQLite db
          >>= function
          | Error err ->
              Alcotest.fail
                (Printf.sprintf "ensure_migrations_table failed: %s"
                   (Caqti_error.show err))
          | Ok () -> (
              let version = 20240115120000L in

              Migra_engine.Runner.add_migration db version None >>= function
              | Error err ->
                  Alcotest.fail
                    (Printf.sprintf "add_migration failed: %s"
                       (Caqti_error.show err))
              | Ok () -> (
                  Migra_engine.Runner.get_applied_records
                    Migra_engine.Dialect.SQLite db
                  >>= function
                  | Error err ->
                      Alcotest.fail
                        (Printf.sprintf "get_applied_records failed: %s"
                           (Caqti_error.show err))
                  | Ok records ->
                      Alcotest.(check int) "One record" 1 (List.length records);
                      let record = List.hd records in
                      Alcotest.(check int64_testable)
                        "Record version" version
                        record.Migra_engine.Runner.version;
                      Alcotest.(check bool)
                        "created_at exists" true
                        (String.length record.Migra_engine.Runner.created_at > 0);
                      Lwt.return_unit))))

let test_sqlite_latest_version () =
  with_sqlite_file "latest_version" (fun db_url _db_file ->
      with_db db_url (fun db ->
          Migra_engine.Runner.ensure_migrations_table
            Migra_engine.Dialect.SQLite db
          >>= function
          | Error err ->
              Alcotest.fail
                (Printf.sprintf "ensure_migrations_table failed: %s"
                   (Caqti_error.show err))
          | Ok () -> (
              Migra_engine.Runner.get_latest_version db >>= function
              | Error err ->
                  Alcotest.fail
                    (Printf.sprintf "get_latest_version failed: %s"
                       (Caqti_error.show err))
              | Ok latest -> (
                  Alcotest.(check (option int64_testable))
                    "No latest version initially" None latest;

                  let v1 = 20240114100000L in
                  let v2 = 20240115120000L in
                  let v3 = 20240116150000L in

                  Migra_engine.Runner.add_migration db v2 None >>= fun _ ->
                  Migra_engine.Runner.add_migration db v1 None >>= fun _ ->
                  Migra_engine.Runner.add_migration db v3 None >>= fun _ ->
                  Migra_engine.Runner.get_latest_version db >>= function
                  | Error err ->
                      Alcotest.fail
                        (Printf.sprintf "get_latest_version failed: %s"
                           (Caqti_error.show err))
                  | Ok latest ->
                      Alcotest.(check (option int64_testable))
                        "Latest is highest" (Some v3) latest;
                      Lwt.return_unit))))

let test_sqlite_memory_basic () =
  with_sqlite_memory (fun db_url ->
      with_db db_url (fun db ->
          Migra_engine.Runner.ensure_migrations_table
            Migra_engine.Dialect.SQLite db
          >>= function
          | Error err ->
              Alcotest.fail
                (Printf.sprintf "ensure_migrations_table failed: %s"
                   (Caqti_error.show err))
          | Ok () -> (
              let version = 20240115120000L in
              Migra_engine.Runner.add_migration db version None >>= function
              | Error err ->
                  Alcotest.fail
                    (Printf.sprintf "add_migration failed: %s"
                       (Caqti_error.show err))
              | Ok () -> (
                  Migra_engine.Runner.is_applied db version >>= function
                  | Error err ->
                      Alcotest.fail
                        (Printf.sprintf "is_applied failed: %s"
                           (Caqti_error.show err))
                  | Ok applied ->
                      Alcotest.(check bool)
                        "Migration applied in memory" true applied;
                      Lwt.return_unit))))

let test_sqlite_memory_create_database () =
  let db_url = "sqlite3://:memory:" in
  Migra_engine.Database.create_database db_url >>= function
  | Error err ->
      Alcotest.fail
        (Printf.sprintf "create_database for :memory: failed: %s"
           (Migra.Types.show_error err))
  | Ok () -> Lwt.return_unit

let test_sqlite_memory_drop_database () =
  let db_url = "sqlite3://:memory:" in
  Migra_engine.Database.drop_database db_url >>= function
  | Error err ->
      Alcotest.fail
        (Printf.sprintf "drop_database for :memory: failed: %s"
           (Migra.Types.show_error err))
  | Ok () -> Lwt.return_unit

(** Test: a SQLite :memory: database lives only as long as its connection.

    Within a single connection data persists, but each new connection to
    [sqlite3::memory:] is a brand-new, independent database. (True process-wide
    sharing would require [file::memory:?cache=shared].) This test documents
    that gotcha so nobody assumes :memory: behaves like a file. *)
let test_sqlite_memory_persistence () =
  with_sqlite_memory (fun db_url ->
      (* First connection: create the table, add a row, confirm it is visible
       on the same connection. *)
      with_db db_url (fun db ->
          Migra_engine.Runner.ensure_migrations_table
            Migra_engine.Dialect.SQLite db
          >>= function
          | Error err ->
              Alcotest.fail
                (Printf.sprintf "ensure_migrations_table failed: %s"
                   (Caqti_error.show err))
          | Ok () -> (
              let version = 20240115120000L in
              Migra_engine.Runner.add_migration db version None >>= function
              | Error err ->
                  Alcotest.fail
                    (Printf.sprintf "add_migration failed: %s"
                       (Caqti_error.show err))
              | Ok () -> (
                  Migra_engine.Runner.get_applied_versions db >>= function
                  | Error err ->
                      Alcotest.fail
                        (Printf.sprintf "get_applied_versions failed: %s"
                           (Caqti_error.show err))
                  | Ok versions ->
                      Alcotest.(check int)
                        ":memory: persists within one connection" 1
                        (List.length versions);
                      Lwt.return_unit)))
      >>= fun () ->
      (* Second connection to the same :memory: URL is an independent database:
       create the table fresh and confirm it starts empty - the first
       connection's row did not carry over. *)
      with_db db_url (fun db ->
          Migra_engine.Runner.ensure_migrations_table
            Migra_engine.Dialect.SQLite db
          >>= function
          | Error err ->
              Alcotest.fail
                (Printf.sprintf "ensure_migrations_table failed: %s"
                   (Caqti_error.show err))
          | Ok () -> (
              Migra_engine.Runner.get_applied_versions db >>= function
              | Error err ->
                  Alcotest.fail
                    (Printf.sprintf "get_applied_versions failed: %s"
                       (Caqti_error.show err))
              | Ok versions ->
                  Alcotest.(check int)
                    "fresh :memory: connection starts empty" 0
                    (List.length versions);
                  Lwt.return_unit)))

(** Test: SQLite dialect timestamp conversion (auto-converts, no casting needed)
*)
let test_sqlite_timestamp_conversion () =
  with_sqlite_file "timestamp" (fun db_url _db_file ->
      with_db db_url (fun db ->
          Migra_engine.Runner.ensure_migrations_table
            Migra_engine.Dialect.SQLite db
          >>= function
          | Error err ->
              Alcotest.fail
                (Printf.sprintf "ensure_migrations_table failed: %s"
                   (Caqti_error.show err))
          | Ok () -> (
              let version = 20240115120000L in
              Migra_engine.Runner.add_migration db version None >>= function
              | Error err ->
                  Alcotest.fail
                    (Printf.sprintf "add_migration failed: %s"
                       (Caqti_error.show err))
              | Ok () -> (
                  Migra_engine.Runner.get_applied_records
                    Migra_engine.Dialect.SQLite db
                  >>= function
                  | Error err ->
                      Alcotest.fail
                        (Printf.sprintf "get_applied_records failed: %s"
                           (Caqti_error.show err))
                  | Ok records ->
                      Alcotest.(check int) "One record" 1 (List.length records);
                      let record = List.hd records in
                      Alcotest.(check bool)
                        "Timestamp converted to string" true
                        (String.length record.Migra_engine.Runner.created_at > 0);
                      Lwt.return_unit))))

let file_based_tests =
  [
    ("SQLite file creation on connect", `Quick, test_sqlite_file_creation);
    ( "SQLite create_database (no-op for file)",
      `Quick,
      test_sqlite_create_database );
    ("SQLite drop_database removes file", `Quick, test_sqlite_drop_database);
    ("SQLite schema_migrations table creation", `Quick, test_sqlite_schema_table);
    ("SQLite schema table is idempotent", `Quick, test_sqlite_schema_idempotent);
    ("SQLite migration operations", `Quick, test_sqlite_migration_operations);
    ("SQLite get_applied_records", `Quick, test_sqlite_get_records);
    ("SQLite get_latest_version", `Quick, test_sqlite_latest_version);
    ("SQLite timestamp conversion", `Quick, test_sqlite_timestamp_conversion);
  ]

let memory_tests =
  [
    ("SQLite :memory: basic operations", `Quick, test_sqlite_memory_basic);
    ( "SQLite :memory: create_database (no-op)",
      `Quick,
      test_sqlite_memory_create_database );
    ( "SQLite :memory: drop_database (no-op)",
      `Quick,
      test_sqlite_memory_drop_database );
    ("SQLite :memory: is per-connection", `Quick, test_sqlite_memory_persistence);
  ]

let suite = file_based_tests @ memory_tests
