
type t =
  | PostgreSQL
  | MariaDB
  | SQLite

module type DIALECT = sig
  val name : string

  val default_port : int option

  (** Admin database to connect to for CREATE/DROP DATABASE operations
      - PostgreSQL: Some "postgres"
      - MariaDB: Some "mysql"
      - SQLite: None (file-based, no admin DB)
  *)
  val admin_database : string option

  (** SQL to check if database exists
      Returns query string with one parameter placeholder
      - PostgreSQL: SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname = $1)
      - MariaDB: SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = ?
      - SQLite: "" (N/A - use file system check instead)
  *)
  val database_exists_sql : string

  (** Generate SQL to create database
      @param db_name Database name to create
      @return SQL statement (not parameterized - database names can't be)
  *)
  val create_database_sql : string -> string

  (** Generate SQL to drop database
      @param db_name Database name to drop
      @return SQL statement (not parameterized - database names can't be)
  *)
  val drop_database_sql : string -> string

  (** Convert timestamp column to string in SELECT
      @param column_name Name of timestamp column
      @return SQL expression that casts to string
      - PostgreSQL: "created_at::text"
      - MariaDB: "CAST(created_at AS CHAR)"
      - SQLite: "created_at" (auto-converts)
  *)
  val timestamp_to_string : string -> string

  (** Optional dialect-specific DDL for schema_migrations table
      Return None to use standard DDL, or Some sql for custom DDL
      - PostgreSQL: None (use standard)
      - MariaDB: Some "... ENGINE=InnoDB"
      - SQLite: None (use standard)
  *)
  val schema_migrations_ddl : string option

  (** Whether this dialect supports CREATE/DROP DATABASE
      SQLite is file-based, so it uses file operations instead
  *)
  val supports_database_lifecycle : bool
end

module PostgreSQL_dialect : DIALECT

module MariaDB_dialect : DIALECT

module SQLite_dialect : DIALECT

(** Normalize database URL for Caqti compatibility

    SQLite: caqti-driver-sqlite3 expects sqlite3:path (single colon), not sqlite3://path
    We accept both formats for user convenience but normalize to what Caqti expects.

    @param url Database URL
    @return Normalized URL
*)
val normalize_url : string -> string

(** Detect database type from URL scheme
    @param url Database URL (e.g., "postgresql://...", "sqlite3://...")
    @return Ok dialect or Error message for unsupported schemes
*)
val detect_from_url : string -> (t, string) result

(** Get dialect module for database type
    @param db_type Database type
    @return First-class module implementing DIALECT
*)
val get_dialect : t -> (module DIALECT)

(** Pretty-print database type
    @param t Database type
    @return Human-readable string
*)
val to_string : t -> string
