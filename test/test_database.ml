
open Lwt.Infix
open Test_helpers

let test_get_hostname_standard () =
  let uri = Uri.of_string "postgresql://localhost:5432/mydb" in
  let result = Migra.Database.get_hostname uri in
  Alcotest.(check bool) "parse succeeds" true (is_ok result);
  let hostname = get_ok result in
  Alcotest.(check string) "hostname is localhost" "localhost" hostname;
  Lwt.return_unit

let test_get_hostname_ip () =
  let uri = Uri.of_string "postgresql://192.168.1.100:5432/mydb" in
  let result = Migra.Database.get_hostname uri in
  Alcotest.(check bool) "parse succeeds" true (is_ok result);
  let hostname = get_ok result in
  Alcotest.(check string) "hostname is IP" "192.168.1.100" hostname;
  Lwt.return_unit

let test_get_hostname_ipv6 () =
  let uri = Uri.of_string "postgresql://[::1]:5432/mydb" in
  let result = Migra.Database.get_hostname uri in
  Alcotest.(check bool) "parse succeeds" true (is_ok result);
  let hostname = get_ok result in
  Alcotest.(check string) "hostname is ::1" "::1" hostname;
  Lwt.return_unit

let test_get_hostname_empty () =
  let uri = Uri.of_string "postgresql:///mydb" in
  let result = Migra.Database.get_hostname uri in
  Alcotest.(check bool) "parse succeeds with empty host" true (is_ok result);
  let hostname = get_ok result in
  Alcotest.(check string) "hostname is empty string" "" hostname;
  Lwt.return_unit

let test_get_port_standard () =
  let uri = Uri.of_string "postgresql://localhost:5432/mydb" in
  let result = Migra.Database.get_port uri in
  Alcotest.(check bool) "parse succeeds" true (is_ok result);
  let port = get_ok result in
  Alcotest.(check int) "port is 5432" 5432 port;
  Lwt.return_unit

let test_get_port_custom () =
  let uri = Uri.of_string "postgresql://localhost:9999/mydb" in
  let result = Migra.Database.get_port uri in
  Alcotest.(check bool) "parse succeeds" true (is_ok result);
  let port = get_ok result in
  Alcotest.(check int) "port is 9999" 9999 port;
  Lwt.return_unit

let test_get_port_missing () =
  let uri = Uri.of_string "postgresql://localhost/mydb" in
  let result = Migra.Database.get_port uri in
  Alcotest.(check bool) "parse fails" true (is_error result);
  Lwt.return_unit

let test_get_database_standard () =
  let uri = Uri.of_string "postgresql://localhost:5432/mydb" in
  let result = Migra.Database.get_database uri in
  Alcotest.(check bool) "parse succeeds" true (is_ok result);
  let db = get_ok result in
  Alcotest.(check string) "database is mydb" "mydb" db;
  Lwt.return_unit

let test_get_database_underscores () =
  let uri = Uri.of_string "postgresql://localhost:5432/my_app_db" in
  let result = Migra.Database.get_database uri in
  Alcotest.(check bool) "parse succeeds" true (is_ok result);
  let db = get_ok result in
  Alcotest.(check string) "database is my_app_db" "my_app_db" db;
  Lwt.return_unit

let test_get_database_empty_path () =
  let uri = Uri.of_string "postgresql://localhost:5432" in
  let result = Migra.Database.get_database uri in
  Alcotest.(check bool) "parse fails on empty path" true (is_error result);
  Lwt.return_unit

let test_get_database_slash_only () =
  let uri = Uri.of_string "postgresql://localhost:5432/" in
  let result = Migra.Database.get_database uri in
  Alcotest.(check bool) "parse fails on slash only" true (is_error result);
  Lwt.return_unit

let test_get_admin_database_url_with_user () =
  let uri = Uri.of_string "postgresql://myuser@localhost:5432/mydb" in
  let result = Migra.Database.get_admin_database_url Migra.Dialect.PostgreSQL uri in
  Alcotest.(check bool) "build succeeds" true (is_ok result);
  let admin_url = get_ok result in
  Alcotest.(check string) "admin URL correct"
    "postgresql://myuser@localhost:5432/postgres" admin_url;
  Lwt.return_unit

let test_get_admin_database_url_no_user () =
  let uri = Uri.of_string "postgresql://localhost:5432/mydb" in
  let result = Migra.Database.get_admin_database_url Migra.Dialect.PostgreSQL uri in
  Alcotest.(check bool) "build succeeds" true (is_ok result);
  let admin_url = get_ok result in
  Alcotest.(check string) "admin URL correct"
    "postgresql://localhost:5432/postgres" admin_url;
  Lwt.return_unit

let test_get_admin_database_url_with_password () =
  let uri = Uri.of_string "postgresql://myuser:mypass@localhost:5432/mydb" in
  let result = Migra.Database.get_admin_database_url Migra.Dialect.PostgreSQL uri in
  Alcotest.(check bool) "build succeeds" true (is_ok result);
  let admin_url = get_ok result in
  (* The password must be preserved: admin commands (init/setup/drop/reset)
     connect through this URL and will fail on password-protected servers
     if it is stripped. *)
  Alcotest.(check string) "admin URL keeps user and password"
    "postgresql://myuser:mypass@localhost:5432/postgres" admin_url;
  Lwt.return_unit

let test_get_admin_database_url_default_port () =
  let uri = Uri.of_string "postgresql://myuser@localhost/mydb" in
  let result = Migra.Database.get_admin_database_url Migra.Dialect.PostgreSQL uri in
  Alcotest.(check bool) "build succeeds" true (is_ok result);
  let admin_url = get_ok result in
  Alcotest.(check string) "admin URL uses default port"
    "postgresql://myuser@localhost:5432/postgres" admin_url;
  Lwt.return_unit

let contains_sub haystack needle =
  let hl = String.length haystack and nl = String.length needle in
  let rec go i = i + nl <= hl && (String.sub haystack i nl = needle || go (i + 1)) in
  nl = 0 || go 0

let test_redact_url () =
  let r1 = Migra.Database.redact_url "postgresql://user:secret@localhost:5432/db" in
  Alcotest.(check bool) "password masked" true (contains_sub r1 "*****");
  Alcotest.(check bool) "secret gone" false (contains_sub r1 "secret");
  Alcotest.(check bool) "user kept" true (contains_sub r1 "user");
  Alcotest.(check bool) "length not leaked" false (contains_sub r1 "******");
  Alcotest.(check string) "no-password url unchanged"
    "postgresql://user@localhost:5432/db"
    (Migra.Database.redact_url "postgresql://user@localhost:5432/db");
  Alcotest.(check string) "sqlite unchanged"
    "sqlite3:/tmp/x.db" (Migra.Database.redact_url "sqlite3:/tmp/x.db");
  Lwt.return_unit

(** Test: a database name containing '/' is rejected (no connection needed -
    the check short-circuits before connecting). *)
let test_create_database_rejects_slash () =
  Migra.Database.create_database "postgresql://localhost:5433/db/extra" >>= function
  | Ok () -> Alcotest.fail "expected Error for a database name containing '/'"
  | Error err ->
      let msg = Migra.Types.show_error err in
      Alcotest.(check bool) "mentions the bad name" true (contains_sub msg "db/extra");
      Alcotest.(check bool) "explains the rule" true (contains_sub msg "cannot contain");
      Lwt.return_unit

let test_drop_database_rejects_slash () =
  Migra.Database.drop_database "mariadb://root@127.0.0.1:3307/db/extra" >>= function
  | Ok () -> Alcotest.fail "expected Error for a database name containing '/'"
  | Error err ->
      Alcotest.(check bool) "rejects slashed name" true
        (contains_sub (Migra.Types.show_error err) "cannot contain");
      Lwt.return_unit

let get_test_admin_url () =
  match Sys.getenv_opt "DATABASE_URL" with
  | None -> "postgresql://localhost:5432/postgres"
  | Some url ->
      let uri = Uri.of_string url in
      match Migra.Database.get_admin_database_url Migra.Dialect.PostgreSQL uri with
      | Ok admin_url -> admin_url
      | Error _ -> "postgresql://localhost:5432/postgres"

let test_create_database () =
  let db_name = test_db_name "db_create" in
  let admin_url = get_test_admin_url () in
  let uri = Uri.of_string admin_url in
  let host = Uri.host uri |> Option.value ~default:"localhost" in
  let port = Uri.port uri |> Option.value ~default:5432 in
  let userinfo = Uri.userinfo uri in
  let auth = match userinfo with
    | None -> ""
    | Some info -> info ^ "@"
  in
  let db_url = Printf.sprintf "postgresql://%s%s:%d/%s" auth host port db_name in

  Migra.Database.create_database db_url >>= function
  | Error msg ->
      Alcotest.fail (Printf.sprintf "create_database failed: %s" (Migra.Types.show_error msg))
  | Ok () ->
      Migra.Database.drop_database db_url >>= fun _ ->
      Lwt.return_unit

let test_create_database_idempotent () =
  let db_name = test_db_name "db_idempotent" in
  let admin_url = get_test_admin_url () in
  let uri = Uri.of_string admin_url in
  let host = Uri.host uri |> Option.value ~default:"localhost" in
  let port = Uri.port uri |> Option.value ~default:5432 in
  let userinfo = Uri.userinfo uri in
  let auth = match userinfo with
    | None -> ""
    | Some info -> info ^ "@"
  in
  let db_url = Printf.sprintf "postgresql://%s%s:%d/%s" auth host port db_name in

  Migra.Database.create_database db_url >>= function
  | Error msg ->
      Alcotest.fail (Printf.sprintf "First create_database failed: %s" (Migra.Types.show_error msg))
  | Ok () ->
      Migra.Database.create_database db_url >>= function
      | Error msg ->
          Alcotest.fail (Printf.sprintf "Second create_database failed: %s" (Migra.Types.show_error msg))
      | Ok () ->
          Migra.Database.drop_database db_url >>= fun _ ->
          Lwt.return_unit

let test_drop_database () =
  let db_name = test_db_name "db_drop" in
  let admin_url = get_test_admin_url () in
  let uri = Uri.of_string admin_url in
  let host = Uri.host uri |> Option.value ~default:"localhost" in
  let port = Uri.port uri |> Option.value ~default:5432 in
  let userinfo = Uri.userinfo uri in
  let auth = match userinfo with
    | None -> ""
    | Some info -> info ^ "@"
  in
  let db_url = Printf.sprintf "postgresql://%s%s:%d/%s" auth host port db_name in

  Migra.Database.create_database db_url >>= function
  | Error msg ->
      Alcotest.fail (Printf.sprintf "create_database failed: %s" (Migra.Types.show_error msg))
  | Ok () ->
      Migra.Database.drop_database db_url >>= function
      | Error msg ->
          Alcotest.fail (Printf.sprintf "drop_database failed: %s" (Migra.Types.show_error msg))
      | Ok () ->
          Lwt.return_unit

let test_drop_database_idempotent () =
  let db_name = test_db_name "db_drop_idempotent" in
  let admin_url = get_test_admin_url () in
  let uri = Uri.of_string admin_url in
  let host = Uri.host uri |> Option.value ~default:"localhost" in
  let port = Uri.port uri |> Option.value ~default:5432 in
  let userinfo = Uri.userinfo uri in
  let auth = match userinfo with
    | None -> ""
    | Some info -> info ^ "@"
  in
  let db_url = Printf.sprintf "postgresql://%s%s:%d/%s" auth host port db_name in

  Migra.Database.drop_database db_url >>= function
  | Error msg ->
      Alcotest.fail (Printf.sprintf "drop_database failed on non-existent DB: %s" (Migra.Types.show_error msg))
  | Ok () ->
      Lwt.return_unit

let test_connect_db () =
  with_test_db_pooled "db_connect" (fun db_url ->
    Migra.Database.connect_db db_url >>= function
    | Error msg ->
        Alcotest.fail (Printf.sprintf "connect_db failed: %s" (Migra.Types.show_error msg))
    | Ok _db ->
        Lwt.return_unit
  )

let test_connect_db_nonexistent () =
  let db_url = "postgresql://localhost:5432/migra_db_that_does_not_exist_12345" in
  Migra.Database.connect_db db_url >>= function
  | Ok _db ->
      Alcotest.fail "Expected connection to fail on non-existent database"
  | Error _msg ->
      Lwt.return_unit

let test_with_db () =
  with_test_db_pooled "db_with" (fun db_url ->
    Migra.Database.with_db db_url (fun _db ->
      Lwt.return 42
    ) >>= function
    | Error msg ->
        Alcotest.fail (Printf.sprintf "with_db failed: %s" (Migra.Types.show_error msg))
    | Ok result ->
        Alcotest.(check int) "function result" 42 result;
        Lwt.return_unit
  )

let test_with_db_exception () =
  with_test_db_pooled "db_with_exception" (fun db_url ->
    Migra.Database.with_db db_url (fun _db ->
      Lwt.fail_with "Intentional test failure"
    ) >>= function
    | Ok _ ->
        Alcotest.fail "Expected with_db to catch exception"
    | Error err ->
        let msg = Migra.Types.show_error err in
        Alcotest.(check bool) "error message contains failure"
          true (String.length msg > 0);
        Lwt.return_unit
  )

let test_initialize () =
  with_test_db_pooled "db_initialize" (fun db_url ->
    Migra.Database.connect_db db_url >>= function
    | Error msg ->
        Alcotest.fail (Printf.sprintf "connect_db failed: %s" (Migra.Types.show_error msg))
    | Ok db ->
        Migra.Runner.ensure_migrations_table Migra.Dialect.PostgreSQL db >>= function
        | Error err ->
            Alcotest.fail (Printf.sprintf "create_table failed: %s" (Caqti_error.show err))
        | Ok () ->
            Migra.Runner.get_applied_versions db >>= function
            | Error err ->
                Alcotest.fail (Printf.sprintf "Query after initialize failed: %s" (Caqti_error.show err))
            | Ok versions ->
                Alcotest.(check int) "schema_migrations table is empty" 0 (List.length versions);
                Lwt.return_unit
  )

let async_of_sync f () = f (); Lwt.return_unit

let suite = [
  "get_hostname_standard", `Quick, test_get_hostname_standard;
  "get_hostname_ip", `Quick, test_get_hostname_ip;
  "get_hostname_ipv6", `Quick, test_get_hostname_ipv6;
  "get_hostname_empty", `Quick, test_get_hostname_empty;
  "get_port_standard", `Quick, test_get_port_standard;
  "get_port_custom", `Quick, test_get_port_custom;
  "get_port_missing", `Quick, test_get_port_missing;
  "get_database_standard", `Quick, test_get_database_standard;
  "get_database_underscores", `Quick, test_get_database_underscores;
  "get_database_empty_path", `Quick, test_get_database_empty_path;
  "get_database_slash_only", `Quick, test_get_database_slash_only;
  "get_admin_database_url_with_user", `Quick, test_get_admin_database_url_with_user;
  "get_admin_database_url_no_user", `Quick, test_get_admin_database_url_no_user;
  "get_admin_database_url_with_password", `Quick, test_get_admin_database_url_with_password;
  "get_admin_database_url_default_port", `Quick, test_get_admin_database_url_default_port;

  "redact_url", `Quick, test_redact_url;
  "create_database_rejects_slash", `Quick, test_create_database_rejects_slash;
  "drop_database_rejects_slash", `Quick, test_drop_database_rejects_slash;

  "create_database", `Quick, test_create_database;
  "create_database_idempotent", `Quick, test_create_database_idempotent;
  "drop_database", `Quick, test_drop_database;
  "drop_database_idempotent", `Quick, test_drop_database_idempotent;
  "connect_db", `Quick, test_connect_db;
  "connect_db_nonexistent", `Quick, test_connect_db_nonexistent;
  "with_db", `Quick, test_with_db;
  "with_db_exception", `Quick, test_with_db_exception;
  "initialize", `Quick, test_initialize;
]
