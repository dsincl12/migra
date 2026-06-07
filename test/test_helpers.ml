open Lwt.Infix

module TestDbPool = struct
  type pool_entry = { db_name : string; db_url : string; in_use : bool ref }

  let pool : pool_entry list ref = ref []
  let pool_size = 3 (* Limit number of test databases - keep it small *)
  let lock = Lwt_mutex.create ()
  let retry_delay = 0.5 (* seconds to wait between retries *)

  let get_admin_url () =
    match Sys.getenv_opt "DATABASE_URL" with
    | None -> "postgresql://localhost:5432/postgres"
    | Some url -> (
        match Uri.of_string url with
        | uri -> (
            match
              Migra_engine.Database.get_admin_database_url
                Migra_engine.Dialect.PostgreSQL uri
            with
            | Ok admin_url -> admin_url
            | Error _ ->
                let userinfo = Uri.userinfo uri in
                let host = Uri.host uri |> Option.value ~default:"localhost" in
                let port = Uri.port uri |> Option.value ~default:5432 in
                let auth =
                  match userinfo with None -> "" | Some info -> info ^ "@"
                in
                Printf.sprintf "postgresql://%s%s:%d/postgres" auth host port))

  let create_entry prefix =
    let timestamp = Unix.time () |> int_of_float in
    let random = Random.int 10000 in
    let db_name =
      Printf.sprintf "migra_test_pool_%s_%d_%d" prefix timestamp random
    in
    let admin_url = get_admin_url () in

    Migra_engine.Database.connect_db admin_url >>= function
    | Error err ->
        Lwt.return_error
          (Printf.sprintf "Failed to connect to postgres: %s"
             (Migra.Types.show_error err))
    | Ok db -> (
        let module Db = (val db : Caqti_lwt.CONNECTION) in
        let open Caqti_request.Infix in
        let open Caqti_type.Std in
        let query =
          (unit ->. unit) ~oneshot:true
            (Printf.sprintf "CREATE DATABASE %s" db_name)
        in

        Db.exec query () >>= function
        | Error err ->
            Lwt.return_error
              (Printf.sprintf "Failed to create test DB: %s"
                 (Caqti_error.show err))
        | Ok () ->
            let uri = Uri.of_string admin_url in
            let userinfo = Uri.userinfo uri in
            let host = Uri.host uri |> Option.value ~default:"localhost" in
            let port = Uri.port uri |> Option.value ~default:5432 in
            let auth =
              match userinfo with None -> "" | Some info -> info ^ "@"
            in
            let test_url =
              Printf.sprintf "postgresql://%s%s:%d/%s" auth host port db_name
            in
            Lwt.return_ok { db_name; db_url = test_url; in_use = ref false })

  let clean_database db_url =
    Migra_engine.Database.connect_db db_url >>= function
    | Error _ -> Lwt.return_unit (* Ignore errors during cleanup *)
    | Ok db ->
        let module Db = (val db : Caqti_lwt.CONNECTION) in
        let open Caqti_request.Infix in
        let open Caqti_type.Std in
        let drop_tables_query =
          (unit ->. unit) ~oneshot:true
            {sql|
          DO $$
          DECLARE
            r RECORD;
          BEGIN
            FOR r IN (SELECT tablename FROM pg_tables WHERE schemaname = 'public')
            LOOP
              EXECUTE 'DROP TABLE IF EXISTS ' || quote_ident(r.tablename) || ' CASCADE';
            END LOOP;
          END $$;
        |sql}
        in

        Db.exec drop_tables_query () >>= fun _ -> Lwt.return_unit

  let rec acquire_with_retry prefix max_retries =
    Lwt_mutex.with_lock lock (fun () ->
        let available =
          List.find_opt (fun entry -> not !(entry.in_use)) !pool
        in
        match available with
        | Some entry ->
            entry.in_use := true;
            Lwt.return (Some entry.db_url)
        | None ->
            if List.length !pool < pool_size then (
              create_entry prefix >>= function
              | Error _ when max_retries > 0 -> Lwt.return None
              | Error err -> Lwt.fail_with err
              | Ok entry ->
                  entry.in_use := true;
                  pool := entry :: !pool;
                  Lwt.return (Some entry.db_url))
            else Lwt.return None)
    >>= function
    | Some db_url -> clean_database db_url >>= fun () -> Lwt.return_ok db_url
    | None when max_retries > 0 ->
        Lwt_unix.sleep retry_delay >>= fun () ->
        acquire_with_retry prefix (max_retries - 1)
    | None ->
        Lwt.return_error
          "Pool exhausted and no databases available after retries"

  let acquire prefix =
    acquire_with_retry prefix 10 (* Try up to 10 times with 0.5s delays *)

  let release db_url =
    Lwt_mutex.with_lock lock (fun () ->
        let entry = List.find_opt (fun e -> e.db_url = db_url) !pool in
        match entry with
        | Some e ->
            e.in_use := false;
            Lwt.return_unit
        | None -> Lwt.return_unit)

  let cleanup () =
    Lwt_mutex.with_lock lock (fun () ->
        let admin_url = get_admin_url () in
        Migra_engine.Database.connect_db admin_url >>= function
        | Error _ -> Lwt.return_unit
        | Ok db ->
            let module Db = (val db : Caqti_lwt.CONNECTION) in
            let open Caqti_request.Infix in
            let open Caqti_type.Std in
            Lwt_list.iter_s
              (fun entry ->
                let query =
                  (unit ->. unit) ~oneshot:true
                    (Printf.sprintf "DROP DATABASE IF EXISTS %s" entry.db_name)
                in
                Db.exec query () >>= fun _ -> Lwt.return_unit)
              !pool)
end

let test_db_name prefix =
  let timestamp = Unix.time () |> int_of_float in
  let random = Random.int 10000 in
  Printf.sprintf "migra_test_%s_%d_%d" prefix timestamp random

let get_admin_url () =
  match Sys.getenv_opt "DATABASE_URL" with
  | None -> "postgresql://localhost:5432/postgres"
  | Some url -> (
      match Uri.of_string url with
      | uri -> (
          match
            Migra_engine.Database.get_admin_database_url
              Migra_engine.Dialect.PostgreSQL uri
          with
          | Ok admin_url -> admin_url
          | Error _ ->
              let userinfo = Uri.userinfo uri in
              let host = Uri.host uri |> Option.value ~default:"localhost" in
              let port = Uri.port uri |> Option.value ~default:5432 in
              let auth =
                match userinfo with None -> "" | Some info -> info ^ "@"
              in
              Printf.sprintf "postgresql://%s%s:%d/postgres" auth host port))

let create_test_db prefix =
  let db_name = test_db_name prefix in
  let admin_url = get_admin_url () in

  Migra_engine.Database.connect_db admin_url >>= function
  | Error err ->
      Lwt.return_error
        (Printf.sprintf "Failed to connect to postgres: %s"
           (Migra.Types.show_error err))
  | Ok db -> (
      let module Db = (val db : Caqti_lwt.CONNECTION) in
      let open Caqti_request.Infix in
      let open Caqti_type.Std in
      let query =
        (unit ->. unit) ~oneshot:true
          (Printf.sprintf "CREATE DATABASE %s" db_name)
      in

      Db.exec query () >>= function
      | Error err ->
          Lwt.return_error
            (Printf.sprintf "Failed to create test DB: %s"
               (Caqti_error.show err))
      | Ok () ->
          let uri = Uri.of_string admin_url in
          let userinfo = Uri.userinfo uri in
          let host = Uri.host uri |> Option.value ~default:"localhost" in
          let port = Uri.port uri |> Option.value ~default:5432 in
          let auth =
            match userinfo with None -> "" | Some info -> info ^ "@"
          in
          let test_url =
            Printf.sprintf "postgresql://%s%s:%d/%s" auth host port db_name
          in
          Lwt.return_ok (db_name, test_url))

let drop_test_db db_name =
  let admin_url = get_admin_url () in

  Migra_engine.Database.connect_db admin_url >>= function
  | Error err ->
      Lwt.return_error
        (Printf.sprintf "Failed to connect to postgres: %s"
           (Migra.Types.show_error err))
  | Ok db -> (
      let module Db = (val db : Caqti_lwt.CONNECTION) in
      let open Caqti_request.Infix in
      let open Caqti_type.Std in
      let query =
        (unit ->. unit) ~oneshot:true
          (Printf.sprintf "DROP DATABASE IF EXISTS %s" db_name)
      in

      Db.exec query () >>= function
      | Error err ->
          Lwt.return_error
            (Printf.sprintf "Failed to drop test DB: %s" (Caqti_error.show err))
      | Ok () -> Lwt.return_ok ())

(** Bracket pattern for test database lifecycle Usage: with_test_db "mytest"
    (fun db_url -> (* test code *)) *)
let with_test_db prefix f =
  create_test_db prefix >>= function
  | Error msg -> Lwt.fail_with msg
  | Ok (db_name, db_url) ->
      Lwt.finalize
        (fun () -> f db_url)
        (fun () ->
          drop_test_db db_name >>= function
          | Error _msg -> Lwt.return_unit
          | Ok () -> Lwt.return_unit)

(** Bracket pattern using pooled databases (better for avoiding connection
    exhaustion) Usage: with_test_db_pooled "mytest" (fun db_url -> (* test code
    *)) *)
let with_test_db_pooled prefix f =
  TestDbPool.acquire prefix >>= function
  | Error msg -> Lwt.fail_with msg
  | Ok db_url ->
      Lwt.finalize (fun () -> f db_url) (fun () -> TestDbPool.release db_url)

let create_temp_dir prefix =
  let timestamp = Unix.time () |> int_of_float in
  let random = Random.int 10000 in
  let dir_name =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "migra_test_%s_%d_%d" prefix timestamp random)
  in
  Unix.mkdir dir_name 0o755;
  dir_name

let rec remove_dir dir =
  if Sys.file_exists dir && Sys.is_directory dir then begin
    Sys.readdir dir
    |> Array.iter (fun name ->
        let path = Filename.concat dir name in
        if Sys.is_directory path then remove_dir path else Sys.remove path);
    Unix.rmdir dir
  end

(** Bracket pattern for temporary directory lifecycle Usage: with_temp_dir
    "mytest" (fun dir -> (* test code *)) *)
let with_temp_dir prefix f =
  let dir = create_temp_dir prefix in
  Lwt.finalize
    (fun () -> f dir)
    (fun () ->
      remove_dir dir;
      Lwt.return_unit)

let create_migration_file dir version description content =
  let filename = Migra_engine.Migration.make_filename version description in
  let filepath = Filename.concat dir filename in
  let oc = open_out filepath in
  output_string oc content;
  close_out oc;
  filepath

let create_migration_with_sections dir version description up_sql down_sql =
  let content =
    Printf.sprintf "-- +migrate up\n%s\n\n-- +migrate down\n%s\n" up_sql
      down_sql
  in
  create_migration_file dir version description content

let int64_testable =
  Alcotest.testable (fun fmt i -> Format.fprintf fmt "%Ld" i) Int64.equal

let migration_testable =
  Alcotest.testable
    (fun fmt m -> Format.fprintf fmt "%s" (Migra_engine.Migration.to_string m))
    (fun a b ->
      Int64.equal a.Migra_engine.Migration.version
        b.Migra_engine.Migration.version)

let is_ok = function Ok _ -> true | Error _ -> false
let is_error = function Ok _ -> false | Error _ -> true

let get_ok = function
  | Ok v -> v
  | Error err ->
      Alcotest.fail
        (Printf.sprintf "Expected Ok but got Error: %s"
           (Migra.Types.show_error err))

let get_error = function
  | Ok _ -> Alcotest.fail "Expected Error but got Ok"
  | Error err -> Migra.Types.show_error err

let string_contains_substring haystack needle =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  let rec search pos =
    if pos + needle_len > haystack_len then false
    else if String.sub haystack pos needle_len = needle then true
    else search (pos + 1)
  in
  if needle_len = 0 then true else search 0
