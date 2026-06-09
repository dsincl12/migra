(** Opt-in logging configuration for Migra. *)

val setup : unit -> unit
(** Install a timestamped log reporter and set the level to [Info], unless a
    reporter is already configured. Linking Migra does not configure logging on
    its own; call this if you want Migra's log output. *)

val set_level : Logs.level -> unit
(** Set the minimum log level. *)
