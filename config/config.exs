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

import_config "#{config_env()}.exs"
