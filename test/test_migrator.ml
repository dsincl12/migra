open Lwt.Infix
open Test_helpers

let test_run_pending () =
  with_test_db_pooled "migrator_run" (fun db_url ->
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

          let config =
            Migra.Migrator.
              {
                database_url = db_url;
                migrations_dir;
                verbose = false;
                table = Migra_engine.Runner.default_table;
              }
          in

          Migra.Migrator.run config >>= function
          | Error err ->
              Alcotest.fail
                (Printf.sprintf "Migrator.run failed: %s"
                   (Migra.Types.show_error err))
          | Ok result ->
              Alcotest.(check int)
                "2 migrations ran" 2
                (List.length result.migrations);
              Alcotest.(check int) "2 successes" 2 result.success_count;
              Alcotest.(check int) "0 failures" 0 result.failure_count;

              List.iter
                (fun m ->
                  Alcotest.(check bool)
                    "migration succeeded" true m.Migra.Migrator.success;
                  Alcotest.(check bool) "no error" true (Option.is_none m.error);
                  Alcotest.(check bool)
                    "has timing" true
                    (Option.is_some m.elapsed_seconds))
                result.migrations;

              Lwt.return_unit))

let test_run_no_pending () =
  with_test_db_pooled "migrator_no_pending" (fun db_url ->
      with_temp_dir "migrations" (fun migrations_dir ->
          let v1 = 20240115120000L in
          let _f1 =
            create_migration_with_sections migrations_dir v1 "table1"
              "CREATE TABLE table1 (id SERIAL PRIMARY KEY);"
              "DROP TABLE table1;"
          in

          let config =
            Migra.Migrator.
              {
                database_url = db_url;
                migrations_dir;
                verbose = false;
                table = Migra_engine.Runner.default_table;
              }
          in

          Migra.Migrator.run config >>= function
          | Error err ->
              Alcotest.fail
                (Printf.sprintf "First run failed: %s"
                   (Migra.Types.show_error err))
          | Ok _ -> (
              Migra.Migrator.run config >>= function
              | Error err ->
                  Alcotest.fail
                    (Printf.sprintf "Second run failed: %s"
                       (Migra.Types.show_error err))
              | Ok result ->
                  Alcotest.(check int)
                    "0 migrations ran" 0
                    (List.length result.migrations);
                  Alcotest.(check int) "0 successes" 0 result.success_count;
                  Alcotest.(check int) "0 failures" 0 result.failure_count;
                  Lwt.return_unit)))

let test_run_stops_on_failure () =
  with_test_db_pooled "migrator_failure" (fun db_url ->
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
            create_migration_with_sections migrations_dir v2 "bad"
              "SELECT * FROM nonexistent_table;" "-- nothing"
          in
          let _f3 =
            create_migration_with_sections migrations_dir v3 "table3"
              "CREATE TABLE table3 (id SERIAL PRIMARY KEY);"
              "DROP TABLE table3;"
          in

          let config =
            Migra.Migrator.
              {
                database_url = db_url;
                migrations_dir;
                verbose = false;
                table = Migra_engine.Runner.default_table;
              }
          in

          Migra.Migrator.run config >>= function
          | Error err ->
              Alcotest.fail
                (Printf.sprintf "Migrator.run failed: %s"
                   (Migra.Types.show_error err))
          | Ok result ->
              Alcotest.(check int)
                "2 migrations attempted" 2
                (List.length result.migrations);
              Alcotest.(check int) "1 success" 1 result.success_count;
              Alcotest.(check int) "1 failure" 1 result.failure_count;

              let m1 = List.nth result.migrations 0 in
              Alcotest.(check bool) "v1 succeeded" true m1.success;

              let m2 = List.nth result.migrations 1 in
              Alcotest.(check bool) "v2 failed" false m2.success;
              Alcotest.(check bool)
                "v2 has error" true (Option.is_some m2.error);

              Lwt.return_unit))

let test_run_or_error_ok () =
  with_test_db_pooled "migrator_run_or_error_ok" (fun db_url ->
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
          let config =
            Migra.Migrator.
              {
                database_url = db_url;
                migrations_dir;
                verbose = false;
                table = Migra_engine.Runner.default_table;
              }
          in
          Migra.Migrator.run_or_error config >>= function
          | Error err ->
              Alcotest.fail
                (Printf.sprintf "run_or_error returned Error on success: %s"
                   (Migra.Types.show_error err))
          | Ok result ->
              Alcotest.(check int) "2 succeeded" 2 result.success_count;
              Alcotest.(check int) "0 failures" 0 result.failure_count;
              Lwt.return_unit))

let test_run_or_error_failure () =
  with_test_db_pooled "migrator_run_or_error_fail" (fun db_url ->
      with_temp_dir "migrations" (fun migrations_dir ->
          let v1 = 20240115120000L in
          let v2 = 20240115130000L in
          let _f1 =
            create_migration_with_sections migrations_dir v1 "table1"
              "CREATE TABLE table1 (id SERIAL PRIMARY KEY);"
              "DROP TABLE table1;"
          in
          let _f2 =
            create_migration_with_sections migrations_dir v2 "bad"
              "SELECT * FROM nonexistent_table;" "-- nothing"
          in
          let config =
            Migra.Migrator.
              {
                database_url = db_url;
                migrations_dir;
                verbose = false;
                table = Migra_engine.Runner.default_table;
              }
          in
          Migra.Migrator.run_or_error config >>= function
          | Ok _ ->
              Alcotest.fail
                "run_or_error returned Ok despite a failed migration"
          | Error
              (Migra.Types.MigrationError
                 (Migra.Types.ExecutionFailed (version, msg))) ->
              Alcotest.(check int64) "failed version reported" v2 version;
              Alcotest.(check bool)
                "error message non-empty" true
                (String.length msg > 0);
              Lwt.return_unit
          | Error other ->
              Alcotest.fail
                (Printf.sprintf "unexpected error variant: %s"
                   (Migra.Types.show_error other))))

let test_rollback_step () =
  with_test_db_pooled "migrator_rollback_step" (fun db_url ->
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

          let config =
            Migra.Migrator.
              {
                database_url = db_url;
                migrations_dir;
                verbose = false;
                table = Migra_engine.Runner.default_table;
              }
          in

          Migra.Migrator.run config >>= function
          | Error err ->
              Alcotest.fail
                (Printf.sprintf "Migrator.run failed: %s"
                   (Migra.Types.show_error err))
          | Ok _ -> (
              Migra.Migrator.rollback config (Step 2) >>= function
              | Error err ->
                  Alcotest.fail
                    (Printf.sprintf "Migrator.rollback failed: %s"
                       (Migra.Types.show_error err))
              | Ok result ->
                  Alcotest.(check int)
                    "2 rollbacks" 2
                    (List.length result.migrations);
                  Alcotest.(check int) "2 successes" 2 result.success_count;
                  Alcotest.(check int) "0 failures" 0 result.failure_count;

                  List.iter
                    (fun m ->
                      Alcotest.(check bool)
                        "rollback succeeded" true m.Migra.Migrator.success)
                    result.migrations;

                  Lwt.return_unit)))

let test_rollback_to () =
  with_test_db_pooled "migrator_rollback_to" (fun db_url ->
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

          let config =
            Migra.Migrator.
              {
                database_url = db_url;
                migrations_dir;
                verbose = false;
                table = Migra_engine.Runner.default_table;
              }
          in

          Migra.Migrator.run config >>= function
          | Error err ->
              Alcotest.fail
                (Printf.sprintf "Migrator.run failed: %s"
                   (Migra.Types.show_error err))
          | Ok _ -> (
              Migra.Migrator.rollback config (To v1) >>= function
              | Error err ->
                  Alcotest.fail
                    (Printf.sprintf "Migrator.rollback failed: %s"
                       (Migra.Types.show_error err))
              | Ok result ->
                  Alcotest.(check int)
                    "2 rollbacks" 2
                    (List.length result.migrations);
                  Alcotest.(check int) "2 successes" 2 result.success_count;
                  Lwt.return_unit)))

let test_rollback_all () =
  with_test_db_pooled "migrator_rollback_all" (fun db_url ->
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

          let config =
            Migra.Migrator.
              {
                database_url = db_url;
                migrations_dir;
                verbose = false;
                table = Migra_engine.Runner.default_table;
              }
          in

          Migra.Migrator.run config >>= function
          | Error err ->
              Alcotest.fail
                (Printf.sprintf "Migrator.run failed: %s"
                   (Migra.Types.show_error err))
          | Ok _ -> (
              Migra.Migrator.rollback config All >>= function
              | Error err ->
                  Alcotest.fail
                    (Printf.sprintf "Migrator.rollback failed: %s"
                       (Migra.Types.show_error err))
              | Ok result ->
                  Alcotest.(check int)
                    "2 rollbacks" 2
                    (List.length result.migrations);
                  Alcotest.(check int) "2 successes" 2 result.success_count;
                  Lwt.return_unit)))

let test_rollback_empty () =
  with_test_db_pooled "migrator_rollback_empty" (fun db_url ->
      with_temp_dir "migrations" (fun migrations_dir ->
          let config =
            Migra.Migrator.
              {
                database_url = db_url;
                migrations_dir;
                verbose = false;
                table = Migra_engine.Runner.default_table;
              }
          in

          Migra.Migrator.rollback config All >>= function
          | Error err ->
              Alcotest.fail
                (Printf.sprintf "Migrator.rollback failed: %s"
                   (Migra.Types.show_error err))
          | Ok result ->
              Alcotest.(check int)
                "0 rollbacks" 0
                (List.length result.migrations);
              Alcotest.(check int) "0 successes" 0 result.success_count;
              Lwt.return_unit))

let test_status () =
  with_test_db_pooled "migrator_status" (fun db_url ->
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

          let config =
            Migra.Migrator.
              {
                database_url = db_url;
                migrations_dir;
                verbose = false;
                table = Migra_engine.Runner.default_table;
              }
          in

          Migra.Migrator.status config >>= function
          | Error err ->
              Alcotest.fail
                (Printf.sprintf "status failed: %s"
                   (Migra.Types.show_error err))
          | Ok initial_status -> (
              Alcotest.(check int)
                "3 migrations found" 3
                (List.length initial_status.migrations);
              Alcotest.(check int) "3 pending" 3 initial_status.pending_count;
              Alcotest.(check int) "0 applied" 0 initial_status.applied_count;

              let config_limited =
                Migra.Migrator.{ config with migrations_dir }
              in
              Migra.Migrator.run config_limited >>= function
              | Error err ->
                  Alcotest.fail
                    (Printf.sprintf "run failed: %s"
                       (Migra.Types.show_error err))
              | Ok run_result -> (
                  Alcotest.(check int)
                    "3 migrations ran" 3
                    (List.length run_result.migrations);

                  Migra.Migrator.status config >>= function
                  | Error err ->
                      Alcotest.fail
                        (Printf.sprintf "status after run failed: %s"
                           (Migra.Types.show_error err))
                  | Ok final_status ->
                      Alcotest.(check int)
                        "3 migrations total" 3
                        (List.length final_status.migrations);
                      Alcotest.(check int)
                        "0 pending" 0 final_status.pending_count;
                      Alcotest.(check int)
                        "3 applied" 3 final_status.applied_count;

                      List.iter
                        (fun m ->
                          Alcotest.(check bool)
                            "migration applied" true m.Migra.Migrator.applied;
                          Alcotest.(check bool)
                            "has timestamp" true
                            (Option.is_some m.applied_at))
                        final_status.migrations;

                      Lwt.return_unit))))

let test_status_mixed () =
  with_test_db_pooled "migrator_status_mixed" (fun db_url ->
      with_temp_dir "migrations" (fun migrations_dir ->
          let v1 = 20240115120000L in
          let _f1 =
            create_migration_with_sections migrations_dir v1 "table1"
              "CREATE TABLE table1 (id SERIAL PRIMARY KEY);"
              "DROP TABLE table1;"
          in

          let config =
            Migra.Migrator.
              {
                database_url = db_url;
                migrations_dir;
                verbose = false;
                table = Migra_engine.Runner.default_table;
              }
          in

          Migra.Migrator.run config >>= function
          | Error err ->
              Alcotest.fail
                (Printf.sprintf "First run failed: %s"
                   (Migra.Types.show_error err))
          | Ok _ -> (
              let v2 = 20240115130000L in
              let _f2 =
                create_migration_with_sections migrations_dir v2 "table2"
                  "CREATE TABLE table2 (id SERIAL PRIMARY KEY);"
                  "DROP TABLE table2;"
              in

              Migra.Migrator.status config >>= function
              | Error err ->
                  Alcotest.fail
                    (Printf.sprintf "status failed: %s"
                       (Migra.Types.show_error err))
              | Ok status ->
                  Alcotest.(check int)
                    "2 migrations total" 2
                    (List.length status.migrations);
                  Alcotest.(check int) "1 pending" 1 status.pending_count;
                  Alcotest.(check int) "1 applied" 1 status.applied_count;

                  let s1 = List.nth status.migrations 0 in
                  Alcotest.(check bool) "v1 applied" true s1.applied;
                  Alcotest.(check bool)
                    "v1 has timestamp" true
                    (Option.is_some s1.applied_at);

                  let s2 = List.nth status.migrations 1 in
                  Alcotest.(check bool) "v2 not applied" false s2.applied;
                  Alcotest.(check bool)
                    "v2 no timestamp" true
                    (Option.is_none s2.applied_at);

                  Lwt.return_unit)))

let test_make_defaults () =
  let c = Migra.Migrator.make ~database_url:"sqlite3:/tmp/x.db" () in
  Alcotest.(check string)
    "default migrations_dir" "migrations" c.Migra.Migrator.migrations_dir;
  Alcotest.(check bool) "default verbose" false c.Migra.Migrator.verbose;
  let c2 =
    Migra.Migrator.make ~database_url:"sqlite3:/tmp/x.db"
      ~migrations_dir:"db/mig" ~verbose:true ()
  in
  Alcotest.(check string)
    "override dir" "db/mig" c2.Migra.Migrator.migrations_dir;
  Lwt.return_unit

let test_run_bad_url () =
  let cfg = Migra.Migrator.make ~database_url:"oracle://localhost/db" () in
  Lwt.catch
    (fun () ->
      Migra.Migrator.run cfg >>= function
      | Error _ -> Lwt.return_unit
      | Ok _ -> Alcotest.fail "expected Error for unsupported URL scheme")
    (fun exn ->
      Alcotest.fail
        (Printf.sprintf "run raised instead of returning Error: %s"
           (Printexc.to_string exn)))

let test_redo () =
  with_test_db_pooled "migrator_redo" (fun db_url ->
      with_temp_dir "migrations" (fun migrations_dir ->
          let v1 = 20240115120000L in
          let v2 = 20240115130000L in
          let _f1 =
            create_migration_with_sections migrations_dir v1 "t1"
              "CREATE TABLE r1 (id SERIAL PRIMARY KEY);" "DROP TABLE r1;"
          in
          let _f2 =
            create_migration_with_sections migrations_dir v2 "t2"
              "CREATE TABLE r2 (id SERIAL PRIMARY KEY);" "DROP TABLE r2;"
          in
          let config =
            Migra.Migrator.make ~database_url:db_url ~migrations_dir ()
          in
          Migra.Migrator.run config >>= function
          | Error err ->
              Alcotest.fail
                (Printf.sprintf "run failed: %s" (Migra.Types.show_error err))
          | Ok _ -> (
              Migra.Migrator.redo config >>= function
              | Error err ->
                  Alcotest.fail
                    (Printf.sprintf "redo failed: %s"
                       (Migra.Types.show_error err))
              | Ok result -> (
                  Alcotest.(check int)
                    "re-applied 1 migration" 1
                    (List.length result.Migra.Migrator.migrations);
                  Alcotest.(check int)
                    "re-apply succeeded" 1 result.success_count;
                  Alcotest.(check int)
                    "no re-apply failures" 0 result.failure_count;
                  Migra.Migrator.status config >>= function
                  | Error err ->
                      Alcotest.fail
                        (Printf.sprintf "status failed: %s"
                           (Migra.Types.show_error err))
                  | Ok st ->
                      Alcotest.(check int)
                        "2 applied after redo" 2 st.applied_count;
                      Lwt.return_unit))))

(* Finding 1: rollback must not bypass drift validation. A migration whose file
   was modified after being applied has down SQL that no longer matches what was
   applied, so rollback must refuse rather than run the modified down SQL. *)
let test_rollback_rejects_checksum_drift () =
  with_test_db_pooled "migrator_rollback_drift" (fun db_url ->
      with_temp_dir "migrations" (fun migrations_dir ->
          let v1 = 20240115120000L in
          let _f1 =
            create_migration_with_sections migrations_dir v1 "drift1"
              "CREATE TABLE drift1 (id SERIAL PRIMARY KEY);"
              "DROP TABLE drift1;"
          in
          let config =
            Migra.Migrator.make ~database_url:db_url ~migrations_dir ()
          in
          Migra.Migrator.run config >>= function
          | Error err ->
              Alcotest.fail
                (Printf.sprintf "run failed: %s" (Migra.Types.show_error err))
          | Ok _ -> (
              (* Overwrite the applied file (same name, different SQL) so its
                 checksum no longer matches the recorded one. *)
              let _ =
                create_migration_with_sections migrations_dir v1 "drift1"
                  "CREATE TABLE drift1 (id SERIAL PRIMARY KEY, extra TEXT);"
                  "DROP TABLE drift1;"
              in
              Migra.Migrator.rollback config All >>= function
              | Ok _ ->
                  Alcotest.fail
                    "rollback should refuse a modified applied migration"
              | Error
                  (Migra.Types.MigrationError
                     (Migra.Types.ChecksumMismatch (v, _))) ->
                  Alcotest.(check int64_testable) "drift version" v1 v;
                  Lwt.return_unit
              | Error err ->
                  Alcotest.fail
                    (Printf.sprintf "expected ChecksumMismatch, got: %s"
                       (Migra.Types.show_error err)))))

(* Finding 1: rollback must not silently drop an applied migration whose file is
   missing (target selection filters it out otherwise). It must surface drift. *)
let test_rollback_rejects_missing_file () =
  with_test_db_pooled "migrator_rollback_missing" (fun db_url ->
      with_temp_dir "migrations" (fun migrations_dir ->
          let v1 = 20240115120000L in
          let f1 =
            create_migration_with_sections migrations_dir v1 "missing1"
              "CREATE TABLE missing1 (id SERIAL PRIMARY KEY);"
              "DROP TABLE missing1;"
          in
          let config =
            Migra.Migrator.make ~database_url:db_url ~migrations_dir ()
          in
          Migra.Migrator.run config >>= function
          | Error err ->
              Alcotest.fail
                (Printf.sprintf "run failed: %s" (Migra.Types.show_error err))
          | Ok _ -> (
              Sys.remove f1;
              Migra.Migrator.rollback config All >>= function
              | Ok _ ->
                  Alcotest.fail
                    "rollback should refuse when an applied file is missing"
              | Error
                  (Migra.Types.MigrationError (Migra.Types.AppliedFileMissing v))
                ->
                  Alcotest.(check int64_testable) "missing version" v1 v;
                  Lwt.return_unit
              | Error err ->
                  Alcotest.fail
                    (Printf.sprintf "expected AppliedFileMissing, got: %s"
                       (Migra.Types.show_error err)))))

(* Finding 1: redo (rollback + re-apply) must apply the same drift guard. *)
let test_redo_rejects_drift () =
  with_test_db_pooled "migrator_redo_drift" (fun db_url ->
      with_temp_dir "migrations" (fun migrations_dir ->
          let v1 = 20240115120000L in
          let _f1 =
            create_migration_with_sections migrations_dir v1 "redodrift"
              "CREATE TABLE redodrift (id SERIAL PRIMARY KEY);"
              "DROP TABLE redodrift;"
          in
          let config =
            Migra.Migrator.make ~database_url:db_url ~migrations_dir ()
          in
          Migra.Migrator.run config >>= function
          | Error err ->
              Alcotest.fail
                (Printf.sprintf "run failed: %s" (Migra.Types.show_error err))
          | Ok _ -> (
              let _ =
                create_migration_with_sections migrations_dir v1 "redodrift"
                  "CREATE TABLE redodrift (id SERIAL PRIMARY KEY, extra TEXT);"
                  "DROP TABLE redodrift;"
              in
              Migra.Migrator.redo config >>= function
              | Ok _ ->
                  Alcotest.fail
                    "redo should refuse a modified applied migration"
              | Error
                  (Migra.Types.MigrationError
                     (Migra.Types.ChecksumMismatch (v, _))) ->
                  Alcotest.(check int64_testable) "drift version" v1 v;
                  Lwt.return_unit
              | Error err ->
                  Alcotest.fail
                    (Printf.sprintf "expected ChecksumMismatch, got: %s"
                       (Migra.Types.show_error err)))))

(* Finding 2: status must surface an applied row whose file is gone rather than
   hiding it (which would understate the applied count). *)
let test_status_includes_missing_file () =
  with_test_db_pooled "migrator_status_missing" (fun db_url ->
      with_temp_dir "migrations" (fun migrations_dir ->
          let v1 = 20240115120000L in
          let v2 = 20240115130000L in
          let f1 =
            create_migration_with_sections migrations_dir v1 "smiss1"
              "CREATE TABLE smiss1 (id SERIAL PRIMARY KEY);"
              "DROP TABLE smiss1;"
          in
          let _f2 =
            create_migration_with_sections migrations_dir v2 "smiss2"
              "CREATE TABLE smiss2 (id SERIAL PRIMARY KEY);"
              "DROP TABLE smiss2;"
          in
          let config =
            Migra.Migrator.make ~database_url:db_url ~migrations_dir ()
          in
          Migra.Migrator.run config >>= function
          | Error err ->
              Alcotest.fail
                (Printf.sprintf "run failed: %s" (Migra.Types.show_error err))
          | Ok _ -> (
              (* Delete the first applied migration's file. *)
              Sys.remove f1;
              Migra.Migrator.status config >>= function
              | Error err ->
                  Alcotest.fail
                    (Printf.sprintf "status failed: %s"
                       (Migra.Types.show_error err))
              | Ok st ->
                  Alcotest.(check int)
                    "both rows still counted applied" 2 st.applied_count;
                  Alcotest.(check int) "no pending" 0 st.pending_count;
                  Alcotest.(check int)
                    "two rows listed" 2
                    (List.length st.migrations);
                  let s1 =
                    List.find
                      (fun s -> Int64.equal s.Migra.Migrator.version v1)
                      st.migrations
                  in
                  Alcotest.(check bool)
                    "missing-file row still applied" true s1.applied;
                  Alcotest.(check string)
                    "missing-file row is labelled" "(migration file missing)"
                    s1.description;
                  Lwt.return_unit)))

let async_of_sync f () =
  f ();
  Lwt.return_unit

let suite =
  [
    ("make_defaults", `Quick, test_make_defaults);
    ("redo", `Quick, test_redo);
    ("redo_rejects_drift", `Quick, test_redo_rejects_drift);
    ( "rollback_rejects_checksum_drift",
      `Quick,
      test_rollback_rejects_checksum_drift );
    ("rollback_rejects_missing_file", `Quick, test_rollback_rejects_missing_file);
    ("run_bad_url", `Quick, test_run_bad_url);
    ("run_pending", `Quick, test_run_pending);
    ("run_no_pending", `Quick, test_run_no_pending);
    ("run_stops_on_failure", `Quick, test_run_stops_on_failure);
    ("run_or_error_ok", `Quick, test_run_or_error_ok);
    ("run_or_error_failure", `Quick, test_run_or_error_failure);
    ("rollback_step", `Quick, test_rollback_step);
    ("rollback_to", `Quick, test_rollback_to);
    ("rollback_all", `Quick, test_rollback_all);
    ("rollback_empty", `Quick, test_rollback_empty);
    ("status", `Quick, test_status);
    ("status_mixed", `Quick, test_status_mixed);
    ("status_includes_missing_file", `Quick, test_status_includes_missing_file);
  ]
