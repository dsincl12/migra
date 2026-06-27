open Lwt.Infix
open Test_helpers

let get_mariadb_admin_url () =
  match Sys.getenv_opt "MARIADB_URL" with
  | Some url -> url
  | None ->
      let user = Sys.getenv "USER" in
      Printf.sprintf "mariadb://%s@localhost:3306/mysql" user

let get_mariadb_test_url db_name =
  match Sys.getenv_opt "MARIADB_URL" with
  | Some url ->
      let uri = Uri.of_string url in
      let userinfo = Uri.userinfo uri in
      let host = Uri.host uri |> Option.value ~default:"localhost" in
      let port = Uri.port uri |> Option.value ~default:3306 in
      let auth = match userinfo with None -> "" | Some info -> info ^ "@" in
      Printf.sprintf "mariadb://%s%s:%d/%s" auth host port db_name
  | None ->
      let user = Sys.getenv "USER" in
      Printf.sprintf "mariadb://%s@localhost:3306/%s" user db_name

let mariadb_test_db_name prefix =
  let timestamp = Unix.time () |> int_of_float in
  let random = Random.int 10000 in
  Printf.sprintf "migra_test_%s_%d_%d" prefix timestamp random

let create_mariadb_test_db prefix =
  let db_name = mariadb_test_db_name prefix in
  let admin_url = get_mariadb_admin_url () in

  Migra.Connection.connect_db admin_url >>= function
  | Error err ->
      Lwt.return_error
        (Printf.sprintf "Failed to connect to MariaDB admin: %s"
           (Migra.Types.show_error err))
  | Ok db -> (
      let module Db = (val db : Caqti_lwt.CONNECTION) in
      let open Caqti_request.Infix in
      let open Caqti_type.Std in
      let query =
        (unit ->. unit) ~oneshot:true
          (Printf.sprintf "CREATE DATABASE IF NOT EXISTS `%s`" db_name)
      in

      Db.exec query () >>= function
      | Error err ->
          Lwt.return_error
            (Printf.sprintf "Failed to create test DB: %s"
               (Caqti_error.show err))
      | Ok () ->
          let test_url = get_mariadb_test_url db_name in
          Lwt.return_ok (db_name, test_url))

let drop_mariadb_test_db db_name =
  let admin_url = get_mariadb_admin_url () in

  Migra.Connection.connect_db admin_url >>= function
  | Error err ->
      Lwt.return_error
        (Printf.sprintf "Failed to connect to MariaDB admin: %s"
           (Migra.Types.show_error err))
  | Ok db -> (
      let module Db = (val db : Caqti_lwt.CONNECTION) in
      let open Caqti_request.Infix in
      let open Caqti_type.Std in
      let query =
        (unit ->. unit) ~oneshot:true
          (Printf.sprintf "DROP DATABASE IF EXISTS `%s`" db_name)
      in

      Db.exec query () >>= function
      | Error err ->
          Lwt.return_error
            (Printf.sprintf "Failed to drop test DB: %s" (Caqti_error.show err))
      | Ok () -> Lwt.return_ok ())

let with_mariadb_test_db prefix f =
  create_mariadb_test_db prefix >>= function
  | Error msg -> Lwt.fail_with msg
  | Ok (db_name, db_url) ->
      Lwt.finalize
        (fun () -> f db_url)
        (fun () ->
          drop_mariadb_test_db db_name >>= function
          | Error _msg -> Lwt.return_unit
          | Ok () -> Lwt.return_unit)

let with_db db_url f =
  Migra.Connection.connect_db db_url >>= function
  | Error err ->
      Lwt.fail_with
        (Printf.sprintf "Failed to connect: %s" (Migra.Types.show_error err))
  | Ok db -> f db

let test_mariadb_create_database () =
  let db_name = mariadb_test_db_name "create_test" in
  let db_url = get_mariadb_test_url db_name in

  Lwt.finalize
    (fun () ->
      Migra.Database.create_database db_url >>= function
      | Error err ->
          Alcotest.fail
            (Printf.sprintf "create_database failed: %s"
               (Migra.Types.show_error err))
      | Ok () -> with_db db_url (fun _db -> Lwt.return_unit))
    (fun () -> drop_mariadb_test_db db_name >>= fun _ -> Lwt.return_unit)

let test_mariadb_create_database_idempotent () =
  let db_name = mariadb_test_db_name "create_idem" in
  let db_url = get_mariadb_test_url db_name in

  Lwt.finalize
    (fun () ->
      Migra.Database.create_database db_url >>= function
      | Error err ->
          Alcotest.fail
            (Printf.sprintf "First create_database failed: %s"
               (Migra.Types.show_error err))
      | Ok () -> (
          Migra.Database.create_database db_url >>= function
          | Error err ->
              Alcotest.fail
                (Printf.sprintf "Second create_database failed: %s"
                   (Migra.Types.show_error err))
          | Ok () -> Lwt.return_unit))
    (fun () -> drop_mariadb_test_db db_name >>= fun _ -> Lwt.return_unit)

let test_mariadb_drop_database () =
  let db_name = mariadb_test_db_name "drop_test" in
  let db_url = get_mariadb_test_url db_name in

  Lwt.finalize
    (fun () ->
      Migra.Database.create_database db_url >>= function
      | Error err ->
          Alcotest.fail
            (Printf.sprintf "create_database failed: %s"
               (Migra.Types.show_error err))
      | Ok () -> (
          Migra.Database.drop_database db_url >>= function
          | Error err ->
              Alcotest.fail
                (Printf.sprintf "drop_database failed: %s"
                   (Migra.Types.show_error err))
          | Ok () -> (
              Migra.Connection.connect_db db_url >>= function
              | Ok _db -> Alcotest.fail "Database still exists after drop"
              | Error _ -> Lwt.return_unit)))
    (fun () -> drop_mariadb_test_db db_name >>= fun _ -> Lwt.return_unit)

let test_mariadb_drop_database_idempotent () =
  let db_name = mariadb_test_db_name "drop_idem" in
  let db_url = get_mariadb_test_url db_name in

  Lwt.finalize
    (fun () ->
      Migra.Database.drop_database db_url >>= function
      | Error err ->
          Alcotest.fail
            (Printf.sprintf "drop_database on non-existent DB failed: %s"
               (Migra.Types.show_error err))
      | Ok () -> Lwt.return_unit)
    (fun () -> Lwt.return_unit)

let test_mariadb_schema_innodb () =
  with_mariadb_test_db "schema_innodb" (fun db_url ->
      with_db db_url (fun db ->
          Migra.Runner.ensure_migrations_table Migra.Dialect.MariaDB db
          >>= function
          | Error err ->
              Alcotest.fail
                (Printf.sprintf "ensure_migrations_table failed: %s"
                   (Caqti_error.show err))
          | Ok () -> (
              let (* Verify table exists and uses InnoDB *)
                module
                Db =
                (val db : Caqti_lwt.CONNECTION)
              in
              let open Caqti_request.Infix in
              let open Caqti_type.Std in
              let query =
                (unit ->! string)
                  {sql|
            SELECT ENGINE FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = DATABASE()
            AND TABLE_NAME = 'schema_migrations'
          |sql}
              in

              Db.find query () >>= function
              | Error err ->
                  Alcotest.fail
                    (Printf.sprintf "Failed to check engine: %s"
                       (Caqti_error.show err))
              | Ok engine ->
                  Alcotest.(check string) "Uses InnoDB engine" "InnoDB" engine;
                  Lwt.return_unit)))

let test_mariadb_schema_idempotent () =
  with_mariadb_test_db "schema_idem" (fun db_url ->
      with_db db_url (fun db ->
          Migra.Runner.ensure_migrations_table Migra.Dialect.MariaDB db
          >>= function
          | Error err ->
              Alcotest.fail
                (Printf.sprintf "First ensure_migrations_table failed: %s"
                   (Caqti_error.show err))
          | Ok () -> (
              Migra.Runner.ensure_migrations_table Migra.Dialect.MariaDB db
              >>= function
              | Error err ->
                  Alcotest.fail
                    (Printf.sprintf "Second ensure_migrations_table failed: %s"
                       (Caqti_error.show err))
              | Ok () -> Lwt.return_unit)))

let test_mariadb_migration_operations () =
  with_mariadb_test_db "migration_ops" (fun db_url ->
      with_db db_url (fun db ->
          Migra.Runner.ensure_migrations_table Migra.Dialect.MariaDB db
          >>= function
          | Error err ->
              Alcotest.fail
                (Printf.sprintf "ensure_migrations_table failed: %s"
                   (Caqti_error.show err))
          | Ok () -> (
              let version = 20240115120000L in

              Migra.Runner.is_applied db version >>= function
              | Error err ->
                  Alcotest.fail
                    (Printf.sprintf "is_applied failed: %s"
                       (Caqti_error.show err))
              | Ok applied -> (
                  Alcotest.(check bool)
                    "Version not applied initially" false applied;

                  Migra.Runner.add_migration db version "test-checksum"
                  >>= function
                  | Error err ->
                      Alcotest.fail
                        (Printf.sprintf "add_migration failed: %s"
                           (Caqti_error.show err))
                  | Ok () -> (
                      Migra.Runner.is_applied db version >>= function
                      | Error err ->
                          Alcotest.fail
                            (Printf.sprintf "is_applied after add failed: %s"
                               (Caqti_error.show err))
                      | Ok applied -> (
                          Alcotest.(check bool)
                            "Version applied after add" true applied;

                          Migra.Runner.remove_migration db version >>= function
                          | Error err ->
                              Alcotest.fail
                                (Printf.sprintf "remove_migration failed: %s"
                                   (Caqti_error.show err))
                          | Ok () -> (
                              Migra.Runner.is_applied db version >>= function
                              | Error err ->
                                  Alcotest.fail
                                    (Printf.sprintf
                                       "is_applied after remove failed: %s"
                                       (Caqti_error.show err))
                              | Ok applied ->
                                  Alcotest.(check bool)
                                    "Version not applied after remove" false
                                    applied;
                                  Lwt.return_unit)))))))

let test_mariadb_get_records () =
  with_mariadb_test_db "get_records" (fun db_url ->
      with_db db_url (fun db ->
          Migra.Runner.ensure_migrations_table Migra.Dialect.MariaDB db
          >>= function
          | Error err ->
              Alcotest.fail
                (Printf.sprintf "ensure_migrations_table failed: %s"
                   (Caqti_error.show err))
          | Ok () -> (
              let version = 20240115120000L in

              Migra.Runner.add_migration db version "test-checksum" >>= function
              | Error err ->
                  Alcotest.fail
                    (Printf.sprintf "add_migration failed: %s"
                       (Caqti_error.show err))
              | Ok () -> (
                  Migra.Runner.get_applied_records Migra.Dialect.MariaDB db
                  >>= function
                  | Error err ->
                      Alcotest.fail
                        (Printf.sprintf "get_applied_records failed: %s"
                           (Caqti_error.show err))
                  | Ok records ->
                      Alcotest.(check int) "One record" 1 (List.length records);
                      let record = List.hd records in
                      Alcotest.(check int64_testable)
                        "Record version" version record.Migra.Runner.version;
                      Alcotest.(check bool)
                        "created_at exists" true
                        (String.length record.Migra.Runner.created_at > 0);
                      Lwt.return_unit))))

let test_mariadb_latest_version () =
  with_mariadb_test_db "latest_version" (fun db_url ->
      with_db db_url (fun db ->
          Migra.Runner.ensure_migrations_table Migra.Dialect.MariaDB db
          >>= function
          | Error err ->
              Alcotest.fail
                (Printf.sprintf "ensure_migrations_table failed: %s"
                   (Caqti_error.show err))
          | Ok () -> (
              Migra.Runner.get_latest_version db >>= function
              | Error err ->
                  Alcotest.fail
                    (Printf.sprintf "get_latest_version failed: %s"
                       (Caqti_error.show err))
              | Ok latest -> (
                  Alcotest.(check (option int64_testable))
                    "No latest version initially" None latest;

                  let v1 = 20240114100000L in
                  let v2 = 20240115120000L in
                  let v3 = 20240116150000L in

                  Migra.Runner.add_migration db v2 "test-checksum" >>= fun _ ->
                  Migra.Runner.add_migration db v1 "test-checksum" >>= fun _ ->
                  Migra.Runner.add_migration db v3 "test-checksum" >>= fun _ ->
                  Migra.Runner.get_latest_version db >>= function
                  | Error err ->
                      Alcotest.fail
                        (Printf.sprintf "get_latest_version failed: %s"
                           (Caqti_error.show err))
                  | Ok latest ->
                      Alcotest.(check (option int64_testable))
                        "Latest is highest" (Some v3) latest;
                      Lwt.return_unit))))

let test_mariadb_get_applied_versions_sorted () =
  with_mariadb_test_db "versions_sorted" (fun db_url ->
      with_db db_url (fun db ->
          Migra.Runner.ensure_migrations_table Migra.Dialect.MariaDB db
          >>= function
          | Error err ->
              Alcotest.fail
                (Printf.sprintf "ensure_migrations_table failed: %s"
                   (Caqti_error.show err))
          | Ok () -> (
              let v1 = 20240115120000L in
              let v2 = 20240114100000L in
              let v3 = 20240116150000L in

              Migra.Runner.add_migration db v2 "test-checksum" >>= fun _ ->
              Migra.Runner.add_migration db v3 "test-checksum" >>= fun _ ->
              Migra.Runner.add_migration db v1 "test-checksum" >>= fun _ ->
              Migra.Runner.get_applied_versions db >>= function
              | Error err ->
                  Alcotest.fail
                    (Printf.sprintf "get_applied_versions failed: %s"
                       (Caqti_error.show err))
              | Ok versions ->
                  Alcotest.(check int) "Three versions" 3 (List.length versions);
                  Alcotest.(check int64_testable)
                    "First version" v2 (List.nth versions 0);
                  Alcotest.(check int64_testable)
                    "Second version" v1 (List.nth versions 1);
                  Alcotest.(check int64_testable)
                    "Third version" v3 (List.nth versions 2);
                  Lwt.return_unit)))

let test_mariadb_timestamp_conversion () =
  with_mariadb_test_db "timestamp" (fun db_url ->
      with_db db_url (fun db ->
          Migra.Runner.ensure_migrations_table Migra.Dialect.MariaDB db
          >>= function
          | Error err ->
              Alcotest.fail
                (Printf.sprintf "ensure_migrations_table failed: %s"
                   (Caqti_error.show err))
          | Ok () -> (
              let version = 20240115120000L in
              Migra.Runner.add_migration db version "test-checksum" >>= function
              | Error err ->
                  Alcotest.fail
                    (Printf.sprintf "add_migration failed: %s"
                       (Caqti_error.show err))
              | Ok () -> (
                  Migra.Runner.get_applied_records Migra.Dialect.MariaDB db
                  >>= function
                  | Error err ->
                      Alcotest.fail
                        (Printf.sprintf "get_applied_records failed: %s"
                           (Caqti_error.show err))
                  | Ok records ->
                      Alcotest.(check int) "One record" 1 (List.length records);
                      let record = List.hd records in
                      Alcotest.(check bool)
                        "Timestamp converted to string" true
                        (String.length record.Migra.Runner.created_at > 0);
                      Lwt.return_unit))))

let test_mariadb_duplicate_migration_fails () =
  with_mariadb_test_db "duplicate" (fun db_url ->
      with_db db_url (fun db ->
          Migra.Runner.ensure_migrations_table Migra.Dialect.MariaDB db
          >>= function
          | Error err ->
              Alcotest.fail
                (Printf.sprintf "ensure_migrations_table failed: %s"
                   (Caqti_error.show err))
          | Ok () -> (
              let version = 20240115120000L in
              Migra.Runner.add_migration db version "test-checksum" >>= function
              | Error err ->
                  Alcotest.fail
                    (Printf.sprintf "First add_migration failed: %s"
                       (Caqti_error.show err))
              | Ok () -> (
                  Migra.Runner.add_migration db version "test-checksum"
                  >>= function
                  | Ok () ->
                      Alcotest.fail
                        "Expected duplicate insert to fail, but it succeeded"
                  | Error _err -> Lwt.return_unit))))

let database_lifecycle_tests =
  [
    ("MariaDB create_database", `Quick, test_mariadb_create_database);
    ( "MariaDB create_database is idempotent",
      `Quick,
      test_mariadb_create_database_idempotent );
    ("MariaDB drop_database", `Quick, test_mariadb_drop_database);
    ( "MariaDB drop_database is idempotent",
      `Quick,
      test_mariadb_drop_database_idempotent );
  ]

let schema_tests =
  [
    ("MariaDB schema uses InnoDB engine", `Quick, test_mariadb_schema_innodb);
    ( "MariaDB schema table is idempotent",
      `Quick,
      test_mariadb_schema_idempotent );
  ]

(** A migration that uses DELIMITER to define a stored procedure (whose body has
    interior semicolons) runs end-to-end on MariaDB. On MySQL, routine creation
    is unsupported (see below), so the check is skipped there. *)
let test_mariadb_delimiter_procedure () =
  with_mariadb_test_db "delim_proc" (fun db_url ->
      with_temp_dir "migrations" (fun migrations_dir ->
          let v1 = 20240115120000L in
          let _f =
            create_migration_with_sections migrations_dir v1 "proc"
              "CREATE TABLE t (id INT PRIMARY KEY);\n\
               DELIMITER //\n\
               CREATE PROCEDURE addrow(IN n INT) BEGIN INSERT INTO t (id) \
               VALUES (n); INSERT INTO t (id) VALUES (n + 1); END //\n\
               DELIMITER ;"
              "DROP PROCEDURE addrow; DROP TABLE t;"
          in
          let contains hay needle =
            let hl = String.length hay and nl = String.length needle in
            let rec go i =
              i + nl <= hl && (String.sub hay i nl = needle || go (i + 1))
            in
            go 0
          in
          with_db db_url (fun db ->
              let module Db = (val db : Caqti_lwt.CONNECTION) in
              let open Caqti_request.Infix in
              let open Caqti_type.Std in
              (* Stored programs (CREATE PROCEDURE/FUNCTION/TRIGGER/EVENT) go
                 through the prepared-statement protocol the driver uses, which
                 MariaDB accepts but MySQL rejects (error 1295; see runner.ml and
                 ocaml-caqti#42). Run the end-to-end check on MariaDB and skip on
                 MySQL; DELIMITER parsing itself is unit-tested on every dialect. *)
              let version_q = (unit ->! string) "SELECT VERSION()" in
              Db.find version_q () >>= function
              | Error err ->
                  Alcotest.fail
                    (Printf.sprintf "SELECT VERSION() failed: %s"
                       (Caqti_error.show err))
              | Ok version when not (contains version "MariaDB") ->
                  Lwt.return_unit
              | Ok _ -> (
                  Migra.Runner.ensure_migrations_table Migra.Dialect.MariaDB db
                  >>= function
                  | Error err ->
                      Alcotest.fail
                        (Printf.sprintf "ensure_migrations_table failed: %s"
                           (Caqti_error.show err))
                  | Ok () -> (
                      Migra.Runner.run_pending db migrations_dir >>= function
                      | Error msg ->
                          Alcotest.fail
                            (Printf.sprintf "run_pending failed: %s"
                               (Migra.Types.show_error msg))
                      | Ok results -> (
                          Alcotest.(check int)
                            "1 migration executed" 1 (List.length results);
                          Alcotest.(check bool)
                            "migration succeeded" true
                            (List.for_all Migra.Runner.is_success results);
                          let call = (unit ->. unit) "CALL addrow(10)" in
                          Db.exec call () >>= function
                          | Error err ->
                              Alcotest.fail
                                (Printf.sprintf "CALL addrow failed: %s"
                                   (Caqti_error.show err))
                          | Ok () -> (
                              let count =
                                (unit ->! int) "SELECT COUNT(*) FROM t"
                              in
                              Db.find count () >>= function
                              | Error err ->
                                  Alcotest.fail
                                    (Printf.sprintf "count failed: %s"
                                       (Caqti_error.show err))
                              | Ok n ->
                                  Alcotest.(check int)
                                    "procedure inserted 2 rows" 2 n;
                                  Lwt.return_unit)))))))

(* Regression: information_schema.tables on MySQL/MariaDB spans every database on
   the server, so table_exists must scope to the current database (DATABASE())
   and not match a schema_migrations owned by another database. *)
let test_mariadb_table_exists_scoped () =
  with_mariadb_test_db "tbl_exists" (fun db_url ->
      create_mariadb_test_db "tbl_exists_other" >>= function
      | Error msg -> Alcotest.fail msg
      | Ok (other_name, other_url) ->
          Lwt.finalize
            (fun () ->
              with_db other_url (fun other ->
                  Migra.Runner.ensure_migrations_table Migra.Dialect.MariaDB
                    other
                  >>= function
                  | Error err ->
                      Alcotest.fail
                        (Printf.sprintf "setup ensure table failed: %s"
                           (Caqti_error.show err))
                  | Ok () -> Lwt.return_unit)
              >>= fun () ->
              with_db db_url (fun db ->
                  Migra.Runner.table_exists Migra.Dialect.MariaDB db
                  >>= function
                  | Error err ->
                      Alcotest.fail
                        (Printf.sprintf "table_exists failed: %s"
                           (Caqti_error.show err))
                  | Ok other_db_match -> (
                      Alcotest.(check bool)
                        "table in another database is not matched" false
                        other_db_match;
                      Migra.Runner.ensure_migrations_table Migra.Dialect.MariaDB
                        db
                      >>= function
                      | Error err ->
                          Alcotest.fail
                            (Printf.sprintf "ensure table failed: %s"
                               (Caqti_error.show err))
                      | Ok () -> (
                          Migra.Runner.table_exists Migra.Dialect.MariaDB db
                          >>= function
                          | Error err ->
                              Alcotest.fail
                                (Printf.sprintf "table_exists failed: %s"
                                   (Caqti_error.show err))
                          | Ok this_db_match ->
                              Alcotest.(check bool)
                                "table in this database is matched" true
                                this_db_match;
                              Lwt.return_unit))))
            (fun () ->
              drop_mariadb_test_db other_name >>= fun _ -> Lwt.return_unit))

let migration_tests =
  [
    ("MariaDB migration operations", `Quick, test_mariadb_migration_operations);
    ("MariaDB DELIMITER procedure", `Quick, test_mariadb_delimiter_procedure);
    ("MariaDB get_applied_records", `Quick, test_mariadb_get_records);
    ("MariaDB get_latest_version", `Quick, test_mariadb_latest_version);
    ( "MariaDB get_applied_versions sorted",
      `Quick,
      test_mariadb_get_applied_versions_sorted );
    ("MariaDB timestamp conversion", `Quick, test_mariadb_timestamp_conversion);
    ( "MariaDB duplicate migration fails",
      `Quick,
      test_mariadb_duplicate_migration_fails );
    ( "MariaDB table_exists is scoped to the database",
      `Quick,
      test_mariadb_table_exists_scoped );
  ]

let suite = database_lifecycle_tests @ schema_tests @ migration_tests
