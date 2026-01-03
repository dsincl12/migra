
open Test_helpers

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

let test_generate_version () =
  let version = Migris.Migration.generate_version () in
  let version_str = Int64.to_string version in

  Alcotest.(check int) "version is 14 digits"
    14 (String.length version_str);

  Alcotest.(check bool) "version is numeric"
    true (String.for_all (fun c -> c >= '0' && c <= '9') version_str);

  let year_str = String.sub version_str 0 4 in
  let year = int_of_string year_str in
  Alcotest.(check bool) "year is reasonable (>= 2020)"
    true (year >= 2020);
  Alcotest.(check bool) "year is reasonable (< 2100)"
    true (year < 2100)

let test_parse_version_valid () =
  let result = Migris.Migration.parse_version "20240115120000_create_users.sql" in
  Alcotest.(check bool) "parse valid filename" true (is_ok result);
  let version = get_ok result in
  Alcotest.(check int64_testable) "correct version"
    20240115120000L version;

  let result2 = Migris.Migration.parse_version "/path/to/20240115120000_create_users.sql" in
  Alcotest.(check bool) "parse filename with path" true (is_ok result2);
  let version2 = get_ok result2 in
  Alcotest.(check int64_testable) "correct version from path"
    20240115120000L version2

let test_parse_version_invalid () =
  let result1 = Migris.Migration.parse_version "2024_short.sql" in
  Alcotest.(check bool) "reject short version" true (is_error result1);

  let result2 = Migris.Migration.parse_version "20240115120000create_users.sql" in
  Alcotest.(check bool) "reject missing underscore" true (is_error result2);

  let result3 = Migris.Migration.parse_version "2024011512000X_create_users.sql" in
  Alcotest.(check bool) "reject non-numeric version" true (is_error result3);

  let result4 = Migris.Migration.parse_version "invalid_name" in
  Alcotest.(check bool) "reject invalid format" true (is_error result4)

let test_parse_description_valid () =
  let result = Migris.Migration.parse_description "20240115120000_create_users.sql" in
  Alcotest.(check bool) "parse valid description" true (is_ok result);
  let desc = get_ok result in
  Alcotest.(check string) "correct description"
    "create_users" desc;

  let result2 = Migris.Migration.parse_description "20240115120000_add_user_email_column.sql" in
  Alcotest.(check bool) "parse multi-underscore description" true (is_ok result2);
  let desc2 = get_ok result2 in
  Alcotest.(check string) "correct multi-word description"
    "add_user_email_column" desc2;

  let result3 = Migris.Migration.parse_description "/migrations/20240115120000_test.sql" in
  Alcotest.(check bool) "parse description from path" true (is_ok result3);
  let desc3 = get_ok result3 in
  Alcotest.(check string) "correct description from path"
    "test" desc3

let test_parse_description_invalid () =
  let result1 = Migris.Migration.parse_description "20240115120000_create_users.txt" in
  Alcotest.(check bool) "reject wrong extension" true (is_error result1);

  let result2 = Migris.Migration.parse_description "20240115120000_create_users" in
  Alcotest.(check bool) "reject no extension" true (is_error result2);

  let result3 = Migris.Migration.parse_description "invalid_name.sql" in
  Alcotest.(check bool) "reject invalid format" true (is_error result3)

let test_from_file_valid () =
  let result = Migris.Migration.from_file "/migrations/20240115120000_create_users.sql" in
  Alcotest.(check bool) "from_file succeeds" true (is_ok result);

  let migration = get_ok result in
  Alcotest.(check int64_testable) "correct version"
    20240115120000L migration.Migris.Migration.version;
  Alcotest.(check string) "correct description"
    "create_users" migration.Migris.Migration.description;
  Alcotest.(check string) "correct file_path"
    "/migrations/20240115120000_create_users.sql" migration.Migris.Migration.file_path

let test_from_file_invalid () =
  let result = Migris.Migration.from_file "invalid_filename.sql" in
  Alcotest.(check bool) "from_file rejects invalid" true (is_error result)

let test_parse_section () =
  let content = {|-- +migrate up
CREATE TABLE users (id INT);

-- +migrate down
DROP TABLE users;|} in

  let up = Migris.Migration.parse_section content "up" in
  Alcotest.(check bool) "up section found" true (Option.is_some up);
  Alcotest.(check string) "correct up content"
    "CREATE TABLE users (id INT);" (Option.get up);

  let down = Migris.Migration.parse_section content "down" in
  Alcotest.(check bool) "down section found" true (Option.is_some down);
  Alcotest.(check string) "correct down content"
    "DROP TABLE users;" (Option.get down)

let test_parse_section_missing () =
  let content = {|-- +migrate up
CREATE TABLE users (id INT);|} in

  let down = Migris.Migration.parse_section content "down" in
  Alcotest.(check bool) "returns None for missing section"
    true (Option.is_none down)

let test_parse_section_with_comments () =
  let content = {|-- This is a comment
-- +migrate up
-- Create users table
CREATE TABLE users (
  id INT PRIMARY KEY,
  name TEXT
);

-- +migrate down
-- Drop users table
DROP TABLE users;|} in

  let up = Migris.Migration.parse_section content "up" in
  Alcotest.(check bool) "up section found with comments" true (Option.is_some up);

  let up_content = Option.get up in
  Alcotest.(check bool) "contains SQL comment"
    true (String.contains up_content '-');
  Alcotest.(check bool) "contains CREATE"
    true (string_contains_substring up_content "CREATE")

let test_make_filename () =
  let filename = Migris.Migration.make_filename 20240115120000L "create_users" in
  Alcotest.(check string) "correct filename format"
    "20240115120000_create_users.sql" filename

let test_compare () =
  let m1 = { Migris.Migration.version = 20240115120000L;
             description = "first";
             file_path = "first.sql" } in
  let m2 = { Migris.Migration.version = 20240115130000L;
             description = "second";
             file_path = "second.sql" } in

  Alcotest.(check bool) "m1 < m2"
    true (Migris.Migration.compare m1 m2 < 0);
  Alcotest.(check bool) "m2 > m1"
    true (Migris.Migration.compare m2 m1 > 0);
  Alcotest.(check bool) "m1 = m1"
    true (Migris.Migration.compare m1 m1 = 0);

  let unsorted = [m2; m1] in
  let sorted = List.sort Migris.Migration.compare unsorted in
  Alcotest.(check bool) "sorted list is correct"
    true (List.hd sorted = m1)

let test_to_string () =
  let migration = { Migris.Migration.version = 20240115120000L;
                    description = "create_users";
                    file_path = "migration.sql" } in
  let str = Migris.Migration.to_string migration in
  Alcotest.(check bool) "contains version"
    true (string_contains_substring str "20240115120000");
  Alcotest.(check bool) "contains description"
    true (string_contains_substring str "create_users")

let test_read_up_sql_with_file () =
  Lwt_main.run (
    with_temp_dir "migration_read_test" (fun dir ->
      let filepath = create_migration_with_sections dir
        20240115120000L
        "create_users"
        "CREATE TABLE users (id INT PRIMARY KEY);"
        "DROP TABLE users;" in

      let migration = { Migris.Migration.version = 20240115120000L;
                        description = "create_users";
                        file_path = filepath } in

      let result = Migris.Migration.read_up_sql migration in
      Alcotest.(check bool) "read_up_sql succeeds" true (is_ok result);

      let sql = get_ok result in
      Alcotest.(check bool) "contains CREATE"
        true (string_contains_substring sql "CREATE TABLE users");

      Lwt.return_unit
    )
  )

let test_read_down_sql_with_file () =
  Lwt_main.run (
    with_temp_dir "migration_read_test" (fun dir ->
      let filepath = create_migration_with_sections dir
        20240115120000L
        "create_users"
        "CREATE TABLE users (id INT PRIMARY KEY);"
        "DROP TABLE users;" in

      let migration = { Migris.Migration.version = 20240115120000L;
                        description = "create_users";
                        file_path = filepath } in

      let result = Migris.Migration.read_down_sql migration in
      Alcotest.(check bool) "read_down_sql succeeds" true (is_ok result);

      let sql = get_ok result in
      Alcotest.(check bool) "contains DROP"
        true (string_contains_substring sql "DROP TABLE users");

      Lwt.return_unit
    )
  )

let test_read_sql_missing_section () =
  Lwt_main.run (
    with_temp_dir "migration_missing_test" (fun dir ->
      let filepath = create_migration_file dir
        20240115120000L
        "incomplete"
        "-- +migrate up\nCREATE TABLE users (id INT);\n" in

      let migration = { Migris.Migration.version = 20240115120000L;
                        description = "incomplete";
                        file_path = filepath } in

      let result = Migris.Migration.read_down_sql migration in
      Alcotest.(check bool) "read_down_sql fails on missing section"
        true (is_error result);

      let error_msg = get_error result in
      Alcotest.(check bool) "error mentions missing section"
        true (string_contains_substring error_msg "missing");

      Lwt.return_unit
    )
  )

let test_read_sql_empty_section () =
  Lwt_main.run (
    with_temp_dir "migration_empty_test" (fun dir ->
      let filepath = create_migration_file dir
        20240115120000L
        "empty"
        "-- +migrate up\n\n-- +migrate down\nDROP TABLE users;\n" in

      let migration = { Migris.Migration.version = 20240115120000L;
                        description = "empty";
                        file_path = filepath } in

      let result = Migris.Migration.read_up_sql migration in
      Alcotest.(check bool) "read_up_sql fails on empty section"
        true (is_error result);

      let error_msg = get_error result in
      Alcotest.(check bool) "error mentions empty section"
        true (string_contains_substring error_msg "empty");

      Lwt.return_unit
    )
  )

let async_of_sync f () = f (); Lwt.return_unit

let suite = [
  "generate_version", `Quick, async_of_sync test_generate_version;
  "parse_version_valid", `Quick, async_of_sync test_parse_version_valid;
  "parse_version_invalid", `Quick, async_of_sync test_parse_version_invalid;
  "parse_description_valid", `Quick, async_of_sync test_parse_description_valid;
  "parse_description_invalid", `Quick, async_of_sync test_parse_description_invalid;
  "from_file_valid", `Quick, async_of_sync test_from_file_valid;
  "from_file_invalid", `Quick, async_of_sync test_from_file_invalid;
  "parse_section", `Quick, async_of_sync test_parse_section;
  "parse_section_missing", `Quick, async_of_sync test_parse_section_missing;
  "parse_section_with_comments", `Quick, async_of_sync test_parse_section_with_comments;
  "make_filename", `Quick, async_of_sync test_make_filename;
  "compare", `Quick, async_of_sync test_compare;
  "to_string", `Quick, async_of_sync test_to_string;
  "read_up_sql_with_file", `Quick, async_of_sync test_read_up_sql_with_file;
  "read_down_sql_with_file", `Quick, async_of_sync test_read_down_sql_with_file;
  "read_sql_missing_section", `Quick, async_of_sync test_read_sql_missing_section;
  "read_sql_empty_section", `Quick, async_of_sync test_read_sql_empty_section;
]
