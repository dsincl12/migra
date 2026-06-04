(** Logging configuration for Migra. *)

val setup : unit -> unit
(** Setup logging with timestamps.

    This is called automatically when the library loads. You typically don't
    need to call this manually. *)

val set_level : Logs.level -> unit
(** Set the minimum log level. *)
