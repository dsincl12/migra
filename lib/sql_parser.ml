(** SQL statement parser and splitter. *)

type quote_state = NotInQuote | InQuote of char

(** Split SQL text into individual statements.

    Parses SQL text and splits it into separate executable statements based on
    semicolons, while correctly handling string literals and escaped quotes.

    {b Algorithm}:
    - State machine tracks whether inside string literal
    - Semicolons outside strings mark statement boundaries
    - Escaped quotes (doubled) are handled correctly
    - Comment-only statements are filtered out

    {b Performance}: O(n) where n is the length of the SQL text, using Buffer
    for efficient string building.

    @param sql The SQL text to split (may contain multiple statements)
    @return List of individual SQL statements (trimmed, non-empty, non-comment-only)

    {b Example}:
    {[
      split_sql "SELECT * FROM users; INSERT INTO logs VALUES ('test');"
      (* Returns: ["SELECT * FROM users"; "INSERT INTO logs VALUES ('test')"] *)

      split_sql "SELECT 'hello; world'; INSERT INTO foo VALUES (1);"
      (* Returns: ["SELECT 'hello; world'"; "INSERT INTO foo VALUES (1)"] *)
    ]}
*)
let split_sql (sql : string) : string list =

  let buf = Buffer.create 256 in
  let statements = ref [] in

  let finish_statement () =
    let stmt = Buffer.contents buf |> String.trim in
    if stmt <> "" then statements := stmt :: !statements;
    Buffer.clear buf
  in

  let rec split_statements quote_state i =
    if i >= String.length sql then
      finish_statement ()
    else
      let c = sql.[i] in
      match quote_state, c with
      | NotInQuote, ('\'' | '"') ->
          Buffer.add_char buf c;
          split_statements (InQuote c) (i + 1)
      | InQuote q, c' when c' = q ->
          if i + 1 < String.length sql && sql.[i + 1] = q then begin
            Buffer.add_char buf c;
            Buffer.add_char buf q;
            split_statements (InQuote q) (i + 2)
          end else begin
            Buffer.add_char buf c;
            split_statements NotInQuote (i + 1)
          end
      | NotInQuote, ';' ->
          finish_statement ();
          split_statements NotInQuote (i + 1)
      | _, _ ->
          Buffer.add_char buf c;
          split_statements quote_state (i + 1)
  in

  split_statements NotInQuote 0;
  List.rev !statements
  |> List.filter (fun s ->
      let lines = String.split_on_char '\n' s in
      let sql_lines = List.filter (fun line ->
        let trimmed = String.trim line in
        String.length trimmed > 0 && not (String.starts_with ~prefix:"--" trimmed)
      ) lines in
      match sql_lines with [] -> false | _ -> true
    )
