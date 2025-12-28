
(** Split SQL text into individual statements.

    Handles string literals (single and double quotes) and escaped quotes properly.
    Filters out comment-only statements.
    Returns list of non-empty SQL statements.

    {b Example}:
    {[
      split_sql "SELECT * FROM users; INSERT INTO logs VALUES ('test');"
      (* Returns: ["SELECT * FROM users"; "INSERT INTO logs VALUES ('test')"] *)
    ]}

    {b Note}: Does not handle inline comments or block comments.
*)
val split_sql : string -> string list
