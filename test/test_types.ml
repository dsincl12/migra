let test_show_file_error () =
  let err1 =
    Migra.Types.FileError (Migra.Types.FileNotFound "/path/to/file.sql")
  in
  let msg1 = Migra.Types.show_error err1 in
  Alcotest.(check bool)
    "contains file path" true
    (Test_helpers.string_contains_substring msg1 "/path/to/file.sql");
  Alcotest.(check bool)
    "mentions not found" true
    (Test_helpers.string_contains_substring msg1 "not found");

  let err2 = Migra.Types.FileError (Migra.Types.InvalidFormat "bad format") in
  let msg2 = Migra.Types.show_error err2 in
  Alcotest.(check bool)
    "contains format message" true
    (Test_helpers.string_contains_substring msg2 "bad format");
  Alcotest.(check bool)
    "mentions invalid" true
    (Test_helpers.string_contains_substring msg2 "Invalid");

  let exn = Failure "read failed" in
  let err3 =
    Migra.Types.FileError (Migra.Types.ReadError ("/path/file.sql", exn))
  in
  let msg3 = Migra.Types.show_error err3 in
  Alcotest.(check bool)
    "contains file path" true
    (Test_helpers.string_contains_substring msg3 "/path/file.sql");
  Alcotest.(check bool)
    "contains exception message" true
    (Test_helpers.string_contains_substring msg3 "read failed")

let test_show_database_error () =
  let err1 = Migra.Types.DatabaseError (Migra.Types.DatabaseNotFound "mydb") in
  let msg1 = Migra.Types.show_error err1 in
  Alcotest.(check bool)
    "contains database name" true
    (Test_helpers.string_contains_substring msg1 "mydb");
  Alcotest.(check bool)
    "mentions not found" true
    (Test_helpers.string_contains_substring msg1 "not found");

  let err2 =
    Migra.Types.DatabaseError (Migra.Types.UrlParseError "invalid URL")
  in
  let msg2 = Migra.Types.show_error err2 in
  Alcotest.(check bool)
    "contains parse message" true
    (Test_helpers.string_contains_substring msg2 "invalid URL");
  Alcotest.(check bool)
    "mentions parse error" true
    (Test_helpers.string_contains_substring msg2 "parse error")

let test_show_migration_error () =
  let err1 =
    Migra.Types.MigrationError (Migra.Types.MissingSection ("file.sql", "up"))
  in
  let msg1 = Migra.Types.show_error err1 in
  Alcotest.(check bool)
    "contains section name" true
    (Test_helpers.string_contains_substring msg1 "up");
  Alcotest.(check bool)
    "contains filename" true
    (Test_helpers.string_contains_substring msg1 "file.sql");
  Alcotest.(check bool)
    "mentions missing" true
    (Test_helpers.string_contains_substring msg1 "Missing");

  let err2 =
    Migra.Types.MigrationError (Migra.Types.EmptySection ("file.sql", "down"))
  in
  let msg2 = Migra.Types.show_error err2 in
  Alcotest.(check bool)
    "contains section name" true
    (Test_helpers.string_contains_substring msg2 "down");
  Alcotest.(check bool)
    "mentions empty" true
    (Test_helpers.string_contains_substring msg2 "Empty");

  let err3 =
    Migra.Types.MigrationError
      (Migra.Types.VersionConflict
         (20240115120000L, "20240115120000_a.sql", "20240115120000_b.sql"))
  in
  let msg3 = Migra.Types.show_error err3 in
  Alcotest.(check bool)
    "contains version" true
    (Test_helpers.string_contains_substring msg3 "20240115120000");
  Alcotest.(check bool)
    "mentions duplicated" true
    (Test_helpers.string_contains_substring msg3 "duplicated")

let test_show_discovery_error () =
  let err = Migra.Types.DiscoveryError "directory not found" in
  let msg = Migra.Types.show_error err in
  Alcotest.(check bool)
    "contains error message" true
    (Test_helpers.string_contains_substring msg "directory not found");
  Alcotest.(check bool)
    "mentions discovery" true
    (Test_helpers.string_contains_substring msg "Discovery")

let test_migration_error_with_file_error () =
  let file_err = Migra.Types.FileNotFound "/migrations/bad.sql" in
  let mig_err = Migra.Types.MigrationError (Migra.Types.ParseError file_err) in
  let msg = Migra.Types.show_error mig_err in
  Alcotest.(check bool)
    "contains filename" true
    (Test_helpers.string_contains_substring msg "/migrations/bad.sql");
  Alcotest.(check bool)
    "mentions not found" true
    (Test_helpers.string_contains_substring msg "not found")

let test_show_error_comprehensive () =
  let errors =
    [
      Migra.Types.FileError (Migra.Types.FileNotFound "test.sql");
      Migra.Types.FileError (Migra.Types.InvalidFormat "bad");
      Migra.Types.FileError (Migra.Types.ReadError ("test.sql", Failure "err"));
      Migra.Types.DatabaseError (Migra.Types.DatabaseNotFound "db");
      Migra.Types.DatabaseError (Migra.Types.UrlParseError "msg");
      Migra.Types.DatabaseError (Migra.Types.ValidationError "msg");
      Migra.Types.MigrationError (Migra.Types.MissingSection ("f.sql", "up"));
      Migra.Types.MigrationError (Migra.Types.EmptySection ("f.sql", "down"));
      Migra.Types.MigrationError
        (Migra.Types.VersionConflict (123L, "a.sql", "b.sql"));
      Migra.Types.DiscoveryError "discovery failed";
    ]
  in

  List.iter
    (fun err ->
      let msg = Migra.Types.show_error err in
      Alcotest.(check bool)
        "error message is non-empty" true
        (String.length msg > 0))
    errors

let async_of_sync f () =
  f ();
  Lwt.return_unit

let suite =
  [
    ("show_file_error", `Quick, async_of_sync test_show_file_error);
    ("show_database_error", `Quick, async_of_sync test_show_database_error);
    ("show_migration_error", `Quick, async_of_sync test_show_migration_error);
    ("show_discovery_error", `Quick, async_of_sync test_show_discovery_error);
    ( "migration_error_with_file_error",
      `Quick,
      async_of_sync test_migration_error_with_file_error );
    ( "show_error_comprehensive",
      `Quick,
      async_of_sync test_show_error_comprehensive );
  ]
