# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and this project adheres to
[Semantic Versioning](https://semver.org/).

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
