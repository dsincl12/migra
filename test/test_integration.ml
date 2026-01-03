
let () = Random.self_init ()

let () =
  Lwt_main.run @@ Alcotest_lwt.run "Migris Integration Tests" [
    "Schema", Test_schema_integration.suite;
    "Database", Test_database.suite;
    "Runner", Test_runner.suite;
    "Migrator", Test_migrator.suite;
    "E2E", Test_e2e.suite;
  ]
