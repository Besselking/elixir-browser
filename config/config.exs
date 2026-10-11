import Config

# The resolver level for every parsed script: :off, :info, or 1 to 4 (4 is the default).
# At level 4 every function that the resolver can rewrite runs on a slot frame. See
# `Browser.JS.Resolve`. The parse option `resolve:` overrides it. To go back to the old
# evaluator, for example to find out if a fault comes from the frames, set the level to
# :off:
# config :browser, js_resolve: :off

# Check mode of the slot frames (`JS_RESOLVE_CHECK=1`): the interpreter asserts that every
# slot access lands on the scope that owns the name. The flag is read when
# `lib/browser/js/interp.ex` compiles, so a change of it recompiles that file. Off, the
# checks cost nothing.
config :browser, js_resolve_check: System.get_env("JS_RESOLVE_CHECK") == "1"

# Closure compilation (step 5): a function that the resolver rewrote compiles at its first
# call into Elixir closures (`Browser.JS.Compile`). `JS_COMPILE=0` turns it off, so that the
# tree walker runs every function. `Browser.JS.Interp.init/1` reads the setting for each new
# heap, so one VM can run both modes (the differential oracle does).
config :browser, js_compile: System.get_env("JS_COMPILE") != "0"

import_config "#{config_env()}.exs"
