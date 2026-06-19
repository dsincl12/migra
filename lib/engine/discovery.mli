module Int64Set : Set.S with type elt = int64

val default_migrations_dir : string
val applied_set_of_list : int64 list -> Int64Set.t
val is_migration_file : string -> bool
val read_directory : string -> (string list, Types.error) result

val find_migrations :
  ?dir:string -> unit -> (Migration.t list, Types.error) result

val existing_migrations :
  ?dir:string -> unit -> (Migration.t list, Types.error) result
(** Migrations on disk, parsed best-effort (non-migration/unparseable files
    skipped, no duplicate or out-of-order check). Used by generation to detect a
    name/version clash without erroring on unrelated directory problems. *)

val find_pending : int64 list -> Migration.t list -> Migration.t list
(** Find pending migrations (not yet applied). Takes a list of applied versions
    and all discovered migrations, returns migrations that haven't been applied
    yet. *)

val find_by_version : Migration.t list -> int64 -> Migration.t option
val ensure_migrations_dir : ?dir:string -> unit -> (unit, Types.error) result
