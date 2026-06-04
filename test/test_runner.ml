open Lwt.Infix
open Test_helpers

let with_initialized_db db_url f =
  Migra.Database.connect_db db_url >>= function
  | Error err ->
      Lwt.fail_with
        (Printf.sprintf "Failed to connect: %s" (Migra.Types.show_error err))
  | Ok db -> (
      Migra.Runner.ensure_migrations_table Migra.Dialect.PostgreSQL db
      >>= function
      | Error err ->
          Lwt.fail_with
            (Printf.sprintf "Failed to create_table: %s" (Caqti_error.show err))
      | Ok () -> f db)

let test_run_migration_success () =
  with_test_db_pooled "runner_success" (fun db_url ->
      with_temp_dir "migrations" (fun migrations_dir ->
          let version = 20240115120000L in
          let _filepath =
            create_migration_with_sections migrations_dir version "create_table"
              "CREATE TABLE test_users (id SERIAL PRIMARY KEY, name TEXT);"
              "DROP TABLE test_users;"
          in

          let migration =
            match Migra.Discovery.find_migrations ~dir:migrations_dir () with
            | Ok (m :: _) -> m
            | _ -> Alcotest.fail "Failed to discover migration"
          in

          with_initialized_db db_url (fun db ->
              Migra.Runner.run_migration db migration >>= fun result ->
              match result with
              | Migra.Runner.Failure (_migration, err) ->
                  Alcotest.fail
                    (Printf.sprintf "run_migration failed: %s"
                       (Migra.Types.show_error err))
              | Migra.Runner.Success _migration -> (
                  Migra.Runner.is_applied db version >>= function
                  | Error err ->
                      Alcotest.fail
                        (Printf.sprintf "is_applied check failed: %s"
                           (Caqti_error.show err))
                  | Ok is_applied -> (
                      Alcotest.(check bool)
                        "version recorded in schema_migrations" true is_applied;

                      let module Db = (val db : Caqti_lwt.CONNECTION) in
                      let open Caqti_request.Infix in
                      let open Caqti_type.Std in
                      let query =
                        (unit ->! bool)
                          "SELECT EXISTS (SELECT 1 FROM \
                           information_schema.tables WHERE table_name = \
                           'test_users')"
                      in
                      Db.find query () >>= function
                      | Error err ->
                          Alcotest.fail
                            (Printf.sprintf "Table existence check failed: %s"
                               (Caqti_error.show err))
                      | Ok table_exists ->
                          Alcotest.(check bool)
                            "test_users table exists" true table_exists;
                          Lwt.return_unit)))))

let test_run_migration_sql_failure_rollback () =
  with_test_db_pooled "runner_sql_fail" (fun db_url ->
      with_temp_dir "migrations" (fun migrations_dir ->
          let version = 20240115120000L in
          let _filepath =
            create_migration_with_sections migrations_dir version "invalid_sql"
              "CREATE TABLE test_table (id SERIAL PRIMARY KEY); SELECT * FROM \
               nonexistent_table_xyz;"
              "DROP TABLE test_table;"
          in

          let migration =
            match Migra.Discovery.find_migrations ~dir:migrations_dir () with
            | Ok (m :: _) -> m
            | _ -> Alcotest.fail "Failed to discover migration"
          in

          with_initialized_db db_url (fun db ->
              Migra.Runner.run_migration db migration >>= fun result ->
              match result with
              | Migra.Runner.Success _ ->
                  Alcotest.fail "Expected migration to fail, but it succeeded"
              | Migra.Runner.Failure (_migration, _err) -> (
                  Migra.Runner.is_applied db version >>= function
                  | Error err ->
                      Alcotest.fail
                        (Printf.sprintf "is_applied check failed: %s"
                           (Caqti_error.show err))
                  | Ok is_applied -> (
                      Alcotest.(check bool)
                        "version NOT recorded (transaction rolled back)" false
                        is_applied;

                      let module Db = (val db : Caqti_lwt.CONNECTION) in
                      let open Caqti_request.Infix in
                      let open Caqti_type.Std in
                      let query =
                        (unit ->! bool)
                          "SELECT EXISTS (SELECT 1 FROM \
                           information_schema.tables WHERE table_name = \
                           'test_table')"
                      in
                      Db.find query () >>= function
                      | Error err ->
                          Alcotest.fail
                            (Printf.sprintf "Table existence check failed: %s"
                               (Caqti_error.show err))
                      | Ok table_exists ->
                          Alcotest.(check bool)
                            "test_table does NOT exist (rolled back)" false
                            table_exists;
                          Lwt.return_unit)))))

let test_run_migration_file_error () =
  with_test_db_pooled "runner_file_err" (fun db_url ->
      with_temp_dir "migrations" (fun migrations_dir ->
          let version = 20240115120000L in
          let filename = Migra.Migration.make_filename version "no_sections" in
          let filepath = Filename.concat migrations_dir filename in
          let oc = open_out filepath in
          output_string oc "This file has no up/down sections\n";
          close_out oc;

          let migration =
            match Migra.Discovery.find_migrations ~dir:migrations_dir () with
            | Ok (m :: _) -> m
            | _ -> Alcotest.fail "Failed to discover migration"
          in

          with_initialized_db db_url (fun db ->
              Migra.Runner.run_migration db migration >>= fun result ->
              Alcotest.(check bool)
                "migration failed" false
                (Migra.Runner.is_success result);
              Alcotest.(check bool)
                "has error message" true
                (Option.is_some (Migra.Runner.error_of_result result));

              Migra.Runner.is_applied db version >>= function
              | Error err ->
                  Alcotest.fail
                    (Printf.sprintf "is_applied check failed: %s"
                       (Caqti_error.show err))
              | Ok is_applied ->
                  Alcotest.(check bool) "version NOT recorded" false is_applied;
                  Lwt.return_unit)))

let test_run_migrations_multiple () =
  with_test_db_pooled "runner_multiple" (fun db_url ->
      with_temp_dir "migrations" (fun migrations_dir ->
          let v1 = 20240115120000L in
          let v2 = 20240115130000L in
          let v3 = 20240115140000L in

          let _f1 =
            create_migration_with_sections migrations_dir v1 "table1"
              "CREATE TABLE table1 (id SERIAL PRIMARY KEY);"
              "DROP TABLE table1;"
          in
          let _f2 =
            create_migration_with_sections migrations_dir v2 "table2"
              "CREATE TABLE table2 (id SERIAL PRIMARY KEY);"
              "DROP TABLE table2;"
          in
          let _f3 =
            create_migration_with_sections migrations_dir v3 "table3"
              "CREATE TABLE table3 (id SERIAL PRIMARY KEY);"
              "DROP TABLE table3;"
          in

          let migrations =
            match Migra.Discovery.find_migrations ~dir:migrations_dir () with
            | Ok migs -> migs
            | Error err ->
                Alcotest.fail
                  (Printf.sprintf "Failed to discover: %s"
                     (Migra.Types.show_error err))
          in

          with_initialized_db db_url (fun db ->
              Migra.Runner.run_migrations db migrations >>= fun results ->
              Alcotest.(check int) "3 results" 3 (List.length results);
              List.iter
                (fun result ->
                  Alcotest.(check bool)
                    "migration succeeded" true
                    (Migra.Runner.is_success result))
                results;

              Migra.Runner.get_applied_versions db >>= function
              | Error err ->
                  Alcotest.fail
                    (Printf.sprintf "get_applied_versions failed: %s"
                       (Caqti_error.show err))
              | Ok versions ->
                  Alcotest.(check int)
                    "3 versions recorded" 3 (List.length versions);
                  Alcotest.(check int64_testable)
                    "v1 recorded" v1 (List.nth versions 0);
                  Alcotest.(check int64_testable)
                    "v2 recorded" v2 (List.nth versions 1);
                  Alcotest.(check int64_testable)
                    "v3 recorded" v3 (List.nth versions 2);
                  Lwt.return_unit)))

let test_run_migrations_stops_on_failure () =
  with_test_db_pooled "runner_stop_fail" (fun db_url ->
      with_temp_dir "migrations" (fun migrations_dir ->
          let v1 = 20240115120000L in
          let v2 = 20240115130000L in
          let v3 = 20240115140000L in

          let _f1 =
            create_migration_with_sections migrations_dir v1 "table1"
              "CREATE TABLE table1 (id SERIAL PRIMARY KEY);"
              "DROP TABLE table1;"
          in
          let _f2 =
            create_migration_with_sections migrations_dir v2 "invalid"
              "SELECT * FROM nonexistent_table_xyz;" "-- nothing"
          in
          let _f3 =
            create_migration_with_sections migrations_dir v3 "table3"
              "CREATE TABLE table3 (id SERIAL PRIMARY KEY);"
              "DROP TABLE table3;"
          in

          let migrations =
            match Migra.Discovery.find_migrations ~dir:migrations_dir () with
            | Ok migs -> migs
            | Error err ->
                Alcotest.fail
                  (Printf.sprintf "Failed to discover: %s"
                     (Migra.Types.show_error err))
          in

          with_initialized_db db_url (fun db ->
              Migra.Runner.run_migrations db migrations >>= fun results ->
              Alcotest.(check int)
                "2 results (stopped after failure)" 2 (List.length results);
              Alcotest.(check bool)
                "first succeeded" true
                (Migra.Runner.is_success (List.nth results 0));
              Alcotest.(check bool)
                "second failed" false
                (Migra.Runner.is_success (List.nth results 1));

              Migra.Runner.get_applied_versions db >>= function
              | Error err ->
                  Alcotest.fail
                    (Printf.sprintf "get_applied_versions failed: %s"
                       (Caqti_error.show err))
              | Ok versions ->
                  Alcotest.(check int)
                    "only 1 version recorded" 1 (List.length versions);
                  Alcotest.(check int64_testable)
                    "v1 recorded" v1 (List.nth versions 0);
                  Lwt.return_unit)))

let test_rollback_migration_success () =
  with_test_db_pooled "runner_rollback" (fun db_url ->
      with_temp_dir "migrations" (fun migrations_dir ->
          let version = 20240115120000L in
          let _filepath =
            create_migration_with_sections migrations_dir version "create_table"
              "CREATE TABLE test_rollback (id SERIAL PRIMARY KEY, name TEXT);"
              "DROP TABLE test_rollback;"
          in

          let migration =
            match Migra.Discovery.find_migrations ~dir:migrations_dir () with
            | Ok (m :: _) -> m
            | _ -> Alcotest.fail "Failed to discover migration"
          in

          with_initialized_db db_url (fun db ->
              Migra.Runner.run_migration db migration >>= function
              | Migra.Runner.Failure (_, err) ->
                  Alcotest.fail
                    (Printf.sprintf "run_migration failed: %s"
                       (Migra.Types.show_error err))
              | Migra.Runner.Success _ -> (
                  Migra.Runner.rollback_migration db migration >>= fun result ->
                  match result with
                  | Migra.Runner.Failure (_, err) ->
                      Alcotest.fail
                        (Printf.sprintf "rollback_migration failed: %s"
                           (Migra.Types.show_error err))
                  | Migra.Runner.Success _ -> (
                      Alcotest.(check bool)
                        "rollback succeeded" true
                        (Migra.Runner.is_success result);

                      Migra.Runner.is_applied db version >>= function
                      | Error err ->
                          Alcotest.fail
                            (Printf.sprintf "is_applied check failed: %s"
                               (Caqti_error.show err))
                      | Ok is_applied -> (
                          Alcotest.(check bool)
                            "version removed" false is_applied;

                          let module Db = (val db : Caqti_lwt.CONNECTION) in
                          let open Caqti_request.Infix in
                          let open Caqti_type.Std in
                          let query =
                            (unit ->! bool)
                              "SELECT EXISTS (SELECT 1 FROM \
                               information_schema.tables WHERE table_name = \
                               'test_rollback')"
                          in
                          Db.find query () >>= function
                          | Error err ->
                              Alcotest.fail
                                (Printf.sprintf
                                   "Table existence check failed: %s"
                                   (Caqti_error.show err))
                          | Ok table_exists ->
                              Alcotest.(check bool)
                                "test_rollback table dropped" false table_exists;
                              Lwt.return_unit))))))

let test_rollback_migration_sql_failure () =
  with_test_db_pooled "runner_rollback_fail" (fun db_url ->
      with_temp_dir "migrations" (fun migrations_dir ->
          let version = 20240115120000L in
          let _filepath =
            create_migration_with_sections migrations_dir version "bad_rollback"
              "CREATE TABLE test_table (id SERIAL PRIMARY KEY);"
              "SELECT * FROM nonexistent_table_xyz;"
          in

          let migration =
            match Migra.Discovery.find_migrations ~dir:migrations_dir () with
            | Ok (m :: _) -> m
            | _ -> Alcotest.fail "Failed to discover migration"
          in

          with_initialized_db db_url (fun db ->
              Migra.Runner.run_migration db migration >>= function
              | Migra.Runner.Failure (_, err) ->
                  Alcotest.fail
                    (Printf.sprintf "run_migration failed: %s"
                       (Migra.Types.show_error err))
              | Migra.Runner.Success _ -> (
                  Migra.Runner.rollback_migration db migration >>= fun result ->
                  Alcotest.(check bool)
                    "rollback failed" false
                    (Migra.Runner.is_success result);

                  Migra.Runner.is_applied db version >>= function
                  | Error err ->
                      Alcotest.fail
                        (Printf.sprintf "is_applied check failed: %s"
                           (Caqti_error.show err))
                  | Ok is_applied ->
                      Alcotest.(check bool)
                        "version still recorded (rollback rolled back)" true
                        is_applied;
                      Lwt.return_unit))))

let test_rollback_step () =
  with_test_db_pooled "runner_step" (fun db_url ->
      with_temp_dir "migrations" (fun migrations_dir ->
          let v1 = 20240115120000L in
          let v2 = 20240115130000L in
          let v3 = 20240115140000L in

          let _f1 =
            create_migration_with_sections migrations_dir v1 "table1"
              "CREATE TABLE table1 (id SERIAL PRIMARY KEY);"
              "DROP TABLE table1;"
          in
          let _f2 =
            create_migration_with_sections migrations_dir v2 "table2"
              "CREATE TABLE table2 (id SERIAL PRIMARY KEY);"
              "DROP TABLE table2;"
          in
          let _f3 =
            create_migration_with_sections migrations_dir v3 "table3"
              "CREATE TABLE table3 (id SERIAL PRIMARY KEY);"
              "DROP TABLE table3;"
          in

          let migrations =
            match Migra.Discovery.find_migrations ~dir:migrations_dir () with
            | Ok migs -> migs
            | Error err ->
                Alcotest.fail
                  (Printf.sprintf "Failed to discover: %s"
                     (Migra.Types.show_error err))
          in

          with_initialized_db db_url (fun db ->
              Migra.Runner.run_migrations db migrations >>= fun _ ->
              Migra.Runner.rollback_step ~migrations_dir db 2 >>= function
              | Error err ->
                  Alcotest.fail
                    (Printf.sprintf "rollback_step failed: %s"
                       (Migra.Types.show_error err))
              | Ok results -> (
                  Alcotest.(check int) "2 rollbacks" 2 (List.length results);

                  Migra.Runner.get_applied_versions db >>= function
                  | Error err ->
                      Alcotest.fail
                        (Printf.sprintf "get_applied_versions failed: %s"
                           (Caqti_error.show err))
                  | Ok versions ->
                      Alcotest.(check int)
                        "only 1 version remains" 1 (List.length versions);
                      Alcotest.(check int64_testable)
                        "v1 remains" v1 (List.nth versions 0);
                      Lwt.return_unit))))

let test_rollback_to () =
  with_test_db_pooled "runner_to" (fun db_url ->
      with_temp_dir "migrations" (fun migrations_dir ->
          let v1 = 20240115120000L in
          let v2 = 20240115130000L in
          let v3 = 20240115140000L in

          let _f1 =
            create_migration_with_sections migrations_dir v1 "table1"
              "CREATE TABLE table1 (id SERIAL PRIMARY KEY);"
              "DROP TABLE table1;"
          in
          let _f2 =
            create_migration_with_sections migrations_dir v2 "table2"
              "CREATE TABLE table2 (id SERIAL PRIMARY KEY);"
              "DROP TABLE table2;"
          in
          let _f3 =
            create_migration_with_sections migrations_dir v3 "table3"
              "CREATE TABLE table3 (id SERIAL PRIMARY KEY);"
              "DROP TABLE table3;"
          in

          let migrations =
            match Migra.Discovery.find_migrations ~dir:migrations_dir () with
            | Ok migs -> migs
            | Error err ->
                Alcotest.fail
                  (Printf.sprintf "Failed to discover: %s"
                     (Migra.Types.show_error err))
          in

          with_initialized_db db_url (fun db ->
              Migra.Runner.run_migrations db migrations >>= fun _ ->
              Migra.Runner.rollback_to ~migrations_dir db v1 >>= function
              | Error err ->
                  Alcotest.fail
                    (Printf.sprintf "rollback_to failed: %s"
                       (Migra.Types.show_error err))
              | Ok results -> (
                  Alcotest.(check int) "2 rollbacks" 2 (List.length results);

                  Migra.Runner.get_applied_versions db >>= function
                  | Error err ->
                      Alcotest.fail
                        (Printf.sprintf "get_applied_versions failed: %s"
                           (Caqti_error.show err))
                  | Ok versions ->
                      Alcotest.(check int)
                        "only 1 version remains" 1 (List.length versions);
                      Alcotest.(check int64_testable)
                        "v1 remains" v1 (List.nth versions 0);
                      Lwt.return_unit))))

let test_rollback_all () =
  with_test_db_pooled "runner_all" (fun db_url ->
      with_temp_dir "migrations" (fun migrations_dir ->
          let v1 = 20240115120000L in
          let v2 = 20240115130000L in
          let v3 = 20240115140000L in

          let _f1 =
            create_migration_with_sections migrations_dir v1 "table1"
              "CREATE TABLE table1 (id SERIAL PRIMARY KEY);"
              "DROP TABLE table1;"
          in
          let _f2 =
            create_migration_with_sections migrations_dir v2 "table2"
              "CREATE TABLE table2 (id SERIAL PRIMARY KEY);"
              "DROP TABLE table2;"
          in
          let _f3 =
            create_migration_with_sections migrations_dir v3 "table3"
              "CREATE TABLE table3 (id SERIAL PRIMARY KEY);"
              "DROP TABLE table3;"
          in

          let migrations =
            match Migra.Discovery.find_migrations ~dir:migrations_dir () with
            | Ok migs -> migs
            | Error err ->
                Alcotest.fail
                  (Printf.sprintf "Failed to discover: %s"
                     (Migra.Types.show_error err))
          in

          with_initialized_db db_url (fun db ->
              Migra.Runner.run_migrations db migrations >>= fun _ ->
              Migra.Runner.rollback_all ~migrations_dir db >>= function
              | Error err ->
                  Alcotest.fail
                    (Printf.sprintf "rollback_all failed: %s"
                       (Migra.Types.show_error err))
              | Ok results -> (
                  Alcotest.(check int) "3 rollbacks" 3 (List.length results);

                  Migra.Runner.get_applied_versions db >>= function
                  | Error err ->
                      Alcotest.fail
                        (Printf.sprintf "get_applied_versions failed: %s"
                           (Caqti_error.show err))
                  | Ok versions ->
                      Alcotest.(check int)
                        "no versions remain" 0 (List.length versions);
                      Lwt.return_unit))))

let test_run_pending () =
  with_test_db_pooled "runner_pending" (fun db_url ->
      with_temp_dir "migrations" (fun migrations_dir ->
          let v1 = 20240115120000L in
          let v2 = 20240115130000L in
          let v3 = 20240115140000L in

          let _f1 =
            create_migration_with_sections migrations_dir v1 "table1"
              "CREATE TABLE table1 (id SERIAL PRIMARY KEY);"
              "DROP TABLE table1;"
          in
          let _f2 =
            create_migration_with_sections migrations_dir v2 "table2"
              "CREATE TABLE table2 (id SERIAL PRIMARY KEY);"
              "DROP TABLE table2;"
          in
          let _f3 =
            create_migration_with_sections migrations_dir v3 "table3"
              "CREATE TABLE table3 (id SERIAL PRIMARY KEY);"
              "DROP TABLE table3;"
          in

          with_initialized_db db_url (fun db ->
              Migra.Runner.run_pending db migrations_dir >>= function
              | Error err ->
                  Alcotest.fail
                    (Printf.sprintf "run_pending failed: %s"
                       (Migra.Types.show_error err))
              | Ok results -> (
                  Alcotest.(check int)
                    "3 migrations executed" 3 (List.length results);
                  List.iter
                    (fun result ->
                      Alcotest.(check bool)
                        "migration succeeded" true
                        (Migra.Runner.is_success result))
                    results;

                  Migra.Runner.get_applied_versions db >>= function
                  | Error err ->
                      Alcotest.fail
                        (Printf.sprintf "get_applied_versions failed: %s"
                           (Caqti_error.show err))
                  | Ok versions ->
                      Alcotest.(check int)
                        "3 versions recorded" 3 (List.length versions);
                      Lwt.return_unit))))

let suite =
  [
    ("run_migration_success", `Quick, test_run_migration_success);
    ( "run_migration_sql_failure_rollback",
      `Quick,
      test_run_migration_sql_failure_rollback );
    ("run_migration_file_error", `Quick, test_run_migration_file_error);
    ("run_migrations_multiple", `Quick, test_run_migrations_multiple);
    ( "run_migrations_stops_on_failure",
      `Quick,
      test_run_migrations_stops_on_failure );
    ("rollback_migration_success", `Quick, test_rollback_migration_success);
    ( "rollback_migration_sql_failure",
      `Quick,
      test_rollback_migration_sql_failure );
    ("rollback_step", `Quick, test_rollback_step);
    ("rollback_to", `Quick, test_rollback_to);
    ("rollback_all", `Quick, test_rollback_all);
    ("run_pending", `Quick, test_run_pending);
  ]
