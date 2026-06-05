# Testing Migra Locally (Before Publishing to Opam)

This guide shows you how to test Migra by building a minimal Dream web application that runs migrations on startup.

---

## Part 1: Install Migra from Source

```bash
# Navigate to the migra project
cd /path/to/migra

# Pin and install migra
opam pin add migra . -y

# Install SQLite driver
opam install caqti-driver-sqlite3
```

**Verify installation:**
```bash
migra --version
# Should show: 0.1.0

ocamlfind query migra
# Should show: ~/.opam/<switch>/lib/migra
```

---

## Part 2: Create a Minimal Dream App

### Step 1: Initialize Project

```bash
cd ~
dune init project todo_app
cd todo_app

mkdir migrations

# Install dependencies
opam install dream
```

### Step 2: Configure Project

Update `dune-project`:

```bash
cat > dune-project << 'EOF'
(lang dune 3.12)
(name todo_app)

(generate_opam_files true)

(package
 (name todo_app)
 (depends
   (ocaml (>= 5.0.0))
   (dune (>= 3.12))
   (dream (>= 1.0.0))
   (migra (>= 0.1.0))
   (lwt (>= 5.6.0))))
EOF
```

### Step 3: Create Migrations

```bash
export DATABASE_URL="sqlite3://./app.db"

migra generate create_todos
```

Edit the migration:

```bash
cat > migrations/*_create_todos.sql << 'EOF'
-- +migrate up
CREATE TABLE todos (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL,
  completed INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

-- +migrate down
DROP TABLE todos;
EOF
```

Create a second migration:

```bash
migra generate add_description_to_todos
```

```bash
cat > migrations/*_add_description_to_todos.sql << 'EOF'
-- +migrate up
ALTER TABLE todos ADD COLUMN description TEXT;

-- +migrate down
ALTER TABLE todos DROP COLUMN description;
EOF
```

### Step 4: Build the Application

Update `bin/dune`:

```bash
cat > bin/dune << 'EOF'
(executable
 (public_name todo_app)
 (name main)
 (libraries dream migra lwt lwt.unix))
EOF
```

Create `bin/main.ml`:

```bash
cat > bin/main.ml << 'EOF'
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
  Lwt_main.run (run_migrations ());

  Dream.run ~port:8080
  @@ Dream.logger
  @@ Dream.router [
    Dream.get "/" (fun _ ->
      Dream.json {|{"message": "Hello, Migra world!"}|});
  ]
EOF
```

### Step 5: Run the Application

```bash
dune build

export DATABASE_URL="sqlite3://./app.db"
dune exec todo_app
```

**Expected output:**
```
Migrations complete: 2 succeeded, 0 failed

[Dream server started on http://localhost:8080]
```

Visit **http://localhost:8080**:
```json
{"message": "Hello, Migra world!"}
```

---

## Part 3: Test the Workflow

### Test 1: Fresh Database

```bash
rm -f app.db
dune exec todo_app
```

**Expected:** Migrations run, server starts

### Test 2: Existing Database

```bash
dune exec todo_app
```

**Expected:** `0 succeeded, 0 failed` (migrations already applied)

### Test 3: Add New Migration

**Terminal 1 (app running):**
```bash
dune exec todo_app
```

**Terminal 2:**
```bash
migra generate add_priority
cat > migrations/*_add_priority.sql << 'EOF'
-- +migrate up
ALTER TABLE todos ADD COLUMN priority INTEGER NOT NULL DEFAULT 0;

-- +migrate down
ALTER TABLE todos DROP COLUMN priority;
EOF

migra migrate
```

**Terminal 1:** Restart app (Ctrl+C, then `dune exec todo_app`)

**Expected:** New migration runs automatically

### Test 4: CLI Commands

```bash
migra status         # Show all migrations
migra rollback       # Rollback last migration
migra reset          # Drop, create, run all migrations
```

---

## Part 4: Multi-Database Testing

### PostgreSQL

```bash
createdb todo_app_pg
opam install caqti-driver-postgresql

export DATABASE_URL="postgresql://localhost:5432/todo_app_pg"
dune exec todo_app
```

### MariaDB

```bash
mysql -e "CREATE DATABASE todo_app_maria"
opam install caqti-driver-mariadb

export DATABASE_URL="mariadb://root@localhost:3306/todo_app_maria"
dune exec todo_app
```

---

## Verification Checklist

- Migrations run automatically on startup
- App starts and responds with JSON
- New migrations apply on restart
- CLI commands work alongside the app
- Works with SQLite, PostgreSQL, MariaDB

---

## Cleanup

```bash
opam pin remove migra
rm -rf ~/todo_app
```

---

## Quick Reference

**Application Pattern:**
```ocaml
let () =
  Lwt_main.run (run_migrations ());
  Dream.run @@ Dream.router [...]
```

**CLI Commands:**
```bash
migra generate <name>  # Generate migration
migra migrate          # Run pending migrations
migra status           # Show migration status
migra rollback         # Rollback last migration
migra reset            # Drop, create, migrate
```

---

**That's it!** A minimal working example of Migra with automatic migrations.
