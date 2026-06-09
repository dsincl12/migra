val split_sql :
  ?backslash_escapes:bool -> ?allow_delimiter:bool -> string -> string list
(** Split SQL on top-level semicolons. Semicolons inside string literals, quoted
    identifiers, dollar-quoted bodies, and comments are not terminators;
    comment- and whitespace-only statements are dropped.
    [~backslash_escapes:true] handles MySQL/MariaDB backslash escapes.
    [~allow_delimiter:true] honors the MySQL/MariaDB [DELIMITER] directive; it
    is off by default so the directive is not applied to dialects that lack it.
*)
