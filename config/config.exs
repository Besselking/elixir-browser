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

# Fast records (the shapes of the data model, `Browser.JS.Shape`). `JS_SHAPES=0` turns them
# off, so that every object is a dictionary record. `Browser.JS.Interp.init/1` reads the
# setting for each new heap.
config :browser, js_shapes: System.get_env("JS_SHAPES") != "0"

# The form of the elements of a new array (`Browser.JS.Elems`). `JS_ELEMS=sparse` makes
# each new array sparse (a map of the elements), so that two runs can show that the two
# forms give the same results. `Browser.JS.Interp.init/1` reads the setting for each new
# heap.
config :browser, js_elems_sparse: System.get_env("JS_ELEMS") == "sparse"

# The JS collector (`Browser.JS.GC`). `JS_GC=every` makes each page runtime collect after
# each timer, so that a test run shows a value that the walk does not reach.
# `Browser.JS.GC.enable/0` reads the setting for each process.
config :browser, js_gc_every: System.get_env("JS_GC") == "every"

import_config "#{config_env()}.exs"
