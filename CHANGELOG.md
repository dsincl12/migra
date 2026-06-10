# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and this project adheres to
[Semantic Versioning](https://semver.org/).

## 2.0.0

### Changed (breaking)
- The engine is no longer shipped as a separate public `migra.engine` library.
  Its modules (runner, SQL parser, dialect, discovery, migration, connection)
  are now private modules of `migra`, so code that reached into `Migra_engine.*`
  must use the public `Migra.*` API. The CLI and the `Migra.Database` /
  `Migra.Migrator` / `Migra.Types` / `Migra.Logging` facades are unchanged.
- `Migra.Migrator.rollback_strategy` is its own type rather than an alias of the
  engine's strategy type.
- Logging is no longer configured as a side effect of loading the library.
  Linking `migra` no longer installs a `Logs` reporter or sets the level; call
  `Migra.Logging.setup ()` to opt in (the CLI does this at startup).
- Removed the unused error variants `FileNotFound`, `DatabaseNotFound`, and
  `TransactionFailed`, and added `WriteError` for migration-file write failures.

### Added
- `generate` honors the `--dir` option (and `Migrator.generate ~migrations_dir`).

### Fixed
- The database lifecycle commands (`init`/`setup`/`drop`/`reset`) accept
  `sqlite3:path` URLs - the documented form, and what `sqlite3://` normalizes
  to - which previously failed with "invalid path format".
- `mysql://` connection URLs are rewritten to the `mariadb://` scheme the Caqti
  driver registers, so they connect instead of reporting a missing driver.
- A connection failure that merely mentions "not found" (a missing host, role,
  or database) is no longer misreported as a missing database driver.
- Migration version stamps are generated in UTC, so they no longer depend on the
  developer's timezone or DST.
- The `DELIMITER` directive is honored only for MySQL/MariaDB, so SQL beginning
  with the word "delimiter" is not misparsed on other dialects.
- The SQL splitter handles digit-led dollar tags (`$1$`), PostgreSQL `E'...'`
  escape strings, and backslash escapes inside MySQL double-quoted strings.
- Each migration file is read once when applied, so the recorded checksum always
  matches the SQL that ran.
- `status` and `migrate --dry-run` are read-only and no longer create the
  migrations-tracking table.
- Conflicting `rollback` selectors (`--all` with `--to` or `--step`) are
  rejected instead of silently ignored.
- A migration-file write failure is reported as a write error (no longer a read
  error) and no longer leaks the file descriptor.
- Removed a doubled blank line from applied/rolled-back migration output.

### Known limitations
- Migration atomicity has per-dialect limits: MySQL/MariaDB DDL implicitly
  commits, a `COMMIT`/`BEGIN` in a migration's own SQL ends Migra's wrapping
  transaction early, and on PostgreSQL a statement that returns rows (e.g.
  `SELECT setval(...)`) is rejected. See the Transactions notes in the README.

## 1.0.1

### Fixed
- `rollback` and `redo` now validate applied migrations against the files on
  disk before running and return `Error` on drift (a modified or missing
  applied migration), just like `migrate`. Previously they could roll back
  using modified down SQL or silently skip a migration whose file was gone.
- `status` now includes an applied migration whose file is missing (shown as
  `(migration file missing)`) instead of hiding it and understating the applied
  count.
- Database lifecycle commands (`create_database`/`drop_database`) now quote and
  escape the database identifier in the generated DDL, so PostgreSQL names such
  as `my-db` work and MariaDB names containing backticks are handled safely.

## 1.0.0

First stable release.

### Added
- Checksums & validation - each applied migration's file checksum is
  recorded; `migrate` refuses to run if an already-applied migration was
  modified (`ChecksumMismatch`) or its file went missing (`AppliedFileMissing`).
- Out-of-order detection - adding a migration older than the latest applied
  one is rejected (`OutOfOrder`).
- Configurable migrations table via `--table` / `Migrator.make ~table`.
- `redo` command and `Migrator.redo` - roll back the last migration(s) and
  re-apply.
- `--dry-run` for `migrate` and `rollback` - preview without changing the
  database.
- `--database-url` flag - overrides the `DATABASE_URL` environment variable.
- Library facade - `Migra.Migrator`
  (run/run_or_error/rollback/redo/status/generate, with `?on_event` progress
  callbacks) and `Migra.Database` (lifecycle + URL helpers) form the public API;
  the implementation lives in the internal `migra.engine` library.
- `Migra.Migrator.run_or_error` - a fail-fast wrapper around `run` for the
  migrate-on-startup path: a migration whose SQL fails is returned as `Error`
  (`MigrationError (ExecutionFailed ...)`) rather than `Ok` with
  `failure_count > 0`.
- Arbitrary SQL support: dollar-quoted bodies, `DELIMITER` for MySQL/MariaDB
  routines, line/block comments, and literal `$`/`?` in statements.

### Changed
- Credentials are masked (`*****`) in `status` output and never printed in clear.
- Stricter migration filenames: exactly 14 digits then `_<description>.sql`;
  malformed migration-shaped files are reported instead of silently skipped.
- `Migrator.run`/`rollback` return `Error` only when migrations could not run;
  per-migration SQL failures surface as `Ok` with `failure_count > 0` (see
  `Migrator.succeeded`).

### Fixed
- Connections are always closed (no leak), even on error paths.
- The admin connection URL preserves passwords, query parameters, and IPv6 hosts.
- Duplicate migration versions are detected and rejected.

### Known limitations
- On MySQL/MariaDB, DDL statements implicitly commit and cannot be rolled back,
  so a multi-statement DDL migration is **not** atomic there. Keep MySQL/MariaDB
  migrations to a single DDL change each. (PostgreSQL and SQLite are fully
  transactional, including DDL.)
