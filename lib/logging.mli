(** Logging configuration for Migra. *)

(** Setup logging with timestamps.

    This is called automatically when the library loads.
   
*)
val setup : unit -> unit

(** Set the minimum log level. *)
val set_level : Logs.level -> unit
