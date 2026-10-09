defmodule Browser.JS.Resolve.Info do
  @moduledoc """
  The facts the resolver knows about one function.

  `Browser.JS.Resolve` makes one `Info` for each function node in a program. The
  `Info` replaces the sixth element of the `{:fn, name, params, body, mode, src}`
  node and keeps the source text in `src`, so the node shape stays the same.

  The frame of a function is a tuple: `{parent_id, rec, caller_id, call_pos,
  root_id, slot_6, ...}`. The first five elements are the header. The slots
  start at position 6. A slot index in this struct is the absolute position in
  that tuple.

  The fields and the step that reads them:

  - `src`: the source text of the function, or `nil`. The closure keeps it for
    `Function.prototype.toString`.
  - `kind`: `:fn`, `:arrow`, `:arrow_expr`, `:method`, `:get`, `:set`, `:ctor`
    or `:derived_ctor`.
  - `name`: the name of the function, or `nil`.
  - `level`: the smallest resolve level that can run this function with slots:
    1 (a leaf: no closures, no `arguments`, not a constructor), 2 (makes
    closures), 3 (`arguments`, `new.target`, `super`, constructors, private
    names) or 4 (async or generator). `nil` when the function is dynamic.
  - `rewritten`: true when the names inside this function are slot forms. This
    is the one switch the interpreter reads (step 2b).
  - `strict`, `async?`, `generator?`, `dynamic`: facts about the function.
    A dynamic function contains a direct `eval` or a `with`, or sits inside one.
  - `params`: `:plain` (names only), `:patterns` (a pattern or a rest
    parameter, no initializer) or `:exprs` (an initializer).
  - `nparams`: the number of parameter positions, the rest parameter not
    counted. `rest?`: the last parameter is a rest parameter.
  - `size`: the size of the frame tuple, header included.
  - `slots`: name or hidden atom to slot index. A name-based lookup on a frame
    reads this map. Block names are not in it. The arguments object sits
    under the name `"arguments"`, or under the atom `:arguments` when the
    body declares a function or a lexical of that name (the object is then
    visible from the parameter defaults only).
  - `hidden`: the hidden slots in slot order: `:this`, `:args`, `:arguments`,
    `:new_target`, `:home`, `:ctor_fn`, `:self`.
  - `kinds`: a tuple with one element per frame position. Positions 1 to 5
    name the header (`:parent`, `:rec`, `:caller`, `:call_pos`, `:root`).
    From position 6: `:param`, `:var`, `:fun`, `:let`, `:const`, `:class`,
    `:using`, `:hidden` or `:self`.
  - `template`: the initial values of the slots after the parameters and the
    hidden slots, in slot order (`:undefined` or `:tdz`). The parameter slots
    are not in it: a frame builder fills them from the arguments, and sets
    them to `:tdz` first when `params` is `:exprs`.
  - `hoist`: `{slot, function_node}` pairs to instantiate at entry, in source
    order. The last pair for a slot wins.
  - `copies`: `{from, to}` slot pairs copied at body entry (a `var` that has a
    parameter's name, when a closure in an initializer captures the parameter).
  - `self`: the slot of the function's own name, or `nil`.
  - `argmap`: parameter name to argument index for a mapped `arguments`
    object, or `nil`.
  - `uses_this`, `uses_arguments`, `uses_new_target`, `uses_super`: the
    function or an arrow inside it reads these.
  - `args_var`: the body declares `var arguments` and no function of that name.
  - `makes_closures`: a function or class node is inside this function.
  - `has_await`: a statement of the body contains `await`, `yield` or
    `for await`.
  - `captured`: the slots that an inner function reads or writes.
  - `free`: `:always` when the frame is erased on return, `:counter` when the
    closure counter decides (step 2c).
  - `tail_sites`: the number of `return` statements marked as tail calls.
  """

  defstruct src: nil,
            kind: :fn,
            name: nil,
            level: nil,
            rewritten: false,
            strict: false,
            async?: false,
            generator?: false,
            dynamic: false,
            params: :plain,
            nparams: 0,
            rest?: false,
            size: 5,
            slots: %{},
            hidden: [],
            kinds: {:parent, :rec, :caller, :call_pos, :root},
            template: [],
            hoist: [],
            copies: [],
            self: nil,
            argmap: nil,
            uses_this: false,
            uses_arguments: false,
            uses_new_target: false,
            uses_super: false,
            args_var: false,
            makes_closures: false,
            has_await: false,
            captured: MapSet.new(),
            free: :always,
            tail_sites: 0

  @type t :: %__MODULE__{}
end
