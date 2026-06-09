type t = PostgreSQL | MariaDB | SQLite

module type DIALECT = sig
  val name : string
  val default_port : int option
  val admin_database : string option
  val database_exists_sql : string
  val create_database_sql : string -> string
  val drop_database_sql : string -> string
  val timestamp_to_string : string -> string
  val supports_database_lifecycle : bool
end

(** Quote [name] as a delimited SQL identifier using [q] as the delimiter,
    escaping any embedded delimiter by doubling it. This turns a name like
    [my-db] or one containing the delimiter into a single, injection-safe
    identifier token. Database names are interpolated into DDL (they cannot be
    bound as parameters), so this is what keeps them safe. *)
let quote_identifier ~(q : char) (name : string) : string =
  let buf = Buffer.create (String.length name + 2) in
  Buffer.add_char buf q;
  String.iter
    (fun c ->
      if c = q then Buffer.add_char buf q;
      Buffer.add_char buf c)
    name;
  Buffer.add_char buf q;
  Buffer.contents buf

module PostgreSQL_dialect : DIALECT = struct
  let name = "PostgreSQL"
  let default_port = Some 5432
  let admin_database = Some "postgres"
  let supports_database_lifecycle = true

  let database_exists_sql =
    "SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname = $1)"

  (* Double-quote the identifier so names that are not bare identifiers (e.g.
     "my-db") are accepted and cannot break out of the statement. *)
  let create_database_sql db_name =
    Printf.sprintf "CREATE DATABASE %s" (quote_identifier ~q:'"' db_name)

  let drop_database_sql db_name =
    Printf.sprintf "DROP DATABASE IF EXISTS %s"
      (quote_identifier ~q:'"' db_name)

  let timestamp_to_string col = Printf.sprintf "%s::text" col
end

module MariaDB_dialect : DIALECT = struct
  let name = "MariaDB"
  let default_port = Some 3306
  let admin_database = Some "mysql"
  let supports_database_lifecycle = true

  let database_exists_sql =
    "SELECT EXISTS(SELECT 1 FROM information_schema.SCHEMATA WHERE SCHEMA_NAME \
     = ?)"

  (* Backtick-quote the identifier (doubling any embedded backtick) so names
     with backticks or other special characters cannot break out of the
     statement; IF NOT EXISTS for idempotency. *)
  let create_database_sql db_name =
    Printf.sprintf "CREATE DATABASE IF NOT EXISTS %s"
      (quote_identifier ~q:'`' db_name)

  let drop_database_sql db_name =
    Printf.sprintf "DROP DATABASE IF EXISTS %s"
      (quote_identifier ~q:'`' db_name)

  let timestamp_to_string col = Printf.sprintf "CAST(%s AS CHAR)" col
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
end

(** Normalize database URL for Caqti compatibility

    SQLite: caqti-driver-sqlite3 expects sqlite3:path (single colon), not
    sqlite3://path We accept both formats for user convenience but normalize to
    what Caqti expects. *)
let normalize_url (url : string) : string =
  let prefix = "sqlite3://" in
  if String.starts_with ~prefix url then
    let n = String.length prefix in
    "sqlite3:" ^ String.sub url n (String.length url - n)
  else url

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
      (* Grab "scheme://" for the message, but clamp the length: a URL like
         "ht:" has no room for the "//" and would otherwise overflow String.sub. *)
      | Some idx -> String.sub url 0 (min (idx + 3) (String.length url))
      | None -> url
    in
    Error
      (Printf.sprintf
         "Unsupported database URL scheme: '%s'\n\n\
          Supported databases:\n\
          - PostgreSQL: postgresql:// or postgres://\n\
          - MariaDB/MySQL: mariadb:// or mysql://\n\
          - SQLite: sqlite3:// or sqlite3:\n\n\
          Examples:\n\
          - postgresql://user@localhost:5432/mydb\n\
          - mariadb://root@localhost:3306/mydb\n\
          - sqlite3://./dev.db (normalized to sqlite3:./dev.db)\n\
          - sqlite3::memory: (in-memory database)\n\n"
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
