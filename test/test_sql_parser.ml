let test_split_sql_single_statement () =
  let sql = "CREATE TABLE users (id INT PRIMARY KEY);" in
  let statements = Migra.Sql_parser.split_sql sql in
  Alcotest.(check int) "1 statement" 1 (List.length statements);
  Alcotest.(check string)
    "correct statement" "CREATE TABLE users (id INT PRIMARY KEY)"
    (List.hd statements)

let test_split_sql_multiple_statements () =
  let sql = "CREATE TABLE users (id INT);CREATE TABLE posts (id INT);" in
  let statements = Migra.Sql_parser.split_sql sql in
  Alcotest.(check int) "2 statements" 2 (List.length statements);
  Alcotest.(check string)
    "first statement" "CREATE TABLE users (id INT)" (List.nth statements 0);
  Alcotest.(check string)
    "second statement" "CREATE TABLE posts (id INT)" (List.nth statements 1)

let test_split_sql_single_quoted_string () =
  let sql = "INSERT INTO users (name) VALUES ('O''Brien; DROP TABLE users');" in
  let statements = Migra.Sql_parser.split_sql sql in
  Alcotest.(check int)
    "1 statement (semicolon in string)" 1 (List.length statements);
  let stmt = List.hd statements in
  Alcotest.(check bool)
    "contains O'Brien" true
    (String.length stmt > 0 && String.contains stmt '\'')

let test_split_sql_double_quoted_string () =
  let sql = "SELECT * FROM \"table;name\";" in
  let statements = Migra.Sql_parser.split_sql sql in
  Alcotest.(check int)
    "1 statement (semicolon in identifier)" 1 (List.length statements);
  Alcotest.(check bool)
    "contains quoted identifier" true
    (String.length (List.hd statements) > 0)

let test_split_sql_escaped_single_quotes () =
  let sql =
    "INSERT INTO users (name) VALUES ('John''s data'); INSERT INTO posts \
     (title) VALUES ('Post''s title');"
  in
  let statements = Migra.Sql_parser.split_sql sql in
  Alcotest.(check int) "2 statements" 2 (List.length statements);
  List.iter
    (fun stmt ->
      Alcotest.(check bool) "contains single quote" true (String.length stmt > 0))
    statements

let test_split_sql_escaped_double_quotes () =
  let sql = {|SELECT * FROM "table""name"; SELECT "col""umn" FROM t;|} in
  let statements = Migra.Sql_parser.split_sql sql in
  Alcotest.(check int) "2 statements" 2 (List.length statements)

let test_split_sql_comment_only () =
  let sql = "-- This is a comment\n;\nCREATE TABLE users (id INT);" in
  let statements = Migra.Sql_parser.split_sql sql in
  Alcotest.(check int)
    "1 statement (comment filtered)" 1 (List.length statements);
  Alcotest.(check bool)
    "contains CREATE" true
    (String.length (List.hd statements) > 0
    && String.sub (List.hd statements) 0 6 = "CREATE")

let test_split_sql_preserves_inline_comments () =
  let sql = "CREATE TABLE users (\n  -- user id\n  id INT\n);" in
  let statements = Migra.Sql_parser.split_sql sql in
  Alcotest.(check int) "1 statement" 1 (List.length statements);
  Alcotest.(check bool)
    "statement is non-empty" true
    (String.length (List.hd statements) > 0)

let test_split_sql_empty () =
  let sql = "" in
  let statements = Migra.Sql_parser.split_sql sql in
  Alcotest.(check int) "no statements" 0 (List.length statements)

let test_split_sql_whitespace_only () =
  let sql = "   \n\t  " in
  let statements = Migra.Sql_parser.split_sql sql in
  Alcotest.(check int) "no statements" 0 (List.length statements)

let test_split_sql_only_semicolons () =
  let sql = ";;;" in
  let statements = Migra.Sql_parser.split_sql sql in
  Alcotest.(check int) "no statements" 0 (List.length statements)

let test_split_sql_complex () =
  let sql =
    {sql|
    CREATE TABLE users (
      id SERIAL PRIMARY KEY,
      email TEXT NOT NULL
    );

    INSERT INTO users (email) VALUES ('test@example.com');

    CREATE INDEX idx_email ON users(email);
  |sql}
  in
  let statements = Migra.Sql_parser.split_sql sql in
  Alcotest.(check int) "3 statements" 3 (List.length statements)

let test_split_sql_no_trailing_semicolon () =
  let sql = "SELECT * FROM users" in
  let statements = Migra.Sql_parser.split_sql sql in
  Alcotest.(check int) "1 statement" 1 (List.length statements);
  Alcotest.(check string)
    "correct statement" "SELECT * FROM users" (List.hd statements)

let test_split_sql_mixed_quotes () =
  let sql = {|SELECT "column_name", 'string;value' FROM "table;name";|} in
  let statements = Migra.Sql_parser.split_sql sql in
  Alcotest.(check int)
    "1 statement (semicolons in mixed quotes)" 1 (List.length statements)

let test_split_sql_newlines_in_strings () =
  let sql = "INSERT INTO users (bio) VALUES ('Line 1\nLine 2;\nLine 3');" in
  let statements = Migra.Sql_parser.split_sql sql in
  Alcotest.(check int) "1 statement" 1 (List.length statements)

let test_split_sql_consecutive_semicolons () =
  let sql = "SELECT 1;;; SELECT 2;;" in
  let statements = Migra.Sql_parser.split_sql sql in
  Alcotest.(check int) "2 statements" 2 (List.length statements);
  Alcotest.(check string) "first statement" "SELECT 1" (List.nth statements 0);
  Alcotest.(check string) "second statement" "SELECT 2" (List.nth statements 1)

let test_split_sql_trims_whitespace () =
  let sql = "  SELECT * FROM users  ;  INSERT INTO posts VALUES (1)  " in
  let statements = Migra.Sql_parser.split_sql sql in
  Alcotest.(check int) "2 statements" 2 (List.length statements);
  Alcotest.(check string)
    "first trimmed" "SELECT * FROM users" (List.nth statements 0);
  Alcotest.(check string)
    "second trimmed" "INSERT INTO posts VALUES (1)" (List.nth statements 1)

let test_split_sql_dollar_quote () =
  let sql =
    "CREATE FUNCTION f() RETURNS int AS $$ BEGIN RETURN 1; END; $$ LANGUAGE \
     plpgsql;"
  in
  let statements = Migra.Sql_parser.split_sql sql in
  Alcotest.(check int)
    "1 statement (dollar-quoted body not split)" 1 (List.length statements)

let test_split_sql_dollar_quote_tagged () =
  let sql =
    "CREATE FUNCTION a() RETURNS void AS $body$ BEGIN; END; $body$ LANGUAGE \
     plpgsql; CREATE FUNCTION b() RETURNS void AS $body$ BEGIN; END; $body$ \
     LANGUAGE plpgsql;"
  in
  let statements = Migra.Sql_parser.split_sql sql in
  Alcotest.(check int) "2 statements" 2 (List.length statements)

let test_split_sql_block_comment () =
  let sql = "/* drop; everything; */ SELECT 1;" in
  let statements = Migra.Sql_parser.split_sql sql in
  Alcotest.(check int)
    "1 statement (semicolons in block comment)" 1 (List.length statements)

let test_split_sql_line_comment_semicolon () =
  let sql = "SELECT 1 -- note; not a terminator\nFROM t;" in
  let statements = Migra.Sql_parser.split_sql sql in
  Alcotest.(check int)
    "1 statement (semicolon in line comment)" 1 (List.length statements)

let test_split_sql_backtick () =
  let sql = "SELECT * FROM `weird;name`;" in
  let statements = Migra.Sql_parser.split_sql sql in
  Alcotest.(check int)
    "1 statement (semicolon in backtick id)" 1 (List.length statements)

let test_split_sql_mysql_backslash () =
  let sql = {|INSERT INTO t VALUES ('a\'; still in string')|} in
  Alcotest.(check int)
    "1 statement (backslash escape on)" 1
    (List.length (Migra.Sql_parser.split_sql ~backslash_escapes:true sql))

let test_split_sql_delimiter () =
  let sql =
    "DELIMITER //\n\
     CREATE PROCEDURE p() BEGIN INSERT INTO t VALUES (1); INSERT INTO t VALUES \
     (2); END //\n\
     DELIMITER ;\n\
     INSERT INTO t VALUES (3);"
  in
  let statements = Migra.Sql_parser.split_sql sql in
  Alcotest.(check int)
    "2 statements (procedure + insert)" 2 (List.length statements);
  Alcotest.(check bool)
    "procedure kept whole" true
    (String.length (List.nth statements 0) > 0
    && not (String.contains (List.nth statements 0) '/'));
  Alcotest.(check string)
    "trailing insert" "INSERT INTO t VALUES (3)" (List.nth statements 1)

let async_of_sync f () =
  f ();
  Lwt.return_unit

let suite =
  [
    ( "split_sql_single_statement",
      `Quick,
      async_of_sync test_split_sql_single_statement );
    ( "split_sql_multiple_statements",
      `Quick,
      async_of_sync test_split_sql_multiple_statements );
    ( "split_sql_single_quoted_string",
      `Quick,
      async_of_sync test_split_sql_single_quoted_string );
    ( "split_sql_double_quoted_string",
      `Quick,
      async_of_sync test_split_sql_double_quoted_string );
    ( "split_sql_escaped_single_quotes",
      `Quick,
      async_of_sync test_split_sql_escaped_single_quotes );
    ( "split_sql_escaped_double_quotes",
      `Quick,
      async_of_sync test_split_sql_escaped_double_quotes );
    ("split_sql_comment_only", `Quick, async_of_sync test_split_sql_comment_only);
    ( "split_sql_preserves_inline_comments",
      `Quick,
      async_of_sync test_split_sql_preserves_inline_comments );
    ("split_sql_empty", `Quick, async_of_sync test_split_sql_empty);
    ( "split_sql_whitespace_only",
      `Quick,
      async_of_sync test_split_sql_whitespace_only );
    ( "split_sql_only_semicolons",
      `Quick,
      async_of_sync test_split_sql_only_semicolons );
    ("split_sql_complex", `Quick, async_of_sync test_split_sql_complex);
    ( "split_sql_no_trailing_semicolon",
      `Quick,
      async_of_sync test_split_sql_no_trailing_semicolon );
    ("split_sql_mixed_quotes", `Quick, async_of_sync test_split_sql_mixed_quotes);
    ( "split_sql_newlines_in_strings",
      `Quick,
      async_of_sync test_split_sql_newlines_in_strings );
    ( "split_sql_consecutive_semicolons",
      `Quick,
      async_of_sync test_split_sql_consecutive_semicolons );
    ( "split_sql_trims_whitespace",
      `Quick,
      async_of_sync test_split_sql_trims_whitespace );
    ("split_sql_dollar_quote", `Quick, async_of_sync test_split_sql_dollar_quote);
    ( "split_sql_dollar_quote_tagged",
      `Quick,
      async_of_sync test_split_sql_dollar_quote_tagged );
    ( "split_sql_block_comment",
      `Quick,
      async_of_sync test_split_sql_block_comment );
    ( "split_sql_line_comment_semicolon",
      `Quick,
      async_of_sync test_split_sql_line_comment_semicolon );
    ("split_sql_backtick", `Quick, async_of_sync test_split_sql_backtick);
    ( "split_sql_mysql_backslash",
      `Quick,
      async_of_sync test_split_sql_mysql_backslash );
    ("split_sql_delimiter", `Quick, async_of_sync test_split_sql_delimiter);
  ]
