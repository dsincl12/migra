open Lwt.Infix
open Test_helpers

let with_initialized_db db_url f =
  Migra_engine.Database.connect_db db_url >>= function
  | Error msg ->
      Lwt.fail_with
        (Printf.sprintf "Failed to connect: %s" (Migra.Types.show_error msg))
  | Ok db -> (
      Migra_engine.Runner.ensure_migrations_table
        Migra_engine.Dialect.PostgreSQL db
      >>= function
      | Error err ->
          Lwt.fail_with
            (Printf.sprintf "Failed to create_table: %s" (Caqti_error.show err))
      | Ok () -> f db)

let test_fresh_setup_workflow () =
  with_test_db_pooled "e2e_fresh" (fun db_url ->
      with_temp_dir "migrations" (fun migrations_dir ->
          let v1 = 20240115120000L in
          let v2 = 20240115130000L in

          let _f1 =
            create_migration_with_sections migrations_dir v1 "create_users"
              "CREATE TABLE users (id SERIAL PRIMARY KEY, name TEXT NOT NULL);"
              "DROP TABLE users;"
          in
          let _f2 =
            create_migration_with_sections migrations_dir v2 "create_posts"
              "CREATE TABLE posts (id SERIAL PRIMARY KEY, user_id INTEGER NOT \
               NULL, title TEXT);"
              "DROP TABLE posts;"
          in

          with_initialized_db db_url (fun db ->
              Migra_engine.Runner.run_pending db migrations_dir >>= function
              | Error msg ->
                  Alcotest.fail
                    (Printf.sprintf "run_pending failed: %s"
                       (Migra.Types.show_error msg))
              | Ok results -> (
                  Alcotest.(check int)
                    "2 migrations executed" 2 (List.length results);
                  List.iter
                    (fun result ->
                      Alcotest.(check bool)
                        "migration succeeded" true
                        (Migra_engine.Runner.is_success result))
                    results;

                  Migra_engine.Runner.get_applied_versions db >>= function
                  | Error err ->
                      Alcotest.fail
                        (Printf.sprintf "get_applied_versions failed: %s"
                           (Caqti_error.show err))
                  | Ok versions ->
                      Alcotest.(check int)
                        "2 versions recorded" 2 (List.length versions);
                      Alcotest.(check int64_testable)
                        "v1 recorded" v1 (List.nth versions 0);
                      Alcotest.(check int64_testable)
                        "v2 recorded" v2 (List.nth versions 1);

                      let module Db = (val db : Caqti_lwt.CONNECTION) in
                      let open Caqti_request.Infix in
                      let open Caqti_type.Std in
                      let check_table name =
                        let query =
                          (string ->! bool)
                            "SELECT EXISTS (SELECT 1 FROM \
                             information_schema.tables WHERE table_name = $1)"
                        in
                        Db.find query name >>= function
                        | Error err ->
                            Alcotest.fail
                              (Printf.sprintf "Table check failed: %s"
                                 (Caqti_error.show err))
                        | Ok exists ->
                            Alcotest.(check bool)
                              (Printf.sprintf "%s table exists" name)
                              true exists;
                            Lwt.return_unit
                      in

                      check_table "users" >>= fun () ->
                      check_table "posts" >>= fun () -> Lwt.return_unit))))

let test_incremental_migrations () =
  with_test_db_pooled "e2e_incremental" (fun db_url ->
      with_temp_dir "migrations" (fun migrations_dir ->
          let v1 = 20240115120000L in
          let v2 = 20240115130000L in

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

          with_initialized_db db_url (fun db ->
              Migra_engine.Runner.run_pending db migrations_dir >>= function
              | Error msg ->
                  Alcotest.fail
                    (Printf.sprintf "First run_pending failed: %s"
                       (Migra.Types.show_error msg))
              | Ok results -> (
                  Alcotest.(check int)
                    "2 migrations in first batch" 2 (List.length results);

                  let v3 = 20240115140000L in
                  let _f3 =
                    create_migration_with_sections migrations_dir v3 "table3"
                      "CREATE TABLE table3 (id SERIAL PRIMARY KEY);"
                      "DROP TABLE table3;"
                  in

                  Migra_engine.Runner.run_pending db migrations_dir >>= function
                  | Error msg ->
                      Alcotest.fail
                        (Printf.sprintf "Second run_pending failed: %s"
                           (Migra.Types.show_error msg))
                  | Ok results2 -> (
                      Alcotest.(check int)
                        "1 migration in second batch" 1 (List.length results2);
                      Alcotest.(check int64_testable)
                        "v3 was executed" v3
                        (Migra_engine.Runner.migration_of_result
                           (List.hd results2))
                          .Migra_engine.Migration.version;

                      Migra_engine.Runner.get_applied_versions db >>= function
                      | Error err ->
                          Alcotest.fail
                            (Printf.sprintf "get_applied_versions failed: %s"
                               (Caqti_error.show err))
                      | Ok versions ->
                          Alcotest.(check int)
                            "3 versions total" 3 (List.length versions);
                          Lwt.return_unit)))))

let test_rollback_workflow () =
  with_test_db_pooled "e2e_rollback" (fun db_url ->
      with_temp_dir "migrations" (fun migrations_dir ->
          let v1 = 20240115120000L in
          let v2 = 20240115130000L in
          let v3 = 20240115140000L in

          let _f1 =
            create_migration_with_sections migrations_dir v1 "users"
              "CREATE TABLE users (id SERIAL PRIMARY KEY);" "DROP TABLE users;"
          in
          let _f2 =
            create_migration_with_sections migrations_dir v2 "posts"
              "CREATE TABLE posts (id SERIAL PRIMARY KEY);" "DROP TABLE posts;"
          in
          let _f3 =
            create_migration_with_sections migrations_dir v3 "comments"
              "CREATE TABLE comments (id SERIAL PRIMARY KEY);"
              "DROP TABLE comments;"
          in

          with_initialized_db db_url (fun db ->
              Migra_engine.Runner.run_pending db migrations_dir >>= function
              | Error msg ->
                  Alcotest.fail
                    (Printf.sprintf "run_pending failed: %s"
                       (Migra.Types.show_error msg))
              | Ok _ -> (
                  Migra_engine.Runner.rollback_step ~migrations_dir db 1
                  >>= function
                  | Error msg ->
                      Alcotest.fail
                        (Printf.sprintf "rollback_step failed: %s"
                           (Migra.Types.show_error msg))
                  | Ok rollback_results -> (
                      Alcotest.(check int)
                        "1 migration rolled back" 1
                        (List.length rollback_results);

                      Migra_engine.Runner.get_applied_versions db >>= function
                      | Error err ->
                          Alcotest.fail
                            (Printf.sprintf "get_applied_versions failed: %s"
                               (Caqti_error.show err))
                      | Ok versions -> (
                          Alcotest.(check int)
                            "2 versions remain" 2 (List.length versions);
                          Alcotest.(check int64_testable)
                            "v1 remains" v1 (List.nth versions 0);
                          Alcotest.(check int64_testable)
                            "v2 remains" v2 (List.nth versions 1);

                          let module Db = (val db : Caqti_lwt.CONNECTION) in
                          let open Caqti_request.Infix in
                          let open Caqti_type.Std in
                          let query =
                            (string ->! bool)
                              "SELECT EXISTS (SELECT 1 FROM \
                               information_schema.tables WHERE table_name = \
                               $1)"
                          in

                          Db.find query "comments" >>= function
                          | Error err ->
                              Alcotest.fail
                                (Printf.sprintf "Table check failed: %s"
                                   (Caqti_error.show err))
                          | Ok exists -> (
                              Alcotest.(check bool)
                                "comments table dropped" false exists;

                              Db.find query "users" >>= function
                              | Error err ->
                                  Alcotest.fail
                                    (Printf.sprintf "Table check failed: %s"
                                       (Caqti_error.show err))
                              | Ok users_exist ->
                                  Alcotest.(check bool)
                                    "users table still exists" true users_exist;
                                  Lwt.return_unit)))))))

let test_rollback_to_workflow () =
  with_test_db_pooled "e2e_rollback_to" (fun db_url ->
      with_temp_dir "migrations" (fun migrations_dir ->
          let v1 = 20240115120000L in
          let v2 = 20240115130000L in
          let v3 = 20240115140000L in
          let v4 = 20240115150000L in

          let _f1 =
            create_migration_with_sections migrations_dir v1 "t1"
              "CREATE TABLE t1 (id SERIAL PRIMARY KEY);" "DROP TABLE t1;"
          in
          let _f2 =
            create_migration_with_sections migrations_dir v2 "t2"
              "CREATE TABLE t2 (id SERIAL PRIMARY KEY);" "DROP TABLE t2;"
          in
          let _f3 =
            create_migration_with_sections migrations_dir v3 "t3"
              "CREATE TABLE t3 (id SERIAL PRIMARY KEY);" "DROP TABLE t3;"
          in
          let _f4 =
            create_migration_with_sections migrations_dir v4 "t4"
              "CREATE TABLE t4 (id SERIAL PRIMARY KEY);" "DROP TABLE t4;"
          in

          with_initialized_db db_url (fun db ->
              Migra_engine.Runner.run_pending db migrations_dir >>= function
              | Error msg ->
                  Alcotest.fail
                    (Printf.sprintf "run_pending failed: %s"
                       (Migra.Types.show_error msg))
              | Ok _ -> (
                  Migra_engine.Runner.rollback_to ~migrations_dir db v2
                  >>= function
                  | Error msg ->
                      Alcotest.fail
                        (Printf.sprintf "rollback_to failed: %s"
                           (Migra.Types.show_error msg))
                  | Ok rollback_results -> (
                      Alcotest.(check int)
                        "2 migrations rolled back" 2
                        (List.length rollback_results);

                      Migra_engine.Runner.get_applied_versions db >>= function
                      | Error err ->
                          Alcotest.fail
                            (Printf.sprintf "get_applied_versions failed: %s"
                               (Caqti_error.show err))
                      | Ok versions ->
                          Alcotest.(check int)
                            "2 versions remain" 2 (List.length versions);
                          Alcotest.(check int64_testable)
                            "v1 remains" v1 (List.nth versions 0);
                          Alcotest.(check int64_testable)
                            "v2 remains" v2 (List.nth versions 1);
                          Lwt.return_unit)))))

let test_reset_workflow () =
  with_test_db_pooled "e2e_reset" (fun db_url ->
      with_temp_dir "migrations" (fun migrations_dir ->
          let v1 = 20240115120000L in
          let v2 = 20240115130000L in

          let _f1 =
            create_migration_with_sections migrations_dir v1 "users"
              "CREATE TABLE users (id SERIAL PRIMARY KEY);" "DROP TABLE users;"
          in
          let _f2 =
            create_migration_with_sections migrations_dir v2 "posts"
              "CREATE TABLE posts (id SERIAL PRIMARY KEY);" "DROP TABLE posts;"
          in

          with_initialized_db db_url (fun db ->
              Migra_engine.Runner.run_pending db migrations_dir >>= function
              | Error msg ->
                  Alcotest.fail
                    (Printf.sprintf "Initial run_pending failed: %s"
                       (Migra.Types.show_error msg))
              | Ok _ -> (
                  Migra_engine.Runner.rollback_all ~migrations_dir db
                  >>= function
                  | Error msg ->
                      Alcotest.fail
                        (Printf.sprintf "rollback_all failed: %s"
                           (Migra.Types.show_error msg))
                  | Ok rollback_results -> (
                      Alcotest.(check int)
                        "2 migrations rolled back" 2
                        (List.length rollback_results);

                      Migra_engine.Runner.get_applied_versions db >>= function
                      | Error err ->
                          Alcotest.fail
                            (Printf.sprintf "get_applied_versions failed: %s"
                               (Caqti_error.show err))
                      | Ok versions -> (
                          Alcotest.(check int)
                            "no versions remain" 0 (List.length versions);

                          Migra_engine.Runner.run_pending db migrations_dir
                          >>= function
                          | Error msg ->
                              Alcotest.fail
                                (Printf.sprintf "Second run_pending failed: %s"
                                   (Migra.Types.show_error msg))
                          | Ok results -> (
                              Alcotest.(check int)
                                "2 migrations reapplied" 2 (List.length results);

                              Migra_engine.Runner.get_applied_versions db
                              >>= function
                              | Error err ->
                                  Alcotest.fail
                                    (Printf.sprintf
                                       "get_applied_versions failed: %s"
                                       (Caqti_error.show err))
                              | Ok final_versions ->
                                  Alcotest.(check int)
                                    "2 versions after reset" 2
                                    (List.length final_versions);
                                  Lwt.return_unit)))))))

let test_failure_recovery () =
  with_test_db_pooled "e2e_recovery" (fun db_url ->
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
            create_migration_with_sections migrations_dir v2 "bad_migration"
              "SELECT * FROM nonexistent_table_xyz;" "-- nothing"
          in
          let _f3 =
            create_migration_with_sections migrations_dir v3 "table3"
              "CREATE TABLE table3 (id SERIAL PRIMARY KEY);"
              "DROP TABLE table3;"
          in

          with_initialized_db db_url (fun db ->
              Migra_engine.Runner.run_pending db migrations_dir >>= function
              | Error msg ->
                  Alcotest.fail
                    (Printf.sprintf "run_pending failed unexpectedly: %s"
                       (Migra.Types.show_error msg))
              | Ok results -> (
                  Alcotest.(check int)
                    "2 results (v1 success, v2 failure)" 2 (List.length results);
                  Alcotest.(check bool)
                    "v1 succeeded" true
                    (Migra_engine.Runner.is_success (List.nth results 0));
                  Alcotest.(check bool)
                    "v2 failed" false
                    (Migra_engine.Runner.is_success (List.nth results 1));

                  Migra_engine.Runner.get_applied_versions db >>= function
                  | Error err ->
                      Alcotest.fail
                        (Printf.sprintf "get_applied_versions failed: %s"
                           (Caqti_error.show err))
                  | Ok versions -> (
                      Alcotest.(check int)
                        "only v1 recorded" 1 (List.length versions);
                      Alcotest.(check int64_testable)
                        "v1 recorded" v1 (List.nth versions 0);

                      let f2_path =
                        Filename.concat migrations_dir
                          (Migra_engine.Migration.make_filename v2
                             "bad_migration")
                      in
                      let oc = open_out f2_path in
                      output_string oc
                        "-- +migrate up\n\
                         CREATE TABLE table2 (id SERIAL PRIMARY KEY);\n\n\
                         -- +migrate down\n\
                         DROP TABLE table2;\n";
                      close_out oc;

                      Migra_engine.Runner.run_pending db migrations_dir
                      >>= function
                      | Error msg ->
                          Alcotest.fail
                            (Printf.sprintf "Second run_pending failed: %s"
                               (Migra.Types.show_error msg))
                      | Ok results2 -> (
                          Alcotest.(check int)
                            "2 migrations in recovery" 2 (List.length results2);
                          List.iter
                            (fun result ->
                              Alcotest.(check bool)
                                "migration succeeded" true
                                (Migra_engine.Runner.is_success result))
                            results2;

                          Migra_engine.Runner.get_applied_versions db
                          >>= function
                          | Error err ->
                              Alcotest.fail
                                (Printf.sprintf
                                   "get_applied_versions failed: %s"
                                   (Caqti_error.show err))
                          | Ok final_versions ->
                              Alcotest.(check int)
                                "all 3 versions recorded" 3
                                (List.length final_versions);
                              Lwt.return_unit))))))

let test_database_lifecycle () =
  let db_name = test_db_name "e2e_lifecycle" in
  let admin_url = get_admin_url () in
  let uri = Uri.of_string admin_url in
  let host = Uri.host uri |> Option.value ~default:"localhost" in
  let port = Uri.port uri |> Option.value ~default:5432 in
  let userinfo = Uri.userinfo uri in
  let auth = match userinfo with None -> "" | Some info -> info ^ "@" in
  let db_url =
    Printf.sprintf "postgresql://%s%s:%d/%s" auth host port db_name
  in

  Migra_engine.Database.create_database db_url >>= function
  | Error msg ->
      Alcotest.fail
        (Printf.sprintf "create_database failed: %s"
           (Migra.Types.show_error msg))
  | Ok () -> (
      Migra_engine.Database.drop_database db_url >>= function
      | Error msg ->
          Alcotest.fail
            (Printf.sprintf "drop_database failed: %s"
               (Migra.Types.show_error msg))
      | Ok () -> (
          Migra_engine.Database.create_database db_url >>= function
          | Error msg ->
              Alcotest.fail
                (Printf.sprintf "Second create_database failed: %s"
                   (Migra.Types.show_error msg))
          | Ok () ->
              Migra_engine.Database.drop_database db_url >>= fun _ ->
              Lwt.return_unit))

(** E2E: a migration whose up SQL contains a dollar-quoted function body (with
    interior semicolons and a '$') runs correctly through the splitter and the
    literal-query execution path, and the function is actually created. *)
let test_postgres_function_migration () =
  with_test_db_pooled "e2e_pgfn" (fun db_url ->
      with_temp_dir "migrations" (fun migrations_dir ->
          let v1 = 20240115120000L in
          let _f1 =
            create_migration_with_sections migrations_dir v1 "add_fn"
              "CREATE TABLE t (id int, note text);\n\
               INSERT INTO t (id, note) VALUES (1, 'cost $5; 100%');\n\
               CREATE FUNCTION add_one(x int) RETURNS int AS $$\n\
               BEGIN\n\
              \  RETURN x + 1;  -- semicolons; in; the; body\n\
               END;\n\
               $$ LANGUAGE plpgsql;"
              "DROP FUNCTION add_one(int); DROP TABLE t;"
          in

          with_initialized_db db_url (fun db ->
              Migra_engine.Runner.run_pending db migrations_dir >>= function
              | Error msg ->
                  Alcotest.fail
                    (Printf.sprintf "run_pending failed: %s"
                       (Migra.Types.show_error msg))
              | Ok results -> (
                  Alcotest.(check int)
                    "1 migration executed" 1 (List.length results);
                  Alcotest.(check bool)
                    "migration succeeded" true
                    (List.for_all Migra_engine.Runner.is_success results);

                  let module Db = (val db : Caqti_lwt.CONNECTION) in
                  let open Caqti_request.Infix in
                  let open Caqti_type.Std in
                  let call_fn = (unit ->! int) "SELECT add_one(41)" in
                  Db.find call_fn () >>= function
                  | Error err ->
                      Alcotest.fail
                        (Printf.sprintf "calling add_one failed: %s"
                           (Caqti_error.show err))
                  | Ok n -> (
                      Alcotest.(check int) "dollar-quoted function works" 42 n;
                      let get_note =
                        (unit ->! string) "SELECT note FROM t WHERE id = 1"
                      in
                      Db.find get_note () >>= function
                      | Error err ->
                          Alcotest.fail
                            (Printf.sprintf "reading note failed: %s"
                               (Caqti_error.show err))
                      | Ok note ->
                          Alcotest.(check string)
                            "literal $/; preserved" "cost $5; 100%" note;
                          Lwt.return_unit)))))

(** E2E: a checksum is recorded on apply; editing an applied migration is caught
    by [validate], while an unchanged tree validates cleanly. *)
let test_checksum_validation () =
  with_test_db_pooled "e2e_checksum" (fun db_url ->
      with_temp_dir "migrations" (fun migrations_dir ->
          let v1 = 20240115120000L in
          let f1 =
            create_migration_with_sections migrations_dir v1 "t"
              "CREATE TABLE cks (id int);" "DROP TABLE cks;"
          in
          with_initialized_db db_url (fun db ->
              Migra_engine.Runner.run_pending db migrations_dir >>= function
              | Error msg ->
                  Alcotest.fail
                    (Printf.sprintf "run_pending failed: %s"
                       (Migra.Types.show_error msg))
              | Ok _ -> (
                  Migra_engine.Runner.get_applied_checksums db >>= fun cks ->
                  (match cks with
                  | Ok [ (v, Some _) ] when Int64.equal v v1 -> ()
                  | _ ->
                      Alcotest.fail
                        "expected one applied migration with a checksum");
                  Migra_engine.Runner.validate ~migrations_dir db >>= fun ok ->
                  Alcotest.(check bool)
                    "validate ok when unchanged" true (Result.is_ok ok);
                  let oc = open_out f1 in
                  output_string oc
                    "-- +migrate up\n\
                     CREATE TABLE cks (id int, extra int);\n\
                     -- +migrate down\n\
                     DROP TABLE cks;\n";
                  close_out oc;
                  Migra_engine.Runner.validate ~migrations_dir db >>= fun bad ->
                  match bad with
                  | Error
                      (Migra.Types.MigrationError
                         (Migra.Types.ChecksumMismatch (v, _)))
                    when Int64.equal v v1 ->
                      Lwt.return_unit
                  | _ -> Alcotest.fail "expected ChecksumMismatch after edit"))))

let test_missing_file_detection () =
  with_test_db_pooled "e2e_missing" (fun db_url ->
      with_temp_dir "migrations" (fun migrations_dir ->
          let v1 = 20240115120000L in
          let f1 =
            create_migration_with_sections migrations_dir v1 "t"
              "CREATE TABLE mf (id int);" "DROP TABLE mf;"
          in
          with_initialized_db db_url (fun db ->
              Migra_engine.Runner.run_pending db migrations_dir >>= function
              | Error msg ->
                  Alcotest.fail
                    (Printf.sprintf "run_pending failed: %s"
                       (Migra.Types.show_error msg))
              | Ok _ -> (
                  Sys.remove f1;
                  Migra_engine.Runner.validate ~migrations_dir db >>= fun r ->
                  match r with
                  | Error
                      (Migra.Types.MigrationError
                         (Migra.Types.AppliedFileMissing v))
                    when Int64.equal v v1 ->
                      Lwt.return_unit
                  | _ -> Alcotest.fail "expected AppliedFileMissing"))))

let test_out_of_order_detection () =
  with_test_db_pooled "e2e_ooo" (fun db_url ->
      with_temp_dir "migrations" (fun migrations_dir ->
          let _ =
            create_migration_with_sections migrations_dir 20240115130000L
              "newer" "CREATE TABLE ooo (id int);" "DROP TABLE ooo;"
          in
          with_initialized_db db_url (fun db ->
              Migra_engine.Runner.run_pending db migrations_dir >>= function
              | Error msg ->
                  Alcotest.fail
                    (Printf.sprintf "run_pending failed: %s"
                       (Migra.Types.show_error msg))
              | Ok _ -> (
                  let _ =
                    create_migration_with_sections migrations_dir
                      20240115120000L "older" "CREATE TABLE ooo2 (id int);"
                      "DROP TABLE ooo2;"
                  in
                  Migra_engine.Runner.pending_migrations ~migrations_dir db
                  >>= fun r ->
                  match r with
                  | Error
                      (Migra.Types.MigrationError (Migra.Types.OutOfOrder _)) ->
                      Lwt.return_unit
                  | _ -> Alcotest.fail "expected OutOfOrder"))))

let test_custom_table () =
  with_test_db_pooled "e2e_custom_table" (fun db_url ->
      with_temp_dir "migrations" (fun migrations_dir ->
          let table = "my_migrations" in
          let v1 = 20240115120000L in
          let _ =
            create_migration_with_sections migrations_dir v1 "t"
              "CREATE TABLE ctbl (id int);" "DROP TABLE ctbl;"
          in
          Migra_engine.Database.connect_db db_url >>= function
          | Error e -> Lwt.fail_with (Migra.Types.show_error e)
          | Ok db -> (
              Migra_engine.Runner.ensure_migrations_table ~table
                Migra_engine.Dialect.PostgreSQL db
              >>= function
              | Error e ->
                  Alcotest.fail
                    (Printf.sprintf "ensure failed: %s" (Caqti_error.show e))
              | Ok () -> (
                  Migra_engine.Runner.run_pending ~table db migrations_dir
                  >>= function
                  | Error msg ->
                      Alcotest.fail
                        (Printf.sprintf "run_pending failed: %s"
                           (Migra.Types.show_error msg))
                  | Ok _ -> (
                      Migra_engine.Runner.get_applied_versions ~table db
                      >>= fun r ->
                      match r with
                      | Ok [ v ] when Int64.equal v v1 -> Lwt.return_unit
                      | _ ->
                          Alcotest.fail "migration not tracked in custom table")
                  ))))

let suite =
  [
    ("fresh_setup_workflow", `Quick, test_fresh_setup_workflow);
    ("postgres_function_migration", `Quick, test_postgres_function_migration);
    ("checksum_validation", `Quick, test_checksum_validation);
    ("missing_file_detection", `Quick, test_missing_file_detection);
    ("out_of_order_detection", `Quick, test_out_of_order_detection);
    ("custom_table", `Quick, test_custom_table);
    ("incremental_migrations", `Quick, test_incremental_migrations);
    ("rollback_workflow", `Quick, test_rollback_workflow);
    ("rollback_to_workflow", `Quick, test_rollback_to_workflow);
    ("reset_workflow", `Quick, test_reset_workflow);
    ("failure_recovery", `Quick, test_failure_recovery);
    ("database_lifecycle", `Quick, test_database_lifecycle);
  ]
