let () = Random.self_init ()

let () =
  Lwt_main.run
  @@ Alcotest_lwt.run "Migra Unit Tests"
       [
         ("Migration", Test_migration.suite);
         ("Discovery", Test_discovery.suite);
         ("SQL Parser", Test_sql_parser.suite);
         ("Types", Test_types.suite);
         ("Dialect", Test_dialect.suite);
       ]
