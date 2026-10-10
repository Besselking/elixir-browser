import Config
config :browser, gui: false
config :browser, history_path: nil
config :browser, local_storage_path: nil
config :browser, crash_dir: nil
config :browser, indexed_db_path: nil

# `JS_RESOLVE=1 mix test` runs every JS, DOM and page test with the resolver at level 1
# (see `Browser.JS.Resolve`); `:off` is the default. A test that passes `resolve:` to
# the parser keeps its own level.
config :browser,
  js_resolve:
    (case System.get_env("JS_RESOLVE") do
       nil -> :off
       "off" -> :off
       "info" -> :info
       "1" -> 1
       # (levels 2 to 4 run from steps 2c to 2e)
       other -> raise "JS_RESOLVE takes off, info or 1, not #{other}"
     end)
