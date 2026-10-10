defmodule Browser.JS.FramesTest do
  # Step 2b: a function that the resolver rewrote at level 1 runs on a tuple frame. The
  # first part builds frames by hand in the test process and calls the evaluator on each
  # new node form. The second part runs the semantic table of the design at `:off` and at
  # level 1 and compares the results. The design is notes/js-frames-2b-design.md.
  use ExUnit.Case, async: true

  alias Browser.JS
  alias Browser.JS.{Interp, Parser}
  alias Browser.JS.Resolve.{Info, Scope}

  @tdz_x "Cannot access 'x' before initialization"

  # True in the check build (`JS_RESOLVE_CHECK=1`), where the evaluator refuses a slot
  # form that lands on the wrong scope (design section 5).
  @check Application.compile_env(:browser, :js_resolve_check, false)
  @const_msg "Assignment to constant variable."

  # ── helpers ────────────────────────────────────────────────

  # Starts a heap in the test process. The built-ins must exist because an error thrown
  # by the evaluator is an object with a prototype.
  defp heap do
    Interp.init(1_000_000)
    Browser.JS.Builtins.install()
    Interp.global()
  end

  # The first function node named `name` in `src`, resolved at level 1.
  defp leaf(src, name, opts \\ []) do
    assert {:ok, tree} = Parser.parse(src, [resolve: 1] ++ opts), src
    node = find(tree, &match?({:fn, ^name, _, _, _, %Info{}}, &1))
    assert node != nil, "no function #{name} in #{inspect(tree)}"
    node
  end

  defp find(node, pred) do
    cond do
      pred.(node) -> node
      is_tuple(node) -> node |> Tuple.to_list() |> find(pred)
      is_list(node) -> Enum.find_value(node, &find(&1, pred))
      true -> nil
    end
  end

  defp info({:fn, _, _, _, _, %Info{} = i}), do: i

  # A frame of `info` under `parent` with the given slot values, stored in the heap. The
  # root is the global scope, as `make_fn` computes it for a function made at the top.
  defp frame(parent, info, slots) do
    Interp.alloc(List.to_tuple([parent, info, nil, nil, Interp.global() | slots]))
  end

  defp slot(fid, i), do: elem(:erlang.get(fid), i - 1)

  # Runs `fun` and reports what it threw: a JS error as `{name, message}`, a return or a
  # tail call as a tagged tuple, or `{:value, v}` when nothing was thrown.
  defp caught(fun) do
    try do
      {:value, fun.()}
    catch
      {:js_error, v} -> {Interp.get(v, "name"), Interp.get(v, "message")}
      {:js_return, v} -> {:return, v}
      {:js_tail, f, t, a} -> {:tail, f, t, a}
      :js_limit -> :js_limit
    end
  end

  # A native `peek()` for a leaf body: it records the newest frame of the heap, so a test
  # can look at a frame while the call that built it is still running. The frame is the
  # highest id whose entry is a tuple with an `Info` in the second position.
  defp install_peek(gid) do
    peek =
      Interp.native("peek", fn _this, _args ->
        last = :erlang.get(:js_next) - 1

        found =
          Enum.find_value(last..0//-1, fn id ->
            case :erlang.get(id) do
              t when is_tuple(t) and tuple_size(t) >= 5 ->
                if match?(%Info{}, elem(t, 1)), do: {id, t}

              _ ->
                nil
            end
          end)

        Process.put(:peeked, found)
        :undefined
      end)

    Interp.declare(gid, "peek", peek)
  end

  defp peeked, do: Process.get(:peeked)

  # The closure record of a function object.
  defp closure({:obj, id}) do
    %{fun: {:closure, c}} = Interp.deref(id)
    c
  end

  # Runs a script in the test process at the given level.
  defp run_script(src, level \\ :off) do
    assert {:ok, program} = Parser.parse(src, resolve: level), src
    Interp.run_program(program, true)
  end

  # ── the frame builder ──────────────────────────────────────

  describe "the frame builder" do
    test "plain parameters: arguments, hidden slots and the template in one tuple" do
      gid = heap()
      install_peek(gid)
      node = leaf("function f(a, b){ peek(); var c; let d; return 0 }", "f")
      f = Interp.make_function(node, gid, false)
      pos = Process.get(:js_pos)

      assert Interp.call(f, :undefined, [1.0]) == 0.0

      # Design 6: `{gid, %Info{}, nil, nil, gid, 1.0, :undefined, :undefined, :tdz}`. The
      # missing `b` is `:undefined`, `var c` starts as `:undefined` and `let d` in the TDZ.
      assert {fid,
              {^gid, %Info{rewritten: true}, nil, ^pos, ^gid, 1.0, :undefined, :undefined, :tdz}} =
               peeked()

      assert tuple_size(elem(peeked(), 1)) == info(node).size

      # The frame is erased when the call returns.
      assert :erlang.get(fid) == :undefined

      # Extra arguments are dropped.
      assert Interp.call(f, :undefined, [1.0, 2.0, 3.0]) == 0.0
      assert {_, {_, _, _, _, _, 1.0, 2.0, :undefined, :tdz}} = peeked()
    end

    test "duplicate parameter names: both positions are filled and the last one is read" do
      gid = heap()
      install_peek(gid)
      f = Interp.make_function(leaf("function f(a, a){ peek(); return a }", "f"), gid, false)

      assert Interp.call(f, :undefined, [1.0, 2.0]) == 2.0
      assert {_, {_, _, _, _, _, 1.0, 2.0}} = peeked()
    end

    test "pattern parameters: one slot per name, `nnames` counts them" do
      gid = heap()
      install_peek(gid)
      src = "function f({a}, [b], ...r){ peek(); return a + b + r.length }"
      node = leaf(src, "f")
      f = Interp.make_function(node, gid, false)
      obj = Interp.new_object([{"a", 1.0}])
      arr = Interp.new_array([2.0])

      assert Interp.call(f, :undefined, [obj, arr, 3.0, 4.0]) == 5.0
      assert {_, {_, _, _, _, _, 1.0, 2.0, {:obj, _} = rest}} = peeked()
      assert Interp.array_list(rest) == [3.0, 4.0]

      # `nnames` is derived from `size` (design 1.1) and must agree with the names of the
      # unresolved parameter list.
      {:ok, plain} = Parser.parse(src, resolve: :off)
      {:fn, _, params, _, _, _} = find(plain, &match?({:fn, "f", _, _, _, _}, &1))
      assert closure(f).nnames == length(Enum.flat_map(params, &Interp.pattern_names(&1, [])))
      assert closure(f).root == gid
    end

    test "default parameters: the slots start in the TDZ and fill in order" do
      gid = heap()
      install_peek(gid)

      f =
        Interp.make_function(
          leaf("function f(a, b = a + 1){ peek(); return a + b }", "f"),
          gid,
          false
        )

      assert Interp.call(f, :undefined, [1.0]) == 3.0
      assert {_, {_, _, _, _, _, 1.0, 2.0}} = peeked()

      g = Interp.make_function(leaf("function f(a = b, b){}", "f"), gid, false)

      assert caught(fn -> Interp.call(g, :undefined, []) end) ==
               {"ReferenceError", "Cannot access 'b' before initialization"}
    end

    test "the hidden `this` slot: raw when strict, the global `this` or a box when sloppy" do
      gid = heap()
      install_peek(gid)

      strict =
        Interp.make_function(
          leaf("function f(){ 'use strict'; peek(); return this }", "f"),
          gid,
          false
        )

      assert Interp.call(strict, 5.0, []) == 5.0
      assert {_, {_, _, _, _, _, 5.0}} = peeked()
      assert Interp.call(strict, :undefined, []) == :undefined

      sloppy = Interp.make_function(leaf("function f(){ peek(); return this }", "f"), gid, false)

      # Without a page the global scope may have no `this`; then `this` stays undefined.
      global_this =
        case Interp.lookup_scoped(gid, :this) do
          {:ok, w} -> w
          :error -> :undefined
        end

      assert Interp.call(sloppy, :undefined, []) == global_this
      assert {_, {_, _, _, _, _, ^global_this}} = peeked()

      boxed = Interp.call(sloppy, 5.0, [])
      assert Interp.typeof(boxed) == "object"
      assert {_, {_, _, _, _, _, ^boxed}} = peeked()
    end

    test "the hidden `self` slot holds the function, and no self-name scope is made" do
      gid = heap()
      install_peek(gid)
      {:ok, tree} = Parser.parse("var g = function h(){ peek(); return h }", resolve: 1)
      node = find(tree, &match?({:fn, "h", _, _, _, %Info{}}, &1))
      assert %Info{hidden: [:self], self: 6} = info(node)

      g = Interp.make_function(node, gid, true)
      assert Interp.call(g, :undefined, []) == g
      assert {_, {^gid, _, _, _, _, ^g}} = peeked()
      # One extra map scope would shift every `{:mref}` hop count by one (design 1.2).
      assert closure(g).scope == gid
    end
  end

  # ── the forms ──────────────────────────────────────────────

  describe "the forms on a hand-built frame" do
    # `a` is slot 6, `b` 7, `c` 8 (`var`), `d` 9 (`let`), `e` 10 (`const`).
    @vars "function f(a, b){ var c; let d; const e = 1 }"

    defp vars_frame(gid) do
      i = info(leaf(@vars, "f"))
      assert %Info{slots: %{"a" => 6, "b" => 7, "c" => 8, "d" => 9, "e" => 10}} = i
      frame(gid, i, [1.0, 2.0, :undefined, :tdz, :tdz])
    end

    test "{:slot}: read, write, TDZ, compound and update" do
      gid = heap()
      fid = vars_frame(gid)

      assert Interp.ev({:slot, 0, 6, "a"}, fid) == 1.0
      assert Interp.ev({:slot, 0, 8, "c"}, fid) == :undefined

      assert caught(fn -> Interp.ev({:slot, 0, 9, "d"}, fid) end) ==
               {"ReferenceError", "Cannot access 'd' before initialization"}

      assert Interp.ev({:assign, "=", {:slot, 0, 8, "c"}, {:num, 5.0}}, fid) == 5.0
      assert slot(fid, 8) == 5.0

      # A write to a slot in the TDZ is the same error as a read.
      assert caught(fn -> Interp.ev({:assign, "=", {:slot, 0, 9, "d"}, {:num, 5.0}}, fid) end) ==
               {"ReferenceError", "Cannot access 'd' before initialization"}

      assert caught(fn -> Interp.ev({:assign, "+=", {:slot, 0, 9, "d"}, {:num, 5.0}}, fid) end) ==
               {"ReferenceError", "Cannot access 'd' before initialization"}

      assert caught(fn -> Interp.ev({:update, "++", true, {:slot, 0, 9, "d"}}, fid) end) ==
               {"ReferenceError", "Cannot access 'd' before initialization"}

      assert Interp.ev({:assign, "+=", {:slot, 0, 6, "a"}, {:num, 1.0}}, fid) == 2.0
      assert Interp.ev({:update, "++", true, {:slot, 0, 6, "a"}}, fid) == 3.0
      assert Interp.ev({:update, "++", false, {:slot, 0, 6, "a"}}, fid) == 3.0
      assert slot(fid, 6) == 4.0
      assert Interp.ev({:sassign, "=", {:slot, 0, 6, "a"}, {:num, 9.0}}, fid) == 9.0
      assert slot(fid, 6) == 9.0
    end

    test "{:slot} in a declaration pattern writes without a check" do
      gid = heap()
      fid = vars_frame(gid)

      Interp.bind_pattern({:slot, 0, 9, "d"}, 7.0, fid, :let)
      assert slot(fid, 9) == 7.0
      Interp.bind_pattern({:slot, 0, 10, "e"}, 1.0, fid, :const)
      assert slot(fid, 10) == 1.0

      Interp.bind_pattern({:default, {:slot, 0, 6, "a"}, {:num, 8.0}}, :undefined, fid, :let)
      assert slot(fid, 6) == 8.0

      arr = Interp.new_array([1.0, 2.0, 3.0])
      pat = {:arrpat, [{:slot, 0, 6, "a"}, {:rest, {:slot, 0, 7, "b"}}]}
      Interp.bind_pattern(pat, arr, fid, :let)
      assert slot(fid, 6) == 1.0
      assert Interp.array_list(slot(fid, 7)) == [2.0, 3.0]

      # A `const` declaration writes its slot like any other declaration.
      Interp.exec_stmt({:var, :const, [{{:slot, 0, 10, "e"}, {:num, 3.0}}]}, fid)
      assert slot(fid, 10) == 3.0

      # `let x = x` reads the slot in the initializer first and throws there. The slot is
      # put back in the TDZ first, because the bind above filled it.
      :erlang.put(fid, :erlang.setelement(9, :erlang.get(fid), :tdz))

      assert caught(fn ->
               Interp.exec_stmt({:var, :let, [{{:slot, 0, 9, "d"}, {:slot, 0, 9, "d"}}]}, fid)
             end) == {"ReferenceError", "Cannot access 'd' before initialization"}
    end

    test "{:cslot}: ReferenceError in the TDZ, else TypeError, after the right side ran" do
      gid = heap()
      fid = vars_frame(gid)

      assert caught(fn -> Interp.ev({:assign, "=", {:cslot, 0, 10, "e"}, {:num, 2.0}}, fid) end) ==
               {"ReferenceError", "Cannot access 'e' before initialization"}

      Interp.bind_pattern({:slot, 0, 10, "e"}, 1.0, fid, :const)

      assert caught(fn -> Interp.ev({:assign, "=", {:cslot, 0, 10, "e"}, {:num, 2.0}}, fid) end) ==
               {"TypeError", @const_msg}

      assert caught(fn -> Interp.ev({:sassign, "=", {:cslot, 0, 10, "e"}, {:num, 2.0}}, fid) end) ==
               {"TypeError", @const_msg}

      assert caught(fn -> Interp.ev({:assign, "+=", {:cslot, 0, 10, "e"}, {:num, 2.0}}, fid) end) ==
               {"TypeError", @const_msg}

      assert caught(fn -> Interp.ev({:update, "++", false, {:cslot, 0, 10, "e"}}, fid) end) ==
               {"TypeError", @const_msg}

      # The right side runs before the error: `c` is written.
      rhs = {:assign, "=", {:slot, 0, 8, "c"}, {:num, 9.0}}

      assert caught(fn -> Interp.ev({:assign, "=", {:cslot, 0, 10, "e"}, rhs}, fid) end) ==
               {"TypeError", @const_msg}

      assert slot(fid, 8) == 9.0
      assert slot(fid, 10) == 1.0

      assert caught(fn -> Interp.bind_pattern({:cslot, 0, 10, "e"}, 5.0, fid, :assign) end) ==
               {"TypeError", @const_msg}
    end

    test "{:fname}: the right side is the value, nothing is written" do
      gid = heap()
      fid = vars_frame(gid)
      assert Interp.ev({:assign, "=", {:fname, 0, 6, "a"}, {:num, 3.0}}, fid) == 3.0
      assert slot(fid, 6) == 1.0
      Interp.bind_pattern({:fname, 0, 6, "a"}, 3.0, fid, :assign)
      assert slot(fid, 6) == 1.0
    end

    test "{:this}: a slot read" do
      gid = heap()
      # The check of design 5 needs `slots[:this] == i`, so the frame comes from a strict
      # function that uses `this`: the hidden slot follows the parameter.
      i = info(leaf("function f(a){ 'use strict'; return this }", "f"))
      assert %Info{slots: %{:this => 7, "a" => 6}, hidden: [:this]} = i
      fid = frame(gid, i, [1.0, 2.0])
      assert Interp.ev({:this, 0, 7}, fid) == 2.0
    end

    test "{:in_tdz} runs the expression; the names hold :tdz in their own slots" do
      gid = heap()
      fid = vars_frame(gid)
      assert Interp.ev({:in_tdz, ["d"], {:num, 1.0}}, fid) == 1.0

      assert caught(fn -> Interp.ev({:in_tdz, ["d"], {:slot, 0, 9, "d"}}, fid) end) ==
               {"ReferenceError", "Cannot access 'd' before initialization"}
    end

    test "typeof and delete on the slot forms" do
      gid = heap()
      fid = vars_frame(gid)
      assert Interp.ev({:unary, "typeof", {:slot, 0, 6, "a"}}, fid) == "number"
      assert Interp.ev({:unary, "typeof", {:slot, 0, 8, "c"}}, fid) == "undefined"

      assert caught(fn -> Interp.ev({:unary, "typeof", {:slot, 0, 9, "d"}}, fid) end) ==
               {"ReferenceError", "Cannot access 'd' before initialization"}

      for form <- [
            {:slot, 0, 6, "a"},
            {:cslot, 0, 10, "e"},
            {:fname, 0, 6, "a"},
            {:mref, 1, "zz"}
          ] do
        assert Interp.ev({:unary, "delete", form}, fid) == false, inspect(form)
      end

      # The delete did not look the slot up, so a slot in the TDZ gives false too.
      assert Interp.ev({:unary, "delete", {:slot, 0, 9, "d"}}, fid) == false
    end

    test "a call through a slot keeps the name in the error" do
      gid = heap()
      fid = vars_frame(gid)

      assert caught(fn -> Interp.ev({:call, {:slot, 0, 6, "a"}, [], false}, fid) end) ==
               {"TypeError", "a is not a function"}

      assert caught(fn -> Interp.ev({:call, {:gref, "undefined"}, [], false}, fid) end) ==
               {"TypeError", "undefined is not a function"}
    end

    test "ev_named gives a function the slot's name" do
      gid = heap()
      fid = vars_frame(gid)
      f = Interp.ev_named({:fn, nil, [], [], false, nil}, fid, {:slot, 0, 6, "a"})
      assert Interp.get(f, "name") == "a"
      g = Interp.ev_named({:fn, nil, [], [], false, nil}, fid, {:gref, "gg"})
      assert Interp.get(g, "name") == "gg"
    end

    test "{:gref}: the root scope answers every role" do
      gid = heap()
      fid = vars_frame(gid)
      Interp.declare(gid, "G", 10.0)
      Interp.declare(gid, "L", :tdz)

      assert Interp.ev({:gref, "G"}, fid) == 10.0
      assert Interp.ev({:assign, "=", {:gref, "G"}, {:num, 11.0}}, fid) == 11.0
      assert Interp.lookup_scoped(gid, "G") == {:ok, 11.0}
      assert Interp.ev({:assign, "+=", {:gref, "G"}, {:num, 1.0}}, fid) == 12.0
      assert Interp.ev({:update, "++", false, {:gref, "G"}}, fid) == 12.0
      assert Interp.lookup_scoped(gid, "G") == {:ok, 13.0}
      Interp.bind_pattern({:gref, "G"}, 7.0, fid, :assign)
      assert Interp.lookup_scoped(gid, "G") == {:ok, 7.0}

      # A sloppy write to an unknown name makes a global; a strict one is an error.
      assert Interp.ev({:assign, "=", {:gref, "H"}, {:num, 5.0}}, fid) == 5.0
      assert Interp.lookup_scoped(gid, "H") == {:ok, 5.0}

      assert caught(fn -> Interp.ev({:sassign, "=", {:gref, "ZZ"}, {:num, 1.0}}, fid) end) ==
               {"ReferenceError", "ZZ is not defined"}

      assert caught(fn -> Interp.ev({:gref, "nope"}, fid) end) ==
               {"ReferenceError", "nope is not defined"}

      assert Interp.ev({:unary, "typeof", {:gref, "nope"}}, fid) == "undefined"

      assert caught(fn -> Interp.ev({:gref, "L"}, fid) end) ==
               {"ReferenceError", "Cannot access 'L' before initialization"}

      assert caught(fn -> Interp.ev({:unary, "typeof", {:gref, "L"}}, fid) end) ==
               {"ReferenceError", "Cannot access 'L' before initialization"}

      # The RHS runs in the frame: it reads a slot.
      assert Interp.ev({:assign, "=", {:gref, "G"}, {:slot, 0, 6, "a"}}, fid) == 1.0
      assert Interp.lookup_scoped(gid, "G") == {:ok, 1.0}

      # `delete` keeps the global-object rules: an implicit global goes away.
      assert Interp.ev({:unary, "delete", {:gref, "H"}}, fid) == true
      assert Interp.ev({:unary, "typeof", {:gref, "H"}}, fid) == "undefined"

      # An accessor property of the global object is a variable too (row 26).
      run_script("Object.defineProperty(globalThis, 'acc', {get(){ return 42 }})")
      assert Interp.ev({:gref, "acc"}, fid) == 42.0
    end

    test "{:mref}: a hop to a map scope, then today's lookup" do
      gid = heap()
      m = Interp.new_scope(gid)
      Interp.declare(m, "b", 1.0)
      Interp.declare(m, "k", 2.0, true)
      Interp.declare(m, "t", :tdz)
      fid = frame(m, info(leaf(@vars, "f")), [1.0, 2.0, :undefined, :tdz, :tdz])

      assert Interp.ev({:mref, 1, "b"}, fid) == 1.0
      assert Interp.ev({:assign, "=", {:mref, 1, "b"}, {:num, 3.0}}, fid) == 3.0
      assert Interp.lookup_scoped(m, "b") == {:ok, 3.0}
      assert Interp.ev({:assign, "+=", {:mref, 1, "b"}, {:num, 1.0}}, fid) == 4.0
      assert Interp.ev({:update, "++", true, {:mref, 1, "b"}}, fid) == 5.0
      assert Interp.ev({:unary, "typeof", {:mref, 1, "b"}}, fid) == "number"
      Interp.bind_pattern({:mref, 1, "b"}, 9.0, fid, :assign)
      assert Interp.lookup_scoped(m, "b") == {:ok, 9.0}

      assert caught(fn -> Interp.ev({:sassign, "=", {:mref, 1, "k"}, {:num, 1.0}}, fid) end) ==
               {"TypeError", @const_msg}

      assert caught(fn -> Interp.ev({:mref, 1, "t"}, fid) end) ==
               {"ReferenceError", "Cannot access 't' before initialization"}

      # A name the map scope does not hold falls through to the chain above it (design
      # 2.2). The resolver never emits such a form, and the check build refuses it.
      unless @check do
        Interp.declare(gid, "G", 10.0)
        assert Interp.ev({:mref, 1, "G"}, fid) == 10.0
      end
    end
  end

  # ── the by-name path through a frame ───────────────────────

  describe "the by-name path" do
    test "lookup, typeof and {:id} reads walk through the frame" do
      gid = heap()
      Interp.declare(gid, "G", 10.0)
      i = info(leaf("function f(a, b){ var c; let d; const e = 1 }", "f"))
      fid = frame(gid, i, [1.0, 2.0, :undefined, :tdz, :tdz])

      assert Interp.lookup_scoped(fid, "a") == {:ok, 1.0}
      assert Interp.lookup_scoped(fid, "d") == {:ok, :tdz}
      assert Interp.lookup_scoped(fid, "G") == {:ok, 10.0}
      assert Interp.lookup_scoped(fid, "nope") == :error
      assert Interp.ev({:id, "a"}, fid) == 1.0
      assert Interp.ev({:unary, "typeof", {:id, "a"}}, fid) == "number"
      assert Interp.ev({:id, "G"}, fid) == 10.0

      assert caught(fn -> Interp.ev({:id, "d"}, fid) end) ==
               {"ReferenceError", "Cannot access 'd' before initialization"}
    end

    test ":strict answers from the Info, else from the chain" do
      gid = heap()
      strict = frame(gid, info(leaf("function f(){ 'use strict' }", "f")), [])
      sloppy = frame(gid, info(leaf("function f(){ }", "f")), [])
      assert Interp.lookup_scoped(strict, :strict) == {:ok, true}
      assert Interp.lookup_scoped(sloppy, :strict) == Interp.lookup_scoped(gid, :strict)
    end

    test "assign_scoped: own slot, TDZ, const, self name, and the hop to the parent" do
      # `assign_scoped/3` is the `@doc false` entry of design 6 for the `assign_var` walker.
      gid = heap()
      Interp.declare(gid, "G", 10.0)
      i = info(leaf("function f(a, b){ var c; let d; const e = 1 }", "f"))
      fid = frame(gid, i, [1.0, 2.0, :undefined, :tdz, 1.0])

      Interp.assign_scoped(fid, "a", 5.0)
      assert slot(fid, 6) == 5.0
      Interp.assign_scoped(fid, "G", 11.0)
      assert Interp.lookup_scoped(gid, "G") == {:ok, 11.0}

      assert caught(fn -> Interp.assign_scoped(fid, "d", 1.0) end) ==
               {"ReferenceError", "Cannot access 'd' before initialization"}

      assert caught(fn -> Interp.assign_scoped(fid, "e", 2.0) end) == {"TypeError", @const_msg}
      assert slot(fid, 10) == 1.0

      {:ok, tree} = Parser.parse("var g = function h(){ return h }", resolve: 1)
      self_info = info(find(tree, &match?({:fn, "h", _, _, _, %Info{}}, &1)))
      sfid = frame(gid, self_info, [{:obj, 0}])
      assert Interp.assign_scoped(sfid, "h", 1.0) == :fname_ignored
      assert slot(sfid, 6) == {:obj, 0}
    end
  end

  # ── statements ─────────────────────────────────────────────

  describe "statements through exec_stmt" do
    # `x` is slot 6 (`let`), `y` slot 7 (`let`).
    @two "function f(){ let x; let y }"

    defp two_frame(gid, x, y) do
      i = info(leaf(@two, "f"))
      assert %Info{slots: %{"x" => 6, "y" => 7}} = i
      frame(gid, i, [x, y])
    end

    test "return forms: :plain is a plain return, :tail runs the trampoline" do
      gid = heap()
      fid = two_frame(gid, 1.0, 2.0)
      g = Interp.native("g", fn _, _ -> 42.0 end)
      Interp.declare(gid, "g", g)

      assert caught(fn -> Interp.exec_stmt({:return, {:num, 1.0}, :plain}, fid) end) ==
               {:return, 1.0}

      assert caught(fn -> Interp.exec_stmt({:return, {:num, 1.0}, :tail}, fid) end) ==
               {:return, 1.0}

      # A call under `:plain` is made here, whatever `:js_tail` says.
      Process.put(:js_tail, true)
      call = {:call, {:gref, "g"}, [], false}
      assert caught(fn -> Interp.exec_stmt({:return, call, :plain}, fid) end) == {:return, 42.0}
      Process.put(:js_tail, false)

      assert caught(fn -> Interp.exec_stmt({:return, call, :tail}, fid) end) ==
               {:tail, g, :undefined, []}

      assert caught(fn -> Interp.exec_stmt({:return, nil}, fid) end) == {:return, :undefined}
    end

    test "{:block}: nil runs the list, a Scope resets its slots first" do
      gid = heap()
      fid = two_frame(gid, 5.0, 6.0)
      write = {:expr, {:assign, "=", {:slot, 0, 7, "y"}, {:num, 1.0}}}

      Interp.exec_stmt({:block, [write], nil}, fid)
      assert slot(fid, 7) == 1.0

      Interp.exec_stmt({:block, [], %Scope{kind: :block, tdz: [6]}}, fid)
      assert slot(fid, 6) == :tdz
      assert slot(fid, 7) == 1.0

      # A read inside the block sees the TDZ again, whatever the slot held before.
      sc = %Scope{kind: :block, tdz: [6]}
      :erlang.put(fid, :erlang.setelement(6, :erlang.get(fid), 5.0))

      assert caught(fn -> Interp.exec_stmt({:block, [{:expr, {:slot, 0, 6, "x"}}], sc}, fid) end) ==
               {"ReferenceError", @tdz_x}
    end

    test "{:for}: the head slots are reset and the loop runs in the frame" do
      gid = heap()
      src = "function f(){ var s = 0; for (let i = 0; i < 3; i++) s += i; return s }"
      {:fn, _, _, [var_s, for_stmt, ret], _, i} = leaf(src, "f")
      assert {:for, _, _, _, _, %Scope{kind: :loop, tdz: [7]}} = for_stmt
      fid = frame(gid, i, [:undefined, 5.0])

      Interp.exec_stmt(var_s, fid)
      Interp.exec_stmt(for_stmt, fid)
      assert slot(fid, 6) == 3.0
      assert caught(fn -> Interp.exec_stmt(ret, fid) end) == {:return, 3.0}

      # No scope was made for the loop: the frame is the newest heap entry.
      assert :erlang.get(:js_next) == fid + 1
    end

    test "{:forin} and {:forof}: the head is read in the TDZ, each item resets the slots" do
      gid = heap()
      fid = two_frame(gid, 5.0, 6.0)
      sc = %Scope{kind: :each, tdz: [6]}

      obj = {:object, [{:init, {:str, "k"}, {:num, 1.0}}]}
      Interp.exec_stmt({:forin, :const, {:slot, 0, 6, "x"}, obj, {:empty}, sc}, fid)
      assert slot(fid, 6) == "k"

      Interp.exec_stmt({:forin, :const, {:slot, 0, 6, "x"}, {:object, []}, {:empty}, sc}, fid)
      assert slot(fid, 6) == :tdz

      arr = {:array, [{:num, 1.0}, {:num, 2.0}]}
      body = {:expr, {:assign, "+=", {:slot, 0, 7, "y"}, {:slot, 0, 6, "x"}}}
      Interp.exec_stmt({:forof, :let, {:slot, 0, 6, "x"}, arr, body, sc}, fid)
      assert slot(fid, 6) == 2.0
      assert slot(fid, 7) == 9.0

      # The head names are in the TDZ while the object expression runs.
      assert caught(fn ->
               Interp.exec_stmt(
                 {:forof, :let, {:slot, 0, 6, "x"}, {:slot, 0, 6, "x"}, {:empty}, sc},
                 fid
               )
             end) == {"ReferenceError", @tdz_x}

      # A default that reads its own name throws on the second round, because the
      # slot is reset per item (design 5 b: the TDZ message, not `a is not defined`).
      {:fn, _, _, [forof], _, i} = leaf("function f(){ for (const [a = a] of [[1], []]) ; }", "f")
      afid = frame(gid, i, [:tdz])

      assert caught(fn -> Interp.exec_stmt(forof, afid) end) ==
               {"ReferenceError", "Cannot access 'a' before initialization"}
    end

    test "{:switch}: the discriminant runs first, then the reset" do
      gid = heap()
      fid = two_frame(gid, 5.0, 6.0)
      sc = %Scope{kind: :switch, tdz: [6]}

      # The discriminant still sees the old value: the reset comes after it.
      Interp.exec_stmt({:switch, {:slot, 0, 6, "x"}, [], sc}, fid)
      assert slot(fid, 6) == :tdz

      cases = [
        {{:num, 1.0}, [{:var, :let, [{{:slot, 0, 6, "x"}, {:str, "one"}}]}, {:break, nil}]},
        {:default, [{:expr, {:assign, "=", {:slot, 0, 7, "y"}, {:str, "other"}}}]}
      ]

      Interp.exec_stmt({:switch, {:num, 1.0}, cases, sc}, fid)
      assert slot(fid, 6) == "one"
      Interp.exec_stmt({:switch, {:num, 2.0}, cases, sc}, fid)
      assert slot(fid, 6) == :tdz
      assert slot(fid, 7) == "other"
    end

    test "{:try}: the catch parameter lands in its slot after the reset" do
      gid = heap()
      fid = two_frame(gid, 5.0, 6.0)
      # The catch scope owns only its parameter `x`: a reset of `y` would put the
      # handler's write to `y` in the TDZ.
      sc = %Scope{kind: :catch, tdz: [6]}
      body = {:block, [{:throw, {:num, 1.0}}], nil}
      handler = {:block, [{:expr, {:assign, "=", {:slot, 0, 7, "y"}, {:slot, 0, 6, "x"}}}], nil}

      Interp.exec_stmt({:try, body, {:slot, 0, 6, "x"}, handler, nil, sc}, fid)
      assert slot(fid, 6) == 1.0
      assert slot(fid, 7) == 1.0

      # A pattern parameter binds through the slot clauses too.
      pat = {:objpat, [{{:str, "a"}, {:slot, 0, 6, "x"}}], nil}
      thrown = {:block, [{:throw, {:object, [{:init, {:str, "a"}, {:num, 7.0}}]}}], nil}
      Interp.exec_stmt({:try, thrown, pat, {:block, [], nil}, nil, sc}, fid)
      assert slot(fid, 6) == 7.0

      # Without a throw the slots are not touched, and the finalizer runs.
      fin = {:block, [{:expr, {:assign, "=", {:slot, 0, 7, "y"}, {:num, 2.0}}}], nil}
      Interp.exec_stmt({:try, {:block, [], nil}, {:slot, 0, 6, "x"}, handler, fin, sc}, fid)
      assert slot(fid, 6) == 7.0
      assert slot(fid, 7) == 2.0
    end

    test "{:using} with a slot target disposes at the end of the block" do
      gid = heap()
      run_script("var log = []; var res = { [Symbol.dispose](){ log.push('d') } }")
      src = "function f(){ { using r = res; log.push('b') } return log.join() }"
      {:fn, _, _, [block, _ret], _, i} = leaf(src, "f")

      assert {:block, [{:using, :using, {:slot, 0, 6, "r"}, {:gref, "res"}, _}], %Scope{tdz: [6]}} =
               block

      fid = frame(gid, i, [:tdz])

      Interp.exec_stmt(block, fid)
      {:ok, log} = Interp.lookup_scoped(gid, "log")
      assert Interp.array_list(log) == ["b", "d"]
      {:ok, res} = Interp.lookup_scoped(gid, "res")
      assert slot(fid, 6) == res
    end
  end

  # ── the free rule, the heap and check mode ─────────────────

  describe "the free rule" do
    test "the frame is erased after a return, a throw and a step limit" do
      gid = heap()
      install_peek(gid)
      ok = Interp.make_function(leaf("function f(){ peek(); return 1 }", "f"), gid, false)
      bad = Interp.make_function(leaf("function f(){ peek(); throw 1 }", "f"), gid, false)

      spin =
        Interp.make_function(leaf("function f(){ peek(); while (true) {} }", "f"), gid, false)

      depth = :erlang.get(:js_depth)
      stack = Process.get(:js_stack, [])

      assert Interp.call(ok, :undefined, []) == 1.0
      {fid, _} = peeked()
      assert :erlang.get(fid) == :undefined

      assert catch_throw(Interp.call(bad, :undefined, [])) == {:js_error, 1.0}
      {fid, _} = peeked()
      assert :erlang.get(fid) == :undefined
      assert :erlang.get(:js_depth) == depth
      assert Process.get(:js_stack, []) == stack

      :erlang.put(:js_steps, 100)
      assert catch_throw(Interp.call(spin, :undefined, [])) == :js_limit
      {fid, _} = peeked()
      assert :erlang.get(fid) == :undefined
      assert :erlang.get(:js_depth) == depth
    end

    test "1000 calls and 1000 throws leave the heap as it was" do
      gid = heap()
      run_script("function leaf(x){ return x + 1 } function thrower(){ throw 1 }", 1)
      {:ok, leaf} = Interp.lookup_scoped(gid, "leaf")
      {:ok, thrower} = Interp.lookup_scoped(gid, "thrower")
      assert %{info: %Info{rewritten: true}} = closure(leaf)

      # The loop is top-level code, which the resolver never rewrites.
      {:ok, {:program, [loop]}} =
        Parser.parse("for (var i = 0; i < 1000; i++) leaf(i)", resolve: :off)

      Interp.exec_stmt(loop, gid)
      size = Interp.heap_size()
      Interp.exec_stmt(loop, gid)
      assert Interp.heap_size() == size

      for _ <- 1..1000, do: assert(Interp.call(leaf, :undefined, [1.0]) == 2.0)
      assert Interp.heap_size() == size

      for _ <- 1..1000,
          do: assert(catch_throw(Interp.call(thrower, :undefined, [])) == {:js_error, 1.0})

      assert Interp.heap_size() == size
    end
  end

  if @check do
    test "check mode: a wrong hop raises an Elixir error that names the form" do
      gid = heap()
      i = info(leaf("function f(a){ }", "f"))
      fid = frame(gid, i, [1.0])
      assert Interp.ev({:slot, 0, 6, "a"}, fid) == 1.0

      # One hop up is the global map scope, which has no slots. The error names the
      # variable and the index it was looked for at.
      e = assert_raise(ArgumentError, fn -> Interp.ev({:slot, 1, 6, "a"}, fid) end)
      assert Exception.message(e) =~ "resolve check"
      assert Exception.message(e) =~ ~s("a" at 6)

      # A slot index past the frame, and a name that is not in `slots`.
      assert_raise(ArgumentError, fn -> Interp.ev({:slot, 0, 9, "a"}, fid) end)

      e = assert_raise(ArgumentError, fn -> Interp.ev({:slot, 0, 6, "zz"}, fid) end)
      assert Exception.message(e) =~ ~s("zz" is not slot 6 of "f")
    end
  else
    @tag skip: "set JS_RESOLVE_CHECK=1 to run the check-mode test"
    test "check mode: a wrong hop raises an Elixir error that names the form" do
      :ok
    end
  end

  # ── the semantic table (design section 6) ──────────────────

  # Each row runs at `:off` and at level 1 through `Browser.JS.eval`; the result must be
  # the one of the design, and the same at both levels. The expected values were checked
  # at `:off` on bb2d6f5. Rows 30, 31, 57 and 58 need a page and are in the module below.
  @rows [
    {1, "function f(){ return x; let x = 1 } try { f() } catch (e) { e.message }",
     {:ok, "Cannot access 'x' before initialization", []}},
    {2, "function f(){ return typeof y; let y } try { f() } catch (e) { e.message }",
     {:ok, "Cannot access 'y' before initialization", []}},
    {3, "function f(){ const c = 1; c = 2 } try { f() } catch (e) { e.message }",
     {:ok, @const_msg, []}},
    {4, "function f(){ c = 2; const c = 1 } try { f() } catch (e) { e.message }",
     {:ok, "Cannot access 'c' before initialization", []}},
    {5, "function f(){ const c = 1; c += 1 } try { f() } catch (e) { e.constructor.name }",
     {:ok, "TypeError", []}},
    {6, "function f(){ let x = 1; { let x = 2 } return x } f()", {:ok, 1.0, []}},
    {7,
     "function f(){ var r = []; for (var i = 0; i < 2; i++) { try { r.push(x) } catch (e) { r.push('tdz') } let x = i } return r.join() } f()",
     {:ok, "tdz,tdz", []}},
    {8, "function f(){ var s = 0; for (let i = 0; i < 3; i++) s += i; return s } f()",
     {:ok, 3.0, []}},
    {10,
     "function f(o){ var k = []; for (const x in o) k.push(x); return k.join() } f({a:1,b:2})",
     {:ok, "a,b", []}},
    {11,
     "function f(v){ switch (v) { case 1: let z = 'one'; return z; default: return 'other' } } f(1) + f(2)",
     {:ok, "oneother", []}},
    {12,
     "function f(){ switch (2) { case 1: let z = 1; case 2: return z } } try { f() } catch (e) { e.constructor.name }",
     {:ok, "ReferenceError", []}},
    {13, "function f(){ try { throw 5 } catch (e) { e = e + 1; return e } } f()", {:ok, 6.0, []}},
    {14, "function f(){ try { throw {a:1,b:2} } catch ({a, b}) { return a + b } } f()",
     {:ok, 3.0, []}},
    {15,
     "function f(){ var t = []; try { t.push(1); return t.join() } finally { t.push(2) } } f()",
     {:ok, "1", []}},
    {16,
     "function f(){ var n = 0; L: for (let i = 0; i < 3; i++) { for (let j = 0; j < 3; j++) { if (j == 1) continue L; if (i == 2) break L; n++ } } return n } f()",
     {:ok, 2.0, []}},
    {17, "function f(){ var s = 'a'; blk: { s += 'b'; break blk; s += 'c' } return s } f()",
     {:ok, "ab", []}},
    {18, "var g = function h(){ h = 1; return typeof h }; g()", {:ok, "function", []}},
    {19,
     "var g = function h(){ \"use strict\"; h = 1 }; try { g() } catch (e) { e.constructor.name }",
     {:ok, "TypeError", []}},
    {20, "(function h(h){ return h })(7)", {:ok, 7.0, []}},
    {21, "({x: 3, m(){ return this.x }}).m()", {:ok, 3.0, []}},
    {22, "function f(){ \"use strict\"; return this } f() === undefined", {:ok, true, []}},
    {23, "function f(){ return typeof this } f.call(5)", {:ok, "object", []}},
    {24, "({v: 9, m(){ return [1].map(x => this.v)[0] }}).m()", {:ok, 9.0, []}},
    {25, "var G = 1; function f(){ G += 1; H = 5; return G + H } f() + H", {:ok, 12.0, []}},
    {26,
     "Object.defineProperty(globalThis, 'acc', {get(){ return 42 }}); function f(){ return acc } f()",
     {:ok, 42.0, []}},
    {27, "var r; try { f() } catch (e) { r = e.message } let L = 1; function f(){ return L } r",
     {:ok, "Cannot access 'L' before initialization", []}},
    {28, "function f(){ return typeof nope } f()", {:ok, "undefined", []}},
    {"28b", "function f(){ return nope } f()",
     {:error, {:uncaught, "ReferenceError: nope is not defined"}, []}},
    {29, "function f(){ \"use strict\"; zz = 1 } try { f() } catch (e) { e.message }",
     {:ok, "zz is not defined", []}},
    {32, "function outer(){ class A { static n(){ return A.name } } return A.n() } outer()",
     {:ok, "A", []}},
    {33, "class A { m(){ return A } } new A().m() === A", {:ok, true, []}},
    {34,
     "function leaf(){ return new Error('x').stack } function outer(){ return leaf() } outer()",
     {:ok, "Error: x\n    at leaf\n    at outer", []}},
    {35, "var f = function(){ return new Error('x').stack }; f()",
     {:ok, "Error: x\n    at f", []}},
    {36,
     "function a(){ return b() } function b(){ var c = () => d(); return c() } function d(){ return new Error('x').stack } a()",
     {:ok, "Error: x\n    at d\n    at c\n    at b\n    at a", []}},
    {38, "function f(n){ return f(n + 1) } try { f(0) } catch (e) { e.message }",
     {:ok, "Maximum call stack size exceeded", []}},
    {39, "\"use strict\"; function f(n){ return n == 0 ? 0 : f(n - 1) } f(5000)", {:ok, 0.0, []}},
    {40,
     "\"use strict\"; function f(n){ try { return n == 0 ? 0 : f(n - 1) } finally {} } try { f(5000) } catch (e) { e.constructor.name }",
     {:ok, "RangeError", []}},
    # Row 41 of the design, changed. The design's source has the directive at the top, so
    # the leaf is strict too and its loop return is a tail call at both levels; and the
    # strict caller's `return leaf()` is a tail call, so `s` leaves the stack. The row now
    # has a sloppy leaf under a strict tail caller, which runs inside a strict non-tail
    # call: the leaf's `return probe()` in a loop is `:plain`, so `leaf` stays on the stack.
    # A stale tail flag from `outer` would have dropped it.
    {41,
     "function outer(){ \"use strict\"; var r = s(); return r } function s(){ \"use strict\"; return leaf() } function leaf(){ var i = 0; while (true) { if (++i == 3) return probe() } } function probe(){ return new Error('x').stack } outer()",
     {:ok, "Error: x\n    at probe\n    at leaf\n    at outer", []}},
    {42,
     "var o = { _v: 1, get v(){ return this._v * 2 }, set v(x){ this._v = x } }; o.v = 5; o.v",
     {:ok, 10.0, []}},
    {43, "[1,2,3].map(function (x) { return x * this.k }, {k: 2}).join()", {:ok, "2,4,6", []}},
    {44,
     "function leaf(x){ return x + 1 } function* g(){ yield leaf(1); yield leaf(2) } [...g()].join()",
     {:ok, "2,3", []}},
    # Row 45 of the design, changed: `a()` is a promise, so the value is logged instead.
    {45,
     "function leaf(x){ return x * 2 } async function a(){ return leaf(21) } a().then(v => console.log(v))",
     {:ok, %{}, [{:log, "42"}]}},
    {46, "eval(\"let q = 5; function leaf(a){ return q + a } leaf(1)\")", {:ok, 6.0, []}},
    {47, "var k = 'global'; var o = {k: 'obj', leaf(){ return k }}; with (o) { leaf() }",
     {:ok, "global", []}},
    {48,
     "with ({}) {} function outer(){ var n = 2; function leaf(){ return n } return leaf() } outer()",
     {:ok, 2.0, []}},
    {49, "function P(x){ this.x = x } new P(3).x", {:ok, 3.0, []}},
    {"49b",
     "\"use strict\"; function Q(){ return g() } function g(){ return {s: new Error('x').stack} } new Q().s",
     {:ok, "Error: x\n    at g\n    at Q", []}},
    {50, "function f(a, a){ return a } f(1, 2)", {:ok, 2.0, []}},
    {51, "function f(a, b = a + 1){ return a + b } f(1)", {:ok, 3.0, []}},
    {"51b", "function f(a = b, b){} try { f() } catch (e) { e.message }",
     {:ok, "Cannot access 'b' before initialization", []}},
    {52, "function f({a}, [b], ...r){ return a + b + r.length } f({a:1}, [2], 3, 4)",
     {:ok, 5.0, []}},
    {53, "function f(){ var r = typeof v; var v = 1; return r } f()", {:ok, "undefined", []}},
    # Row 54 of the design is level 2 at level 1 (the `[Symbol.dispose]` method is a
    # function node inside `f`), so row 54b makes the resource outside the leaf.
    {54,
     "function f(){ var log = []; { using r = { [Symbol.dispose](){ log.push('d') } }; log.push('b') } return log.join() } f()",
     {:ok, "b,d", []}},
    {"54b",
     "var log = []; var res = { [Symbol.dispose](){ log.push('d') } }; function f(){ { using r = res; log.push('b') } return log.join() } f()",
     {:ok, "b,d", []}},
    {55, "function f(){ var x = 1; return delete x } f()", {:ok, false, []}},
    {56, "function f(){ return [1].map(x => arguments[0]) } f(7).join()", {:ok, "7", []}},
    {"self", "var g = function h(){ return h }; g() === g", {:ok, true, []}}
  ]

  describe "the semantic table" do
    test "every row gives the design's value at :off and the same value at level 1" do
      for {n, src, expected} <- @rows do
        assert JS.eval(src, resolve: :off) == expected, "row #{n} at :off: #{src}"
        assert JS.eval(src, resolve: 1) == expected, "row #{n} at level 1: #{src}"
      end
    end

    test "row 9: a ReferenceError at both levels, the TDZ message with slots" do
      src =
        "function f(){ for (const [a = a] of [[1], []]) ; } try { f() } catch (e) { e.constructor.name + ':' + e.message }"

      assert JS.eval(src, resolve: :off) == {:ok, "ReferenceError:a is not defined", []}

      assert JS.eval(src, resolve: 1) ==
               {:ok, "ReferenceError:Cannot access 'a' before initialization", []}
    end

    test "row 37: the step limit at both levels" do
      src = "function f(){ var n = 0; while (true) n++ } f()"
      assert JS.eval(src, resolve: :off, max_steps: 10_000) == {:error, :step_limit, []}
      assert JS.eval(src, resolve: 1, max_steps: 10_000) == {:error, :step_limit, []}
    end

    test "the leaf functions of the table are rewritten at level 1" do
      # A row proves nothing if its function took the old path.
      for {n, src} <- [
            {1, "function f(){ return x; let x = 1 }"},
            {21, "({x: 3, m(){ return this.x }})"},
            {34, "function leaf(){ return new Error('x').stack }"},
            {49, "function P(x){ this.x = x }"},
            {"54b", "var res; function f(){ { using r = res; log.push('b') } return log.join() }"}
          ] do
        {:ok, tree} = Parser.parse(src, resolve: 1)
        assert find(tree, &match?({:fn, _, _, _, _, %Info{rewritten: true}}, &1)), "row #{n}"
      end
    end
  end
end

defmodule Browser.JS.FramesPageTest do
  # Rows 30, 31, 57 and 58 of the design table run page scripts, which read the level from
  # the application env. The env is global, so this module runs on its own, after the
  # async ones, and clears the env after each test.
  use ExUnit.Case, async: false

  alias Browser.JS.Runtime

  @levels [:off, 1]

  # Runs the page's scripts at `level`; `files` maps urls to what fetching them returns.
  # Returns the console lines, the ones logged by timers and loads included, and the errors.
  defp page(html, level, files \\ %{}) do
    # The suite-wide level (`JS_RESOLVE=1`) lives in the same key, so the test restores
    # it instead of deleting it; a delete would run every later sync module at `:off`.
    previous = Application.get_env(:browser, :js_resolve)
    Application.put_env(:browser, :js_resolve, level)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:browser, :js_resolve)
        v -> Application.put_env(:browser, :js_resolve, v)
      end
    end)

    {raw, _} = html |> Browser.HTML.parse() |> Browser.Forms.index()

    fetch = fn url ->
      case Map.fetch(files, url) do
        {:ok, body} -> {:ok, body, url}
        :error -> {:error, "404"}
      end
    end

    pid =
      Runtime.start(raw, %{
        url: "http://t.test/dir/page?a=1#top",
        width: 800,
        height: 600,
        fetch: fetch
      })

    r = Runtime.run_scripts(pid)
    logs = for({:log, t} <- r.console, do: t) ++ collect(pid)
    Runtime.stop(pid)
    {logs, for({:error, t} <- r.console, do: t)}
  end

  defp collect(pid) do
    receive do
      {:js_async, ^pid, reply} -> for({:log, t} <- reply.console, do: t) ++ collect(pid)
    after
      150 -> for {:log, t} <- Runtime.flush(pid).console, do: t
    end
  end

  test "row 30: a module function reads the module scope and a global" do
    html = """
    <body><script>var c = 2</script>
    <script type=module>const b = 1; export function f(){ return b + c } console.log(f())</script></body>
    """

    for level <- @levels do
      assert page(html, level) == {["3"], []}, "level #{level}"
    end
  end

  test "row 31: a write to an import is a TypeError" do
    files = %{"http://t.test/m.js" => "export let a = 0;"}

    html = """
    <body><script type=module>
    import {a} from "/m.js"; export function g(){ a = 1 }
    try { g() } catch (e) { console.log(e.constructor.name, a) }
    </script></body>
    """

    for level <- @levels do
      assert page(html, level, files) == {["TypeError 0"], []}, "level #{level}"
    end
  end

  test "row 57: a named element is found from the root" do
    html =
      ~S|<body><div id="el"></div><script>function f(){ return el.id } console.log(f())</script></body>|

    for level <- @levels do
      assert page(html, level) == {["el"], []}, "level #{level}"
    end
  end

  test "row 58: a child function called by the parent reads the child's global" do
    html = ~S"""
    <body><script>
    var v = 'parent';
    const f = document.createElement("iframe");
    f.srcdoc = "<script>var v = 'child'; function get(){ return v }<\/script>";
    f.onload = () => console.log(f.contentWindow.get(), v);
    document.body.appendChild(f);
    </script></body>
    """

    for level <- @levels do
      assert page(html, level) == {["child parent"], []}, "level #{level}"
    end
  end
end
