
open Lwt.Infix
open Test_helpers

let test_run_pending () =
  with_test_db_pooled "migrator_run" (fun db_url ->
    with_temp_dir "migrations" (fun migrations_dir ->
      let v1 = 20240115120000L in
      let v2 = 20240115130000L in

      let _f1 = create_migration_with_sections migrations_dir v1 "table1"
        "CREATE TABLE table1 (id SERIAL PRIMARY KEY);" "DROP TABLE table1;" in
      let _f2 = create_migration_with_sections migrations_dir v2 "table2"
        "CREATE TABLE table2 (id SERIAL PRIMARY KEY);" "DROP TABLE table2;" in

      let config = Migra.Migrator.{
        database_url = db_url;
        migrations_dir;
        verbose = false;
      } in

      Migra.Migrator.run config >>= function
      | Error err ->
          Alcotest.fail (Printf.sprintf "Migrator.run failed: %s" (Migra.Types.show_error err))
      | Ok result ->
          Alcotest.(check int) "2 migrations ran" 2 (List.length result.migrations);
          Alcotest.(check int) "2 successes" 2 result.success_count;
          Alcotest.(check int) "0 failures" 0 result.failure_count;

          List.iter (fun m ->
            Alcotest.(check bool) "migration succeeded" true m.Migra.Migrator.success;
            Alcotest.(check bool) "no error" true (Option.is_none m.error);
            Alcotest.(check bool) "has timing" true (Option.is_some m.elapsed_seconds);
          ) result.migrations;

          Lwt.return_unit
    )
  )

let test_run_no_pending () =
  with_test_db_pooled "migrator_no_pending" (fun db_url ->
    with_temp_dir "migrations" (fun migrations_dir ->
      let v1 = 20240115120000L in
      let _f1 = create_migration_with_sections migrations_dir v1 "table1"
        "CREATE TABLE table1 (id SERIAL PRIMARY KEY);" "DROP TABLE table1;" in

      let config = Migra.Migrator.{
        database_url = db_url;
        migrations_dir;
        verbose = false;
      } in

      Migra.Migrator.run config >>= function
      | Error err ->
          Alcotest.fail (Printf.sprintf "First run failed: %s" (Migra.Types.show_error err))
      | Ok _ ->
          Migra.Migrator.run config >>= function
          | Error err ->
              Alcotest.fail (Printf.sprintf "Second run failed: %s" (Migra.Types.show_error err))
          | Ok result ->
              Alcotest.(check int) "0 migrations ran" 0 (List.length result.migrations);
              Alcotest.(check int) "0 successes" 0 result.success_count;
              Alcotest.(check int) "0 failures" 0 result.failure_count;
              Lwt.return_unit
    )
  )

let test_run_stops_on_failure () =
  with_test_db_pooled "migrator_failure" (fun db_url ->
    with_temp_dir "migrations" (fun migrations_dir ->
      let v1 = 20240115120000L in
      let v2 = 20240115130000L in
      let v3 = 20240115140000L in

      let _f1 = create_migration_with_sections migrations_dir v1 "table1"
        "CREATE TABLE table1 (id SERIAL PRIMARY KEY);" "DROP TABLE table1;" in
      let _f2 = create_migration_with_sections migrations_dir v2 "bad"
        "SELECT * FROM nonexistent_table;" "-- nothing" in
      let _f3 = create_migration_with_sections migrations_dir v3 "table3"
        "CREATE TABLE table3 (id SERIAL PRIMARY KEY);" "DROP TABLE table3;" in

      let config = Migra.Migrator.{
        database_url = db_url;
        migrations_dir;
        verbose = false;
      } in

      Migra.Migrator.run config >>= function
      | Error err ->
          Alcotest.fail (Printf.sprintf "Migrator.run failed: %s" (Migra.Types.show_error err))
      | Ok result ->
          Alcotest.(check int) "2 migrations attempted" 2 (List.length result.migrations);
          Alcotest.(check int) "1 success" 1 result.success_count;
          Alcotest.(check int) "1 failure" 1 result.failure_count;

          let m1 = List.nth result.migrations 0 in
          Alcotest.(check bool) "v1 succeeded" true m1.success;

          let m2 = List.nth result.migrations 1 in
          Alcotest.(check bool) "v2 failed" false m2.success;
          Alcotest.(check bool) "v2 has error" true (Option.is_some m2.error);

          Lwt.return_unit
    )
  )

let test_rollback_step () =
  with_test_db_pooled "migrator_rollback_step" (fun db_url ->
    with_temp_dir "migrations" (fun migrations_dir ->
      let v1 = 20240115120000L in
      let v2 = 20240115130000L in
      let v3 = 20240115140000L in

      let _f1 = create_migration_with_sections migrations_dir v1 "table1"
        "CREATE TABLE table1 (id SERIAL PRIMARY KEY);" "DROP TABLE table1;" in
      let _f2 = create_migration_with_sections migrations_dir v2 "table2"
        "CREATE TABLE table2 (id SERIAL PRIMARY KEY);" "DROP TABLE table2;" in
      let _f3 = create_migration_with_sections migrations_dir v3 "table3"
        "CREATE TABLE table3 (id SERIAL PRIMARY KEY);" "DROP TABLE table3;" in

      let config = Migra.Migrator.{
        database_url = db_url;
        migrations_dir;
        verbose = false;
      } in

      Migra.Migrator.run config >>= function
      | Error err ->
          Alcotest.fail (Printf.sprintf "Migrator.run failed: %s" (Migra.Types.show_error err))
      | Ok _ ->
          Migra.Migrator.rollback config (Step 2) >>= function
          | Error err ->
              Alcotest.fail (Printf.sprintf "Migrator.rollback failed: %s" (Migra.Types.show_error err))
          | Ok result ->
              Alcotest.(check int) "2 rollbacks" 2 (List.length result.migrations);
              Alcotest.(check int) "2 successes" 2 result.success_count;
              Alcotest.(check int) "0 failures" 0 result.failure_count;

              List.iter (fun m ->
                Alcotest.(check bool) "rollback succeeded" true m.Migra.Migrator.success;
              ) result.migrations;

              Lwt.return_unit
    )
  )

let test_rollback_to () =
  with_test_db_pooled "migrator_rollback_to" (fun db_url ->
    with_temp_dir "migrations" (fun migrations_dir ->
      let v1 = 20240115120000L in
      let v2 = 20240115130000L in
      let v3 = 20240115140000L in

      let _f1 = create_migration_with_sections migrations_dir v1 "table1"
        "CREATE TABLE table1 (id SERIAL PRIMARY KEY);" "DROP TABLE table1;" in
      let _f2 = create_migration_with_sections migrations_dir v2 "table2"
        "CREATE TABLE table2 (id SERIAL PRIMARY KEY);" "DROP TABLE table2;" in
      let _f3 = create_migration_with_sections migrations_dir v3 "table3"
        "CREATE TABLE table3 (id SERIAL PRIMARY KEY);" "DROP TABLE table3;" in

      let config = Migra.Migrator.{
        database_url = db_url;
        migrations_dir;
        verbose = false;
      } in

      Migra.Migrator.run config >>= function
      | Error err ->
          Alcotest.fail (Printf.sprintf "Migrator.run failed: %s" (Migra.Types.show_error err))
      | Ok _ ->
          Migra.Migrator.rollback config (To v1) >>= function
          | Error err ->
              Alcotest.fail (Printf.sprintf "Migrator.rollback failed: %s" (Migra.Types.show_error err))
          | Ok result ->
              Alcotest.(check int) "2 rollbacks" 2 (List.length result.migrations);
              Alcotest.(check int) "2 successes" 2 result.success_count;
              Lwt.return_unit
    )
  )

let test_rollback_all () =
  with_test_db_pooled "migrator_rollback_all" (fun db_url ->
    with_temp_dir "migrations" (fun migrations_dir ->
      let v1 = 20240115120000L in
      let v2 = 20240115130000L in

      let _f1 = create_migration_with_sections migrations_dir v1 "table1"
        "CREATE TABLE table1 (id SERIAL PRIMARY KEY);" "DROP TABLE table1;" in
      let _f2 = create_migration_with_sections migrations_dir v2 "table2"
        "CREATE TABLE table2 (id SERIAL PRIMARY KEY);" "DROP TABLE table2;" in

      let config = Migra.Migrator.{
        database_url = db_url;
        migrations_dir;
        verbose = false;
      } in

      Migra.Migrator.run config >>= function
      | Error err ->
          Alcotest.fail (Printf.sprintf "Migrator.run failed: %s" (Migra.Types.show_error err))
      | Ok _ ->
          Migra.Migrator.rollback config All >>= function
          | Error err ->
              Alcotest.fail (Printf.sprintf "Migrator.rollback failed: %s" (Migra.Types.show_error err))
          | Ok result ->
              Alcotest.(check int) "2 rollbacks" 2 (List.length result.migrations);
              Alcotest.(check int) "2 successes" 2 result.success_count;
              Lwt.return_unit
    )
  )

let test_rollback_empty () =
  with_test_db_pooled "migrator_rollback_empty" (fun db_url ->
    with_temp_dir "migrations" (fun migrations_dir ->
      let config = Migra.Migrator.{
        database_url = db_url;
        migrations_dir;
        verbose = false;
      } in

      Migra.Migrator.rollback config All >>= function
      | Error err ->
          Alcotest.fail (Printf.sprintf "Migrator.rollback failed: %s" (Migra.Types.show_error err))
      | Ok result ->
          Alcotest.(check int) "0 rollbacks" 0 (List.length result.migrations);
          Alcotest.(check int) "0 successes" 0 result.success_count;
          Lwt.return_unit
    )
  )

let test_status () =
  with_test_db_pooled "migrator_status" (fun db_url ->
    with_temp_dir "migrations" (fun migrations_dir ->
      let v1 = 20240115120000L in
      let v2 = 20240115130000L in
      let v3 = 20240115140000L in

      let _f1 = create_migration_with_sections migrations_dir v1 "table1"
        "CREATE TABLE table1 (id SERIAL PRIMARY KEY);" "DROP TABLE table1;" in
      let _f2 = create_migration_with_sections migrations_dir v2 "table2"
        "CREATE TABLE table2 (id SERIAL PRIMARY KEY);" "DROP TABLE table2;" in
      let _f3 = create_migration_with_sections migrations_dir v3 "table3"
        "CREATE TABLE table3 (id SERIAL PRIMARY KEY);" "DROP TABLE table3;" in

      let config = Migra.Migrator.{
        database_url = db_url;
        migrations_dir;
        verbose = false;
      } in

      Migra.Migrator.status config >>= function
      | Error err ->
          Alcotest.fail (Printf.sprintf "status failed: %s" (Migra.Types.show_error err))
      | Ok initial_status ->
          Alcotest.(check int) "3 migrations found" 3 (List.length initial_status.migrations);
          Alcotest.(check int) "3 pending" 3 initial_status.pending_count;
          Alcotest.(check int) "0 applied" 0 initial_status.applied_count;

          let config_limited = Migra.Migrator.{ config with migrations_dir } in
          Migra.Migrator.run config_limited >>= function
          | Error err ->
              Alcotest.fail (Printf.sprintf "run failed: %s" (Migra.Types.show_error err))
          | Ok run_result ->
              Alcotest.(check int) "3 migrations ran" 3 (List.length run_result.migrations);

              Migra.Migrator.status config >>= function
              | Error err ->
                  Alcotest.fail (Printf.sprintf "status after run failed: %s" (Migra.Types.show_error err))
              | Ok final_status ->
                  Alcotest.(check int) "3 migrations total" 3 (List.length final_status.migrations);
                  Alcotest.(check int) "0 pending" 0 final_status.pending_count;
                  Alcotest.(check int) "3 applied" 3 final_status.applied_count;

                  List.iter (fun m ->
                    Alcotest.(check bool) "migration applied" true m.Migra.Migrator.applied;
                    Alcotest.(check bool) "has timestamp" true (Option.is_some m.applied_at);
                  ) final_status.migrations;

                  Lwt.return_unit
    )
  )

let test_status_mixed () =
  with_test_db_pooled "migrator_status_mixed" (fun db_url ->
    with_temp_dir "migrations" (fun migrations_dir ->
      let v1 = 20240115120000L in
      let _f1 = create_migration_with_sections migrations_dir v1 "table1"
        "CREATE TABLE table1 (id SERIAL PRIMARY KEY);" "DROP TABLE table1;" in

      let config = Migra.Migrator.{
        database_url = db_url;
        migrations_dir;
        verbose = false;
      } in

      Migra.Migrator.run config >>= function
      | Error err ->
          Alcotest.fail (Printf.sprintf "First run failed: %s" (Migra.Types.show_error err))
      | Ok _ ->
          let v2 = 20240115130000L in
          let _f2 = create_migration_with_sections migrations_dir v2 "table2"
            "CREATE TABLE table2 (id SERIAL PRIMARY KEY);" "DROP TABLE table2;" in

          Migra.Migrator.status config >>= function
          | Error err ->
              Alcotest.fail (Printf.sprintf "status failed: %s" (Migra.Types.show_error err))
          | Ok status ->
              Alcotest.(check int) "2 migrations total" 2 (List.length status.migrations);
              Alcotest.(check int) "1 pending" 1 status.pending_count;
              Alcotest.(check int) "1 applied" 1 status.applied_count;

              let s1 = List.nth status.migrations 0 in
              Alcotest.(check bool) "v1 applied" true s1.applied;
              Alcotest.(check bool) "v1 has timestamp" true (Option.is_some s1.applied_at);

              let s2 = List.nth status.migrations 1 in
              Alcotest.(check bool) "v2 not applied" false s2.applied;
              Alcotest.(check bool) "v2 no timestamp" true (Option.is_none s2.applied_at);

              Lwt.return_unit
    )
  )

let async_of_sync f () = f (); Lwt.return_unit

let suite = [
  "run_pending", `Quick, test_run_pending;
  "run_no_pending", `Quick, test_run_no_pending;
  "run_stops_on_failure", `Quick, test_run_stops_on_failure;
  "rollback_step", `Quick, test_rollback_step;
  "rollback_to", `Quick, test_rollback_to;
  "rollback_all", `Quick, test_rollback_all;
  "rollback_empty", `Quick, test_rollback_empty;
  "status", `Quick, test_status;
  "status_mixed", `Quick, test_status_mixed;
]
