(** Public database lifecycle and connection-URL helpers. *)

let create_database = Migra_engine.Database.create_database
let drop_database = Migra_engine.Database.drop_database
let database_name = Migra_engine.Database.database_name
let get_database_url = Migra_engine.Database.get_database_url
let redact_url = Migra_engine.Database.redact_url
