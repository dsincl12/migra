
(** Split SQL text into individual statements on top-level semicolons.

    Semicolons inside string literals ['...'], quoted identifiers ["..."] /
    [`...`], PostgreSQL dollar-quoted bodies [$$...$$] / [$tag$...$tag$], line
    comments [-- ...], and (nested) block comments [/* ... */] are not treated
    as terminators. Comment-only and whitespace-only statements are dropped;
    results are trimmed.

    Pass [~backslash_escapes:true] for MySQL/MariaDB, where [\] escapes the next
    character inside a single-quoted string. The default [false] is correct for
    PostgreSQL and SQLite.

    {b Example}:
    {[
      split_sql "SELECT * FROM users; INSERT INTO logs VALUES ('test');"
      (* Returns: ["SELECT * FROM users"; "INSERT INTO logs VALUES ('test')"] *)
    ]} *)
val split_sql : ?backslash_escapes:bool -> string -> string list
