let () = Random.self_init ()

(* Drop the pooled throwaway databases when the run finishes (success or
   failure). [~and_exit:false] keeps Alcotest from exiting the process before the
   cleanup in the finalizer runs; the exit code is re-raised afterwards. *)
let () =
  Lwt_main.run
    (Lwt.finalize
       (fun () ->
         Alcotest_lwt.run ~and_exit:false "Migra Integration Tests"
           [
             ("Schema", Test_schema_integration.suite);
             ("Database", Test_database.suite);
             ("Runner", Test_runner.suite);
             ("Migrator", Test_migrator.suite);
             ("Workflows", Test_workflows.suite);
             ("SQLite Integration", Test_integration_sqlite.suite);
             ("MariaDB Integration", Test_integration_mariadb.suite);
           ])
       (fun () -> Test_helpers.TestDbPool.cleanup ()))
