# Migra

[![OCaml](https://img.shields.io/badge/OCaml-%23EC6813.svg?style=flat&logo=ocaml&logoColor=white)](https://ocaml.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**A database migration tool and library for OCaml supporting PostgreSQL, MariaDB/MySQL, and SQLite.**

Write plain SQL migrations with up/down sections. Run them with transaction safety. Roll them back when needed. Use the CLI for day-to-day development or the library for programmatic control.

**Key Features:**
- Zero-configuration database detection - just set `DATABASE_URL` and Migra automatically detects your database type
- Transaction safety - automatic rollback on failure, no partial migrations
- Both CLI and Library - use the CLI for development, embed the library in your applications
- Flexible rollbacks - rollback by steps, to a version, or all at once
- Production-ready - battle-tested error handling and logging

## Features

**CLI:**
- Plain SQL migrations with up/down sections
- Transaction-wrapped execution (automatic rollback on failure)
- Database lifecycle commands (create, drop, reset)
- Rollback support (last migration, N steps, to version, or all)
- Verbose mode to see executed SQL
- Zero configuration (just `DATABASE_URL`)

**Library:**
- Programmatic migration execution
- Structured results for error handling
- Embeddable in applications
- Minimal API surface (run, rollback, status)

## Table of Contents

- [Installation](#installation)
- [Supported Databases](#supported-databases)
- [CLI Quick Start](#cli-quick-start)
- [CLI Commands](#cli-commands)
- [Working Example](#working-example)
- [Configuration](#configuration)
- [Using as a Library](#using-as-a-library)
  - [Quick Start: Application Integration](#quick-start-application-integration)
  - [API Reference](#api-reference)
  - [Error Handling](#error-handling)
- [How It Works](#how-it-works)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [Version Compatibility](#version-compatibility)
- [License](#license)

## Installation

**Prerequisites:** OCaml ≥ 5.4.0, Opam ≥ 2.0, Dune ≥ 3.20

### Quick Start

**Migra uses Caqti's dynamic driver loading** - install only the database driver(s) you need:

```bash
# 1. Install Migra CLI
opam install migra

# 2. Install driver for your database
# PostgreSQL:
opam install caqti-driver-postgresql

# OR MariaDB/MySQL:
opam install caqti-driver-mariadb

# OR SQLite:
opam install caqti-driver-sqlite3

# 3. Use it!
export DATABASE_URL="sqlite3://./dev.db"
migra init
migra generate create_users
migra migrate
```

**System dependencies:**

If using PostgreSQL or MariaDB, install system libraries first:

```bash
# PostgreSQL (macOS)
brew install libpq pkg-config
export PKG_CONFIG_PATH="/opt/homebrew/opt/libpq/lib/pkgconfig:$PKG_CONFIG_PATH"

# MariaDB (macOS)
brew install mariadb-connector-c

# SQLite - no system dependencies needed!
```

### CLI Installation Options

**PostgreSQL only:**
```bash
brew install libpq pkg-config
export PKG_CONFIG_PATH="/opt/homebrew/opt/libpq/lib/pkgconfig:$PKG_CONFIG_PATH"
opam install migra caqti-driver-postgresql
```

**SQLite only (easiest for development):**
```bash
opam install migra caqti-driver-sqlite3
# No system dependencies!
```

**MariaDB/MySQL only:**
```bash
brew install mariadb-connector-c
opam install migra caqti-driver-mariadb
```

**All databases:**
```bash
brew install libpq mariadb-connector-c pkg-config
export PKG_CONFIG_PATH="/opt/homebrew/opt/libpq/lib/pkgconfig:$PKG_CONFIG_PATH"
opam install migra caqti-driver-postgresql caqti-driver-mariadb caqti-driver-sqlite3
```

### Using as a Library

Same approach - install only what you need:

**PostgreSQL only:**
```bash
# System dependencies (macOS)
brew install postgresql libpq pkg-config
export PKG_CONFIG_PATH="/opt/homebrew/opt/libpq/lib/pkgconfig:$PKG_CONFIG_PATH"

# Install driver + migra
opam install caqti-driver-postgresql migra
```

**MariaDB/MySQL only:**
```bash
# System dependencies (macOS)
brew install mariadb-connector-c

# Install driver + migra
opam install caqti-driver-mariadb migra
```

**SQLite only:**
```bash
# No system dependencies needed on most systems!

# Install driver + migra
opam install caqti-driver-sqlite3 migra
```

**Multiple databases:**
```bash
# Install only what you need
opam install caqti-driver-postgresql caqti-driver-sqlite3 migra
```

Migra uses Caqti's dynamic driver loading - you only need to install drivers for the databases you'll actually use.

## Supported Databases

Migra automatically detects the database type from your `DATABASE_URL` scheme:

| Database   | URL Scheme              | Example                                    |
|------------|-------------------------|---------------------------------------------|
| PostgreSQL | `postgresql://` or `postgres://` | `postgresql://user@localhost:5432/mydb`   |
| MariaDB    | `mariadb://` or `mysql://` | `mariadb://user@localhost:3306/mydb`      |
| SQLite     | `sqlite3://`            | `sqlite3://./mydb.db`                      |
| SQLite     | `sqlite3://`            | `sqlite3://:memory:` (in-memory)           |

**Switching databases is as simple as changing the URL:**

```bash
# Development with SQLite (no database server needed!)
export DATABASE_URL="sqlite3://./dev.db"
migra migrate

# Production with PostgreSQL
export DATABASE_URL="postgresql://user@prod-db.example.com:5432/myapp"
migra migrate

# Testing with MariaDB
export DATABASE_URL="mariadb://root@localhost:3306/test_db"
migra migrate
```

All migration files are database-agnostic SQL, so they work across all supported databases (as long as you use compatible SQL syntax).

**Perfect for different environments:**
- SQLite for local development and testing (zero setup!)
- PostgreSQL or **MariaDB** for staging and production

## CLI Quick Start

**With PostgreSQL:**
```bash
# 1. Set your database connection
export DATABASE_URL="postgresql://user@localhost:5432/myapp"

# 2. Create the database
migra init
# Creating database: myapp
# Database 'myapp' created successfully
#

# 3. Create your first migration
migra generate create_users_table
# Creating migrations/20240115120000_create_users_table.sql
```

**With SQLite (perfect for development!):**
```bash
# 1. Set your database connection (no server needed!)
export DATABASE_URL="sqlite3://./dev.db"

# 2. Create the database (creates the file automatically)
migra init
# Creating database: ./dev.db
# Database './dev.db' created successfully
#

# 3. Create your first migration
migra generate create_users_table
# Creating migrations/20240115120000_create_users_table.sql
```

**With MariaDB/MySQL:**
```bash
# 1. Set your database connection
export DATABASE_URL="mariadb://root@localhost:3306/myapp"

# 2. Create the database
migra init
# Creating database: myapp
# Database 'myapp' created successfully
#

# 3. Create your first migration
migra generate create_users_table
# Creating migrations/20240115120000_create_users_table.sql
```

The generated file contains this template:

```sql
-- +migrate up


-- +migrate down

```

Edit it to add your SQL:

```sql
-- +migrate up
CREATE TABLE users (
  id SERIAL PRIMARY KEY,
  email VARCHAR(255) NOT NULL UNIQUE,
  name VARCHAR(100) NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_users_email ON users(email);

-- +migrate down
DROP TABLE users;
```

```bash
# 4. Run the migration
migra migrate
# == Running 20240115120000_create_users_table.sql
# == Migrated 20240115120000 in 0.045s

# 5. Check status
migra status
#
# Database: postgresql://user@localhost:5432/myapp
#
# Status    Migration ID    Migration Name
# --------------------------------------------------
# up        20240115120000  create_users_table
```

## CLI Commands

### Database Lifecycle

**Create database:**
```bash
migra init
# Creating database: myapp
# Database 'myapp' created successfully
#
```

**Create database and run all migrations:**
```bash
migra setup
# Creating database: myapp
# Database 'myapp' ready
#
# == Running 20240115120000_create_users_table.sql
# == Migrated 20240115120000 in 0.045s
#
# Setup complete!
```

**Drop database:**
```bash
migra drop
# Dropping database: myapp
# Database 'myapp' dropped successfully
```

**Reset (drop + recreate + migrate):**
```bash
migra reset
# Resetting database: myapp
#
# Dropping database...
# Database 'myapp' dropped
#
# Creating database...
# Database 'myapp' created
#
# == Running 20240115120000_create_users_table.sql
# == Migrated 20240115120000 in 0.045s
#
# Reset complete!
```

### Migrations

**Create new migration:**
```bash
migra generate add_email_to_users
# Creating migrations/20240115130000_add_email_to_users.sql
```

**Run pending migrations:**
```bash
migra migrate
# == Running 20240115130000_add_email_to_users.sql
# == Migrated 20240115130000 in 0.032s
```

**Show migration status:**
```bash
migra status
#
# Database: postgresql://user@localhost:5432/myapp
#
# Status    Migration ID    Migration Name
# --------------------------------------------------
# up        20240115120000  create_users_table
# up        20240115130000  add_email_to_users
# down      20240116090000  create_posts_table
```

### Rollbacks

**Rollback last migration:**
```bash
migra rollback
# == Rolling back 20240115130000_add_email_to_users.sql
# == Rolled back 20240115130000 in 0.028s
```

**Rollback last N migrations:**
```bash
migra rollback --step 2
# == Rolling back 20240116090000_create_posts_table.sql
# == Rolled back 20240116090000 in 0.025s
#
# == Rolling back 20240115130000_add_email_to_users.sql
# == Rolled back 20240115130000 in 0.023s
```

**Rollback to specific version (exclusive):**
```bash
migra rollback --to 20240115120000
# == Rolling back 20240116090000_create_posts_table.sql
# == Rolled back 20240116090000 in 0.025s
#
# == Rolling back 20240115130000_add_email_to_users.sql
# == Rolled back 20240115130000 in 0.023s
```
The target version (20240115120000) remains applied.

**Rollback all migrations:**
```bash
migra rollback --all
# == Rolling back 20240116090000_create_posts_table.sql
# == Rolled back 20240116090000 in 0.025s
#
# == Rolling back 20240115130000_add_email_to_users.sql
# == Rolled back 20240115130000 in 0.023s
#
# == Rolling back 20240115120000_create_users_table.sql
# == Rolled back 20240115120000 in 0.024s
```

### Verbose Mode

Add `--verbose` to see SQL execution:

```bash
migra migrate --verbose
# == Running 20240115120000_create_users_table.sql
# [SQL] BEGIN
# [SQL] CREATE TABLE users (id SERIAL PRIMARY KEY, email VARCHAR(255) NOT NULL UNIQUE, ...)
# [SQL] CREATE INDEX idx_users_email ON users(email)
# [SQL] INSERT INTO schema_migrations (version) VALUES (20240115120000)
# [SQL] COMMIT
# == Migrated 20240115120000 in 0.045s
```

Works with: `migrate`, `rollback`, `setup`, `reset`

## How It Works

Migra tracks migrations in a `schema_migrations` table:

```sql
CREATE TABLE schema_migrations (
  version BIGINT PRIMARY KEY,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
)
```

Every migration runs in a transaction:

```sql
BEGIN;
  -- Your SQL from "-- +migrate up" section
  INSERT INTO schema_migrations (version) VALUES (20240115120000);
COMMIT;
```

If anything fails, the transaction rolls back completely. No partial migrations, no inconsistent state.

Migration files use timestamp-based versioning (`YYYYMMDDHHMMSS_description.sql`) and run in chronological order.

### Cross-Database SQL Portability

Migra supports PostgreSQL, MariaDB/MySQL, and SQLite, but you're responsible for writing SQL that works across your target databases. Here are common differences to be aware of:

| Feature | PostgreSQL | MariaDB/MySQL | SQLite |
|---------|-----------|---------------|--------|
| **Auto-increment** | `SERIAL` or `BIGSERIAL` | `AUTO_INCREMENT` | `AUTOINCREMENT` |
| **Boolean** | `BOOLEAN` | `TINYINT(1)` or `BOOLEAN` | `INTEGER` (0/1) |
| **JSON** | `JSON` or `JSONB` | `JSON` | `TEXT` |
| **Timestamp** | `TIMESTAMP` | `TIMESTAMP` or `DATETIME` | `TEXT`, `INTEGER`, or `REAL` |
| **String concat** | `\|\|` or `CONCAT()` | `CONCAT()` | `\|\|` |

**Tips for portable migrations:**
- Use standard SQL types when possible (`VARCHAR`, `INTEGER`, `TEXT`)
- Test migrations on all databases you plan to support
- Use conditional migrations if you need database-specific features
- Keep complex queries database-agnostic or maintain separate migration sets

## Working Example

```bash
export DATABASE_URL="postgresql://alice@localhost:5432/blog"

# Create database
migra init
# Creating database: blog
# Database 'blog' created successfully

# Create migration
migra generate create_posts_table
# Creating migrations/20240115120000_create_posts_table.sql

# Edit the file
cat > migrations/20240115120000_create_posts_table.sql << 'EOF'
-- +migrate up
CREATE TABLE posts (
  id SERIAL PRIMARY KEY,
  title VARCHAR(255) NOT NULL,
  body TEXT NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- +migrate down
DROP TABLE posts;
EOF

# Run it
migra migrate
# == Running 20240115120000_create_posts_table.sql
# == Migrated 20240115120000 in 0.045s

# Create another migration
migra generate add_published_flag
# Creating migrations/20240115130000_add_published_flag.sql

# Edit it
cat > migrations/20240115130000_add_published_flag.sql << 'EOF'
-- +migrate up
ALTER TABLE posts ADD COLUMN published BOOLEAN DEFAULT FALSE;

-- +migrate down
ALTER TABLE posts DROP COLUMN published;
EOF

# Run it
migra migrate
# == Running 20240115130000_add_published_flag.sql
# == Migrated 20240115130000 in 0.032s

# Check status
migra status
#
# Database: postgresql://alice@localhost:5432/blog
#
# Status    Migration ID    Migration Name
# --------------------------------------------------
# up        20240115120000  create_posts_table
# up        20240115130000  add_published_flag

# Made a mistake? Roll back the last one
migra rollback
# == Rolling back 20240115130000_add_published_flag.sql
# == Rolled back 20240115130000 in 0.028s

# Fix and re-run
migra migrate
# == Running 20240115130000_add_published_flag.sql
# == Migrated 20240115130000 in 0.032s

# Need a fresh start?
migra reset
# Resetting database: blog
#
# Dropping database...
# Database 'blog' dropped
#
# Creating database...
# Database 'blog' created
#
# == Running 20240115120000_create_posts_table.sql
# == Migrated 20240115120000 in 0.045s
#
# == Running 20240115130000_add_published_flag.sql
# == Migrated 20240115130000 in 0.032s
#
# Reset complete!
```

## Configuration

Set `DATABASE_URL` environment variable. Migra automatically detects the database type from the URL scheme.

**PostgreSQL:**
```bash
export DATABASE_URL="postgresql://[user[:password]@][host][:port]/database"

# Examples:
export DATABASE_URL="postgresql://alice@localhost:5432/myapp"
export DATABASE_URL="postgresql://alice:secret@localhost:5432/myapp"
export DATABASE_URL="postgresql://user@db.example.com:5432/production"
```

**MariaDB/MySQL:**
```bash
export DATABASE_URL="mariadb://[user[:password]@][host][:port]/database"
# or
export DATABASE_URL="mysql://[user[:password]@][host][:port]/database"

# Examples:
export DATABASE_URL="mariadb://root@localhost:3306/myapp"
export DATABASE_URL="mariadb://user:pass@localhost:3306/myapp"
export DATABASE_URL="mysql://admin@db.example.com:3306/production"
```

**SQLite:**
```bash
# File-based (relative path):
export DATABASE_URL="sqlite3://./dev.db"
export DATABASE_URL="sqlite3://./database/myapp.db"

# File-based (absolute path):
export DATABASE_URL="sqlite3:///absolute/path/to/myapp.db"

# In-memory (perfect for testing):
export DATABASE_URL="sqlite3://:memory:"
```

## Using as a Library

Migra can be embedded in your OCaml applications for programmatic migration control. This is ideal for running migrations automatically on application startup or integrating migrations into your deployment pipeline.

### Installation

**Important:** Migra uses Caqti's dynamic driver loading. You must install the database driver(s) you need separately.

Add to your `dune` file:
```dune
(executable
 (name my_app)
 (libraries migra lwt lwt.unix caqti-driver-postgresql))  ; Add only the drivers you need
```

Or in `dune-project`:
```dune
(package
 (name my_app)
 (depends
   (migra (>= 0.1.0))
   (lwt (>= 5.6.0))
   (caqti-driver-postgresql (>= 2.0.0))))  ; Install only what you use
```

**Available drivers:**
- `caqti-driver-postgresql` - For PostgreSQL
- `caqti-driver-mariadb` - For MariaDB/MySQL
- `caqti-driver-sqlite3` - For SQLite

You can install multiple drivers if your app supports multiple databases.

### Quick Start: Application Integration

Here's a complete example showing how to run migrations on application startup:

```ocaml
open Lwt.Infix

(* Get database URL from environment or use default *)
let database_url =
  match Sys.getenv_opt "DATABASE_URL" with
  | Some url -> url
  | None -> "sqlite3://./app.db"

(* Run migrations on startup *)
let run_migrations () =
  let config = Migra.Migrator.{
    database_url;
    migrations_dir = "migrations";
    verbose = true;
  } in

  Migra.Migrator.run config >>= function
  | Error err ->
      Lwt_io.eprintlf "Migration failed: %s" (Migra.Types.show_error err) >>= fun () ->
      Lwt.fail_with "Database migration failed"
  | Ok result ->
      Lwt_io.printlf "Migrations complete: %d succeeded, %d failed"
        result.success_count result.failure_count >>= fun () ->
      if result.failure_count > 0 then
        Lwt.fail_with "Some migrations failed"
      else
        Lwt.return_unit

(* Main application *)
let () =
  (* Run migrations first *)
  Lwt_main.run (run_migrations ());

  (* Then start your application *)
  print_endline "Starting application...";
  (* Your app code here *)
```

This pattern ensures your database is always up-to-date when your application starts.

### Running Migrations

```ocaml
let config = Migra.Migrator.{
  database_url = "postgresql://localhost/myapp";
  migrations_dir = "db/migrations";
  verbose = false;
}

(* Run all pending migrations *)
Migra.Migrator.run config >>= function
| Ok result ->
    Printf.printf "Migrations: %d succeeded, %d failed\n"
      result.success_count result.failure_count;

    (* Print details for each migration *)
    List.iter (fun m ->
      if m.Migra.Migrator.success then
        Printf.printf "   %Ld: %s (%.3fs)\n"
          m.version m.description
          (Option.value ~default:0.0 m.elapsed_seconds)
      else
        Printf.printf "   %Ld: %s - %s\n"
          m.version m.description
          (Option.value ~default:"unknown error" m.error)
    ) result.migrations;
    Lwt.return_unit
| Error err ->
    Printf.eprintf "Migration error: %s\n" (Migra.Types.show_error err);
    Lwt.return_unit
```

### Rolling Back Migrations

```ocaml
open Lwt.Infix

(* Rollback last migration *)
let rollback_one config =
  Migra.Migrator.rollback config (Step 1) >>= function
  | Ok result ->
      Printf.printf "Rolled back %d migrations\n" result.success_count;
      Lwt.return_unit
  | Error err ->
      Printf.eprintf "Rollback failed: %s\n" (Migra.Types.show_error err);
      Lwt.return_unit

(* Rollback last 3 migrations *)
let rollback_three config =
  Migra.Migrator.rollback config (Step 3)

(* Rollback to specific version (exclusive) *)
let rollback_to config =
  Migra.Migrator.rollback config (To 20240115120000L)

(* Rollback all migrations *)
let rollback_all config =
  Migra.Migrator.rollback config All
```

### Checking Migration Status

```ocaml
Migra.Migrator.status config >>= function
| Ok status ->
    Printf.printf "Database: %s\n" status.database_url;
    Printf.printf "Applied: %d | Pending: %d\n"
      status.applied_count status.pending_count;
    Printf.printf "\nMigrations:\n";

    List.iter (fun m ->
      let status_str = if m.Migra.Migrator.applied then " up  " else " down" in
      let timestamp = match m.applied_at with
        | Some t -> Printf.sprintf " (applied: %s)" t
        | None -> ""
      in
      Printf.printf "  [%s] %Ld: %s%s\n"
        status_str m.version m.description timestamp
    ) status.migrations;
    Lwt.return_unit
| Error err ->
    Printf.eprintf "Status check failed: %s\n" (Migra.Types.show_error err);
    Lwt.return_unit
```

### Complete Example: Web Application with Auto-Migrations

This example demonstrates integrating Migra with a web framework (using Dream as an example):

```ocaml
open Lwt.Infix

let database_url =
  match Sys.getenv_opt "DATABASE_URL" with
  | Some url -> url
  | None -> "sqlite3://./app.db"

let run_migrations () =
  let config = Migra.Migrator.{
    database_url;
    migrations_dir = "migrations";
    verbose = true;
  } in

  Migra.Migrator.run config >>= function
  | Error err ->
      Lwt_io.eprintlf "Migration failed: %s" (Migra.Types.show_error err) >>= fun () ->
      Lwt.fail_with "Database migration failed"
  | Ok result ->
      Lwt_io.printlf "Migrations complete: %d succeeded, %d failed"
        result.success_count result.failure_count >>= fun () ->
      if result.failure_count > 0 then
        Lwt.fail_with "Some migrations failed"
      else
        Lwt.return_unit

let () =
  (* Run migrations before starting the server *)
  Lwt_main.run (run_migrations ());

  (* Start your web application *)
  Dream.run ~port:8080
  @@ Dream.logger
  @@ Dream.router [
    Dream.get "/" (fun _ ->
      Dream.json {|{"status": "ready"}|});
  ]
```

**To test this integration:**

1. Create a new project with migrations directory:
   ```bash
   mkdir -p my_app/migrations
   cd my_app
   ```

2. Add Migra to your dependencies and install drivers:
   ```bash
   opam install migra caqti-driver-sqlite3 dream
   ```

3. Generate a migration using the CLI:
   ```bash
   export DATABASE_URL="sqlite3://./app.db"
   migra generate create_users
   ```

4. Edit the generated migration file and add your schema

5. Build and run your application:
   ```bash
   dune build
   dune exec my_app
   ```

The migrations will run automatically before your application starts!

For a complete working example, see [TESTING_LOCALLY.md](TESTING_LOCALLY.md).

### API Reference

The library provides three main functions in the `Migra.Migrator` module:

**`run : config -> (operation_result, Types.error) Lwt_result.t`**
- Execute all pending migrations
- Runs migrations in chronological order
- Stops at first failure
- Returns detailed results for each migration

**`rollback : config -> rollback_strategy -> (operation_result, Types.error) Lwt_result.t`**
- Rollback migrations according to strategy
- Strategies: `Step of int`, `To of int64`, `All`
- Executes down SQL in reverse chronological order
- Stops at first failure

**`status : config -> (status_result, Types.error) Lwt_result.t`**
- Inspect current migration status
- Lists all migrations with applied/pending status
- Returns timestamps for applied migrations

**Configuration:**
```ocaml
type config = {
  database_url : string;      (* Database connection URL *)
  migrations_dir : string;    (* Directory containing .sql files *)
  verbose : bool;             (* Enable SQL statement logging *)
}
```

**Rollback strategies:**
```ocaml
type rollback_strategy =
  | Step of int         (* Rollback last N migrations *)
  | To of int64         (* Rollback to version (exclusive) *)
  | All                 (* Rollback all migrations *)
```

### Error Handling

All Migra functions return `Lwt_result.t` types. Use `Migra.Types.show_error` to get human-readable error messages:

```ocaml
Migra.Migrator.run config >>= function
| Ok result -> (* Handle success *)
| Error err ->
    Lwt_io.eprintlf "Error: %s" (Migra.Types.show_error err)
```

Common error types:
- Connection failures
- Invalid migration file format
- SQL execution errors
- Missing migrations directory
- Invalid database URL

### CLI vs Library

**Use the CLI for:**
- Database lifecycle operations (`init`, `drop`, `reset`, `setup`)
- Generating migration files (`generate`)
- Interactive development and testing

**Use the Library for:**
- Running migrations on application startup
- Integrating migrations into deployment pipelines
- Programmatic migration control
- Custom tooling and scripts

## Troubleshooting

### Connection Issues

**Can't connect to PostgreSQL:**
```bash
echo $DATABASE_URL                        # Check it's set
psql $DATABASE_URL -c "SELECT 1"          # Test connection
brew services list | grep postgresql      # Check PostgreSQL is running
```

**Can't connect to MariaDB:**
```bash
echo $DATABASE_URL                        # Check it's set
mysql -u root -e "SELECT 1"               # Test connection
brew services list | grep mariadb         # Check MariaDB is running (macOS)
# or
brew services list | grep mysql           # Check MySQL is running (macOS)
```

**SQLite file permission issues:**
```bash
# Check directory is writable
ls -ld $(dirname ./dev.db)
# Check file permissions if it exists
ls -l ./dev.db
```

### Driver Installation Issues

**PostgreSQL driver won't install:**
```bash
export PKG_CONFIG_PATH="/opt/homebrew/opt/libpq/lib/pkgconfig:$PKG_CONFIG_PATH"
opam install caqti-driver-postgresql
```

**MariaDB driver won't install:**
```bash
brew install mariadb-connector-c
opam install caqti-driver-mariadb
```

**SQLite driver won't install:**
```bash
# SQLite is usually included with the system, but if needed:
brew install sqlite3
opam install caqti-driver-sqlite3
```

### Migration Issues

**Migration failed:**
Don't worry - it was rolled back completely. Fix your SQL and run `migra migrate` again.

**Unsupported database URL scheme:**
```
Error: Unsupported database URL scheme
```
Make sure your `DATABASE_URL` starts with one of:
- `postgresql://` or `postgres://` for PostgreSQL
- `mariadb://` or `mysql://` for MariaDB/MySQL
- `sqlite3://` for SQLite

**SQLite in-memory database seems empty:**
SQLite `:memory:` databases only persist for the duration of the connection. Each new connection gets a fresh database. This is intentional and perfect for testing!

## Contributing

Contributions are welcome! Here's how you can help:

1. **Report bugs** - Open an issue describing the bug and how to reproduce it
2. **Suggest features** - Open an issue describing the feature and use case
3. **Submit pull requests** - Fork the repo, make your changes, and submit a PR

**Development setup:**
```bash
git clone https://github.com/dsincl12/migra.git
cd migra
opam install . --deps-only --with-test
dune build
dune runtest
```

**Running tests:**
```bash
# Unit tests
dune runtest

# Integration tests (requires PostgreSQL, MariaDB, and SQLite)
export DATABASE_URL="postgresql://localhost/migra_test"
dune runtest
```

## Version Compatibility

- OCaml: ≥ 5.4.0
- Dune: ≥ 3.20
- Caqti: ≥ 2.0.0
- Lwt: ≥ 5.6.0

**Database versions tested:**
- PostgreSQL: 14, 15, 16
- MariaDB: 10.6, 10.11, 11.0
- MySQL: 8.0
- SQLite: 3.40+

## License

MIT License - see [LICENSE](LICENSE) file for details.

Copyright (c) 2024 David Sinclair

## Links

- GitHub: [https://github.com/dsincl12/migra](https://github.com/dsincl12/migra)
- Documentation: [https://github.com/dsincl12/migra](https://github.com/dsincl12/migra)
- Issues: [https://github.com/dsincl12/migra/issues](https://github.com/dsincl12/migra/issues)

---

**Built with OCaml  | Powered by PostgreSQL  | MariaDB  | SQLite **
