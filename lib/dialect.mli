type t = PostgreSQL | MariaDB | SQLite

module type DIALECT = sig
  val name : string
  val default_port : int option

  val admin_database : string option
  (** Admin database to connect to for CREATE/DROP DATABASE operations
      - PostgreSQL: Some "postgres"
      - MariaDB: Some "mysql"
      - SQLite: None (file-based, no admin DB) *)

  val database_exists_sql : string
  (** SQL to check if database exists Returns query string with one parameter
      placeholder
      - PostgreSQL: SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname = $1)
      - MariaDB: SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE
        SCHEMA_NAME = ?
      - SQLite: "" (N/A - use file system check instead) *)

  val create_database_sql : string -> string
  (** Generate SQL to create database
      @param db_name Database name to create
      @return SQL statement (not parameterized - database names can't be) *)

  val drop_database_sql : string -> string
  (** Generate SQL to drop database
      @param db_name Database name to drop
      @return SQL statement (not parameterized - database names can't be) *)

  val timestamp_to_string : string -> string
  (** Convert timestamp column to string in SELECT
      @param column_name Name of timestamp column
      @return
        SQL expression that casts to string
        - PostgreSQL: "created_at::text"
        - MariaDB: "CAST(created_at AS CHAR)"
        - SQLite: "created_at" (auto-converts) *)

  val supports_database_lifecycle : bool
  (** Whether this dialect supports CREATE/DROP DATABASE SQLite is file-based,
      so it uses file operations instead *)
end

module PostgreSQL_dialect : DIALECT
module MariaDB_dialect : DIALECT
module SQLite_dialect : DIALECT

val normalize_url : string -> string
(** Normalize database URL for Caqti compatibility

    SQLite: caqti-driver-sqlite3 expects sqlite3:path (single colon), not
    sqlite3://path We accept both formats for user convenience but normalize to
    what Caqti expects.

    @param url Database URL
    @return Normalized URL *)

val detect_from_url : string -> (t, string) result
(** Detect database type from URL scheme
    @param url Database URL (e.g., "postgresql://...", "sqlite3://...")
    @return Ok dialect or Error message for unsupported schemes *)

val get_dialect : t -> (module DIALECT)
(** Get dialect module for database type
    @param db_type Database type
    @return First-class module implementing DIALECT *)

val to_string : t -> string
(** Pretty-print database type
    @param t Database type
    @return Human-readable string *)
