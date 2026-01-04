# Changelog

All notable changes to Migra will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Multi-database support - Migra now supports PostgreSQL, MariaDB/MySQL, and SQLite
  - Automatic database detection from DATABASE_URL scheme
  - PostgreSQL support: `postgresql://` or `postgres://`
  - MariaDB/MySQL support: `mariadb://` or `mysql://`
  - SQLite support: `sqlite3://` (file-based and `:memory:`)
- Dialect abstraction layer (`lib/dialect.ml`)
  - Database-specific SQL generation (CREATE DATABASE, timestamp casting, etc.)
  - Configurable schema_migrations table DDL per database
  - Support for database lifecycle operations (create/drop) with dialect-aware handling
- SQLite-specific features
  - File-based databases with automatic file creation
  - In-memory databases for testing (`sqlite3://:memory:`)
  - Special handling for file operations (no CREATE/DROP DATABASE SQL)
- Comprehensive documentation
  - `README.md`: Multi-database examples, installation for all databases, SQL portability guide
  - `TROUBLESHOOTING.md`: Database-specific issues, driver installation, connection troubleshooting
  - `DATABASE_COMPARISON.md`: Feature comparison, when to use each database, migration portability guide
- Improved error messages
  - Helpful error message for unsupported DATABASE_URL schemes with examples
  - Clear indication of supported database types (PostgreSQL, MariaDB, SQLite)
  - Reference to DATABASE_COMPARISON.md for help choosing a database
- Verbose output enhancements
  - Shows database type when running with `--verbose` flag
  - Example: `[INFO] Using PostgreSQL database`
  - Available in `migrate`, `rollback`, `setup`, and `reset` commands
- Comprehensive test coverage
  - 64 unit tests (including dialect detection and SQL generation)
  - 13 SQLite integration tests (file-based and `:memory:` databases)
  - 12 MariaDB integration tests (database lifecycle, InnoDB engine verification)
  - All existing PostgreSQL tests passing with dialect abstraction
  - Total: 92 integration tests + 64 unit tests = 156 tests (100% passing)

### Changed
- Dependencies (breaking: requires new database drivers)
  - Added `caqti-driver-mariadb` (>= 2.0.0) for MariaDB/MySQL support
  - Added `caqti-driver-sqlite3` (>= 2.0.0) for SQLite support
  - Existing `caqti-driver-postgresql` requirement unchanged
- Database module (`lib/database.ml`)
  - `create_database` and `drop_database` now dialect-aware
  - SQLite uses file operations instead of SQL for database lifecycle
  - Automatic admin database connection based on dialect (postgres, mysql, or N/A)
- Runner module (`lib/runner.ml`)
  - `ensure_migrations_table` now accepts dialect parameter for database-specific DDL
  - Timestamp queries now use dialect-specific casting (PostgreSQL `::text`, MariaDB `CAST()`, SQLite direct)
  - Migration functions thread dialect through call chain
- Commands module (`bin/commands.ml`)
  - All commands (`migrate`, `rollback`, `setup`, `reset`) detect and use appropriate dialect
  - Verbose mode shows database type being used

### Fixed
- MariaDB database existence check now returns boolean correctly (using `EXISTS()`)
- Cross-database compatibility for `schema_migrations` table creation

## [0.1.0] - Initial Release

### Added
- PostgreSQL database migration support
- CLI commands: `init`, `migrate`, `rollback`, `status`, `create`, `setup`, `reset`, `drop`
- Transaction-wrapped migration execution with automatic rollback on failure
- Up/down migration support with `-- +migrate up` and `-- +migrate down` markers
- Rollback strategies: last N migrations, to specific version, or all migrations
- Verbose mode (`--verbose`) for detailed SQL execution logging
- Migration file generator with timestamp-based versioning
- OCaml library API for programmatic migration control
- Comprehensive test suite

---

## Migration Guide

### Upgrading to Multi-Database Support

If you're upgrading from the PostgreSQL-only version:

1. **Install additional drivers** (if you plan to use them):
   ```bash
   # For MariaDB/MySQL:
   brew install mariadb-connector-c
   opam install caqti-driver-mariadb

   # For SQLite:
   opam install caqti-driver-sqlite3
   ```

2. **DATABASE_URL format unchanged for PostgreSQL users**:
   ```bash
   # Your existing PostgreSQL URLs continue to work:
   export DATABASE_URL="postgresql://user@localhost:5432/mydb"
   ```

3. **New URL schemes available**:
   ```bash
   # Switch to MariaDB:
   export DATABASE_URL="mariadb://user@localhost:3306/mydb"

   # Switch to SQLite (perfect for development!):
   export DATABASE_URL="sqlite3://./dev.db"
   ```

4. **No code changes required** - Migra auto-detects the database type from the URL scheme

### Breaking Changes

- New dependencies required: Installing Migra now requires all three database drivers by default
  - If you only need PostgreSQL, you can still use it exclusively (just ignore other drivers)
  - Future versions may make drivers optional (install only what you need)

### Compatibility

- Migration files: Existing PostgreSQL-specific SQL will continue to work with PostgreSQL
- Library API: No breaking changes to the public API
- CLI: All existing commands work identically
- Cross-database portability: Write portable SQL to run the same migrations on all three databases (see DATABASE_COMPARISON.md)

---

## Future Enhancements (Not Yet Implemented)

These features are planned but not yet available:

- Optional database drivers (install only what you need)
- Automatic SQL translation between database dialects
- Migration compatibility checker (warn about database-specific SQL)
- Connection pooling configuration per database type
- Database-specific optimizations (VACUUM, ANALYZE, etc.)
- Additional database support (Oracle, SQL Server, etc.)

---

For detailed information about supported databases, see [DATABASE_COMPARISON.md](DATABASE_COMPARISON.md).

For troubleshooting, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
