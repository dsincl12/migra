# Running the tests locally

Migra has two test suites:

- Unit tests - fast, no database required.
- Integration tests - exercise real PostgreSQL, MariaDB, and SQLite.

## Prerequisites

OCaml ≥ 4.14 with dune, then the project dependencies and the database drivers:

```sh
opam install . --deps-only --with-test
opam install caqti-driver-postgresql caqti-driver-mariadb caqti-driver-sqlite3
```

If a driver fails to build, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md)
(`PKG_CONFIG_PATH` for the system libraries).

## Build & unit tests

```sh
dune build
dune fmt          # check/apply formatting (ocamlformat)
dune runtest      # runs the unit suite - no database needed
```

## Integration tests

These need running databases. SQLite needs nothing; PostgreSQL uses `DATABASE_URL`
and MariaDB/MySQL use `MARIADB_URL`. A `docker-compose.yml` brings up Postgres,
MariaDB, and MySQL:

```sh
docker compose up -d --wait
```

Then run the integration suite (note `127.0.0.1` for MariaDB so it uses TCP, not
a Unix socket):

```sh
DATABASE_URL="postgresql://postgres@localhost:5433/postgres" \
MARIADB_URL="mariadb://root:root@127.0.0.1:3307/mysql" \
  dune exec test/test_integration.exe
```

The suite creates and drops its own throwaway databases on those servers. To run
a single suite or test, pass Alcotest arguments, e.g.:

```sh
dune exec test/test_integration.exe -- test E2E
```

## Cleanup

```sh
docker compose down
```
