
let string_contains_substring haystack needle =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  let rec search pos =
    if pos + needle_len > haystack_len then false
    else if String.sub haystack pos needle_len = needle then true
    else search (pos + 1)
  in
  if needle_len = 0 then true
  else search 0

let test_show_file_error () =
  let err1 = Migris.Types.FileError (Migris.Types.FileNotFound "/path/to/file.sql") in
  let msg1 = Migris.Types.show_error err1 in
  Alcotest.(check bool) "contains file path"
    true (string_contains_substring msg1 "/path/to/file.sql");
  Alcotest.(check bool) "mentions not found"
    true (string_contains_substring msg1 "not found");

  let err2 = Migris.Types.FileError (Migris.Types.InvalidFormat "bad format") in
  let msg2 = Migris.Types.show_error err2 in
  Alcotest.(check bool) "contains format message"
    true (string_contains_substring msg2 "bad format");
  Alcotest.(check bool) "mentions invalid"
    true (string_contains_substring msg2 "Invalid");

  let exn = Failure "read failed" in
  let err3 = Migris.Types.FileError (Migris.Types.ReadError ("/path/file.sql", exn)) in
  let msg3 = Migris.Types.show_error err3 in
  Alcotest.(check bool) "contains file path"
    true (string_contains_substring msg3 "/path/file.sql");
  Alcotest.(check bool) "contains exception message"
    true (string_contains_substring msg3 "read failed")

let test_show_database_error () =
  let err1 = Migris.Types.DatabaseError (Migris.Types.DatabaseNotFound "mydb") in
  let msg1 = Migris.Types.show_error err1 in
  Alcotest.(check bool) "contains database name"
    true (string_contains_substring msg1 "mydb");
  Alcotest.(check bool) "mentions not found"
    true (string_contains_substring msg1 "not found");

  let err2 = Migris.Types.DatabaseError (Migris.Types.ParseError "invalid URL") in
  let msg2 = Migris.Types.show_error err2 in
  Alcotest.(check bool) "contains parse message"
    true (string_contains_substring msg2 "invalid URL");
  Alcotest.(check bool) "mentions parse error"
    true (string_contains_substring msg2 "Parse error")

let test_show_migration_error () =
  let err1 = Migris.Types.MigrationError (Migris.Types.MissingSection ("file.sql", "up")) in
  let msg1 = Migris.Types.show_error err1 in
  Alcotest.(check bool) "contains section name"
    true (string_contains_substring msg1 "up");
  Alcotest.(check bool) "contains filename"
    true (string_contains_substring msg1 "file.sql");
  Alcotest.(check bool) "mentions missing"
    true (string_contains_substring msg1 "Missing");

  let err2 = Migris.Types.MigrationError (Migris.Types.EmptySection ("file.sql", "down")) in
  let msg2 = Migris.Types.show_error err2 in
  Alcotest.(check bool) "contains section name"
    true (string_contains_substring msg2 "down");
  Alcotest.(check bool) "mentions empty"
    true (string_contains_substring msg2 "Empty");

  let err3 = Migris.Types.MigrationError (Migris.Types.VersionConflict 20240115120000L) in
  let msg3 = Migris.Types.show_error err3 in
  Alcotest.(check bool) "contains version"
    true (string_contains_substring msg3 "20240115120000");
  Alcotest.(check bool) "mentions conflict"
    true (string_contains_substring msg3 "conflict")

let test_show_discovery_error () =
  let err = Migris.Types.DiscoveryError "directory not found" in
  let msg = Migris.Types.show_error err in
  Alcotest.(check bool) "contains error message"
    true (string_contains_substring msg "directory not found");
  Alcotest.(check bool) "mentions discovery"
    true (string_contains_substring msg "Discovery")

let test_migration_error_with_file_error () =
  let file_err = Migris.Types.FileNotFound "/migrations/bad.sql" in
  let mig_err = Migris.Types.MigrationError (Migris.Types.ParseError file_err) in
  let msg = Migris.Types.show_error mig_err in
  Alcotest.(check bool) "contains filename"
    true (string_contains_substring msg "/migrations/bad.sql");
  Alcotest.(check bool) "mentions not found"
    true (string_contains_substring msg "not found")

let test_show_error_comprehensive () =
  let errors = [
    Migris.Types.FileError (Migris.Types.FileNotFound "test.sql");
    Migris.Types.FileError (Migris.Types.InvalidFormat "bad");
    Migris.Types.FileError (Migris.Types.ReadError ("test.sql", Failure "err"));
    Migris.Types.DatabaseError (Migris.Types.DatabaseNotFound "db");
    Migris.Types.DatabaseError (Migris.Types.ParseError "msg");
    Migris.Types.MigrationError (Migris.Types.MissingSection ("f.sql", "up"));
    Migris.Types.MigrationError (Migris.Types.EmptySection ("f.sql", "down"));
    Migris.Types.MigrationError (Migris.Types.VersionConflict 123L);
    Migris.Types.DiscoveryError "discovery failed";
  ] in

  List.iter (fun err ->
    let msg = Migris.Types.show_error err in
    Alcotest.(check bool) "error message is non-empty"
      true (String.length msg > 0)
  ) errors

let async_of_sync f () = f (); Lwt.return_unit

let suite = [
  "show_file_error", `Quick, async_of_sync test_show_file_error;
  "show_database_error", `Quick, async_of_sync test_show_database_error;
  "show_migration_error", `Quick, async_of_sync test_show_migration_error;
  "show_discovery_error", `Quick, async_of_sync test_show_discovery_error;
  "migration_error_with_file_error", `Quick, async_of_sync test_migration_error_with_file_error;
  "show_error_comprehensive", `Quick, async_of_sync test_show_error_comprehensive;
]
