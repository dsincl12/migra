# Migris

A database migration tool and library for OCaml and PostgreSQL.

Write plain SQL migrations with up/down sections. Run them with transaction safety. Roll them back when needed. Use the CLI for day-to-day development or the library for programmatic control.

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
- [CLI Quick Start](#cli-quick-start)
- [CLI Commands](#cli-commands)
- [Using as a Library](#using-as-a-library)
- [Configuration](#configuration)
- [How It Works](#how-it-works)
- [Troubleshooting](#troubleshooting)

## Installation

**Prerequisites:** OCaml ≥ 5.0, Opam ≥ 2.0, PostgreSQL ≥ 13, Dune ≥ 2.7

```bash
# Install system dependencies (macOS)
brew install postgresql libpq pkg-config
export PKG_CONFIG_PATH="/opt/homebrew/opt/libpq/lib/pkgconfig:$PKG_CONFIG_PATH"

# Install OCaml dependencies
opam install lwt caqti caqti-lwt caqti-driver-postgresql uri cmdliner

# Build Migris
git clone <your-repo-url>
cd migris
dune build

# Optional: create alias
alias migris="_build/default/bin/main.exe"
```

## CLI Quick Start

```bash
# 1. Set your database connection
export DATABASE_URL="postgresql://user@localhost:5432/myapp"

# 2. Create the database
migris init
# Creating database: myapp
# Database 'myapp' created successfully
#
# Run 'migris migrate' to apply migrations

# 3. Create your first migration
migris create create_users_table
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
migris migrate
# == Running 20240115120000_create_users_table.sql
# == Migrated 20240115120000 in 0.045s

# 5. Check status
migris status
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
migris init
# Creating database: myapp
# Database 'myapp' created successfully
#
# Run 'migris migrate' to apply migrations
```

**Create database and run all migrations:**
```bash
migris setup
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
migris drop
# Dropping database: myapp
# Database 'myapp' dropped successfully
```

**Reset (drop + recreate + migrate):**
```bash
migris reset
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
migris create add_email_to_users
# Creating migrations/20240115130000_add_email_to_users.sql
```

**Run pending migrations:**
```bash
migris migrate
# == Running 20240115130000_add_email_to_users.sql
# == Migrated 20240115130000 in 0.032s
```

**Show migration status:**
```bash
migris status
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
migris rollback
# == Rolling back 20240115130000_add_email_to_users.sql
# == Rolled back 20240115130000 in 0.028s
```

**Rollback last N migrations:**
```bash
migris rollback --step 2
# == Rolling back 20240116090000_create_posts_table.sql
# == Rolled back 20240116090000 in 0.025s
#
# == Rolling back 20240115130000_add_email_to_users.sql
# == Rolled back 20240115130000 in 0.023s
```

**Rollback to specific version (exclusive):**
```bash
migris rollback --to 20240115120000
# == Rolling back 20240116090000_create_posts_table.sql
# == Rolled back 20240116090000 in 0.025s
#
# == Rolling back 20240115130000_add_email_to_users.sql
# == Rolled back 20240115130000 in 0.023s
```
The target version (20240115120000) remains applied.

**Rollback all migrations:**
```bash
migris rollback --all
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
migris migrate --verbose
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

Migris tracks migrations in a `schema_migrations` table:

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

## Working Example

```bash
export DATABASE_URL="postgresql://alice@localhost:5432/blog"

# Create database
migris init
# Creating database: blog
# Database 'blog' created successfully

# Create migration
migris create create_posts_table
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
migris migrate
# == Running 20240115120000_create_posts_table.sql
# == Migrated 20240115120000 in 0.045s

# Create another migration
migris create add_published_flag
# Creating migrations/20240115130000_add_published_flag.sql

# Edit it
cat > migrations/20240115130000_add_published_flag.sql << 'EOF'
-- +migrate up
ALTER TABLE posts ADD COLUMN published BOOLEAN DEFAULT FALSE;

-- +migrate down
ALTER TABLE posts DROP COLUMN published;
EOF

# Run it
migris migrate
# == Running 20240115130000_add_published_flag.sql
# == Migrated 20240115130000 in 0.032s

# Check status
migris status
#
# Database: postgresql://alice@localhost:5432/blog
#
# Status    Migration ID    Migration Name
# --------------------------------------------------
# up        20240115120000  create_posts_table
# up        20240115130000  add_published_flag

# Made a mistake? Roll back the last one
migris rollback
# == Rolling back 20240115130000_add_published_flag.sql
# == Rolled back 20240115130000 in 0.028s

# Fix and re-run
migris migrate
# == Running 20240115130000_add_published_flag.sql
# == Migrated 20240115130000 in 0.032s

# Need a fresh start?
migris reset
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

Set `DATABASE_URL` environment variable:

```bash
export DATABASE_URL="postgresql://[user[:password]@][host][:port]/database"
```

Examples:
```bash
export DATABASE_URL="postgresql://alice@localhost:5432/myapp"
export DATABASE_URL="postgresql://alice:secret@localhost:5432/myapp"
export DATABASE_URL="postgresql://user@db.example.com:5432/production"
```

## Using as a Library

Migris can be embedded in your OCaml applications for programmatic migration control.

### Installation

Add to your `dune` file:
```dune
(executable
 (name my_app)
 (libraries migris))
```

Or in `dune-project`:
```dune
(package
 (name my_app)
 (depends
   (migris (>= 0.1.0))))
```

### Basic Usage

```ocaml
open Lwt.Infix

let run_migrations () =
  let config = Migris.Migrator.{
    database_url = "postgresql://localhost/myapp";
    migrations_dir = "migrations";
    verbose = false;
  } in

  Lwt_main.run (
    Migris.Migrator.run config >>= function
    | Ok result ->
        Printf.printf "Successfully ran %d migrations\n" result.success_count;
        Lwt.return_unit
    | Error msg ->
        Printf.eprintf "Migration failed: %s\n" msg;
        exit 1
  )
```

### Running Migrations

```ocaml
let config = Migris.Migrator.{
  database_url = "postgresql://localhost/myapp";
  migrations_dir = "db/migrations";
  verbose = false;
}

(* Run all pending migrations *)
Migris.Migrator.run config >>= function
| Ok result ->
    Printf.printf "Migrations: %d succeeded, %d failed\n"
      result.success_count result.failure_count;
    List.iter (fun m ->
      if m.Migris.Migrator.success then
        Printf.printf " %Ld: %s\n" m.version m.description
      else
        Printf.printf " %Ld: %s - %s\n"
          m.version m.description
          (Option.value ~default:"unknown error" m.error)
    ) result.migrations;
    Lwt.return_unit
| Error msg ->
    Printf.eprintf "Error: %s\n" msg;
    Lwt.return_unit
```

### Rolling Back Migrations

```ocaml
(* Rollback last migration *)
let rollback_one config =
  Migris.Migrator.rollback config (Step 1)

(* Rollback last 3 migrations *)
let rollback_three config =
  Migris.Migrator.rollback config (Step 3)

(* Rollback to specific version (exclusive) *)
let rollback_to config =
  Migris.Migrator.rollback config (To 20240115120000L)

(* Rollback all migrations *)
let rollback_all config =
  Migris.Migrator.rollback config All
```

### Checking Migration Status

```ocaml
Migris.Migrator.status config >>= function
| Ok status ->
    Printf.printf "Database: %s\n" status.database_url;
    Printf.printf "Applied: %d | Pending: %d\n"
      status.applied_count status.pending_count;

    List.iter (fun m ->
      let status_str = if m.Migris.Migrator.applied then "up" else "down" in
      Printf.printf "  [%s] %Ld: %s\n"
        status_str m.version m.description
    ) status.migrations;
    Lwt.return_unit
| Error msg ->
    Printf.eprintf "Error: %s\n" msg;
    Lwt.return_unit
```

### API Reference

The library provides three main functions:

**`Migris.Migrator.run`** - Execute pending migrations
- Returns: `(operation_result, string) Lwt_result.t`
- Runs all pending migrations in chronological order
- Stops at first failure

**`Migris.Migrator.rollback`** - Rollback migrations
- Strategies: `Step of int`, `To of int64`, `All`
- Returns: `(operation_result, string) Lwt_result.t`
- Executes down SQL in reverse chronological order

**`Migris.Migrator.status`** - Inspect migration status
- Returns: `(status_result, string) Lwt_result.t`
- Lists all migrations with applied/pending status

For database lifecycle (create/drop databases) and file generation, use the CLI commands.

## Troubleshooting

**Can't connect to database:**
```bash
echo $DATABASE_URL                        # Check it's set
psql $DATABASE_URL -c "SELECT 1"          # Test connection
brew services list | grep postgresql      # Check PostgreSQL is running
```

**PostgreSQL driver won't install:**
```bash
export PKG_CONFIG_PATH="/opt/homebrew/opt/libpq/lib/pkgconfig:$PKG_CONFIG_PATH"
opam install caqti-driver-postgresql
```

**Migration failed:**
Don't worry - it was rolled back completely. Fix your SQL and run `migris migrate` again.

## License

See LICENSE file.

---

**Built with OCaml  | Powered by PostgreSQL **
