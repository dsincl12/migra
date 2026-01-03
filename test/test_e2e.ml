
open Lwt.Infix
open Test_helpers

let with_initialized_db db_url f =
  Migris.Database.connect_db db_url >>= function
  | Error msg -> Lwt.fail_with (Printf.sprintf "Failed to connect: %s" (Migris.Types.show_error msg))
  | Ok db ->
      Migris.Runner.ensure_migrations_table db >>= function
      | Error err -> Lwt.fail_with (Printf.sprintf "Failed to create_table: %s" (Caqti_error.show err))
      | Ok () -> f db

let test_fresh_setup_workflow () =
  with_test_db_pooled "e2e_fresh" (fun db_url ->
    with_temp_dir "migrations" (fun migrations_dir ->
      let v1 = 20240115120000L in
      let v2 = 20240115130000L in

      let _f1 = create_migration_with_sections migrations_dir v1 "create_users"
        "CREATE TABLE users (id SERIAL PRIMARY KEY, name TEXT NOT NULL);"
        "DROP TABLE users;" in
      let _f2 = create_migration_with_sections migrations_dir v2 "create_posts"
        "CREATE TABLE posts (id SERIAL PRIMARY KEY, user_id INTEGER NOT NULL, title TEXT);"
        "DROP TABLE posts;" in

      with_initialized_db db_url (fun db ->
        Migris.Runner.run_pending db migrations_dir >>= function
        | Error msg ->
            Alcotest.fail (Printf.sprintf "run_pending failed: %s" (Migris.Types.show_error msg))
        | Ok results ->
            Alcotest.(check int) "2 migrations executed" 2 (List.length results);
            List.iter (fun result ->
              Alcotest.(check bool) "migration succeeded" true (Migris.Runner.is_success result)
            ) results;

            Migris.Runner.get_applied_versions db >>= function
            | Error err ->
                Alcotest.fail (Printf.sprintf "get_applied_versions failed: %s" (Caqti_error.show err))
            | Ok versions ->
                Alcotest.(check int) "2 versions recorded" 2 (List.length versions);
                Alcotest.(check int64_testable) "v1 recorded" v1 (List.nth versions 0);
                Alcotest.(check int64_testable) "v2 recorded" v2 (List.nth versions 1);

                let module Db = (val db : Caqti_lwt.CONNECTION) in
                let open Caqti_request.Infix in
                let open Caqti_type.Std in

                let check_table name =
                  let query = (string ->! bool)
                    "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = $1)" in
                  Db.find query name >>= function
                  | Error err ->
                      Alcotest.fail (Printf.sprintf "Table check failed: %s" (Caqti_error.show err))
                  | Ok exists ->
                      Alcotest.(check bool) (Printf.sprintf "%s table exists" name) true exists;
                      Lwt.return_unit
                in

                check_table "users" >>= fun () ->
                check_table "posts" >>= fun () ->
                Lwt.return_unit
      )
    )
  )

let test_incremental_migrations () =
  with_test_db_pooled "e2e_incremental" (fun db_url ->
    with_temp_dir "migrations" (fun migrations_dir ->
      let v1 = 20240115120000L in
      let v2 = 20240115130000L in

      let _f1 = create_migration_with_sections migrations_dir v1 "table1"
        "CREATE TABLE table1 (id SERIAL PRIMARY KEY);" "DROP TABLE table1;" in
      let _f2 = create_migration_with_sections migrations_dir v2 "table2"
        "CREATE TABLE table2 (id SERIAL PRIMARY KEY);" "DROP TABLE table2;" in

      with_initialized_db db_url (fun db ->
        Migris.Runner.run_pending db migrations_dir >>= function
        | Error msg ->
            Alcotest.fail (Printf.sprintf "First run_pending failed: %s" (Migris.Types.show_error msg))
        | Ok results ->
            Alcotest.(check int) "2 migrations in first batch" 2 (List.length results);

            let v3 = 20240115140000L in
            let _f3 = create_migration_with_sections migrations_dir v3 "table3"
              "CREATE TABLE table3 (id SERIAL PRIMARY KEY);" "DROP TABLE table3;" in

            Migris.Runner.run_pending db migrations_dir >>= function
            | Error msg ->
                Alcotest.fail (Printf.sprintf "Second run_pending failed: %s" (Migris.Types.show_error msg))
            | Ok results2 ->
                Alcotest.(check int) "1 migration in second batch" 1 (List.length results2);
                Alcotest.(check int64_testable) "v3 was executed"
                  v3 (Migris.Runner.migration_of_result (List.hd results2)).Migris.Migration.version;

                Migris.Runner.get_applied_versions db >>= function
                | Error err ->
                    Alcotest.fail (Printf.sprintf "get_applied_versions failed: %s" (Caqti_error.show err))
                | Ok versions ->
                    Alcotest.(check int) "3 versions total" 3 (List.length versions);
                    Lwt.return_unit
      )
    )
  )

let test_rollback_workflow () =
  with_test_db_pooled "e2e_rollback" (fun db_url ->
    with_temp_dir "migrations" (fun migrations_dir ->
      let v1 = 20240115120000L in
      let v2 = 20240115130000L in
      let v3 = 20240115140000L in

      let _f1 = create_migration_with_sections migrations_dir v1 "users"
        "CREATE TABLE users (id SERIAL PRIMARY KEY);" "DROP TABLE users;" in
      let _f2 = create_migration_with_sections migrations_dir v2 "posts"
        "CREATE TABLE posts (id SERIAL PRIMARY KEY);" "DROP TABLE posts;" in
      let _f3 = create_migration_with_sections migrations_dir v3 "comments"
        "CREATE TABLE comments (id SERIAL PRIMARY KEY);" "DROP TABLE comments;" in

      with_initialized_db db_url (fun db ->
        Migris.Runner.run_pending db migrations_dir >>= function
        | Error msg ->
            Alcotest.fail (Printf.sprintf "run_pending failed: %s" (Migris.Types.show_error msg))
        | Ok _ ->
            Migris.Runner.rollback_step ~migrations_dir db 1 >>= function
            | Error msg ->
                Alcotest.fail (Printf.sprintf "rollback_step failed: %s" (Migris.Types.show_error msg))
            | Ok rollback_results ->
                Alcotest.(check int) "1 migration rolled back" 1 (List.length rollback_results);

                Migris.Runner.get_applied_versions db >>= function
                | Error err ->
                    Alcotest.fail (Printf.sprintf "get_applied_versions failed: %s" (Caqti_error.show err))
                | Ok versions ->
                    Alcotest.(check int) "2 versions remain" 2 (List.length versions);
                    Alcotest.(check int64_testable) "v1 remains" v1 (List.nth versions 0);
                    Alcotest.(check int64_testable) "v2 remains" v2 (List.nth versions 1);

                    let module Db = (val db : Caqti_lwt.CONNECTION) in
                    let open Caqti_request.Infix in
                    let open Caqti_type.Std in
                    let query = (string ->! bool)
                      "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = $1)" in

                    Db.find query "comments" >>= function
                    | Error err ->
                        Alcotest.fail (Printf.sprintf "Table check failed: %s" (Caqti_error.show err))
                    | Ok exists ->
                        Alcotest.(check bool) "comments table dropped" false exists;

                        Db.find query "users" >>= function
                        | Error err ->
                            Alcotest.fail (Printf.sprintf "Table check failed: %s" (Caqti_error.show err))
                        | Ok users_exist ->
                            Alcotest.(check bool) "users table still exists" true users_exist;
                            Lwt.return_unit
      )
    )
  )

let test_rollback_to_workflow () =
  with_test_db_pooled "e2e_rollback_to" (fun db_url ->
    with_temp_dir "migrations" (fun migrations_dir ->
      let v1 = 20240115120000L in
      let v2 = 20240115130000L in
      let v3 = 20240115140000L in
      let v4 = 20240115150000L in

      let _f1 = create_migration_with_sections migrations_dir v1 "t1"
        "CREATE TABLE t1 (id SERIAL PRIMARY KEY);" "DROP TABLE t1;" in
      let _f2 = create_migration_with_sections migrations_dir v2 "t2"
        "CREATE TABLE t2 (id SERIAL PRIMARY KEY);" "DROP TABLE t2;" in
      let _f3 = create_migration_with_sections migrations_dir v3 "t3"
        "CREATE TABLE t3 (id SERIAL PRIMARY KEY);" "DROP TABLE t3;" in
      let _f4 = create_migration_with_sections migrations_dir v4 "t4"
        "CREATE TABLE t4 (id SERIAL PRIMARY KEY);" "DROP TABLE t4;" in

      with_initialized_db db_url (fun db ->
        Migris.Runner.run_pending db migrations_dir >>= function
        | Error msg ->
            Alcotest.fail (Printf.sprintf "run_pending failed: %s" (Migris.Types.show_error msg))
        | Ok _ ->
            Migris.Runner.rollback_to ~migrations_dir db v2 >>= function
            | Error msg ->
                Alcotest.fail (Printf.sprintf "rollback_to failed: %s" (Migris.Types.show_error msg))
            | Ok rollback_results ->
                Alcotest.(check int) "2 migrations rolled back" 2 (List.length rollback_results);

                Migris.Runner.get_applied_versions db >>= function
                | Error err ->
                    Alcotest.fail (Printf.sprintf "get_applied_versions failed: %s" (Caqti_error.show err))
                | Ok versions ->
                    Alcotest.(check int) "2 versions remain" 2 (List.length versions);
                    Alcotest.(check int64_testable) "v1 remains" v1 (List.nth versions 0);
                    Alcotest.(check int64_testable) "v2 remains" v2 (List.nth versions 1);
                    Lwt.return_unit
      )
    )
  )

let test_reset_workflow () =
  with_test_db_pooled "e2e_reset" (fun db_url ->
    with_temp_dir "migrations" (fun migrations_dir ->
      let v1 = 20240115120000L in
      let v2 = 20240115130000L in

      let _f1 = create_migration_with_sections migrations_dir v1 "users"
        "CREATE TABLE users (id SERIAL PRIMARY KEY);" "DROP TABLE users;" in
      let _f2 = create_migration_with_sections migrations_dir v2 "posts"
        "CREATE TABLE posts (id SERIAL PRIMARY KEY);" "DROP TABLE posts;" in

      with_initialized_db db_url (fun db ->
        Migris.Runner.run_pending db migrations_dir >>= function
        | Error msg ->
            Alcotest.fail (Printf.sprintf "Initial run_pending failed: %s" (Migris.Types.show_error msg))
        | Ok _ ->
            Migris.Runner.rollback_all ~migrations_dir db >>= function
            | Error msg ->
                Alcotest.fail (Printf.sprintf "rollback_all failed: %s" (Migris.Types.show_error msg))
            | Ok rollback_results ->
                Alcotest.(check int) "2 migrations rolled back" 2 (List.length rollback_results);

                Migris.Runner.get_applied_versions db >>= function
                | Error err ->
                    Alcotest.fail (Printf.sprintf "get_applied_versions failed: %s" (Caqti_error.show err))
                | Ok versions ->
                    Alcotest.(check int) "no versions remain" 0 (List.length versions);

                    Migris.Runner.run_pending db migrations_dir >>= function
                    | Error msg ->
                        Alcotest.fail (Printf.sprintf "Second run_pending failed: %s" (Migris.Types.show_error msg))
                    | Ok results ->
                        Alcotest.(check int) "2 migrations reapplied" 2 (List.length results);

                        Migris.Runner.get_applied_versions db >>= function
                        | Error err ->
                            Alcotest.fail (Printf.sprintf "get_applied_versions failed: %s" (Caqti_error.show err))
                        | Ok final_versions ->
                            Alcotest.(check int) "2 versions after reset" 2 (List.length final_versions);
                            Lwt.return_unit
      )
    )
  )

let test_failure_recovery () =
  with_test_db_pooled "e2e_recovery" (fun db_url ->
    with_temp_dir "migrations" (fun migrations_dir ->
      let v1 = 20240115120000L in
      let v2 = 20240115130000L in
      let v3 = 20240115140000L in

      let _f1 = create_migration_with_sections migrations_dir v1 "table1"
        "CREATE TABLE table1 (id SERIAL PRIMARY KEY);" "DROP TABLE table1;" in
      let _f2 = create_migration_with_sections migrations_dir v2 "bad_migration"
        "SELECT * FROM nonexistent_table_xyz;" "-- nothing" in
      let _f3 = create_migration_with_sections migrations_dir v3 "table3"
        "CREATE TABLE table3 (id SERIAL PRIMARY KEY);" "DROP TABLE table3;" in

      with_initialized_db db_url (fun db ->
        Migris.Runner.run_pending db migrations_dir >>= function
        | Error msg ->
            Alcotest.fail (Printf.sprintf "run_pending failed unexpectedly: %s" (Migris.Types.show_error msg))
        | Ok results ->
            Alcotest.(check int) "2 results (v1 success, v2 failure)" 2 (List.length results);
            Alcotest.(check bool) "v1 succeeded" true (Migris.Runner.is_success (List.nth results 0));
            Alcotest.(check bool) "v2 failed" false (Migris.Runner.is_success (List.nth results 1));

            Migris.Runner.get_applied_versions db >>= function
            | Error err ->
                Alcotest.fail (Printf.sprintf "get_applied_versions failed: %s" (Caqti_error.show err))
            | Ok versions ->
                Alcotest.(check int) "only v1 recorded" 1 (List.length versions);
                Alcotest.(check int64_testable) "v1 recorded" v1 (List.nth versions 0);

                let f2_path = Filename.concat migrations_dir (Migris.Migration.make_filename v2 "bad_migration") in
                let oc = open_out f2_path in
                output_string oc "-- +migrate up\nCREATE TABLE table2 (id SERIAL PRIMARY KEY);\n\n-- +migrate down\nDROP TABLE table2;\n";
                close_out oc;

                Migris.Runner.run_pending db migrations_dir >>= function
                | Error msg ->
                    Alcotest.fail (Printf.sprintf "Second run_pending failed: %s" (Migris.Types.show_error msg))
                | Ok results2 ->
                    Alcotest.(check int) "2 migrations in recovery" 2 (List.length results2);
                    List.iter (fun result ->
                      Alcotest.(check bool) "migration succeeded" true (Migris.Runner.is_success result)
                    ) results2;

                    Migris.Runner.get_applied_versions db >>= function
                    | Error err ->
                        Alcotest.fail (Printf.sprintf "get_applied_versions failed: %s" (Caqti_error.show err))
                    | Ok final_versions ->
                        Alcotest.(check int) "all 3 versions recorded" 3 (List.length final_versions);
                        Lwt.return_unit
      )
    )
  )

let test_database_lifecycle () =
  let db_name = test_db_name "e2e_lifecycle" in
  let admin_url = get_admin_url () in
  let uri = Uri.of_string admin_url in
  let host = Uri.host uri |> Option.value ~default:"localhost" in
  let port = Uri.port uri |> Option.value ~default:5432 in
  let userinfo = Uri.userinfo uri in
  let auth = match userinfo with
    | None -> ""
    | Some info -> info ^ "@"
  in
  let db_url = Printf.sprintf "postgresql://%s%s:%d/%s" auth host port db_name in

  Migris.Database.create_database db_url >>= function
  | Error msg ->
      Alcotest.fail (Printf.sprintf "create_database failed: %s" (Migris.Types.show_error msg))
  | Ok () ->
      Migris.Database.drop_database db_url >>= function
      | Error msg ->
          Alcotest.fail (Printf.sprintf "drop_database failed: %s" (Migris.Types.show_error msg))
      | Ok () ->
          Migris.Database.create_database db_url >>= function
          | Error msg ->
              Alcotest.fail (Printf.sprintf "Second create_database failed: %s" (Migris.Types.show_error msg))
          | Ok () ->
              Migris.Database.drop_database db_url >>= fun _ ->
              Lwt.return_unit

let suite = [
  "fresh_setup_workflow", `Quick, test_fresh_setup_workflow;
  "incremental_migrations", `Quick, test_incremental_migrations;
  "rollback_workflow", `Quick, test_rollback_workflow;
  "rollback_to_workflow", `Quick, test_rollback_to_workflow;
  "reset_workflow", `Quick, test_reset_workflow;
  "failure_recovery", `Quick, test_failure_recovery;
  "database_lifecycle", `Quick, test_database_lifecycle;
]
