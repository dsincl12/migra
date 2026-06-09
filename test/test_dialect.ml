let test_detect_postgresql () =
  let result1 =
    Migra_engine.Dialect.detect_from_url "postgresql://localhost/test"
  in
  Alcotest.(
    check
      (result
         (of_pp (fun fmt t ->
              Format.fprintf fmt "%s" (Migra_engine.Dialect.to_string t)))
         string))
    "postgresql:// scheme" (Ok Migra_engine.Dialect.PostgreSQL) result1;

  let result2 =
    Migra_engine.Dialect.detect_from_url "postgres://localhost/test"
  in
  Alcotest.(
    check
      (result
         (of_pp (fun fmt t ->
              Format.fprintf fmt "%s" (Migra_engine.Dialect.to_string t)))
         string))
    "postgres:// scheme" (Ok Migra_engine.Dialect.PostgreSQL) result2

let test_detect_mariadb () =
  let result1 =
    Migra_engine.Dialect.detect_from_url "mariadb://localhost/test"
  in
  Alcotest.(
    check
      (result
         (of_pp (fun fmt t ->
              Format.fprintf fmt "%s" (Migra_engine.Dialect.to_string t)))
         string))
    "mariadb:// scheme" (Ok Migra_engine.Dialect.MariaDB) result1;

  let result2 = Migra_engine.Dialect.detect_from_url "mysql://localhost/test" in
  Alcotest.(
    check
      (result
         (of_pp (fun fmt t ->
              Format.fprintf fmt "%s" (Migra_engine.Dialect.to_string t)))
         string))
    "mysql:// scheme" (Ok Migra_engine.Dialect.MariaDB) result2

let test_detect_sqlite () =
  let result1 = Migra_engine.Dialect.detect_from_url "sqlite3://./test.db" in
  Alcotest.(
    check
      (result
         (of_pp (fun fmt t ->
              Format.fprintf fmt "%s" (Migra_engine.Dialect.to_string t)))
         string))
    "sqlite3:// with path" (Ok Migra_engine.Dialect.SQLite) result1;

  let result2 = Migra_engine.Dialect.detect_from_url "sqlite3://:memory:" in
  Alcotest.(
    check
      (result
         (of_pp (fun fmt t ->
              Format.fprintf fmt "%s" (Migra_engine.Dialect.to_string t)))
         string))
    "sqlite3:// with :memory:" (Ok Migra_engine.Dialect.SQLite) result2

let test_detect_unsupported () =
  let result1 =
    Migra_engine.Dialect.detect_from_url "oracle://localhost/test"
  in
  (match result1 with
  | Error msg ->
      Alcotest.(check bool)
        "error message mentions unsupported" true
        (String.length msg > 0 && String.sub msg 0 11 = "Unsupported")
  | Ok _ -> Alcotest.fail "Should have returned error for oracle://");

  let result2 =
    Migra_engine.Dialect.detect_from_url "mongodb://localhost/test"
  in
  (match result2 with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "Should have returned error for mongodb://");

  (* Regression: a colon too near the end used to overflow String.sub and
     raise Invalid_argument instead of returning a clean Error. *)
  List.iter
    (fun url ->
      match Migra_engine.Dialect.detect_from_url url with
      | Error _ -> ()
      | Ok _ ->
          Alcotest.fail (Printf.sprintf "Should have returned error for %S" url))
    [ "ht:"; "x:"; ":" ]

let test_to_string () =
  Alcotest.(check string)
    "PostgreSQL name" "PostgreSQL"
    (Migra_engine.Dialect.to_string Migra_engine.Dialect.PostgreSQL);
  Alcotest.(check string)
    "MariaDB name" "MariaDB"
    (Migra_engine.Dialect.to_string Migra_engine.Dialect.MariaDB);
  Alcotest.(check string)
    "SQLite name" "SQLite"
    (Migra_engine.Dialect.to_string Migra_engine.Dialect.SQLite)

let test_get_dialect () =
  let module PG =
    (val Migra_engine.Dialect.get_dialect Migra_engine.Dialect.PostgreSQL
        : Migra_engine.Dialect.DIALECT)
  in
  Alcotest.(check string) "PostgreSQL dialect name" "PostgreSQL" PG.name;
  Alcotest.(check (option int))
    "PostgreSQL default port" (Some 5432) PG.default_port;
  Alcotest.(check (option string))
    "PostgreSQL admin db" (Some "postgres") PG.admin_database;
  Alcotest.(check bool)
    "PostgreSQL supports lifecycle" true PG.supports_database_lifecycle;

  let module Maria =
    (val Migra_engine.Dialect.get_dialect Migra_engine.Dialect.MariaDB
        : Migra_engine.Dialect.DIALECT)
  in
  Alcotest.(check string) "MariaDB dialect name" "MariaDB" Maria.name;
  Alcotest.(check (option int))
    "MariaDB default port" (Some 3306) Maria.default_port;
  Alcotest.(check (option string))
    "MariaDB admin db" (Some "mysql") Maria.admin_database;
  Alcotest.(check bool)
    "MariaDB supports lifecycle" true Maria.supports_database_lifecycle;

  let module Lite =
    (val Migra_engine.Dialect.get_dialect Migra_engine.Dialect.SQLite
        : Migra_engine.Dialect.DIALECT)
  in
  Alcotest.(check string) "SQLite dialect name" "SQLite" Lite.name;
  Alcotest.(check (option int)) "SQLite default port" None Lite.default_port;
  Alcotest.(check (option string)) "SQLite admin db" None Lite.admin_database;
  Alcotest.(check bool)
    "SQLite supports lifecycle" false Lite.supports_database_lifecycle

let test_postgresql_dialect_sql () =
  let module D =
    (val Migra_engine.Dialect.get_dialect Migra_engine.Dialect.PostgreSQL
        : Migra_engine.Dialect.DIALECT)
  in
  Alcotest.(check bool)
    "database_exists_sql contains pg_database" true
    (String.length D.database_exists_sql > 0);

  let create_sql = D.create_database_sql "testdb" in
  Alcotest.(check bool)
    "create_database_sql contains CREATE DATABASE" true
    (String.length create_sql > 0);

  let drop_sql = D.drop_database_sql "testdb" in
  Alcotest.(check bool)
    "drop_database_sql contains DROP DATABASE" true
    (String.length drop_sql > 0);

  let timestamp_sql = D.timestamp_to_string "created_at" in
  Alcotest.(check string)
    "timestamp cast uses ::text" "created_at::text" timestamp_sql

(* Database names are interpolated into CREATE/DROP DATABASE (they cannot be
   bound as parameters), so the dialect must delimit them and escape any
   embedded delimiter. *)
let test_identifier_quoting () =
  let module PG =
    (val Migra_engine.Dialect.get_dialect Migra_engine.Dialect.PostgreSQL
        : Migra_engine.Dialect.DIALECT)
  in
  Alcotest.(check string)
    "PostgreSQL double-quotes a hyphenated name" "CREATE DATABASE \"my-db\""
    (PG.create_database_sql "my-db");
  Alcotest.(check string)
    "PostgreSQL drop double-quotes" "DROP DATABASE IF EXISTS \"my-db\""
    (PG.drop_database_sql "my-db");
  Alcotest.(check string)
    "PostgreSQL doubles an embedded double-quote" "CREATE DATABASE \"a\"\"b\""
    (PG.create_database_sql "a\"b");

  let module Maria =
    (val Migra_engine.Dialect.get_dialect Migra_engine.Dialect.MariaDB
        : Migra_engine.Dialect.DIALECT)
  in
  Alcotest.(check string)
    "MariaDB backtick-quotes a hyphenated name"
    "CREATE DATABASE IF NOT EXISTS `my-db`"
    (Maria.create_database_sql "my-db");
  Alcotest.(check string)
    "MariaDB drop backtick-quotes" "DROP DATABASE IF EXISTS `my-db`"
    (Maria.drop_database_sql "my-db");
  Alcotest.(check string)
    "MariaDB doubles an embedded backtick"
    "CREATE DATABASE IF NOT EXISTS `a``b`"
    (Maria.create_database_sql "a`b")

let test_sqlite_dialect_sql () =
  let module D =
    (val Migra_engine.Dialect.get_dialect Migra_engine.Dialect.SQLite
        : Migra_engine.Dialect.DIALECT)
  in
  let timestamp_sql = D.timestamp_to_string "created_at" in
  Alcotest.(check string)
    "timestamp doesn't need casting" "created_at" timestamp_sql

let async_of_sync f () =
  f ();
  Lwt.return_unit

let suite =
  [
    ("detect_postgresql", `Quick, async_of_sync test_detect_postgresql);
    ("detect_mariadb", `Quick, async_of_sync test_detect_mariadb);
    ("detect_sqlite", `Quick, async_of_sync test_detect_sqlite);
    ("detect_unsupported", `Quick, async_of_sync test_detect_unsupported);
    ("to_string", `Quick, async_of_sync test_to_string);
    ("get_dialect", `Quick, async_of_sync test_get_dialect);
    ("postgresql_dialect_sql", `Quick, async_of_sync test_postgresql_dialect_sql);
    ("identifier_quoting", `Quick, async_of_sync test_identifier_quoting);
    ("sqlite_dialect_sql", `Quick, async_of_sync test_sqlite_dialect_sql);
  ]
