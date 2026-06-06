# Troubleshooting

## "No database driver found for '...://'"

Migra loads its Caqti driver at runtime; the driver for your database must be
installed:

```sh
opam install caqti-driver-postgresql   # postgresql:// , postgres://
opam install caqti-driver-mariadb      # mariadb:// , mysql://
opam install caqti-driver-sqlite3      # sqlite3://
```

If the **opam build of a driver fails** to find the system C library, point
`PKG_CONFIG_PATH` at it (these are often keg-only on Homebrew):

```sh
# PostgreSQL (libpq)
brew install libpq
PKG_CONFIG_PATH="$(brew --prefix libpq)/lib/pkgconfig:$PKG_CONFIG_PATH" \
  opam install caqti-driver-postgresql

# MariaDB/MySQL (mariadb-connector-c) - also needs mariadb_config on PATH
brew install mariadb-connector-c
PATH="$(brew --prefix mariadb-connector-c)/bin:$PATH" \
PKG_CONFIG_PATH="$(brew --prefix mariadb-connector-c)/lib/pkgconfig:$PKG_CONFIG_PATH" \
  opam install caqti-driver-mariadb

# SQLite
brew install sqlite
PKG_CONFIG_PATH="$(brew --prefix sqlite)/lib/pkgconfig:$PKG_CONFIG_PATH" \
  opam install caqti-driver-sqlite3
```

## "Connection failure: ... Connection refused"

The server isn't reachable at the URL's host/port. Check it's running and the
port is right.

**MySQL/MariaDB specifically:** a host of `localhost` makes the client connect
over a **Unix socket** and *ignore the port*. To force TCP (e.g. to a container
on a mapped port), use `127.0.0.1`:

```
mariadb://root:root@127.0.0.1:3306/mydb     # TCP
mariadb://root:root@localhost:3306/mydb     # Unix socket - port ignored
```

## "the connection URL contains more than one '@'"

A character in your username/password isn't URL-encoded, so it's misread as part
of the host. Percent-encode it - `@` -> `%40`, `:` -> `%3A`, `/` -> `%2F`:

```
postgresql://user:p%40ss@localhost:5432/mydb
```

## "Migration N (...) was modified after it was applied (checksum mismatch)"

You edited a migration file that has already been applied. Migra stores a
checksum of each applied migration and refuses to proceed when one changes.
Either restore the file to what was applied, or roll the migration back
(`migra rollback`) and re-apply it with the new contents.

## "Migration N is recorded as applied but its file is missing"

A migration recorded in `schema_migrations` has no corresponding file. Restore
the file, or reconcile the table if the migration was intentionally removed.

## "Migration N is older than the most recently applied migration M (out-of-order)"

A pending migration has a timestamp earlier than one already applied. Applying
it would rewrite history. Renumber it to a current timestamp (e.g. regenerate
with `migra generate`), or roll back to before its slot and re-apply in order.

## "Invalid migration filename '...'"

Migration files must be named `YYYYMMDDHHMMSS_description.sql` - exactly 14
digits, an underscore, a non-empty description, and a `.sql` extension. Files
whose name starts with digits but doesn't match are rejected rather than
silently skipped.

## A MySQL/MariaDB migration left the database half-changed

MySQL and MariaDB **implicitly commit on every DDL statement** and cannot roll
it back - a server limitation, not something Migra can override. If a migration
with several DDL statements fails partway, earlier statements are already
committed. Keep MySQL/MariaDB migrations to a single DDL change each.
(PostgreSQL and SQLite are fully transactional, including DDL.)
