# Troubleshooting Guide

## PostgreSQL Driver Installation Issue

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

## Related Issues

### Missing DATABASE_URL

When running `migris migrate` or `migris status` without setting DATABASE_URL:

```bash
Error: DATABASE_URL environment variable not set
Please set DATABASE_URL environment variable
```

**Solution**: Set the DATABASE_URL environment variable:

```bash
export DATABASE_URL="postgresql://username:password@localhost:5432/database_name"
migris migrate
```

### Connection Refused Errors

If you get connection errors when running migrations:

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

# Verify the port (default is 5432)
psql -l
```

### Permissions Issues

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

## Getting Help

If you encounter other issues:

1. Check that all dependencies are installed: `opam list`
2. Verify PostgreSQL is accessible: `psql -d $DATABASE_URL`
3. Run with verbose output to see detailed errors
4. Check the migrations directory exists and has correct permissions

For build issues, check:
- OCaml version: `ocaml --version` (requires >= 5.0)
- Dune version: `dune --version` (requires >= 2.7)
- Opam version: `opam --version`
