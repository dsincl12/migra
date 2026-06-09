(** Logging configuration for Migra. *)

val setup : unit -> unit
(** Install a timestamped log reporter and set the level to [Info], unless a
    reporter is already configured (in which case it does nothing, leaving an
    embedding application's logging untouched).

    Not called automatically: linking the library does not change global [Logs]
    state. The CLI calls this at startup; library embedders call it only if they
    want Migra's log output. *)

val set_level : Logs.level -> unit
(** Set the minimum log level. *)
