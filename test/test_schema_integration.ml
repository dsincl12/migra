
open Lwt.Infix
open Test_helpers

let with_db db_url f =
  Migris.Database.connect_db db_url >>= function
  | Error err -> Lwt.fail_with (Printf.sprintf "Failed to connect: %s" (Migris.Types.show_error err))
  | Ok db -> f db

let test_create_table () =
  with_test_db_pooled "schema_create" (fun db_url ->
    with_db db_url (fun db ->
      Migris.Runner.ensure_migrations_table db >>= function
      | Error err ->
          Alcotest.fail (Printf.sprintf "create_table failed: %s" (Caqti_error.show err))
      | Ok () ->
          Migris.Runner.get_applied_versions db >>= function
          | Error err ->
              Alcotest.fail (Printf.sprintf "Query after create failed: %s" (Caqti_error.show err))
          | Ok versions ->
              Alcotest.(check int) "New table is empty" 0 (List.length versions);
              Lwt.return_unit
    )
  )

let test_create_table_idempotent () =
  with_test_db_pooled "schema_idempotent" (fun db_url ->
    with_db db_url (fun db ->
      Migris.Runner.ensure_migrations_table db >>= function
      | Error err ->
          Alcotest.fail (Printf.sprintf "First create_table failed: %s" (Caqti_error.show err))
      | Ok () ->
          Migris.Runner.ensure_migrations_table db >>= function
          | Error err ->
              Alcotest.fail (Printf.sprintf "Second create_table failed: %s" (Caqti_error.show err))
          | Ok () ->
              Lwt.return_unit
    )
  )

let test_initialize_idempotent () =
  with_test_db_pooled "schema_init" (fun db_url ->
    with_db db_url (fun db ->
      Migris.Runner.ensure_migrations_table db >>= function
      | Error err ->
          Alcotest.fail (Printf.sprintf "First initialize failed: %s" (Caqti_error.show err))
      | Ok () ->
          Migris.Runner.ensure_migrations_table db >>= function
          | Error err ->
              Alcotest.fail (Printf.sprintf "Second initialize failed: %s" (Caqti_error.show err))
          | Ok () ->
              Lwt.return_unit
    )
  )

let test_is_applied_false () =
  with_test_db_pooled "schema_is_applied_false" (fun db_url ->
    with_db db_url (fun db ->
      Migris.Runner.ensure_migrations_table db >>= function
      | Error err ->
          Alcotest.fail (Printf.sprintf "Initialize failed: %s" (Caqti_error.show err))
      | Ok () ->
          Migris.Runner.is_applied db 20240115120000L >>= function
          | Error err ->
              Alcotest.fail (Printf.sprintf "is_applied failed: %s" (Caqti_error.show err))
          | Ok applied ->
              Alcotest.(check bool) "Version not applied" false applied;
              Lwt.return_unit
    )
  )

let test_is_applied_true () =
  with_test_db_pooled "schema_is_applied_true" (fun db_url ->
    with_db db_url (fun db ->
      Migris.Runner.ensure_migrations_table db >>= function
      | Error err ->
          Alcotest.fail (Printf.sprintf "Initialize failed: %s" (Caqti_error.show err))
      | Ok () ->
          let version = 20240115120000L in
          Migris.Runner.add_migration db version >>= function
          | Error err ->
              Alcotest.fail (Printf.sprintf "add_migration failed: %s" (Caqti_error.show err))
          | Ok () ->
              Migris.Runner.is_applied db version >>= function
              | Error err ->
                  Alcotest.fail (Printf.sprintf "is_applied failed: %s" (Caqti_error.show err))
              | Ok applied ->
                  Alcotest.(check bool) "Version is applied" true applied;
                  Lwt.return_unit
    )
  )

let test_get_applied_versions_empty () =
  with_test_db_pooled "schema_versions_empty" (fun db_url ->
    with_db db_url (fun db ->
      Migris.Runner.ensure_migrations_table db >>= function
      | Error err ->
          Alcotest.fail (Printf.sprintf "Initialize failed: %s" (Caqti_error.show err))
      | Ok () ->
          Migris.Runner.get_applied_versions db >>= function
          | Error err ->
              Alcotest.fail (Printf.sprintf "get_applied_versions failed: %s" (Caqti_error.show err))
          | Ok versions ->
              Alcotest.(check int) "Empty versions list" 0 (List.length versions);
              Lwt.return_unit
    )
  )

let test_get_applied_versions_sorted () =
  with_test_db_pooled "schema_versions_sorted" (fun db_url ->
    with_db db_url (fun db ->
      Migris.Runner.ensure_migrations_table db >>= function
      | Error err ->
          Alcotest.fail (Printf.sprintf "Initialize failed: %s" (Caqti_error.show err))
      | Ok () ->
          let v1 = 20240115120000L in
          let v2 = 20240114100000L in
          let v3 = 20240116150000L in

          Migris.Runner.add_migration db v2 >>= fun _ ->
          Migris.Runner.add_migration db v3 >>= fun _ ->
          Migris.Runner.add_migration db v1 >>= fun _ ->

          Migris.Runner.get_applied_versions db >>= function
          | Error err ->
              Alcotest.fail (Printf.sprintf "get_applied_versions failed: %s" (Caqti_error.show err))
          | Ok versions ->
              Alcotest.(check int) "Three versions" 3 (List.length versions);
              Alcotest.(check int64_testable) "First version" v2 (List.nth versions 0);
              Alcotest.(check int64_testable) "Second version" v1 (List.nth versions 1);
              Alcotest.(check int64_testable) "Third version" v3 (List.nth versions 2);
              Lwt.return_unit
    )
  )

let test_get_applied_records_empty () =
  with_test_db_pooled "schema_records_empty" (fun db_url ->
    with_db db_url (fun db ->
      Migris.Runner.ensure_migrations_table db >>= function
      | Error err ->
          Alcotest.fail (Printf.sprintf "Initialize failed: %s" (Caqti_error.show err))
      | Ok () ->
          Migris.Runner.get_applied_records db >>= function
          | Error err ->
              Alcotest.fail (Printf.sprintf "get_applied_records failed: %s" (Caqti_error.show err))
          | Ok records ->
              Alcotest.(check int) "Empty records list" 0 (List.length records);
              Lwt.return_unit
    )
  )

let test_get_applied_records_with_timestamps () =
  with_test_db_pooled "schema_records" (fun db_url ->
    with_db db_url (fun db ->
      Migris.Runner.ensure_migrations_table db >>= function
      | Error err ->
          Alcotest.fail (Printf.sprintf "Initialize failed: %s" (Caqti_error.show err))
      | Ok () ->
          let version = 20240115120000L in
          Migris.Runner.add_migration db version >>= function
          | Error err ->
              Alcotest.fail (Printf.sprintf "add_migration failed: %s" (Caqti_error.show err))
          | Ok () ->
              Migris.Runner.get_applied_records db >>= function
              | Error err ->
                  Alcotest.fail (Printf.sprintf "get_applied_records failed: %s" (Caqti_error.show err))
              | Ok records ->
                  Alcotest.(check int) "One record" 1 (List.length records);
                  let record = List.hd records in
                  Alcotest.(check int64_testable) "Record version" version record.Migris.Runner.version;
                  Alcotest.(check bool) "created_at exists"
                    true (String.length record.Migris.Runner.created_at > 0);
                  Lwt.return_unit
    )
  )

let test_add_migration_success () =
  with_test_db_pooled "schema_record" (fun db_url ->
    with_db db_url (fun db ->
      Migris.Runner.ensure_migrations_table db >>= function
      | Error err ->
          Alcotest.fail (Printf.sprintf "Initialize failed: %s" (Caqti_error.show err))
      | Ok () ->
          let version = 20240115120000L in
          Migris.Runner.add_migration db version >>= function
          | Error err ->
              Alcotest.fail (Printf.sprintf "add_migration failed: %s" (Caqti_error.show err))
          | Ok () ->
              Migris.Runner.is_applied db version >>= function
              | Error err ->
                  Alcotest.fail (Printf.sprintf "is_applied failed: %s" (Caqti_error.show err))
              | Ok applied ->
                  Alcotest.(check bool) "Migration was recorded" true applied;
                  Lwt.return_unit
    )
  )

let test_add_migration_duplicate_fails () =
  with_test_db_pooled "schema_duplicate" (fun db_url ->
    with_db db_url (fun db ->
      Migris.Runner.ensure_migrations_table db >>= function
      | Error err ->
          Alcotest.fail (Printf.sprintf "Initialize failed: %s" (Caqti_error.show err))
      | Ok () ->
          let version = 20240115120000L in
          Migris.Runner.add_migration db version >>= function
          | Error err ->
              Alcotest.fail (Printf.sprintf "First add_migration failed: %s" (Caqti_error.show err))
          | Ok () ->
              Migris.Runner.add_migration db version >>= function
              | Ok () ->
                  Alcotest.fail "Expected duplicate insert to fail, but it succeeded"
              | Error _err ->
                  Lwt.return_unit
    )
  )

let test_remove_migration_success () =
  with_test_db_pooled "schema_remove" (fun db_url ->
    with_db db_url (fun db ->
      Migris.Runner.ensure_migrations_table db >>= function
      | Error err ->
          Alcotest.fail (Printf.sprintf "Initialize failed: %s" (Caqti_error.show err))
      | Ok () ->
          let version = 20240115120000L in
          Migris.Runner.add_migration db version >>= fun _ ->
          Migris.Runner.remove_migration db version >>= function
          | Error err ->
              Alcotest.fail (Printf.sprintf "remove_migration failed: %s" (Caqti_error.show err))
          | Ok () ->
              Migris.Runner.is_applied db version >>= function
              | Error err ->
                  Alcotest.fail (Printf.sprintf "is_applied failed: %s" (Caqti_error.show err))
              | Ok applied ->
                  Alcotest.(check bool) "Migration was removed" false applied;
                  Lwt.return_unit
    )
  )

let test_remove_migration_nonexistent () =
  with_test_db_pooled "schema_remove_nonexist" (fun db_url ->
    with_db db_url (fun db ->
      Migris.Runner.ensure_migrations_table db >>= function
      | Error err ->
          Alcotest.fail (Printf.sprintf "Initialize failed: %s" (Caqti_error.show err))
      | Ok () ->
          Migris.Runner.remove_migration db 20240115120000L >>= function
          | Error err ->
              Alcotest.fail (Printf.sprintf "remove_migration failed: %s" (Caqti_error.show err))
          | Ok () ->
              Lwt.return_unit
    )
  )

let test_get_latest_version_none () =
  with_test_db_pooled "schema_latest_none" (fun db_url ->
    with_db db_url (fun db ->
      Migris.Runner.ensure_migrations_table db >>= function
      | Error err ->
          Alcotest.fail (Printf.sprintf "Initialize failed: %s" (Caqti_error.show err))
      | Ok () ->
          Migris.Runner.get_latest_version db >>= function
          | Error err ->
              Alcotest.fail (Printf.sprintf "get_latest_version failed: %s" (Caqti_error.show err))
          | Ok latest ->
              Alcotest.(check (option int64_testable)) "No latest version" None latest;
              Lwt.return_unit
    )
  )

let test_get_latest_version_some () =
  with_test_db_pooled "schema_latest_some" (fun db_url ->
    with_db db_url (fun db ->
      Migris.Runner.ensure_migrations_table db >>= function
      | Error err ->
          Alcotest.fail (Printf.sprintf "Initialize failed: %s" (Caqti_error.show err))
      | Ok () ->
          let version = 20240115120000L in
          Migris.Runner.add_migration db version >>= fun _ ->
          Migris.Runner.get_latest_version db >>= function
          | Error err ->
              Alcotest.fail (Printf.sprintf "get_latest_version failed: %s" (Caqti_error.show err))
          | Ok latest ->
              Alcotest.(check (option int64_testable)) "Latest version" (Some version) latest;
              Lwt.return_unit
    )
  )

let test_get_latest_version_highest () =
  with_test_db_pooled "schema_latest_highest" (fun db_url ->
    with_db db_url (fun db ->
      Migris.Runner.ensure_migrations_table db >>= function
      | Error err ->
          Alcotest.fail (Printf.sprintf "Initialize failed: %s" (Caqti_error.show err))
      | Ok () ->
          let v1 = 20240115120000L in
          let v2 = 20240114100000L in
          let v3 = 20240116150000L in

          Migris.Runner.add_migration db v2 >>= fun _ ->
          Migris.Runner.add_migration db v1 >>= fun _ ->
          Migris.Runner.add_migration db v3 >>= fun _ ->

          Migris.Runner.get_latest_version db >>= function
          | Error err ->
              Alcotest.fail (Printf.sprintf "get_latest_version failed: %s" (Caqti_error.show err))
          | Ok latest ->
              Alcotest.(check (option int64_testable)) "Latest is highest" (Some v3) latest;
              Lwt.return_unit
    )
  )

let suite = [
  "create_table creates schema_migrations table", `Quick, test_create_table;
  "create_table is idempotent", `Quick, test_create_table_idempotent;
  "initialize is idempotent", `Quick, test_initialize_idempotent;
  "is_applied returns false for non-existent version", `Quick, test_is_applied_false;
  "is_applied returns true for applied version", `Quick, test_is_applied_true;
  "get_applied_versions returns empty list for new table", `Quick, test_get_applied_versions_empty;
  "get_applied_versions returns sorted list", `Quick, test_get_applied_versions_sorted;
  "get_applied_records returns empty list for new table", `Quick, test_get_applied_records_empty;
  "get_applied_records returns records with timestamps", `Quick, test_get_applied_records_with_timestamps;
  "add_migration successfully inserts version", `Quick, test_add_migration_success;
  "add_migration fails on duplicate version", `Quick, test_add_migration_duplicate_fails;
  "remove_migration successfully removes version", `Quick, test_remove_migration_success;
  "remove_migration is safe on non-existent version", `Quick, test_remove_migration_nonexistent;
  "get_latest_version returns None for empty table", `Quick, test_get_latest_version_none;
  "get_latest_version returns Some(version) for non-empty table", `Quick, test_get_latest_version_some;
  "get_latest_version returns highest version number", `Quick, test_get_latest_version_highest;
]
