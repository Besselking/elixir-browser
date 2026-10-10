import Config
config :browser, gui: false
config :browser, history_path: nil
config :browser, local_storage_path: nil
config :browser, crash_dir: nil
config :browser, indexed_db_path: nil

# `JS_RESOLVE=1 mix test` runs every JS, DOM and page test with the resolver at level 1,
# and `JS_RESOLVE=2` runs them at level 2 (see `Browser.JS.Resolve`); `:off` is the
# default. A test that passes `resolve:` to the parser keeps its own level.
config :browser,
  js_resolve:
    (case System.get_env("JS_RESOLVE") do
       nil -> :off
       "off" -> :off
       "info" -> :info
       "1" -> 1
       "2" -> 2
       # Levels 3 and 4 are refused here because they cannot run until steps 2d and 2e.
       other -> raise "JS_RESOLVE takes off, info, 1 or 2, not #{other}"
     end)
