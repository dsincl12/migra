(lang dune 3.12)

(name migris)

(generate_opam_files true)

(source
 (github dsincl12/migris))

(authors "David Sinclair")

(license MIT)

(documentation https://github.com/dsincl12/migris)

(package
 (name migris)
 (synopsis "A simple database migration tool for OCaml")
 (depends
   (ocaml (>= 4.14.0))
   (dune (>= 3.12))
   (lwt (>= 5.6.0))
   (lwt_ppx (and :with-test (>= 2.1.0)))
   (alcotest (and :with-test (>= 1.7.0)))
   (alcotest-lwt (and :with-test (>= 1.7.0)))
   (caqti (>= 2.0.0))
   (caqti-lwt (>= 2.0.0))
   (caqti-driver-postgresql (>= 2.0.0))
   (uri (>= 4.4.0))
   (cmdliner (>= 1.2.0)))
 (tags
  (topics database migrations postgresql)))

; See the complete stanza docs at https://dune.readthedocs.io/en/stable/dune-files.html#dune-project
