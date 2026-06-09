# Migra

[![OCaml](https://img.shields.io/badge/OCaml-%23EC6813.svg?style=flat&logo=ocaml&logoColor=white)](https://ocaml.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A database migration tool **and** library for OCaml, supporting PostgreSQL,
MariaDB/MySQL, and SQLite. Write plain-SQL migrations with `up`/`down` sections;
run them from the CLI during development, or embed the library in your app and
migrate on startup.

```sh
migra generate create_users      # scaffold a timestamped migration
$EDITOR migrations/*_create_users.sql
migra migrate                    # apply pending migrations
migra status                     # see what's applied
```

## Features

- Three databases from one tool - PostgreSQL, MariaDB/MySQL, SQLite - chosen
  automatically from the connection URL.
- Plain SQL, with `up`/`down` sections in a single file. Full SQL is
  supported: dollar-quoted function bodies, `DELIMITER` for MySQL routines, and
  comments.
- Transaction-safe - each migration runs in a transaction and rolls back on
  failure (with a caveat for MySQL/MariaDB DDL - see [Safety](#safety--validation)).
- Checksums & drift detection - editing an already-applied migration, a
  missing migration file, or an out-of-order migration are all caught before
  anything runs.
- Flexible rollback - by step, to a version, or all; plus `redo`.
- `--dry-run` to preview, **`--database-url`** to override the environment,
  **`--table`** to customise the tracking table.
- CLI and library - the CLI is a thin layer over the public
  [`Migra.Migrator`](lib/migrator.mli) API.

## Installation

```sh
opam install migra
# plus the driver(s) you need (optional dependencies):
opam install caqti-driver-postgresql   # postgresql://, postgres://
opam install caqti-driver-mariadb      # mariadb://, mysql://
opam install caqti-driver-sqlite3      # sqlite3://
```

## Supported databases

Migra detects the database from the URL scheme:

| Database        | URL examples                                     |
| --------------- | ------------------------------------------------ |
| PostgreSQL      | `postgresql://user:pass@localhost:5432/mydb`     |
| MariaDB / MySQL | `mariadb://root@127.0.0.1:3306/mydb`, `mysql://...` |
| SQLite          | `sqlite3:./dev.db`, `sqlite3::memory:`           |

The URL comes from `--database-url` or the `DATABASE_URL` environment variable.
Percent-encode special characters in credentials (`@` -> `%40`).

## Migration files

Files are named `YYYYMMDDHHMMSS_description.sql` and contain two sections:

```sql
-- +migrate up
CREATE TABLE users (id SERIAL PRIMARY KEY, email TEXT NOT NULL);

-- +migrate down
DROP TABLE users;
```

For MySQL/MariaDB stored routines whose body contains semicolons, use a
`DELIMITER` directive (as you would in the `mysql` client):

```sql
-- +migrate up
DELIMITER //
CREATE PROCEDURE addrow(IN n INT) BEGIN INSERT INTO t VALUES (n); END //
DELIMITER ;
```

## CLI

```sh
export DATABASE_URL="postgresql://localhost:5432/myapp"

migra generate <name>     # create a new migration file
migra migrate             # apply all pending migrations
migra status              # show applied/pending migrations
migra rollback            # roll back the most recent migration
migra redo                # roll back the last migration and re-apply it
migra init                # create the database
migra setup               # create the database and migrate
migra drop                # drop the database
migra reset               # drop, recreate, and migrate
```

Common options: `-d/--dir DIR` (migrations directory, default `migrations`),
`-t/--table NAME` (tracking table, default `schema_migrations`),
`-D/--database-url URL`, `-v/--verbose`, and `--dry-run` (on `migrate` /
`rollback`). `rollback` also takes `--step N`, `--to VERSION`, `--all`.

## Library usage

Use the library to run migrations programmatically - for example, on web-app
startup. See [`examples/migrate_on_startup.ml`](examples/migrate_on_startup.ml).

```ocaml
let migrate () =
  let config = Migra.Migrator.make ~database_url:(Sys.getenv "DATABASE_URL") () in
  match Lwt_main.run (Migra.Migrator.run config) with
  | Error e ->
      Printf.eprintf "migration error: %s\n" (Migra.Types.show_error e); exit 1
  | Ok r when not (Migra.Migrator.succeeded r) ->
      Printf.eprintf "%d migration(s) failed\n" r.failure_count; exit 1
  | Ok r -> Printf.printf "applied %d migration(s)\n" r.success_count

(* e.g. before Dream.run: *)
let () = migrate (); Dream.run @@ Dream.logger @@ router
```

The public API is two modules:

- `Migra.Migrator` - `run`, `rollback`, `redo`, `status`, `generate`,
  `pending_plan`/`rollback_plan`; a `make` config constructor; and an optional
  `?on_event` callback for progress reporting.
- `Migra.Database` - database lifecycle (`create_database`, `drop_database`)
  and URL helpers.

`run`/`rollback` return `Error` only when migrations could not be run at all
(bad URL, connection failure, drift); a migration whose SQL fails surfaces as
`Ok` with `failure_count > 0` - check `Migra.Migrator.succeeded`.

## Safety & validation

- Checksums. When a migration is applied, a checksum of its file is stored.
  `migrate`, `rollback`, and `redo` re-validate applied migrations first and
  refuse to run if an applied file was modified after being applied or has gone
  missing; `migrate` additionally refuses a new migration that is older than the
  latest applied one. `status` does not fail on drift - it lists a missing
  applied file as `(migration file missing)` so the drift is visible.
- Transactions. On PostgreSQL and SQLite, migrations (including DDL) are
  fully transactional. **On MySQL/MariaDB, DDL statements implicitly commit and
  cannot be rolled back** - this is a server limitation, so keep MySQL/MariaDB
  migrations to a single DDL change each.

## Development

```sh
dune build
dune fmt              # format (ocamlformat)
dune runtest          # unit tests (no database needed)

# Integration tests need running databases; docker-compose.yml brings them up:
docker compose up -d --wait
DATABASE_URL=postgresql://postgres@localhost:5433/postgres \
MARIADB_URL=mariadb://root:root@127.0.0.1:3307/mysql \
  dune exec test/test_integration.exe
docker compose down
```

See [`docs/`](docs/) for [troubleshooting](docs/TROUBLESHOOTING.md) and [running the tests](docs/TESTING_LOCALLY.md).

## License

MIT License

Copyright (c) 2025 David Sinclair

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
