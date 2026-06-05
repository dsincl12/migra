(** SQL statement splitter. *)

type state =
  | Normal
  | Line_comment (* -- ... until newline *)
  | Block_comment of int (* /* ... */, [n] = nesting depth >= 1 *)
  | Single_quote (* '...' *)
  | Double_quote (* "..." *)
  | Backtick (* `...` *)
  | Dollar_quote of string (* $tag$ ... $tag$; tag includes the surrounding $ *)

let is_space c = c = ' ' || c = '\t' || c = '\n' || c = '\r'
let is_blank c = c = ' ' || c = '\t'

let split_sql ?(backslash_escapes = false) (sql : string) : string list =
  let n = String.length sql in
  let buf = Buffer.create 256 in
  let statements = ref [] in
  let has_content = ref false in
  (* any real (non-comment, non-space) char seen? *)

  let finish () =
    let stmt = String.trim (Buffer.contents buf) in
    if !has_content && stmt <> "" then statements := stmt :: !statements;
    Buffer.clear buf;
    has_content := false
  in

  let char_at i = if i < n then sql.[i] else '\000' in

  (* Dollar-quote tag ($ [A-Za-z0-9_]* $) starting at [i], else None. *)
  let read_dollar_tag i =
    let j = ref (i + 1) in
    while
      !j < n
      &&
      let c = sql.[!j] in
      (c >= 'a' && c <= 'z')
      || (c >= 'A' && c <= 'Z')
      || (c >= '0' && c <= '9')
      || c = '_'
    do
      incr j
    done;
    if !j < n && sql.[!j] = '$' then Some (String.sub sql i (!j - i + 1), !j + 1)
    else None
  in

  (* If a [DELIMITER <token>] directive begins at line position [i] (allowing
     leading blanks), return the new delimiter and the index past the line. *)
  let parse_delimiter_directive i =
    let j = ref i in
    while !j < n && is_blank sql.[!j] do
      incr j
    done;
    let kw = "delimiter" and klen = 9 in
    if
      !j + klen <= n
      && String.lowercase_ascii (String.sub sql !j klen) = kw
      && (!j + klen >= n || is_blank sql.[!j + klen])
    then begin
      let k = ref (!j + klen) in
      while !k < n && is_blank sql.[!k] do
        incr k
      done;
      let s = !k in
      while !k < n && not (is_space sql.[!k]) do
        incr k
      done;
      let token = String.sub sql s (!k - s) in
      while !k < n && sql.[!k] <> '\n' do
        incr k
      done;
      let after = if !k < n then !k + 1 else !k in
      if token = "" then None else Some (token, after)
    end
    else None
  in

  (* matches [delim] literally at position [i] *)
  let matches_delim delim i =
    let dl = String.length delim in
    dl > 0 && i + dl <= n && String.sub sql i dl = delim
  in

  let rec scan state delim line_start i =
    if i >= n then finish ()
    else
      let c = sql.[i] in
      match state with
      | Normal -> (
          match if line_start then parse_delimiter_directive i else None with
          | Some (new_delim, after) ->
              finish ();
              scan Normal new_delim true after
          | None ->
              if matches_delim delim i then (
                finish ();
                scan Normal delim false (i + String.length delim))
              else if c = '-' && char_at (i + 1) = '-' then (
                Buffer.add_string buf "--";
                scan Line_comment delim false (i + 2))
              else if c = '/' && char_at (i + 1) = '*' then (
                Buffer.add_string buf "/*";
                scan (Block_comment 1) delim false (i + 2))
              else if c = '\'' then (
                Buffer.add_char buf c;
                has_content := true;
                scan Single_quote delim false (i + 1))
              else if c = '"' then (
                Buffer.add_char buf c;
                has_content := true;
                scan Double_quote delim false (i + 1))
              else if c = '`' then (
                Buffer.add_char buf c;
                has_content := true;
                scan Backtick delim false (i + 1))
              else if c = '$' then (
                match read_dollar_tag i with
                | Some (tag, next) ->
                    Buffer.add_string buf tag;
                    has_content := true;
                    scan (Dollar_quote tag) delim false next
                | None ->
                    Buffer.add_char buf c;
                    has_content := true;
                    scan Normal delim false (i + 1))
              else (
                Buffer.add_char buf c;
                if not (is_space c) then has_content := true;
                let line_start' = c = '\n' || (line_start && is_blank c) in
                scan Normal delim line_start' (i + 1)))
      | Line_comment ->
          Buffer.add_char buf c;
          if c = '\n' then scan Normal delim true (i + 1)
          else scan Line_comment delim false (i + 1)
      | Block_comment depth ->
          if c = '*' && char_at (i + 1) = '/' then (
            Buffer.add_string buf "*/";
            if depth = 1 then scan Normal delim false (i + 2)
            else scan (Block_comment (depth - 1)) delim false (i + 2))
          else if c = '/' && char_at (i + 1) = '*' then (
            Buffer.add_string buf "/*";
            scan (Block_comment (depth + 1)) delim false (i + 1 + 1))
          else (
            Buffer.add_char buf c;
            scan (Block_comment depth) delim false (i + 1))
      | Single_quote ->
          if backslash_escapes && c = '\\' && i + 1 < n then (
            Buffer.add_char buf c;
            Buffer.add_char buf (char_at (i + 1));
            scan Single_quote delim false (i + 2))
          else if c = '\'' then
            if char_at (i + 1) = '\'' then (
              Buffer.add_string buf "''";
              scan Single_quote delim false (i + 2))
            else (
              Buffer.add_char buf c;
              scan Normal delim false (i + 1))
          else (
            Buffer.add_char buf c;
            scan Single_quote delim false (i + 1))
      | Double_quote ->
          if c = '"' then
            if char_at (i + 1) = '"' then (
              Buffer.add_string buf "\"\"";
              scan Double_quote delim false (i + 2))
            else (
              Buffer.add_char buf c;
              scan Normal delim false (i + 1))
          else (
            Buffer.add_char buf c;
            scan Double_quote delim false (i + 1))
      | Backtick ->
          if c = '`' then
            if char_at (i + 1) = '`' then (
              Buffer.add_string buf "``";
              scan Backtick delim false (i + 2))
            else (
              Buffer.add_char buf c;
              scan Normal delim false (i + 1))
          else (
            Buffer.add_char buf c;
            scan Backtick delim false (i + 1))
      | Dollar_quote tag ->
          let tl = String.length tag in
          if c = '$' && i + tl <= n && String.sub sql i tl = tag then (
            Buffer.add_string buf tag;
            scan Normal delim false (i + tl))
          else (
            Buffer.add_char buf c;
            scan (Dollar_quote tag) delim false (i + 1))
  in
  scan Normal ";" true 0;
  List.rev !statements
