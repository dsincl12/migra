open Test_helpers

let test_is_migration_file_valid () =
  Alcotest.(check bool)
    "valid migration file" true
    (Migra.Discovery.is_migration_file "20240115120000_create_users.sql");

  Alcotest.(check bool)
    "valid with longer description" true
    (Migra.Discovery.is_migration_file
       "20240115120000_add_user_email_column.sql");

  Alcotest.(check bool)
    "valid with short description" true
    (Migra.Discovery.is_migration_file "20240115120000_a.sql")

let test_is_migration_file_invalid () =
  Alcotest.(check bool)
    "reject .txt extension" false
    (Migra.Discovery.is_migration_file "20240115120000_create_users.txt");

  Alcotest.(check bool)
    "reject no extension" false
    (Migra.Discovery.is_migration_file "20240115120000_create_users");

  Alcotest.(check bool)
    "reject too short" false
    (Migra.Discovery.is_migration_file "2024_short.sql");

  Alcotest.(check bool)
    "reject non-numeric version" false
    (Migra.Discovery.is_migration_file "2024011512000X_create.sql");

  Alcotest.(check bool)
    "reject missing underscore" false
    (Migra.Discovery.is_migration_file "20240115120000create.sql");

  Alcotest.(check bool)
    "reject README" false
    (Migra.Discovery.is_migration_file "README.md");

  Alcotest.(check bool)
    "reject empty" false
    (Migra.Discovery.is_migration_file "");

  Alcotest.(check bool)
    "reject just .sql" false
    (Migra.Discovery.is_migration_file ".sql")

let test_read_directory_valid () =
  Lwt_main.run
    (with_temp_dir "discovery_test" (fun dir ->
         let _ = create_migration_file dir 20240115120000L "first" "-- test" in
         let _ = create_migration_file dir 20240115130000L "second" "-- test" in

         let result = Migra.Discovery.read_directory dir in
         Alcotest.(check bool) "read_directory succeeds" true (is_ok result);

         let files =
           match result with
           | Ok f -> f
           | Error err ->
               Alcotest.fail
                 (Printf.sprintf "Expected Ok but got Error: %s"
                    (Migra.Types.show_error err))
         in
         Alcotest.(check bool) "found files" true (List.length files >= 2);

         Lwt.return_unit))

let test_read_directory_nonexistent () =
  let result =
    Migra.Discovery.read_directory "/tmp/nonexistent_directory_12345"
  in
  Alcotest.(check bool) "read_directory fails" true (is_error result);

  let error =
    match result with
    | Ok _ -> Alcotest.fail "Expected Error but got Ok"
    | Error err -> Migra.Types.show_error err
  in
  Alcotest.(check bool)
    "mentions nonexistent" true
    (Test_helpers.string_contains_substring error "does not exist")

let test_read_directory_not_a_dir () =
  Lwt_main.run
    (with_temp_dir "discovery_test" (fun dir ->
         let filepath = Filename.concat dir "testfile.txt" in
         let oc = open_out filepath in
         close_out oc;

         let result = Migra.Discovery.read_directory filepath in
         Alcotest.(check bool) "read_directory fails" true (is_error result);

         let error =
           match result with
           | Ok _ -> Alcotest.fail "Expected Error but got Ok"
           | Error err -> Migra.Types.show_error err
         in
         Alcotest.(check bool)
           "mentions not a directory" true
           (Test_helpers.string_contains_substring error "not a directory");

         Lwt.return_unit))

let test_find_migrations () =
  Lwt_main.run
    (with_temp_dir "discovery_test" (fun dir ->
         let _ =
           create_migration_with_sections dir 20240115130000L "third"
             "CREATE TABLE c;" "DROP TABLE c;"
         in
         let _ =
           create_migration_with_sections dir 20240115110000L "first"
             "CREATE TABLE a;" "DROP TABLE a;"
         in
         let _ =
           create_migration_with_sections dir 20240115120000L "second"
             "CREATE TABLE b;" "DROP TABLE b;"
         in

         let result = Migra.Discovery.find_migrations ~dir () in
         Alcotest.(check bool) "find_migrations succeeds" true (is_ok result);

         let migrations =
           match result with
           | Ok m -> m
           | Error err ->
               Alcotest.fail
                 (Printf.sprintf "Expected Ok but got Error: %s"
                    (Migra.Types.show_error err))
         in
         Alcotest.(check int) "found 3 migrations" 3 (List.length migrations);

         let versions =
           List.map (fun m -> m.Migra.Migration.version) migrations
         in
         Alcotest.(check (list int64_testable))
           "migrations sorted"
           [ 20240115110000L; 20240115120000L; 20240115130000L ]
           versions;

         Lwt.return_unit))

let test_find_migrations_duplicate_version () =
  Lwt_main.run
    (with_temp_dir "discovery_dup" (fun dir ->
         let _ =
           create_migration_with_sections dir 20240115120000L "alpha"
             "CREATE TABLE a;" "DROP TABLE a;"
         in
         let _ =
           create_migration_with_sections dir 20240115120000L "beta"
             "CREATE TABLE b;" "DROP TABLE b;"
         in

         let result = Migra.Discovery.find_migrations ~dir () in
         Alcotest.(check bool)
           "find_migrations fails on duplicate" true (is_error result);

         let error =
           match result with
           | Ok _ -> Alcotest.fail "Expected Error but got Ok"
           | Error err -> Migra.Types.show_error err
         in
         Alcotest.(check bool)
           "mentions the conflicting version" true
           (Test_helpers.string_contains_substring error "20240115120000");
         Alcotest.(check bool)
           "mentions duplicated" true
           (Test_helpers.string_contains_substring error "duplicated");

         Lwt.return_unit))

let test_find_migrations_rejects_malformed () =
  Lwt_main.run
    (with_temp_dir "discovery_malformed" (fun dir ->
         let _ =
           create_migration_with_sections dir 20240115120000L "ok"
             "CREATE TABLE t;" "DROP TABLE t;"
         in
         let oc = open_out (Filename.concat dir "1234567890_234_oops.sql") in
         output_string oc "-- +migrate up\n-- +migrate down\n";
         close_out oc;
         let result = Migra.Discovery.find_migrations ~dir () in
         Alcotest.(check bool)
           "malformed migration file is an error" true (is_error result);
         Lwt.return_unit))

let test_find_migrations_ignores_non_migration_sql () =
  Lwt_main.run
    (with_temp_dir "discovery_helper" (fun dir ->
         let _ =
           create_migration_with_sections dir 20240115120000L "ok"
             "CREATE TABLE t;" "DROP TABLE t;"
         in
         let oc = open_out (Filename.concat dir "helpers.sql") in
         output_string oc "SELECT 1;";
         close_out oc;
         let result = Migra.Discovery.find_migrations ~dir () in
         Alcotest.(check bool)
           "succeeds, ignoring non-migration .sql" true (is_ok result);
         (match result with
         | Ok ms ->
             Alcotest.(check int) "only the real migration" 1 (List.length ms)
         | Error _ -> ());
         Lwt.return_unit))

let test_find_migrations_uppercase_ext () =
  Lwt_main.run
    (with_temp_dir "discovery_upper" (fun dir ->
         let oc = open_out (Filename.concat dir "20240115120000_up.SQL") in
         output_string oc
           "-- +migrate up\nCREATE TABLE t;\n-- +migrate down\nDROP TABLE t;\n";
         close_out oc;
         let result = Migra.Discovery.find_migrations ~dir () in
         Alcotest.(check bool) "uppercase .SQL recognized" true (is_ok result);
         (match result with
         | Ok ms ->
             Alcotest.(check int) "one migration found" 1 (List.length ms)
         | Error _ -> ());
         Lwt.return_unit))

let test_find_migrations_empty () =
  Lwt_main.run
    (with_temp_dir "discovery_empty" (fun dir ->
         let result = Migra.Discovery.find_migrations ~dir () in
         Alcotest.(check bool) "find_migrations succeeds" true (is_ok result);

         let migrations =
           match result with
           | Ok m -> m
           | Error err ->
               Alcotest.fail
                 (Printf.sprintf "Expected Ok but got Error: %s"
                    (Migra.Types.show_error err))
         in
         Alcotest.(check int) "no migrations found" 0 (List.length migrations);

         Lwt.return_unit))

let test_find_migrations_filters () =
  Lwt_main.run
    (with_temp_dir "discovery_filter" (fun dir ->
         let _ =
           create_migration_with_sections dir 20240115120000L "valid"
             "CREATE TABLE t;" "DROP TABLE t;"
         in

         let oc1 = open_out (Filename.concat dir "README.md") in
         close_out oc1;
         let oc2 = open_out (Filename.concat dir "invalid_name.sql") in
         close_out oc2;

         let result = Migra.Discovery.find_migrations ~dir () in
         Alcotest.(check bool) "find_migrations succeeds" true (is_ok result);

         let migrations =
           match result with
           | Ok m -> m
           | Error err ->
               Alcotest.fail
                 (Printf.sprintf "Expected Ok but got Error: %s"
                    (Migra.Types.show_error err))
         in
         Alcotest.(check int) "only valid migrations" 1 (List.length migrations);

         Lwt.return_unit))

let test_find_pending_none_applied () =
  let migrations =
    [
      {
        Migra.Migration.version = 1L;
        description = "first";
        file_path = "1.sql";
      };
      {
        Migra.Migration.version = 2L;
        description = "second";
        file_path = "2.sql";
      };
      {
        Migra.Migration.version = 3L;
        description = "third";
        file_path = "3.sql";
      };
    ]
  in

  let pending = Migra.Discovery.find_pending [] migrations in
  Alcotest.(check int) "all pending" 3 (List.length pending);
  Alcotest.(check (list migration_testable)) "same as input" migrations pending

let test_find_pending_all_applied () =
  let migrations =
    [
      {
        Migra.Migration.version = 1L;
        description = "first";
        file_path = "1.sql";
      };
      {
        Migra.Migration.version = 2L;
        description = "second";
        file_path = "2.sql";
      };
      {
        Migra.Migration.version = 3L;
        description = "third";
        file_path = "3.sql";
      };
    ]
  in

  let applied = [ 1L; 2L; 3L ] in
  let pending = Migra.Discovery.find_pending applied migrations in
  Alcotest.(check int) "none pending" 0 (List.length pending)

let test_find_pending_partial () =
  let migrations =
    [
      {
        Migra.Migration.version = 1L;
        description = "first";
        file_path = "1.sql";
      };
      {
        Migra.Migration.version = 2L;
        description = "second";
        file_path = "2.sql";
      };
      {
        Migra.Migration.version = 3L;
        description = "third";
        file_path = "3.sql";
      };
      {
        Migra.Migration.version = 4L;
        description = "fourth";
        file_path = "4.sql";
      };
    ]
  in

  let applied = [ 1L; 3L ] in
  let pending = Migra.Discovery.find_pending applied migrations in
  Alcotest.(check int) "two pending" 2 (List.length pending);

  let pending_versions =
    List.map (fun m -> m.Migra.Migration.version) pending
  in
  Alcotest.(check (list int64_testable))
    "correct pending versions" [ 2L; 4L ] pending_versions

let test_find_by_version_found () =
  let migrations =
    [
      {
        Migra.Migration.version = 1L;
        description = "first";
        file_path = "1.sql";
      };
      {
        Migra.Migration.version = 2L;
        description = "second";
        file_path = "2.sql";
      };
      {
        Migra.Migration.version = 3L;
        description = "third";
        file_path = "3.sql";
      };
    ]
  in

  let result = Migra.Discovery.find_by_version migrations 2L in
  Alcotest.(check bool) "migration found" true (Option.is_some result);

  let migration = Option.get result in
  Alcotest.(check int64_testable)
    "correct version" 2L migration.Migra.Migration.version;
  Alcotest.(check string)
    "correct description" "second" migration.Migra.Migration.description

let test_find_by_version_not_found () =
  let migrations =
    [
      {
        Migra.Migration.version = 1L;
        description = "first";
        file_path = "1.sql";
      };
      {
        Migra.Migration.version = 2L;
        description = "second";
        file_path = "2.sql";
      };
    ]
  in

  let result = Migra.Discovery.find_by_version migrations 99L in
  Alcotest.(check bool) "migration not found" true (Option.is_none result)

let test_ensure_migrations_dir_creates () =
  Lwt_main.run
    (with_temp_dir "discovery_ensure" (fun dir ->
         let migrations_dir = Filename.concat dir "migrations" in

         Alcotest.(check bool)
           "dir doesn't exist yet" false
           (Sys.file_exists migrations_dir);

         let result =
           Migra.Discovery.ensure_migrations_dir ~dir:migrations_dir ()
         in
         Alcotest.(check bool) "ensure succeeds" true (is_ok result);

         Alcotest.(check bool)
           "dir exists" true
           (Sys.file_exists migrations_dir);
         Alcotest.(check bool)
           "is a directory" true
           (Sys.is_directory migrations_dir);

         Lwt.return_unit))

let test_ensure_migrations_dir_idempotent () =
  Lwt_main.run
    (with_temp_dir "discovery_idempotent" (fun dir ->
         let migrations_dir = Filename.concat dir "migrations" in

         let result1 =
           Migra.Discovery.ensure_migrations_dir ~dir:migrations_dir ()
         in
         Alcotest.(check bool) "first call succeeds" true (is_ok result1);

         let result2 =
           Migra.Discovery.ensure_migrations_dir ~dir:migrations_dir ()
         in
         Alcotest.(check bool) "second call succeeds" true (is_ok result2);

         Lwt.return_unit))

let test_ensure_migrations_dir_file_exists () =
  Lwt_main.run
    (with_temp_dir "discovery_file" (fun dir ->
         let filepath = Filename.concat dir "not_a_dir" in

         let oc = open_out filepath in
         close_out oc;

         let result = Migra.Discovery.ensure_migrations_dir ~dir:filepath () in
         Alcotest.(check bool) "ensure fails" true (is_error result);

         let error =
           match result with
           | Ok _ -> Alcotest.fail "Expected Error but got Ok"
           | Error err -> Migra.Types.show_error err
         in
         Alcotest.(check bool)
           "mentions not a directory" true
           (Test_helpers.string_contains_substring error "not a directory");

         Lwt.return_unit))

let async_of_sync f () =
  f ();
  Lwt.return_unit

let suite =
  [
    ( "is_migration_file_valid",
      `Quick,
      async_of_sync test_is_migration_file_valid );
    ( "is_migration_file_invalid",
      `Quick,
      async_of_sync test_is_migration_file_invalid );
    ("read_directory_valid", `Quick, async_of_sync test_read_directory_valid);
    ( "read_directory_nonexistent",
      `Quick,
      async_of_sync test_read_directory_nonexistent );
    ( "read_directory_not_a_dir",
      `Quick,
      async_of_sync test_read_directory_not_a_dir );
    ("find_migrations", `Quick, async_of_sync test_find_migrations);
    ( "find_migrations_duplicate_version",
      `Quick,
      async_of_sync test_find_migrations_duplicate_version );
    ( "find_migrations_rejects_malformed",
      `Quick,
      async_of_sync test_find_migrations_rejects_malformed );
    ( "find_migrations_ignores_non_migration_sql",
      `Quick,
      async_of_sync test_find_migrations_ignores_non_migration_sql );
    ( "find_migrations_uppercase_ext",
      `Quick,
      async_of_sync test_find_migrations_uppercase_ext );
    ("find_migrations_empty", `Quick, async_of_sync test_find_migrations_empty);
    ( "find_migrations_filters",
      `Quick,
      async_of_sync test_find_migrations_filters );
    ( "find_pending_none_applied",
      `Quick,
      async_of_sync test_find_pending_none_applied );
    ( "find_pending_all_applied",
      `Quick,
      async_of_sync test_find_pending_all_applied );
    ("find_pending_partial", `Quick, async_of_sync test_find_pending_partial);
    ("find_by_version_found", `Quick, async_of_sync test_find_by_version_found);
    ( "find_by_version_not_found",
      `Quick,
      async_of_sync test_find_by_version_not_found );
    ( "ensure_migrations_dir_creates",
      `Quick,
      async_of_sync test_ensure_migrations_dir_creates );
    ( "ensure_migrations_dir_idempotent",
      `Quick,
      async_of_sync test_ensure_migrations_dir_idempotent );
    ( "ensure_migrations_dir_file_exists",
      `Quick,
      async_of_sync test_ensure_migrations_dir_file_exists );
  ]
