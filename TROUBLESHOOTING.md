# Troubleshooting Guide

This guide covers common issues with Migra across all supported databases: PostgreSQL, MariaDB/MySQL, and SQLite.

## Table of Contents

- [Driver Installation Issues](#driver-installation-issues)
  - [PostgreSQL Driver](#postgresql-driver-installation)
  - [MariaDB Driver](#mariadb-driver-installation)
  - [SQLite Driver](#sqlite-driver-installation)
- [Connection Issues](#connection-issues)
- [Database-Specific Issues](#database-specific-issues)
  - [PostgreSQL](#postgresql-specific-issues)
  - [MariaDB/MySQL](#mariadbmysql-specific-issues)
  - [SQLite](#sqlite-specific-issues)
- [General Issues](#general-issues)
- [Getting Help](#getting-help)

---

## Driver Installation Issues

### PostgreSQL Driver Installation

### Problem

When trying to install the OCaml PostgreSQL bindings, the build fails with:

```
[ERROR] The compilation of postgresql.5.3.2 failed at "dune build -p postgresql -j 9 @install".

Fatal error: exception End_of_file
```

The build log shows:

```
run: /opt/homebrew/bin/pkgconf --personality aarch64-apple-darwin25.1.0 --cflags libpq
-> process exited with code 0
-> stdout:
 | -I/opt/homebrew/opt/libpq/include -I/opt/homebrew/Cellar/openssl@3/3.6.0/include
-> stderr:
run: /opt/homebrew/bin/pkgconf --personality aarch64-apple-darwin25.1.0 --libs libpq
-> process exited with code 0
-> stdout:
 | -L/opt/homebrew/opt/libpq/lib -lpq
-> stderr:
Fatal error: exception End_of_file
```

### Root Cause

The `postgresql` OCaml package uses a dune discovery script (`config/discover.exe`) that reads pkg-config output to find PostgreSQL library paths. When executed without the proper PKG_CONFIG_PATH environment variable set, the discovery script:

1. Successfully runs `pkgconf --cflags libpq` and `pkgconf --libs libpq` in a subprocess
2. Reads the output
3. But encounters an unexpected EOF when trying to parse the results

This happens because:
- The system's `pkg-config` / `pkgconf` can't find `libpq.pc` without the correct search path
- While Homebrew installs libpq to `/opt/homebrew/Cellar/libpq/18.1/`, the `.pc` files are in a subdirectory (`lib/pkgconfig/`)
- The OCaml build process doesn't automatically discover Homebrew's pkg-config paths

### Solution

Set the `PKG_CONFIG_PATH` environment variable to include the libpq pkg-config directory before installing:

```bash
# Find the libpq installation
brew list libpq | grep libpq.pc
# Output: /opt/homebrew/Cellar/libpq/18.1/lib/pkgconfig/libpq.pc

# Set PKG_CONFIG_PATH and install
export PKG_CONFIG_PATH="/opt/homebrew/Cellar/libpq/18.1/lib/pkgconfig:$PKG_CONFIG_PATH"
opam install postgresql -y
opam install caqti-driver-postgresql -y
```

### Verification

After installation, verify the packages are installed:

```bash
opam list | grep -i postgres
# Should show:
# conf-postgresql         2           Virtual package relying on a PostgreSQL system installation
# caqti-driver-postgresql 2.2.4       PostgreSQL driver for Caqti using C bindings
# postgresql              5.3.2       Bindings to the PostgreSQL library
```

Test that pkg-config can find libpq:

```bash
export PKG_CONFIG_PATH="/opt/homebrew/Cellar/libpq/18.1/lib/pkgconfig:$PKG_CONFIG_PATH"
pkgconf --cflags libpq
pkgconf --libs libpq
```

### Making the Fix Permanent

To avoid this issue in the future, add the PKG_CONFIG_PATH to your shell profile:

```bash
# Add to ~/.zshrc or ~/.bashrc
export PKG_CONFIG_PATH="/opt/homebrew/Cellar/libpq/18.1/lib/pkgconfig:$PKG_CONFIG_PATH"
```

**Note**: The path may change when libpq is upgraded. You can make it version-independent:

```bash
# More flexible approach
export PKG_CONFIG_PATH="/opt/homebrew/opt/libpq/lib/pkgconfig:$PKG_CONFIG_PATH"
```

The `/opt/homebrew/opt/libpq` symlink always points to the currently active libpq version.

### Alternative: Using Homebrew's pkg-config Setup

Homebrew provides its own pkg-config that should automatically know about installed packages:

```bash
# Ensure you're using Homebrew's pkg-config
which pkg-config
# Should show: /opt/homebrew/bin/pkg-config

# If not, you may need to link it
brew link pkg-config
```

However, even with Homebrew's pkg-config, explicitly setting PKG_CONFIG_PATH is more reliable for opam builds.

---

### MariaDB Driver Installation

#### Problem

When trying to install the OCaml MariaDB bindings, the build fails with errors about missing `mysql_config` or MariaDB headers:

```
[ERROR] The compilation of mariadb.1.2.1 failed
Could not find mysql_config
```

Or:

```
File "src/mariadb_stubs.c", line 1:
fatal error: 'mysql.h' file not found
```

#### Root Cause

The `mariadb` OCaml package requires the MariaDB client libraries and development headers. Even if you have a MariaDB/MySQL server installed, you may not have the connector library that includes `mysql_config`.

On macOS, there are multiple approaches:
1. Installing the full `mariadb` package (includes server + client)
2. Installing just `mariadb-connector-c` (client libraries only, recommended)

#### Solution

**Option 1: Install MariaDB Connector C (Recommended for development)**

```bash
# Install just the client libraries
brew install mariadb-connector-c

# Install the OCaml driver
opam install mariadb caqti-driver-mariadb
```

**Option 2: Install Full MariaDB Server**

```bash
# Install the full MariaDB package
brew install mariadb

# This provides mysql_config
which mysql_config
# Output: /opt/homebrew/bin/mysql_config

# Install the OCaml driver
opam install mariadb caqti-driver-mariadb
```

#### Additional Configuration (if needed)

If you still get errors, you may need to set pkg-config paths:

```bash
# Set MariaDB-specific pkg-config path
export PKG_CONFIG_PATH="/opt/homebrew/opt/mariadb-connector-c/lib/pkgconfig:$PKG_CONFIG_PATH"

# Or if using full MariaDB:
export PKG_CONFIG_PATH="/opt/homebrew/opt/mariadb/lib/pkgconfig:$PKG_CONFIG_PATH"

# Then retry installation
opam install mariadb caqti-driver-mariadb
```

#### Verification

After installation, verify the packages are installed:

```bash
opam list | grep -i maria
# Should show:
# caqti-driver-mariadb  2.2.4       MariaDB driver for Caqti
# mariadb               1.2.1       OCaml bindings for MariaDB/MySQL
```

Test that mysql_config works:

```bash
mysql_config --version
mysql_config --cflags
mysql_config --libs
```

---

### SQLite Driver Installation

#### Problem

SQLite driver installation usually succeeds since SQLite is included with most systems, but you might encounter:

```
[ERROR] The compilation of sqlite3.5.2.0 failed
Package sqlite3 was not found in the pkg-config search path
```

#### Solution

Install SQLite development libraries:

**macOS:**
```bash
# SQLite is usually already installed
# If needed:
brew install sqlite3

# Install the OCaml driver
opam install sqlite3 caqti-driver-sqlite3
```

**Linux (Ubuntu/Debian):**
```bash
sudo apt-get install libsqlite3-dev
opam install sqlite3 caqti-driver-sqlite3
```

**Linux (Fedora/RHEL):**
```bash
sudo dnf install sqlite-devel
opam install sqlite3 caqti-driver-sqlite3
```

#### Verification

```bash
opam list | grep -i sqlite
# Should show:
# caqti-driver-sqlite3  2.2.4       SQLite3 driver for Caqti
# sqlite3               5.2.0       SQLite3 bindings
```

Test SQLite:
```bash
sqlite3 --version
```

---

## Connection Issues

### Missing DATABASE_URL

When running `migra migrate` or `migra status` without setting DATABASE_URL:

```bash
Error: DATABASE_URL environment variable not set
Please set DATABASE_URL environment variable
```

**Solution**: Set the DATABASE_URL environment variable for your database:

**PostgreSQL:**
```bash
export DATABASE_URL="postgresql://username@localhost:5432/database_name"
# or with password:
export DATABASE_URL="postgresql://username:password@localhost:5432/database_name"
migra migrate
```

**MariaDB/MySQL:**
```bash
export DATABASE_URL="mariadb://root@localhost:3306/database_name"
# or:
export DATABASE_URL="mysql://username:password@localhost:3306/database_name"
migra migrate
```

**SQLite:**
```bash
# File-based:
export DATABASE_URL="sqlite3://./dev.db"
# or in-memory:
export DATABASE_URL="sqlite3://:memory:"
migra migrate
```

---

### Unsupported Database URL Scheme

If you get an error about unsupported URL scheme:

```bash
Error: Unsupported database URL scheme: oracle://localhost/mydb
Supported: postgresql://, mariadb://, mysql://, sqlite3://
```

**Solution**: Make sure your `DATABASE_URL` starts with one of the supported schemes:
- `postgresql://` or `postgres://` for PostgreSQL
- `mariadb://` or `mysql://` for MariaDB/MySQL
- `sqlite3://` for SQLite

---

### Connection Refused Errors

#### PostgreSQL Connection Refused

If you get connection errors when running migrations against PostgreSQL:

```bash
Error: connection to server at "localhost" (::1), port 5432 failed: Connection refused
```

**Possible causes:**
1. PostgreSQL server is not running
2. PostgreSQL is listening on a different port
3. Firewall is blocking the connection

**Solution**:
```bash
# Check if PostgreSQL is running (macOS)
brew services list | grep postgres

# Start PostgreSQL if needed
brew services start postgresql@16

# Or start manually:
postgres -D /opt/homebrew/var/postgresql@16

# Verify the port (default is 5432)
psql -l

# Test connection directly:
psql -h localhost -p 5432 -U your_username -d your_database
```

#### MariaDB/MySQL Connection Refused

If you get connection errors when running migrations against MariaDB/MySQL:

```bash
Error: Can't connect to MySQL server on 'localhost' (61)
```

**Solution**:
```bash
# Check if MariaDB/MySQL is running (macOS)
brew services list | grep mariadb
# or
brew services list | grep mysql

# Start MariaDB if needed
brew services start mariadb

# Or MySQL:
brew services start mysql

# Test connection:
mysql -h localhost -u root -p
# or for MariaDB:
mariadb -h localhost -u root -p

# Check the port (default is 3306):
mysql -u root -e "SHOW VARIABLES LIKE 'port';"
```

#### SQLite Connection Issues

SQLite rarely has connection issues since it's file-based, but you might encounter:

**File permission errors:**
```bash
Error: unable to open database file
```

**Solution**:
```bash
# Check directory permissions (directory must be writable)
ls -ld $(dirname ./dev.db)

# If needed, fix permissions:
chmod 755 $(dirname ./dev.db)

# For the database file itself:
chmod 644 ./dev.db
```

**File not found (if expected to exist):**
```bash
# Migra creates the file automatically, but if using an absolute path:
export DATABASE_URL="sqlite3:///absolute/path/to/mydb.db"

# Make sure the directory exists:
mkdir -p /absolute/path/to
```

---

### Database Authentication Errors

#### PostgreSQL Authentication Failed

```bash
Error: FATAL: password authentication failed for user "username"
```

**Solutions:**
1. **Verify credentials in DATABASE_URL:**
   ```bash
   export DATABASE_URL="postgresql://correct_user:correct_password@localhost:5432/mydb"
   ```

2. **Check PostgreSQL authentication method:**
   ```bash
   # Check pg_hba.conf
   cat /opt/homebrew/var/postgresql@16/pg_hba.conf

   # Look for lines like:
   # local   all   all   trust          # No password needed
   # local   all   all   md5            # Password required
   ```

3. **Reset password:**
   ```bash
   psql -U postgres
   ALTER USER your_username WITH PASSWORD 'new_password';
   ```

#### MariaDB/MySQL Authentication Failed

```bash
Error: Access denied for user 'username'@'localhost' (using password: YES)
```

**Solutions:**
1. **Verify credentials:**
   ```bash
   export DATABASE_URL="mariadb://root:correct_password@localhost:3306/mydb"
   ```

2. **Check user exists and has permissions:**
   ```bash
   mysql -u root -p

   # Check users:
   SELECT user, host FROM mysql.user;

   # Grant permissions:
   GRANT ALL PRIVILEGES ON mydb.* TO 'username'@'localhost' IDENTIFIED BY 'password';
   FLUSH PRIVILEGES;
   ```

3. **MariaDB root user might not have password:**
   ```bash
   # Try without password:
   export DATABASE_URL="mariadb://root@localhost:3306/mydb"
   ```

---

## Database-Specific Issues

### PostgreSQL-Specific Issues

#### Permissions Issues

If migrations fail with permission errors:

```bash
Error: permission denied for schema public
```

**Solution**: Ensure your database user has the correct permissions:

```sql
-- Connect as superuser
psql -U postgres -d your_database

-- Grant necessary permissions
GRANT ALL PRIVILEGES ON SCHEMA public TO your_username;
GRANT CREATE ON SCHEMA public TO your_username;
```

#### Database Already Exists

If `migra init` reports the database already exists but you want to recreate it:

```bash
# Option 1: Drop and recreate
migra drop
migra init

# Option 2: Use reset (drop + create + migrate)
migra reset
```

#### Lock Conflicts

PostgreSQL may report lock conflicts if another session is holding locks:

```bash
Error: deadlock detected
```

**Solution:**
- Close other connections to the database
- Check for long-running queries: `SELECT * FROM pg_stat_activity;`
- Kill blocking queries if needed (as superuser)

---

### MariaDB/MySQL-Specific Issues

#### Storage Engine Issues

If you encounter errors about storage engines:

```bash
Error: Table 'schema_migrations' is using unknown storage engine 'InnoDB'
```

**Solution**: Ensure InnoDB is enabled (it should be by default):

```sql
-- Check available engines:
SHOW ENGINES;

-- Should show InnoDB as DEFAULT or YES
```

#### Character Set Issues

MariaDB/MySQL may have character set warnings:

```bash
Warning: Using a password on the command line interface can be insecure
```

**Solution:**
- This is normal and safe for `DATABASE_URL` usage
- For production, consider using connection files or environment-based configs

#### Case Sensitivity

MariaDB/MySQL table names are case-sensitive on Linux but not on macOS/Windows:

**Solution:**
- Use consistent casing in your migrations
- Be aware when moving between development and production environments

#### Reserved Words

MariaDB/MySQL has many reserved words that might conflict with table names:

```bash
Error: You have an error in your SQL syntax near 'order'
```

**Solution**: Use backticks to quote identifiers:
```sql
CREATE TABLE `order` (id INT PRIMARY KEY);
-- instead of:
CREATE TABLE order (id INT PRIMARY KEY);
```

---

### SQLite-Specific Issues

#### In-Memory Database Appears Empty

Each connection to `sqlite3://:memory:` creates a new, empty database:

```bash
export DATABASE_URL="sqlite3://:memory:"
migra migrate     # Creates schema in connection 1
migra status      # Creates NEW empty database in connection 2
```

**This is expected behavior.** In-memory databases are ephemeral and session-specific.

**Solution**: Use file-based databases for persistence:
```bash
export DATABASE_URL="sqlite3://./dev.db"
```

#### File Locking Issues

SQLite uses file locking, which can cause issues with concurrent access:

```bash
Error: database is locked
```

**Possible causes:**
1. Another process has the database open
2. NFS or network filesystem issues
3. Previous crash left stale lock

**Solutions:**
```bash
# 1. Close other connections/processes using the database

# 2. Check for processes:
lsof ./dev.db

# 3. If safe, delete lock files:
rm ./dev.db-shm ./dev.db-wal

# 4. For development, use WAL mode to reduce locking:
sqlite3 ./dev.db "PRAGMA journal_mode=WAL;"
```

#### Limited Concurrent Writes

SQLite only allows one writer at a time. This is normal and expected.

**For migrations, this is not an issue** since migrations run sequentially.

#### Type Affinity vs Strict Types

SQLite uses type affinity rather than strict typing:

```sql
-- This works in SQLite (might not in PostgreSQL/MariaDB):
CREATE TABLE users (
  id INTEGER PRIMARY KEY,
  age TEXT  -- Can store "25" as text instead of integer
);
```

**Solution**: Use proper data types to maintain portability across databases.

#### ALTER TABLE Limitations

SQLite has limited `ALTER TABLE` support:
- Cannot drop columns (before SQLite 3.35.0)
- Cannot modify column types
- Cannot add constraints to existing columns

**Workarounds:**
1. **Recreate table approach:**
   ```sql
   -- +migrate up
   CREATE TABLE users_new (
     id INTEGER PRIMARY KEY,
     name TEXT NOT NULL,
     -- removed old 'age' column
     created_at TEXT
   );
   INSERT INTO users_new SELECT id, name, created_at FROM users;
   DROP TABLE users;
   ALTER TABLE users_new RENAME TO users;

   -- +migrate down
   -- Reverse the process
   ```

2. **Check SQLite version:**
   ```bash
   sqlite3 --version
   # SQLite 3.35.0+ supports DROP COLUMN
   ```

---

## General Issues

### Migration Fails Mid-Execution

If a migration fails, it's automatically rolled back:

```bash
Error: migration 20240115120000 failed: ...
```

**What happens:**
- The transaction is rolled back
- The database remains in its previous state
- The `schema_migrations` table is not updated

**Solution:**
1. Fix the SQL in the migration file
2. Run `migra migrate` again
3. The failed migration will retry

### Migrations Directory Not Found

```bash
Error: Migrations directory './migrations' does not exist
```

**Solution:**
```bash
# Create the directory:
mkdir migrations

# Or if in wrong location:
cd /path/to/your/project
migra migrate
```

### Invalid Migration File Format

```bash
Error: Invalid migration file format
```

**Causes:**
- Missing `-- +migrate up` or `-- +migrate down` markers
- Incorrect filename format (should be `YYYYMMDDHHMMSS_description.sql`)

**Solution:**
```bash
# Create migration properly:
migra create my_migration_name

# Ensure file has both sections:
-- +migrate up


-- +migrate down

```

---

## Getting Help

If you encounter other issues not covered in this guide:

### Quick Diagnostic Checklist

1. **Check dependencies are installed:**
   ```bash
   opam list | grep caqti
   # Should show caqti, caqti-lwt, and at least one driver
   ```

2. **Verify database connectivity:**
   ```bash
   # PostgreSQL:
   psql -d $DATABASE_URL -c "SELECT 1"

   # MariaDB/MySQL:
   mysql --defaults-extra-file=<(echo "[client]"; echo "user=root") -e "SELECT 1"

   # SQLite:
   sqlite3 ./dev.db "SELECT 1"
   ```

3. **Check DATABASE_URL is set and valid:**
   ```bash
   echo $DATABASE_URL
   # Should start with postgresql://, mariadb://, mysql://, or sqlite3://
   ```

4. **Run with verbose output:**
   ```bash
   migra migrate --verbose
   # Shows all SQL being executed
   ```

5. **Verify migrations directory:**
   ```bash
   ls -la migrations/
   # Should contain *.sql files with YYYYMMDDHHMMSS_*.sql format
   ```

### Build Issues

For build or installation problems:

```bash
# Check versions:
ocaml --version    # Requires >= 5.0
dune --version     # Requires >= 2.7
opam --version     # Requires >= 2.0

# Check system dependencies:
pkgconf --version  # For PostgreSQL/MariaDB driver builds

# PostgreSQL development files:
pkgconf --cflags libpq

# MariaDB development files:
mysql_config --version

# SQLite development files:
pkgconf --cflags sqlite3
```

### Database Version Compatibility

Migra is tested with:
- PostgreSQL 13, 14, 15, 16
- MariaDB 10.5+, **MySQL** 5.7+, 8.0+
- SQLite 3.35.0+ (some features require newer versions)

### Getting More Help

- File an issue: [GitHub Issues](https://github.com/your-repo/migra/issues)
- Check documentation: See [README.md](README.md) for examples
- Review test files: `test/test_integration_*.ml` show working examples
