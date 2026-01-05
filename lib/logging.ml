(** Logging configuration for Migra. *)

(** Setup logging with timestamps.

    This is called automatically when the library loads.
   
*)
let setup () =
  (* Check if the default nop reporter is still active *)
  let current_reporter = Logs.reporter () in
  if current_reporter == Logs.nop_reporter then
    (* No reporter set up yet, install ours *)
    begin
      Fmt_tty.setup_std_outputs ();
      let pp_header ppf (l, h) =
        let timestamp = Unix.gettimeofday () in
        let tm = Unix.localtime timestamp in
        let frac = int_of_float ((timestamp -. floor timestamp) *. 1000.) in
        let header = match h with Some h -> h | None -> "migra" in
        Fmt.pf ppf "%02d.%02d.%02d %02d:%02d:%02d.%03d %15s %a "
          (tm.tm_year mod 100)
          (tm.tm_mon + 1)
          tm.tm_mday
          tm.tm_hour
          tm.tm_min
          tm.tm_sec
          frac
          header
          Logs.pp_level l
      in
      let reporter = Logs_fmt.reporter ~pp_header () in
      Logs.set_reporter reporter;
      Logs.set_level (Some Logs.Info);
      ()
    end
  else
    (* Reporter already exists, respect the existing configuration *)
    ()

(** Set the minimum log level. *)
let set_level level =
  Logs.set_level (Some level)

(* Automatically initialize logging when the library is loaded *)
let () = setup ()
