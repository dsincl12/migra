# Migris Test Suite

The test suite is split into **unit tests** and **integration tests** for fast feedback during development.

## Running Tests

### Unit Tests (Fast - No Database Required)

```bash
dune runtest
```

Runs in ~0.01 seconds. Includes:
- SQL Parser tests
- Type conversion tests
- Migration filename parsing
- File discovery logic

### Integration Tests (Requires PostgreSQL)

```bash
dune build @runtest-integration
```

Runs in ~2 seconds. Includes:
- Database operations
- Migration execution
- Schema management
- End-to-end workflows

Requires PostgreSQL running and accessible via `DATABASE_URL` environment variable or default connection (`postgresql://localhost:5432/postgres`).

### All Tests

```bash
dune runtest && dune build @runtest-integration
```

Runs both unit and integration tests.

## Test Organization

- `test_unit.ml` - Entry point for unit tests
- `test_integration.ml` - Entry point for integration tests
- `test_helpers.ml` - Shared test utilities and database pooling
- `test_sql_parser.ml` - Pure unit tests
- `test_types.ml` - Pure unit tests
- `test_migration.ml` - Pure unit tests (filename parsing)
- `test_discovery.ml` - Pure unit tests (file discovery)
- `test_database.ml` - Integration tests (DB operations)
- `test_runner.ml` - Integration tests (migration execution)
- `test_schema_integration.ml` - Integration tests (schema management)
- `test_e2e.ml` - Integration tests (end-to-end workflows)

## Database Pooling

Integration tests use a pool of 3 databases that are reused across tests. Each test gets a clean slate by dropping all tables between runs. This is **~40x faster** than creating/dropping databases for each test.
