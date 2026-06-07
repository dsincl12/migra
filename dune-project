(lang dune 3.12)

(name migra)

(version 1.0.0)

(generate_opam_files true)

(source
 (github dsincl12/migra))

(authors "David Sinclair")
(maintainers "David Sinclair")

(license MIT)

(documentation https://github.com/dsincl12/migra)

(package
 (name migra)
 (synopsis "A database migration tool for OCaml supporting PostgreSQL, MariaDB, and SQLite")
 (depends
   (ocaml (>= 4.14.0))
   (lwt (>= 5.6.0))
   (alcotest (and :with-test (>= 1.7.0)))
   (alcotest-lwt (and :with-test (>= 1.7.0)))
   (caqti (>= 2.0.0))
   (caqti-lwt (>= 2.0.0))
   (caqti-dynload (>= 2.0.0))
   (uri (>= 4.4.0))
   (cmdliner (>= 1.2.0))
   (logs (>= 0.7.0))
   (logs-ppx (>= 0.2.0))
   (fmt (>= 0.9.0)))
 (depopts
   caqti-driver-postgresql
   caqti-driver-mariadb
   caqti-driver-sqlite3)
 (tags
  (topics database migrations postgresql mariadb mysql sqlite)))

; See the complete stanza docs at https://dune.readthedocs.io/en/stable/dune-files.html#dune-project
