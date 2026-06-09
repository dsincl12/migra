# Migra Test Suite

The test suite is split into **unit tests** and **integration tests** for fast
feedback during development.

For the full local setup (database services, ports, environment variables), see
[../docs/TESTING_LOCALLY.md](../docs/TESTING_LOCALLY.md) - it is the source of
truth for how to run the integration suite. This file just describes how the
tests are organized.

## Running Tests

### Unit tests (fast - no database required)

```bash
dune runtest
```

Pure logic only: SQL splitting, error rendering, filename parsing, file
discovery, dialect/URL handling, and the public URL helpers. No database needed.

### Integration tests (require PostgreSQL, MariaDB, and SQLite)

```bash
dune build @runtest-integration
```

These exercise real databases. SQLite needs nothing; PostgreSQL is selected via
`DATABASE_URL` and MariaDB via `MARIADB_URL`. The exact URLs and a
`docker-compose.yml` that brings both servers up are documented in
[../docs/TESTING_LOCALLY.md](../docs/TESTING_LOCALLY.md). The suite creates and
drops its own throwaway databases on those servers.

## Test organization

Entry points and shared helpers:

- `test_unit.ml` - entry point for the unit suite
- `test_integration.ml` - entry point for the integration suite
- `test_helpers.ml` - shared utilities and the PostgreSQL test-database pool

Unit test modules:

- `test_sql_parser.ml` - SQL statement splitter
- `test_types.ml` - error rendering
- `test_migration.ml` - filename parsing, sections, checksums
- `test_discovery.ml` - migration file discovery
- `test_dialect.ml` - dialect detection and URL normalization
- `test_database_facade.ml` - `Migra.Database` URL helpers

Integration test modules:

- `test_database.ml` - database create/drop and connection handling
- `test_runner.ml` - migration execution against a real database
- `test_schema_integration.ml` - the `schema_migrations` table
- `test_migrator.ml` - the `Migra.Migrator` facade
- `test_e2e.ml` - multi-migration workflows through the runner
- `test_integration_sqlite.ml` - SQLite-specific behavior
- `test_integration_mariadb.ml` - MariaDB-specific behavior

## Database pooling

The integration suite reuses a small pool of PostgreSQL databases, giving each
test a clean slate by dropping all tables between runs instead of
creating/dropping a database per test. The pooled databases are dropped when the
run finishes.
