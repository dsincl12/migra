(** Unit tests for the public [Migra.Database] URL helpers. These are pure (no
    connection), so they live in the fast unit suite. *)

let name_result = Alcotest.(result string string)

let database_name url =
  match Migra.Database.database_name url with
  | Ok name -> Ok name
  | Error err -> Error (Migra.Types.show_error err)

let test_database_name_server () =
  Alcotest.(check name_result)
    "postgresql path without leading slash" (Ok "mydb")
    (database_name "postgresql://user@localhost:5432/mydb");
  Alcotest.(check name_result)
    "postgres scheme" (Ok "mydb")
    (database_name "postgres://localhost/mydb");
  Alcotest.(check name_result)
    "mariadb path" (Ok "app")
    (database_name "mariadb://root@localhost:3306/app");
  Alcotest.(check name_result)
    "mysql path" (Ok "app")
    (database_name "mysql://root@localhost:3306/app")

(* Regression for the bug where sqlite3:path URLs (the README's documented form,
   and what sqlite3:// normalizes to) were rejected as "invalid path format". *)
let test_database_name_sqlite () =
  Alcotest.(check name_result)
    "sqlite3:relative path" (Ok "./dev.db")
    (database_name "sqlite3:./dev.db");
  Alcotest.(check name_result)
    "sqlite3:// normalizes to the same path" (Ok "./dev.db")
    (database_name "sqlite3://./dev.db");
  Alcotest.(check name_result)
    "sqlite3 absolute path" (Ok "/abs/dev.db")
    (database_name "sqlite3:/abs/dev.db");
  Alcotest.(check name_result)
    "sqlite3 in-memory" (Ok ":memory:")
    (database_name "sqlite3::memory:")

let test_database_name_unsupported () =
  match Migra.Database.database_name "oracle://localhost/test" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected an error for an unsupported scheme"

let test_redact_url () =
  Alcotest.(check string)
    "password is masked" "postgresql://user:*****@localhost:5432/db"
    (Migra.Database.redact_url "postgresql://user:secret@localhost:5432/db");
  Alcotest.(check string)
    "no password is left untouched" "postgresql://user@localhost:5432/db"
    (Migra.Database.redact_url "postgresql://user@localhost:5432/db");
  Alcotest.(check string)
    "sqlite path is left untouched" "sqlite3:./dev.db"
    (Migra.Database.redact_url "sqlite3:./dev.db")

(* Only a genuine missing-driver error should be rewritten into install
   instructions; a connection failure that merely says "not found" must not. *)
let test_is_missing_driver_error () =
  let check expected msg =
    Alcotest.(check bool)
      msg expected
      (Migra.Connection.is_missing_driver_error msg)
  in
  check true "Caqti failed to find a suitable driver for the URI";
  check true "no driver found for scheme mariadb: shared library not found";
  check false "FATAL: database \"app\" does not exist";
  check false "could not translate host name \"db\" to address: not found";
  check false "FATAL: role \"app\" not found"

let async_of_sync f () =
  f ();
  Lwt.return_unit

let suite =
  [
    ("database_name_server", `Quick, async_of_sync test_database_name_server);
    ("database_name_sqlite", `Quick, async_of_sync test_database_name_sqlite);
    ( "database_name_unsupported",
      `Quick,
      async_of_sync test_database_name_unsupported );
    ("redact_url", `Quick, async_of_sync test_redact_url);
    ( "is_missing_driver_error",
      `Quick,
      async_of_sync test_is_missing_driver_error );
  ]
