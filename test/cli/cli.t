Migra CLI end-to-end against SQLite (no database server required).

  $ export DATABASE_URL="sqlite3:./app.db"

generate creates one timestamped migration file in the chosen directory:

  $ migra generate -d gen add_widget > /dev/null
  $ ls gen/*.sql | wc -l | tr -d ' '
  1

Use a fixed-version migration so the apply/rollback output is deterministic:

  $ mkdir migrations
  $ cat > migrations/20240101120000_create_widgets.sql <<'EOF'
  > -- +migrate up
  > CREATE TABLE widgets (id INTEGER PRIMARY KEY, name TEXT);
  > -- +migrate down
  > DROP TABLE widgets;
  > EOF

init creates the database:

  $ migra init
  Creating database: ./app.db
  Database './app.db' created successfully

--dry-run shows the plan without applying:

  $ migra migrate --dry-run
  Would apply 1 migration(s):
    20240101120000  create_widgets

migrate applies the pending migration (the elapsed time is stripped):

  $ migra migrate | sed 's/ in [0-9.]*s$//'
  == Applying 20240101120000 create_widgets
  == Applied 20240101120000

status lists it as up:

  $ migra status | grep create_widgets
    up        20240101120000  create_widgets

re-running migrate finds nothing pending:

  $ migra migrate
  No pending migrations

rollback reverts it:

  $ migra rollback | sed 's/ in [0-9.]*s$//'
  == Rolling back 20240101120000 create_widgets
  == Rolled back 20240101120000

conflicting rollback selectors are rejected:

  $ migra rollback --all --step 2
  Error: --all cannot be combined with --to or --step
  [1]

drop removes the database:

  $ migra drop
  Dropping database: ./app.db
  Database './app.db' dropped successfully
