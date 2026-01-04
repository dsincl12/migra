
type t =
  | PostgreSQL
  | MariaDB
  | SQLite

module type DIALECT = sig
  val name : string
  val default_port : int option
  val admin_database : string option
  val database_exists_sql : string
  val create_database_sql : string -> string
  val drop_database_sql : string -> string
  val timestamp_to_string : string -> string
  val schema_migrations_ddl : string option
  val supports_database_lifecycle : bool
end

module PostgreSQL_dialect : DIALECT = struct
  let name = "PostgreSQL"
  let default_port = Some 5432
  let admin_database = Some "postgres"
  let supports_database_lifecycle = true

  let database_exists_sql =
    "SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname = $1)"

  let create_database_sql db_name =
    Printf.sprintf "CREATE DATABASE %s" db_name

  let drop_database_sql db_name =
    Printf.sprintf "DROP DATABASE IF EXISTS %s" db_name

  let timestamp_to_string col =
    Printf.sprintf "%s::text" col

  let schema_migrations_ddl = None
end

module MariaDB_dialect : DIALECT = struct
  let name = "MariaDB"
  let default_port = Some 3306
  let admin_database = Some "mysql"
  let supports_database_lifecycle = true

  let database_exists_sql =
    "SELECT EXISTS(SELECT 1 FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = ?)"

  let create_database_sql db_name =
    (* Use backticks for identifier quoting, IF NOT EXISTS for idempotency *)
    Printf.sprintf "CREATE DATABASE IF NOT EXISTS `%s`" db_name

  let drop_database_sql db_name =
    Printf.sprintf "DROP DATABASE IF EXISTS `%s`" db_name

  let timestamp_to_string col =
    Printf.sprintf "CAST(%s AS CHAR)" col

  (* MariaDB-specific: use InnoDB engine explicitly *)
  let schema_migrations_ddl = Some {sql|
    CREATE TABLE IF NOT EXISTS schema_migrations (
      version BIGINT PRIMARY KEY,
      created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
    ) ENGINE=InnoDB
  |sql}
end

module SQLite_dialect : DIALECT = struct
  let name = "SQLite"
  let default_port = None
  let admin_database = None
  let supports_database_lifecycle = false

  (* These are unused for SQLite but required by signature *)
  let database_exists_sql = ""
  let create_database_sql _ = ""
  let drop_database_sql _ = ""

  let timestamp_to_string col = col

  let schema_migrations_ddl = None
end

(** Normalize database URL for Caqti compatibility

    SQLite: caqti-driver-sqlite3 expects sqlite3:path (single colon), not sqlite3://path
    We accept both formats for user convenience but normalize to what Caqti expects.
*)
let normalize_url (url : string) : string =
  if String.starts_with ~prefix:"sqlite3://" url then
    "sqlite3:" ^ String.sub url 10 (String.length url - 10)
  else
    url

let detect_from_url (url : string) : (t, string) result =
  if String.starts_with ~prefix:"postgresql://" url then Ok PostgreSQL
  else if String.starts_with ~prefix:"postgres://" url then Ok PostgreSQL
  else if String.starts_with ~prefix:"mariadb://" url then Ok MariaDB
  else if String.starts_with ~prefix:"mysql://" url then Ok MariaDB
  else if String.starts_with ~prefix:"sqlite3://" url then Ok SQLite
  else if String.starts_with ~prefix:"sqlite3:" url then Ok SQLite
  else
    let scheme =
      match String.index_opt url ':' with
      | Some idx -> String.sub url 0 (idx + 3)
      | None -> url
    in
    Error (Printf.sprintf
      "Unsupported database URL scheme: '%s'\n\
       \n\
       Supported databases:\n\
       - PostgreSQL: postgresql:// or postgres://\n\
       - MariaDB/MySQL: mariadb:// or mysql://\n\
       - SQLite: sqlite3:// or sqlite3:\n\
       \n\
       Examples:\n\
       - postgresql://user@localhost:5432/mydb\n\
       - mariadb://root@localhost:3306/mydb\n\
       - sqlite3://./dev.db (normalized to sqlite3:./dev.db)\n\
       - sqlite3::memory: (in-memory database)\n\
       \n"
      scheme)

let get_dialect (db_type : t) : (module DIALECT) =
  match db_type with
  | PostgreSQL -> (module PostgreSQL_dialect)
  | MariaDB -> (module MariaDB_dialect)
  | SQLite -> (module SQLite_dialect)

let to_string = function
  | PostgreSQL -> "PostgreSQL"
  | MariaDB -> "MariaDB"
  | SQLite -> "SQLite"
