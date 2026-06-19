open Test_helpers

let test_generate_version () =
  let version = Migra.Migration.generate_version () in
  let version_str = Int64.to_string version in

  Alcotest.(check int) "version is 14 digits" 14 (String.length version_str);

  Alcotest.(check bool)
    "version is numeric" true
    (String.for_all (fun c -> c >= '0' && c <= '9') version_str);

  let year_str = String.sub version_str 0 4 in
  let year = int_of_string year_str in
  Alcotest.(check bool) "year is reasonable (>= 2020)" true (year >= 2020);
  Alcotest.(check bool) "year is reasonable (< 2100)" true (year < 2100);

  (* The UTC decomposition must yield in-range calendar/clock fields. *)
  let field off = int_of_string (String.sub version_str off 2) in
  let month = field 4 and day = field 6 in
  let hour = field 8 and minute = field 10 and second = field 12 in
  Alcotest.(check bool) "month in 1..12" true (month >= 1 && month <= 12);
  Alcotest.(check bool) "day in 1..31" true (day >= 1 && day <= 31);
  Alcotest.(check bool) "hour in 0..23" true (hour >= 0 && hour <= 23);
  Alcotest.(check bool) "minute in 0..59" true (minute >= 0 && minute <= 59);
  Alcotest.(check bool) "second in 0..60" true (second >= 0 && second <= 60);

  (* The generated stamp round-trips through a filename. *)
  let filename = Migra.Migration.make_filename version "round_trip" in
  Alcotest.(check int64_testable)
    "version parses back from its filename" version
    (get_ok (Migra.Migration.parse_version filename))

let test_parse_version_valid () =
  let result =
    Migra.Migration.parse_version "20240115120000_create_users.sql"
  in
  Alcotest.(check bool) "parse valid filename" true (is_ok result);
  let version = get_ok result in
  Alcotest.(check int64_testable) "correct version" 20240115120000L version;

  let result2 =
    Migra.Migration.parse_version "/path/to/20240115120000_create_users.sql"
  in
  Alcotest.(check bool) "parse filename with path" true (is_ok result2);
  let version2 = get_ok result2 in
  Alcotest.(check int64_testable)
    "correct version from path" 20240115120000L version2

let test_parse_version_invalid () =
  let result1 = Migra.Migration.parse_version "2024_short.sql" in
  Alcotest.(check bool) "reject short version" true (is_error result1);

  let result2 =
    Migra.Migration.parse_version "20240115120000create_users.sql"
  in
  Alcotest.(check bool) "reject missing underscore" true (is_error result2);

  let result3 =
    Migra.Migration.parse_version "2024011512000X_create_users.sql"
  in
  Alcotest.(check bool) "reject non-numeric version" true (is_error result3);

  let result4 = Migra.Migration.parse_version "invalid_name" in
  Alcotest.(check bool) "reject invalid format" true (is_error result4);

  (* Strict: the version must be exactly 14 ASCII decimal digits. Int64.of_string
     would otherwise accept all of these. *)
  List.iter
    (fun f ->
      Alcotest.(check bool)
        (Printf.sprintf "reject %s" f)
        true
        (is_error (Migra.Migration.parse_version f)))
    [ "-2024011512000_x.sql"; "0x012345678901_x.sql"; "1234567890_234_x.sql" ]

let test_parse_description_valid () =
  let result =
    Migra.Migration.parse_description "20240115120000_create_users.sql"
  in
  Alcotest.(check bool) "parse valid description" true (is_ok result);
  let desc = get_ok result in
  Alcotest.(check string) "correct description" "create_users" desc;

  let result2 =
    Migra.Migration.parse_description "20240115120000_add_user_email_column.sql"
  in
  Alcotest.(check bool)
    "parse multi-underscore description" true (is_ok result2);
  let desc2 = get_ok result2 in
  Alcotest.(check string)
    "correct multi-word description" "add_user_email_column" desc2;

  let result3 =
    Migra.Migration.parse_description "/migrations/20240115120000_test.sql"
  in
  Alcotest.(check bool) "parse description from path" true (is_ok result3);
  let desc3 = get_ok result3 in
  Alcotest.(check string) "correct description from path" "test" desc3

let test_parse_description_invalid () =
  let result1 =
    Migra.Migration.parse_description "20240115120000_create_users.txt"
  in
  Alcotest.(check bool) "reject wrong extension" true (is_error result1);

  let result2 =
    Migra.Migration.parse_description "20240115120000_create_users"
  in
  Alcotest.(check bool) "reject no extension" true (is_error result2);

  let result3 = Migra.Migration.parse_description "invalid_name.sql" in
  Alcotest.(check bool) "reject invalid format" true (is_error result3)

let test_from_file_valid () =
  let result =
    Migra.Migration.from_file "/migrations/20240115120000_create_users.sql"
  in
  Alcotest.(check bool) "from_file succeeds" true (is_ok result);

  let migration = get_ok result in
  Alcotest.(check int64_testable)
    "correct version" 20240115120000L migration.Migra.Migration.version;
  Alcotest.(check string)
    "correct description" "create_users" migration.Migra.Migration.description;
  Alcotest.(check string)
    "correct file_path" "/migrations/20240115120000_create_users.sql"
    migration.Migra.Migration.file_path

let test_from_file_invalid () =
  let result = Migra.Migration.from_file "invalid_filename.sql" in
  Alcotest.(check bool) "from_file rejects invalid" true (is_error result)

let test_parse_section () =
  let content =
    {|-- +migrate up
CREATE TABLE users (id INT);

-- +migrate down
DROP TABLE users;|}
  in

  let up = Migra.Migration.parse_section content "up" in
  Alcotest.(check bool) "up section found" true (Option.is_some up);
  Alcotest.(check string)
    "correct up content" "CREATE TABLE users (id INT);" (Option.get up);

  let down = Migra.Migration.parse_section content "down" in
  Alcotest.(check bool) "down section found" true (Option.is_some down);
  Alcotest.(check string)
    "correct down content" "DROP TABLE users;" (Option.get down)

let test_parse_section_missing () =
  let content = {|-- +migrate up
CREATE TABLE users (id INT);|} in

  let down = Migra.Migration.parse_section content "down" in
  Alcotest.(check bool)
    "returns None for missing section" true (Option.is_none down)

let test_parse_section_with_comments () =
  let content =
    {|-- This is a comment
-- +migrate up
-- Create users table
CREATE TABLE users (
  id INT PRIMARY KEY,
  name TEXT
);

-- +migrate down
-- Drop users table
DROP TABLE users;|}
  in

  let up = Migra.Migration.parse_section content "up" in
  Alcotest.(check bool)
    "up section found with comments" true (Option.is_some up);

  let up_content = Option.get up in
  Alcotest.(check bool)
    "contains SQL comment" true
    (String.contains up_content '-');
  Alcotest.(check bool)
    "contains CREATE" true
    (Test_helpers.string_contains_substring up_content "CREATE")

let test_make_filename () =
  let filename = Migra.Migration.make_filename 20240115120000L "create_users" in
  Alcotest.(check string)
    "correct filename format" "20240115120000_create_users.sql" filename

let test_compare () =
  let m1 =
    {
      Migra.Migration.version = 20240115120000L;
      description = "first";
      file_path = "first.sql";
    }
  in
  let m2 =
    {
      Migra.Migration.version = 20240115130000L;
      description = "second";
      file_path = "second.sql";
    }
  in

  Alcotest.(check bool) "m1 < m2" true (Migra.Migration.compare m1 m2 < 0);
  Alcotest.(check bool) "m2 > m1" true (Migra.Migration.compare m2 m1 > 0);
  Alcotest.(check bool) "m1 = m1" true (Migra.Migration.compare m1 m1 = 0);

  let unsorted = [ m2; m1 ] in
  let sorted = List.sort Migra.Migration.compare unsorted in
  Alcotest.(check bool) "sorted list is correct" true (List.hd sorted = m1)

let test_to_string () =
  let migration =
    {
      Migra.Migration.version = 20240115120000L;
      description = "create_users";
      file_path = "migration.sql";
    }
  in
  let str = Migra.Migration.to_string migration in
  Alcotest.(check bool)
    "contains version" true
    (Test_helpers.string_contains_substring str "20240115120000");
  Alcotest.(check bool)
    "contains description" true
    (Test_helpers.string_contains_substring str "create_users")

let test_read_up_sql_with_file () =
  Lwt_main.run
    (with_temp_dir "migration_read_test" (fun dir ->
         let filepath =
           create_migration_with_sections dir 20240115120000L "create_users"
             "CREATE TABLE users (id INT PRIMARY KEY);" "DROP TABLE users;"
         in

         let migration =
           {
             Migra.Migration.version = 20240115120000L;
             description = "create_users";
             file_path = filepath;
           }
         in

         let result = Migra.Migration.read_up_sql migration in
         Alcotest.(check bool) "read_up_sql succeeds" true (is_ok result);

         let sql = get_ok result in
         Alcotest.(check bool)
           "contains CREATE" true
           (Test_helpers.string_contains_substring sql "CREATE TABLE users");

         Lwt.return_unit))

(* The combined reader returns the same up SQL as read_up_sql and the same
   checksum as checksum, both from a single file read. *)
let test_read_up_sql_with_checksum () =
  Lwt_main.run
    (with_temp_dir "migration_checksum_test" (fun dir ->
         let filepath =
           create_migration_with_sections dir 20240115120000L "create_users"
             "CREATE TABLE users (id INT PRIMARY KEY);" "DROP TABLE users;"
         in
         let migration =
           {
             Migra.Migration.version = 20240115120000L;
             description = "create_users";
             file_path = filepath;
           }
         in

         let combined = Migra.Migration.read_up_sql_with_checksum migration in
         Alcotest.(check bool)
           "read_up_sql_with_checksum succeeds" true (is_ok combined);
         let sql, checksum = get_ok combined in
         Alcotest.(check string)
           "same up SQL as read_up_sql"
           (get_ok (Migra.Migration.read_up_sql migration))
           sql;
         Alcotest.(check string)
           "same checksum as checksum"
           (get_ok (Migra.Migration.checksum migration))
           checksum;
         Lwt.return_unit))

let test_read_down_sql_with_file () =
  Lwt_main.run
    (with_temp_dir "migration_read_test" (fun dir ->
         let filepath =
           create_migration_with_sections dir 20240115120000L "create_users"
             "CREATE TABLE users (id INT PRIMARY KEY);" "DROP TABLE users;"
         in

         let migration =
           {
             Migra.Migration.version = 20240115120000L;
             description = "create_users";
             file_path = filepath;
           }
         in

         let result = Migra.Migration.read_down_sql migration in
         Alcotest.(check bool) "read_down_sql succeeds" true (is_ok result);

         let sql = get_ok result in
         Alcotest.(check bool)
           "contains DROP" true
           (Test_helpers.string_contains_substring sql "DROP TABLE users");

         Lwt.return_unit))

let test_read_sql_missing_section () =
  Lwt_main.run
    (with_temp_dir "migration_missing_test" (fun dir ->
         let filepath =
           create_migration_file dir 20240115120000L "incomplete"
             "-- +migrate up\nCREATE TABLE users (id INT);\n"
         in

         let migration =
           {
             Migra.Migration.version = 20240115120000L;
             description = "incomplete";
             file_path = filepath;
           }
         in

         let result = Migra.Migration.read_down_sql migration in
         Alcotest.(check bool)
           "read_down_sql fails on missing section" true (is_error result);

         let error_msg = get_error result in
         Alcotest.(check bool)
           "error mentions missing section" true
           (Test_helpers.string_contains_substring error_msg "missing");

         Lwt.return_unit))

let test_read_sql_empty_section () =
  Lwt_main.run
    (with_temp_dir "migration_empty_test" (fun dir ->
         let filepath =
           create_migration_file dir 20240115120000L "empty"
             "-- +migrate up\n\n-- +migrate down\nDROP TABLE users;\n"
         in

         let migration =
           {
             Migra.Migration.version = 20240115120000L;
             description = "empty";
             file_path = filepath;
           }
         in

         let result = Migra.Migration.read_up_sql migration in
         Alcotest.(check bool)
           "read_up_sql fails on empty section" true (is_error result);

         let error_msg = get_error result in
         Alcotest.(check bool)
           "error mentions empty section" true
           (Test_helpers.string_contains_substring error_msg "empty");

         Lwt.return_unit))

let test_parse_section_exact_marker () =
  Alcotest.(check bool)
    "up does not match upgrade" true
    (Migra.Migration.parse_section "-- +migrate upgrade\nSELECT 1;\n" "up"
    = None);
  match
    Migra.Migration.parse_section
      "-- +migrate up\nSELECT 2;\n-- +migrate down\nSELECT 3;\n" "up"
  with
  | Some s ->
      Alcotest.(check bool) "exact up section found" true (String.length s > 0)
  | None -> Alcotest.fail "expected the up section to be found"

let test_checksum () =
  Lwt_main.run
    (with_temp_dir "checksum" (fun dir ->
         let f =
           create_migration_with_sections dir 20240115120000L "t"
             "CREATE TABLE c (id int);" "DROP TABLE c;"
         in
         let m =
           match Migra.Migration.from_file f with
           | Ok m -> m
           | Error _ -> Alcotest.fail "from_file failed"
         in
         let cs1 =
           match Migra.Migration.checksum m with
           | Ok c -> c
           | Error _ -> Alcotest.fail "checksum failed"
         in
         let cs2 =
           match Migra.Migration.checksum m with
           | Ok c -> c
           | Error _ -> Alcotest.fail "checksum failed"
         in
         Alcotest.(check string) "deterministic" cs1 cs2;
         let oc = open_out f in
         output_string oc
           "-- +migrate up\n\
            CREATE TABLE c (id int, x int);\n\
            -- +migrate down\n\
            DROP TABLE c;\n";
         close_out oc;
         let cs3 =
           match Migra.Migration.checksum m with
           | Ok c -> c
           | Error _ -> Alcotest.fail "checksum failed"
         in
         Alcotest.(check bool) "changes on edit" true (cs1 <> cs3);
         Lwt.return_unit))

let test_validate_table_name () =
  let ok n = Result.is_ok (Migra.Runner.validate_table_name n) in
  Alcotest.(check bool) "plain" true (ok "schema_migrations");
  Alcotest.(check bool) "schema-qualified" true (ok "public.schema_migrations");
  Alcotest.(check bool) "underscore start" true (ok "_t");
  Alcotest.(check bool) "reject empty" false (ok "");
  Alcotest.(check bool) "reject space" false (ok "my table");
  Alcotest.(check bool) "reject injection" false (ok "t; DROP TABLE x");
  Alcotest.(check bool) "reject leading digit" false (ok "1t")

let test_validate_name () =
  let ok n = Result.is_ok (Migra.Migration.validate_name n) in
  Alcotest.(check bool) "plain snake_case" true (ok "create_users");
  Alcotest.(check bool) "digits" true (ok "2fa_support");
  Alcotest.(check bool) "uppercase" true (ok "CreateUsers");
  Alcotest.(check bool) "reject empty" false (ok "");
  Alcotest.(check bool) "reject space" false (ok "create users");
  Alcotest.(check bool) "reject slash" false (ok "../evil");
  Alcotest.(check bool) "reject dot" false (ok "a.b");
  Alcotest.(check bool) "reject hyphen" false (ok "create-users")

let test_generate_creates_discoverable () =
  Lwt_main.run
    (with_temp_dir "gen" (fun dir ->
         (match Migra.Migrator.generate ~migrations_dir:dir "create_users" with
         | Error e -> Alcotest.fail (Migra.Types.show_error e)
         | Ok path ->
             Alcotest.(check bool) "file created" true (Sys.file_exists path));
         (* the directory must stay discoverable after generating *)
         (match Migra.Discovery.find_migrations ~dir () with
         | Error e -> Alcotest.fail (Migra.Types.show_error e)
         | Ok ms ->
             Alcotest.(check int) "one migration discovered" 1 (List.length ms);
             Alcotest.(check string)
               "description round-trips" "create_users"
               (List.hd ms).Migra.Migration.description);
         Lwt.return_unit))

let test_generate_rejects_invalid_name () =
  Lwt_main.run
    (with_temp_dir "gen" (fun dir ->
         (match Migra.Migrator.generate ~migrations_dir:dir "" with
         | Ok _ -> Alcotest.fail "empty name should be rejected"
         | Error _ -> ());
         (* a rejected name must not leave a file that poisons discovery *)
         (match Migra.Discovery.find_migrations ~dir () with
         | Error e -> Alcotest.fail (Migra.Types.show_error e)
         | Ok ms -> Alcotest.(check int) "no file created" 0 (List.length ms));
         Lwt.return_unit))

let test_generate_rejects_duplicate_name () =
  Lwt_main.run
    (with_temp_dir "gen" (fun dir ->
         (match Migra.Migrator.generate ~migrations_dir:dir "create_users" with
         | Error e -> Alcotest.fail (Migra.Types.show_error e)
         | Ok _ -> ());
         (match Migra.Migrator.generate ~migrations_dir:dir "create_users" with
         | Ok _ -> Alcotest.fail "duplicate name should be rejected"
         | Error _ -> ());
         Lwt.return_unit))

let test_generate_rejects_version_collision () =
  Lwt_main.run
    (with_temp_dir "gen" (fun dir ->
         (* Pre-seed a migration at the version generate will compute this
            second. Generate must refuse to add a second file sharing that
            version rather than poison discovery; if the clock ticks over first
            it uses the next second - either way the seeded version is never
            used by two files. *)
         let version = Migra.Migration.generate_version () in
         let _ =
           create_migration_with_sections dir version "seeded"
             "CREATE TABLE a (id INT);" "DROP TABLE a;"
         in
         ignore (Migra.Migrator.generate ~migrations_dir:dir "fresh");
         (match Migra.Discovery.find_migrations ~dir () with
         | Error e -> Alcotest.fail (Migra.Types.show_error e)
         | Ok ms ->
             let sharing =
               List.filter
                 (fun (m : Migra.Migration.t) -> Int64.equal m.version version)
                 ms
             in
             Alcotest.(check int)
               "seeded version used by exactly one file" 1 (List.length sharing));
         Lwt.return_unit))

let async_of_sync f () =
  f ();
  Lwt.return_unit

let suite =
  [
    ("checksum", `Quick, async_of_sync test_checksum);
    ("validate_table_name", `Quick, async_of_sync test_validate_table_name);
    ("validate_name", `Quick, async_of_sync test_validate_name);
    ( "generate_creates_discoverable",
      `Quick,
      async_of_sync test_generate_creates_discoverable );
    ( "generate_rejects_invalid_name",
      `Quick,
      async_of_sync test_generate_rejects_invalid_name );
    ( "generate_rejects_duplicate_name",
      `Quick,
      async_of_sync test_generate_rejects_duplicate_name );
    ( "generate_rejects_version_collision",
      `Quick,
      async_of_sync test_generate_rejects_version_collision );
    ( "parse_section_exact_marker",
      `Quick,
      async_of_sync test_parse_section_exact_marker );
    ("generate_version", `Quick, async_of_sync test_generate_version);
    ("parse_version_valid", `Quick, async_of_sync test_parse_version_valid);
    ("parse_version_invalid", `Quick, async_of_sync test_parse_version_invalid);
    ( "parse_description_valid",
      `Quick,
      async_of_sync test_parse_description_valid );
    ( "parse_description_invalid",
      `Quick,
      async_of_sync test_parse_description_invalid );
    ("from_file_valid", `Quick, async_of_sync test_from_file_valid);
    ("from_file_invalid", `Quick, async_of_sync test_from_file_invalid);
    ("parse_section", `Quick, async_of_sync test_parse_section);
    ("parse_section_missing", `Quick, async_of_sync test_parse_section_missing);
    ( "parse_section_with_comments",
      `Quick,
      async_of_sync test_parse_section_with_comments );
    ("make_filename", `Quick, async_of_sync test_make_filename);
    ("compare", `Quick, async_of_sync test_compare);
    ("to_string", `Quick, async_of_sync test_to_string);
    ("read_up_sql_with_file", `Quick, async_of_sync test_read_up_sql_with_file);
    ( "read_up_sql_with_checksum",
      `Quick,
      async_of_sync test_read_up_sql_with_checksum );
    ( "read_down_sql_with_file",
      `Quick,
      async_of_sync test_read_down_sql_with_file );
    ( "read_sql_missing_section",
      `Quick,
      async_of_sync test_read_sql_missing_section );
    ("read_sql_empty_section", `Quick, async_of_sync test_read_sql_empty_section);
  ]
