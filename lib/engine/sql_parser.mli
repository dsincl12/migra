val split_sql : ?backslash_escapes:bool -> string -> string list
(** Split SQL on top-level semicolons. Semicolons inside string literals, quoted
    identifiers, dollar-quoted bodies, and comments are not terminators;
    comment- and whitespace-only statements are dropped.
    [~backslash_escapes:true] handles MySQL/MariaDB backslash escapes. *)
