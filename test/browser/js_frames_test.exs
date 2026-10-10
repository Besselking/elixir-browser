defmodule Browser.JS.FramesTest do
  # Step 2b: a function that the resolver rewrote at level 1 runs on a tuple frame. Step
  # 2c: a level 2 function, which makes closures, runs on a frame too, and a scope whose
  # names a closure captures gets a block frame. Step 2d: a level 3 function (`arguments`,
  # `new.target`, `super`, constructors) runs on a frame with hidden slots. The first part
  # builds frames by hand in the test process and calls the evaluator on each new node
  # form. The second part runs the semantic tables of the designs at `:off` and at levels
  # 1, 2 and 3 and compares the results. The designs are notes/js-frames-2b-design.md,
  # notes/js-frames-2c-design.md and notes/js-frames-2d-design.md.
  use ExUnit.Case, async: true

  alias Browser.JS
  alias Browser.JS.{GC, Interp, Parser, Resolve}
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
      assert freed?(fid)

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
      # A closure can only be made in a frame that frees by the closure count (check mode
      # fails a closure in a leaf), so the record of the hand-built frame is made level 2.
      i = info(leaf(@vars, "f"))
      fid = frame(gid, %{i | level: 2, free: :counter}, [1.0, 2.0, :undefined, :tdz, :tdz])
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
      assert freed?(fid)

      assert catch_throw(Interp.call(bad, :undefined, [])) == {:js_error, 1.0}
      {fid, _} = peeked()
      assert freed?(fid)
      assert :erlang.get(:js_depth) == depth
      assert Process.get(:js_stack, []) == stack

      :erlang.put(:js_steps, 100)
      assert catch_throw(Interp.call(spin, :undefined, [])) == :js_limit
      {fid, _} = peeked()
      assert freed?(fid)
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

  # ── step 2c: level 2 functions, block frames, loop frames ──

  # The tests below follow section 6.1 of notes/js-frames-2c-design.md. A level 2 function
  # makes closures, so its frame and its block frames can live after the statement or the
  # call that made them. The counter `:js_fns` decides if a frame is freed.

  # The first function node named `name` in `src`, resolved at level 2.
  defp fn2(src, name) do
    assert {:ok, tree} = Parser.parse(src, resolve: 2), src
    node = find(tree, &match?({:fn, ^name, _, _, _, %Info{}}, &1))
    assert node != nil, "no function #{name} in #{inspect(tree)}"
    node
  end

  # The body statements and the record of a function node.
  defp body_of({:fn, _, _, body, _, %Info{} = i}), do: {body, i}

  # True when the heap entry `id` is freed. Without check mode a free erases the entry. In
  # check mode it leaves a tombstone, so that a later read can name the frame (design 5).
  defp freed?(id) do
    case :erlang.get(id) do
      :undefined -> true
      {:js_freed, _} -> true
      _ -> false
    end
  end

  # A frame with a call position in its header, so a test can see that a block frame
  # copies the header of its parent.
  defp frame_at(parent, info, pos, slots) do
    Interp.alloc(List.to_tuple([parent, info, nil, pos, Interp.global() | slots]))
  end

  # A block frame of `sc` under the frame `parent`, with the header copied from `parent`
  # as `enter_scope` copies it (design 3.2).
  defp block_frame(parent, %Scope{} = sc, slots) do
    p = :erlang.get(parent)

    Interp.alloc(List.to_tuple([parent, sc, elem(p, 2), elem(p, 3), elem(p, 4) | slots]))
  end

  # The function objects in the JS array `arr`.
  defp fns_in(arr), do: Interp.array_list(arr)

  describe "level 2: the body entry (enter_body)" do
    test "the copies run before the hoist, and each closure is made on the stored frame" do
      gid = heap()
      install_peek(gid)

      src =
        "function f(a, g = () => a){ peek(); var a; function a(){} return [typeof a, typeof g()].join() }"

      node = fn2(src, "f")
      assert %Info{level: 2, free: :counter, copies: [{6, 8}], hoist: [{8, _}]} = info(node)
      f = Interp.make_function(node, gid, false)

      # The copy writes the parameter into slot 8 first. The hoist then puts the function
      # there. In the other order the copy would overwrite the function with `1`.
      assert Interp.call(f, :undefined, [1.0]) == "function,number"
      {fid, t} = peeked()
      assert elem(t, 5) == 1.0
      assert Interp.typeof(elem(t, 7)) == "function"

      # Both closures hop from this frame, and their root is the root in its header.
      for fun <- [elem(t, 6), elem(t, 7)] do
        assert closure(fun).scope == fid
        assert closure(fun).root == elem(t, 4)
      end

      # The closures moved the counter, so the frame lives after the call.
      refute freed?(fid)
    end

    test "the last hoist pair for a slot wins" do
      gid = heap()

      node =
        fn2("function f(){ function g(){ return 1 } function g(){ return 2 } return g() }", "f")

      assert [{6, _}, {6, _}] = info(node).hoist
      f = Interp.make_function(node, gid, false)
      assert Interp.call(f, :undefined, []) == 2.0
    end

    test "a hoisted function overwrites the slot of a parameter with the same name" do
      gid = heap()
      install_peek(gid)
      node = fn2("function f(a){ function a(){} peek(); return typeof a }", "f")
      assert %Info{slots: %{"a" => 6}, hoist: [{6, _}]} = info(node)
      f = Interp.make_function(node, gid, false)
      assert Interp.call(f, :undefined, [1.0]) == "function"
      {_, t} = peeked()
      assert Interp.typeof(elem(t, 5)) == "function"
    end

    test "a default sees the parameter, the body sees the copy (design 1.1, `d`)" do
      gid = heap()
      node = fn2("function d(a = 1, g = () => a){ var a = 5; return [a, g()].join() }", "d")
      assert %Info{params: :exprs, copies: [{6, 8}], template: [:undefined]} = info(node)
      d = Interp.make_function(node, gid, false)
      assert Interp.call(d, :undefined, []) == "5,1"
    end

    test "a level 2 call that makes no closure frees its frame; one that makes one keeps it" do
      gid = heap()
      install_peek(gid)
      node = fn2("function f(x){ peek(); if (x) return () => x * 2; return 2 }", "f")
      f = Interp.make_function(node, gid, false)

      assert Interp.call(f, :undefined, [0.0]) == 2.0
      {fid, _} = peeked()
      assert freed?(fid)

      g = Interp.call(f, :undefined, [3.0])
      {fid, _} = peeked()
      refute freed?(fid)
      assert closure(g).scope == fid
      assert Interp.call(g, :undefined, []) == 6.0
    end

    test "a block in the body of a call: the closure keeps the block frame" do
      gid = heap()
      node = fn2("function f(){ { let x = 1; return () => x } }", "f")
      f = Interp.make_function(node, gid, false)
      g = Interp.call(f, :undefined, [])
      assert Interp.call(g, :undefined, []) == 1.0
      assert {_, %Scope{kind: :block, frame: true}, _, _, _, 1.0} = :erlang.get(closure(g).scope)
    end
  end

  describe "level 2: block frames through exec_stmt (enter_scope, leave_scope)" do
    @blocks "function f(){ var fs = []; { let x = 1; fs.push(() => x) } { fs.push(() => x); throw 0; let x } }"

    test "a framed block: the header of env, the template, the frame kept by a closure" do
      gid = heap()
      {[_var, kept, thrown], i} = body_of(fn2(@blocks, "f"))
      assert {:block, _, %Scope{frame: true, kind: :block, template: [:tdz]} = sc} = kept
      arr = Interp.new_array([])
      fid = frame_at(gid, i, 42, [arr])

      assert Interp.exec_stmt(kept, fid) == :ok
      [g] = fns_in(arr)
      bid = closure(g).scope
      # The header copies `caller_id`, `call_pos` and `root_id` from the function frame.
      assert :erlang.get(bid) == {fid, sc, nil, 42, gid, 1.0}
      assert Interp.call(g, :undefined, []) == 1.0

      # The second block throws before its `let` runs. The frame comes from the template,
      # so the closure sees `x` in its TDZ, and the throw does not free the frame.
      assert catch_throw(Interp.exec_stmt(thrown, fid)) == {:js_error, 0.0}
      [_, h] = fns_in(arr)
      hid = closure(h).scope
      assert hid != bid
      refute freed?(hid)
      assert elem(:erlang.get(hid), 5) == :tdz

      assert caught(fn -> Interp.call(h, :undefined, []) end) ==
               {"ReferenceError", @tdz_x}
    end

    test "a framed block that made no closure is freed, also after a throw" do
      gid = heap()
      {[_var, {:block, _, sc}, _], i} = body_of(fn2(@blocks, "f"))
      fid = frame(gid, i, [Interp.new_array([])])
      let_x = {:var, :let, [{{:slot, 0, 6, "x"}, {:num, 1.0}}]}
      size = Interp.heap_size()

      n = :erlang.get(:js_next)
      assert Interp.exec_stmt({:block, [let_x], sc}, fid) == :ok
      assert freed?(n)
      assert Interp.heap_size() == size

      n = :erlang.get(:js_next)

      assert catch_throw(Interp.exec_stmt({:block, [let_x, {:throw, {:num, 1.0}}], sc}, fid)) ==
               {:js_error, 1.0}

      assert freed?(n)
      assert Interp.heap_size() == size
    end

    test "a switch frame: the hoist runs at entry, so the frame is kept" do
      gid = heap()

      src =
        "function f(){ switch (1) { case 0: function h(){ return 1 } case 1: let z = 2; return () => z + h() } }"

      {[switch], i} = body_of(fn2(src, "f"))

      assert {:switch, _, _,
              %Scope{kind: :switch, frame: true, slots: %{"z" => 6, "h" => 7}, hoist: [{7, _}]} =
                sc} = switch

      fid = frame(gid, i, [])

      assert {:return, g} = caught(fn -> Interp.exec_stmt(switch, fid) end)
      assert Interp.call(g, :undefined, []) == 3.0
      sid = closure(g).scope
      assert {^fid, ^sc, _, _, ^gid, 2.0, h} = :erlang.get(sid)
      assert Interp.typeof(h) == "function"
      assert closure(h).scope == sid

      # No case matches, but the hoist made `h`: the counter moved and the frame stays.
      n = :erlang.get(:js_next)
      assert Interp.exec_stmt({:switch, {:num, 5.0}, elem(switch, 2), sc}, fid) == :ok
      refute freed?(n)
    end

    test "a catch frame holds the parameter; the handler runs in it" do
      gid = heap()
      src = "function f(){ try { throw 7 } catch (e) { return () => e } }"
      {[try], i} = body_of(fn2(src, "f"))
      assert {:try, _, _, _, nil, %Scope{kind: :catch, frame: true} = sc} = try
      fid = frame(gid, i, [])

      assert {:return, g} = caught(fn -> Interp.exec_stmt(try, fid) end)
      assert :erlang.get(closure(g).scope) == {fid, sc, nil, nil, gid, 7.0}
      assert Interp.call(g, :undefined, []) == 7.0

      # A handler that makes no closure leaves nothing behind.
      n = :erlang.get(:js_next)
      size = Interp.heap_size()
      thrower = {:block, [{:throw, {:num, 1.0}}], nil}
      Interp.exec_stmt({:try, thrower, {:slot, 0, 6, "e"}, {:block, [], nil}, nil, sc}, fid)
      assert freed?(n)
      assert Interp.heap_size() == size
    end
  end

  describe "level 2: loop frames" do
    test "copy_scope on a frame: a new id, the same parent, the values copied" do
      gid = heap()
      fid = frame(gid, info(fn2("function f(){ var a }", "f")), [:undefined])
      sc = %Scope{kind: :loop, frame: true, per_iter: true, size: 6, slots: %{"i" => 6}}
      src = block_frame(fid, sc, [1.0])

      copy = Interp.copy_scope(src, gid)
      assert copy != src
      assert :erlang.get(copy) == :erlang.get(src)
      assert elem(:erlang.get(copy), 0) == fid

      # The copy is a frame of its own: a write to it does not reach the source.
      Interp.ev({:assign, "=", {:slot, 0, 6, "i"}, {:num, 2.0}}, copy)
      assert elem(:erlang.get(src), 5) == 1.0
    end

    @for_let "function f(k){ var fs = []; for (let i = 0; i < 3; i++) if (k) fs.push(() => i); return fs }"

    test "for (let): no copy and no frame left while no closure is made" do
      gid = heap()
      {[_, for_stmt, _], i} = body_of(fn2(@for_let, "f"))
      assert {:for, _, _, _, _, %Scope{kind: :loop, frame: true, per_iter: true}} = for_stmt
      fid = frame(gid, i, [false, Interp.new_array([])])

      n = :erlang.get(:js_next)
      size = Interp.heap_size()
      assert Interp.exec_stmt(for_stmt, fid) == :ok
      # One frame was made for the loop and freed after it.
      assert :erlang.get(:js_next) == n + 1
      assert freed?(n)
      assert Interp.heap_size() == size
    end

    test "for (let): a copy per round after a closure, and the update runs in the copy" do
      gid = heap()
      {[_, for_stmt, _], i} = body_of(fn2(@for_let, "f"))
      arr = Interp.new_array([])
      fid = frame(gid, i, [true, arr])

      n = :erlang.get(:js_next)
      size = Interp.heap_size()
      assert Interp.exec_stmt(for_stmt, fid) == :ok

      # The loop frame, three closures, and a copy after each round in which the counter
      # moved: three copies (the last one is made before the test that ends the loop, as
      # `:off` makes it). The init made no closure, so the first round runs in the loop
      # frame itself.
      assert :erlang.get(:js_next) == n + 7
      assert Interp.heap_size() == size + 7

      fs = fns_in(arr)
      assert Enum.map(fs, &Interp.call(&1, :undefined, [])) == [0.0, 1.0, 2.0]
      scopes = Enum.map(fs, &closure(&1).scope)
      assert hd(scopes) == n
      assert length(Enum.uniq(scopes)) == 3
      for s <- scopes, do: assert(elem(:erlang.get(s), 0) == fid)
    end

    @for_of "function f(xs, c){ var fs = []; for (const k of xs) if (c) fs.push(() => k); return fs }"

    test "for-of: the item frame is renewed in place while no closure is made" do
      gid = heap()
      {[_, for_of, _], i} = body_of(fn2(@for_of, "f"))
      assert {:forof, :const, _, _, _, %Scope{kind: :each, frame: true, per_iter: false}} = for_of
      xs = Interp.new_array(["a", "b", "c"])
      fid = frame(gid, i, [xs, false, Interp.new_array([])])

      n = :erlang.get(:js_next)
      size = Interp.heap_size()
      assert Interp.exec_stmt(for_of, fid) == :ok
      # The head frame serves every item, and it is freed at the end.
      assert :erlang.get(:js_next) == n + 1
      assert freed?(n)
      assert Interp.heap_size() == size
    end

    test "for-of: a new item frame after a closure was made" do
      gid = heap()
      {[_, for_of, _], i} = body_of(fn2(@for_of, "f"))
      arr = Interp.new_array([])
      fid = frame(gid, i, [Interp.new_array(["a", "b", "c"]), true, arr])

      n = :erlang.get(:js_next)
      assert Interp.exec_stmt(for_of, fid) == :ok

      # The head frame takes the first item; each later item gets a new frame because the
      # closure of the round before moved the counter: 1 + 3 closures + 2 frames.
      assert :erlang.get(:js_next) == n + 6

      fs = fns_in(arr)
      assert Enum.map(fs, &Interp.call(&1, :undefined, [])) == ["a", "b", "c"]
      scopes = Enum.map(fs, &closure(&1).scope)
      assert hd(scopes) == n
      assert length(Enum.uniq(scopes)) == 3
      for s <- scopes, do: assert(elem(:erlang.get(s), 0) == fid)
    end

    test "for-of over an iterator (proto_loop with a frame per item)" do
      gid = heap()
      {[_, for_of, _], i} = body_of(fn2(@for_of, "f"))
      run_script("var S = new Set(['a', 'b', 'c'])")
      {:ok, set} = Interp.lookup_scoped(gid, "S")

      arr = Interp.new_array([])
      fid = frame(gid, i, [set, true, arr])
      n = :erlang.get(:js_next)
      assert Interp.exec_stmt(for_of, fid) == :ok
      fs = fns_in(arr)
      assert Enum.map(fs, &Interp.call(&1, :undefined, [])) == ["a", "b", "c"]
      scopes = Enum.map(fs, &closure(&1).scope)
      assert hd(scopes) == n
      assert length(Enum.uniq(scopes)) == 3

      # Without a closure the head frame is freed.
      fid = frame(gid, i, [set, false, Interp.new_array([])])
      n = :erlang.get(:js_next)
      assert Interp.exec_stmt(for_of, fid) == :ok
      assert freed?(n)
    end

    test "for-of: a closure made by the object expression keeps the head frame in its TDZ" do
      gid = heap()
      src = "function f(){ for (const k of [() => k]) k() }"
      {[for_of], i} = body_of(fn2(src, "f"))
      fid = frame(gid, i, [])

      assert caught(fn -> Interp.exec_stmt(for_of, fid) end) ==
               {"ReferenceError", "Cannot access 'k' before initialization"}
    end
  end

  describe "level 2: the by-name walkers on a block frame" do
    # A framed block that also holds the slot of a frameless block inside it: `y` at 8 is
    # in `kinds` but not in `slots` (design 3.1).
    @sc %Scope{
      kind: :block,
      frame: true,
      size: 8,
      slots: %{"x" => 6, "c" => 7},
      kinds: %{6 => :let, 7 => :const, 8 => :let},
      template: [:tdz, :tdz, :tdz]
    }

    test "kind_at: assign_frame reads the kinds of a Scope and of an Info" do
      gid = heap()
      fid = vars_frame(gid)
      bid = block_frame(fid, @sc, [:tdz, 1.0, 3.0])

      assert caught(fn -> Interp.assign_scoped(bid, "x", 5.0) end) == {"ReferenceError", @tdz_x}
      :erlang.put(bid, :erlang.setelement(6, :erlang.get(bid), 0.0))
      Interp.assign_scoped(bid, "x", 5.0)
      assert elem(:erlang.get(bid), 5) == 5.0

      assert caught(fn -> Interp.assign_scoped(bid, "c", 2.0) end) == {"TypeError", @const_msg}
      assert elem(:erlang.get(bid), 6) == 1.0

      # A name that the block does not hold goes on to the function frame, whose kinds
      # are a tuple.
      Interp.assign_scoped(bid, "a", 7.0)
      assert slot(fid, 6) == 7.0
      :erlang.put(fid, :erlang.setelement(10, :erlang.get(fid), 1.0))
      assert caught(fn -> Interp.assign_scoped(bid, "e", 2.0) end) == {"TypeError", @const_msg}
    end

    test "lookup_frame: block names from `slots`, the rest from the parent" do
      gid = heap()
      fid = vars_frame(gid)
      bid = block_frame(fid, @sc, [5.0, 1.0, 3.0])

      assert Interp.lookup_scoped(bid, "x") == {:ok, 5.0}
      assert Interp.lookup_scoped(bid, "a") == {:ok, 1.0}
      assert Interp.lookup_scoped(bid, "nope") == :error
      assert Interp.ev({:id, "c"}, bid) == 1.0
    end

    test "slot forms on a block frame (check_slot reads the Scope kinds in check mode)" do
      gid = heap()
      fid = vars_frame(gid)
      bid = block_frame(fid, @sc, [5.0, 1.0, 3.0])

      assert Interp.ev({:slot, 0, 6, "x"}, bid) == 5.0
      assert Interp.ev({:slot, 0, 8, "y"}, bid) == 3.0
      assert Interp.ev({:assign, "=", {:slot, 0, 8, "y"}, {:num, 4.0}}, bid) == 4.0
      assert Interp.ev({:slot, 1, 6, "a"}, bid) == 1.0

      assert caught(fn -> Interp.ev({:assign, "=", {:cslot, 0, 7, "c"}, {:num, 2.0}}, bid) end) ==
               {"TypeError", @const_msg}
    end

    test ":strict through a block frame" do
      gid = heap()
      strict = frame(gid, info(fn2("function f(){ 'use strict'; return () => 1 }", "f")), [])
      sloppy = frame(gid, info(fn2("function f(){ return () => 1 }", "f")), [])
      sc = %Scope{kind: :block, frame: true}

      assert Interp.lookup_scoped(block_frame(strict, sc, []), :strict) == {:ok, true}

      assert Interp.lookup_scoped(block_frame(sloppy, sc, []), :strict) ==
               Interp.lookup_scoped(gid, :strict)
    end

    test "{:gref} in a map scope over a frame (root/1 with a map env)" do
      gid = heap()
      fid = vars_frame(gid)
      Interp.declare(gid, "G", 10.0)
      # A class scope over a frame, as `Classes.define` makes it (classes.ex:35). The
      # check build no longer refuses it.
      cenv = Interp.new_scope(fid)
      field = Interp.new_fn_scope(cenv, %{this: :undefined, field_init: true})

      assert Interp.ev({:gref, "G"}, cenv) == 10.0
      assert Interp.ev({:assign, "=", {:gref, "G"}, {:num, 11.0}}, cenv) == 11.0
      assert Interp.lookup_scoped(gid, "G") == {:ok, 11.0}
      assert Interp.ev({:gref, "G"}, field) == 11.0
      assert Interp.ev({:unary, "typeof", {:gref, "nope"}}, cenv) == "undefined"
    end

    test "in_field_initializer?: a function frame stops the walk, an arrow or a block does not" do
      gid = heap()
      # The scope of a field initializer, as `Classes` makes it (classes.ex:253).
      fsc =
        Interp.new_fn_scope(gid, %{
          this: :undefined,
          home: :undefined,
          new_target: :undefined,
          field_init: true
        })

      plain = frame(fsc, info(fn2("function f(){ return () => 1 }", "f")), [])

      {:ok, tree} =
        Parser.parse(
          "class A { x = () => { let q = 1; return () => eval('arguments') } }",
          resolve: 2
        )

      arrow_node = find(tree, &match?({:fn, nil, [], _, :arrow, %Info{level: 2}}, &1))
      assert arrow_node != nil
      arrow = frame(fsc, info(arrow_node), [1.0])
      sc = %Scope{kind: :block, frame: true}

      # Eval code never runs in a frame itself: the function that holds the eval is
      # dynamic, so it runs on the old path in a map scope over the frame.
      in_dynamic = fn env -> Interp.new_fn_scope(env) end

      # Outside a field initializer, eval code may name `arguments`.
      assert Interp.direct_eval(["typeof arguments"], in_dynamic.(plain)) == "undefined"

      assert Interp.direct_eval(["typeof arguments"], in_dynamic.(block_frame(plain, sc, []))) ==
               "undefined"

      # In a field initializer (an arrow does not end it), `arguments` is a SyntaxError.
      assert {"SyntaxError", _} =
               caught(fn -> Interp.direct_eval(["arguments"], in_dynamic.(arrow)) end)

      assert {"SyntaxError", _} =
               caught(fn ->
                 Interp.direct_eval(["arguments"], in_dynamic.(block_frame(arrow, sc, [])))
               end)
    end
  end

  describe "level 2: the free rule and the GC" do
    test "calls that make no closure leave the heap flat; the GC takes back the others" do
      gid = heap()
      run_script("function f(x){ if (x) return () => 1; return 2 }", 2)
      {:ok, f} = Interp.lookup_scoped(gid, "f")
      assert %{info: %Info{level: 2, rewritten: true, free: :counter}} = closure(f)

      Browser.JS.GC.collect()
      base = Interp.heap_size()

      for _ <- 1..1000, do: assert(Interp.call(f, :undefined, [0.0]) == 2.0)
      assert Interp.heap_size() == base

      # Each call keeps its frame and makes one function object.
      for _ <- 1..1000, do: Interp.call(f, :undefined, [1.0])
      assert Interp.heap_size() == base + 2000

      Browser.JS.GC.collect()
      assert Interp.heap_size() == base
    end

    test "a frame held by a returned closure survives the GC" do
      gid = heap()
      run_script("function mk(x){ let y = x * 2; return () => y }", 2)
      {:ok, mk} = Interp.lookup_scoped(gid, "mk")
      g = Interp.call(mk, :undefined, [3.0])
      # A process key is a root of the GC.
      Process.put(:frames_test_hold, g)

      Browser.JS.GC.collect()
      refute freed?(closure(g).scope)
      assert Interp.call(g, :undefined, []) == 6.0
    end

    test "a throw keeps the frame of an escaped closure and frees the others" do
      gid = heap()

      run_script(
        "function t(){ let x = 'kept'; var g = () => x; throw g } " <>
          "function u(x){ let y = x; if (x) { var g = () => y } throw 1 }",
        2
      )

      {:ok, t} = Interp.lookup_scoped(gid, "t")
      {:ok, u} = Interp.lookup_scoped(gid, "u")

      assert {:js_error, g} = catch_throw(Interp.call(t, :undefined, []))
      refute freed?(closure(g).scope)
      assert Interp.call(g, :undefined, []) == "kept"

      size = Interp.heap_size()

      for _ <- 1..100,
          do: assert(catch_throw(Interp.call(u, :undefined, [0.0])) == {:js_error, 1.0})

      assert Interp.heap_size() == size
    end

    test "the GC marks the slots of a frame, and not the integer in `call_pos`" do
      gid = heap()
      i = info(leaf("function f(a){ }", "f"))
      {:obj, kept} = obj = Interp.new_object([])
      {:obj, stray} = Interp.new_object([])
      # The line number in `call_pos` can be equal to the id of a heap entry by chance.
      fid = Interp.alloc({gid, i, nil, stray, gid, obj})
      Process.put(:frames_test_hold, fid)

      Browser.JS.GC.collect()
      assert :erlang.get(fid) != :undefined
      assert :erlang.get(kept) != :undefined
      assert :erlang.get(stray) == :undefined
    end
  end

  if @check do
    test "check mode: a hop to a freed frame raises and names the frame" do
      gid = heap()
      fid = frame(gid, info(fn2("function f(a){ return () => a }", "f")), [1.0])
      bid = block_frame(fid, %Scope{kind: :block, frame: true}, [])
      assert Interp.ev({:slot, 1, 6, "a"}, bid) == 1.0

      size = Interp.heap_size()
      Interp.free(fid)
      assert freed?(fid)
      assert Interp.heap_size() == size - 1

      e = assert_raise(ArgumentError, fn -> Interp.ev({:slot, 1, 6, "a"}, bid) end)
      assert Exception.message(e) =~ "use of a freed frame of"
      assert Exception.message(e) =~ "f"
    end

    test "check mode: a leaf that makes a closure fails the leaf invariant" do
      gid = heap()
      node = fn2("function f(){ return () => 1 }", "f")
      # The resolver would give this function level 2. Here its record says level 1, so
      # the frame is freed on return although a closure holds it.
      fake = put_elem(node, 5, %{info(node) | level: 1, free: :always})
      f = Interp.make_function(fake, gid, false)
      assert_raise(ArgumentError, fn -> Interp.call(f, :undefined, []) end)
    end
  else
    @tag skip: "set JS_RESOLVE_CHECK=1 to run the check-mode tests"
    test "check mode: a hop to a freed frame raises and names the frame" do
      :ok
    end

    @tag skip: "set JS_RESOLVE_CHECK=1 to run the check-mode tests"
    test "check mode: a leaf that makes a closure fails the leaf invariant" do
      :ok
    end
  end

  # ── the semantic table (design section 6) ──────────────────

  # Each row runs at `:off` and at levels 1, 2 and 3 through `Browser.JS.eval`; the result
  # must be the one of the design, and the same at each level. The expected values were
  # checked at `:off` on bb2d6f5. Rows 30, 31, 57 and 58 need a page and are in the module
  # below. Step 2c added level 2 (2c design 6.2), and step 2d added level 3 (2d design 5.1).
  @levels [:off, 1, 2, 3]

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
    test "every row gives the design's value at :off and at levels 1, 2 and 3" do
      for {n, src, expected} <- @rows, level <- @levels do
        assert JS.eval(src, resolve: level) == expected, "row #{n} at #{level}: #{src}"
      end
    end

    test "row 9: a ReferenceError at both levels, the TDZ message with slots" do
      src =
        "function f(){ for (const [a = a] of [[1], []]) ; } try { f() } catch (e) { e.constructor.name + ':' + e.message }"

      assert JS.eval(src, resolve: :off) == {:ok, "ReferenceError:a is not defined", []}

      # The function is a leaf, so levels 2 and 3 run it as level 1 does.
      for level <- [1, 2, 3] do
        assert JS.eval(src, resolve: level) ==
                 {:ok, "ReferenceError:Cannot access 'a' before initialization", []}
      end
    end

    test "a strict leaf in a sloppy script does not make a global by destructuring" do
      for src <- [
            ~S|function f(){ "use strict"; [zz] = [1] } try { f(); "created " + zz } catch (e) { e.message }|,
            ~S|function f(){ "use strict"; for (zz of [1]); } try { f(); "created " + zz } catch (e) { e.message }|,
            ~S|function f(){ "use strict"; for (zz in {a: 1}); } try { f(); "created " + zz } catch (e) { e.message }|,
            ~S|class A { m(){ [zz] = [1] } } try { new A().m(); "created " + zz } catch (e) { e.message }|
          ] do
        for level <- @levels,
            do: assert(JS.eval(src, resolve: level) == {:ok, "zz is not defined", []}, src)
      end
    end

    test "a sloppy leaf still makes a global by destructuring" do
      src = ~S|function f(){ [zz] = [1] } f(); zz|

      for level <- @levels, do: assert(JS.eval(src, resolve: level) == {:ok, 1.0, []})
    end

    # `async` makes a function level 4, which runs from step 2e (2d design 5.1).
    test "a function of a level above 3 stops with a clear error" do
      src = "async function f(){} f()"

      assert {:error, {:crash, _} = crash, _} = JS.eval(src, resolve: 4)

      assert inspect(crash) =~
               "resolve level 4 functions cannot run yet; use :off, :info, 1, 2 or 3"
    end

    test "row 37: the step limit at each level" do
      src = "function f(){ var n = 0; while (true) n++ } f()"

      for level <- @levels do
        assert JS.eval(src, resolve: level, max_steps: 10_000) == {:error, :step_limit, []}
      end

      # A level 2 function that loops in a framed block stops the same way.
      src = "function f(){ var fs = []; for (let i = 0; ; i++) fs.push(() => i) } f()"

      for level <- @levels do
        assert JS.eval(src, resolve: level, max_steps: 10_000) == {:error, :step_limit, []}
      end
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

  # ── the semantic table of step 2c (2c design 6.2) ──────────

  # A short row runs inside a function that collects closures in `fs` and joins what
  # they give. Each value was checked at `:off` and at level 1 on 8b654a1, and each one is
  # the value of the design table. Rows with a letter are not in the design: they test
  # the renew rule and the iterator loop with frames (7b, 7c, 7d, 8b), the order of the
  # copies and the hoist (23b), and an arrow frame inside a field initializer (68).
  @pre "function f(){ var fs = []; "
  @post "; return fs.map(g => g()).join() } f()"

  @rows_2c [
    {1, @pre <> "for (let i = 0; i < 3; i++) fs.push(() => i)" <> @post, "0,1,2"},
    {2, @pre <> "for (var i = 0; i < 3; i++) fs.push(() => i)" <> @post, "3,3,3"},
    {3,
     "function f(){ var fs = []; for (let i = 0, j = () => i; i < 3; i++) fs.push(j); return fs.map(g => g()).join() } f()",
     "0,0,0"},
    {4, @pre <> "for (let i = 0; i < 3; fs.push(() => i), i++) ;" <> @post, "1,2,3"},
    {5,
     @pre <>
       "for (let i = 0; i < 4; i++) { if (i == 1) continue; fs.push(() => i); if (i == 2) break }" <>
       @post, "0,2"},
    {6, @pre <> "for (let i = 0; i < 2; i++) { let y = i * 10; fs.push(() => y + i) }" <> @post,
     "0,11"},
    {7,
     @pre <>
       "for (const k of ['a','b']) fs.push(() => k); for (const k in {x:1,y:2}) fs.push(() => k)" <>
       @post, "a,b,x,y"},
    {"7b", @pre <> "for (const k of new Set(['a','b'])) fs.push(() => k)" <> @post, "a,b"},
    {"7c",
     @pre <>
       "for (const k of ['a','b','c']) if (k != 'b') fs.push(() => k); for (const k of ['d','e','f']) if (k == 'd') fs.push(() => k)" <>
       @post, "a,c,d"},
    {"7d", @pre <> "for (let i = 0; i < 4; i++) if (i % 2) fs.push(() => i)" <> @post, "1,3"},
    {8,
     "function f(){ try { for (const k of [() => k]) k() } catch (e) { return e.constructor.name } } f()",
     "ReferenceError"},
    {"8b",
     "function f(){ try { for (const k of new Set([() => k])) k() } catch (e) { return e.constructor.name } } f()",
     "ReferenceError"},
    {9,
     @pre <>
       "L: for (let i = 0; i < 3; i++) { for (let j = 0; j < 3; j++) { fs.push(() => i + ':' + j); if (j == 1) continue L } }" <>
       @post, "0:0,0:1,1:0,1:1,2:0,2:1"},
    {10,
     @pre <>
       "switch (1) { case 1: let z = 'z'; fs.push(() => z); case 2: fs.push(() => typeof z) }" <>
       @post, "z,string"},
    {11, "function f(){ var g; try { throw 7 } catch (e) { g = () => e } return g() } f()", 7.0},
    {12,
     "function f(){ var g; try { throw {a: 1} } catch ({a}) { g = () => a; a = 2 } return g() } f()",
     2.0},
    {13, "function f(){ var n = 0; function inc(){ return ++n } inc(); inc(); return n } f()",
     2.0},
    {14,
     "function mk(){ var c = 0; return { inc(){ return ++c }, get v(){ return c } } } var o = mk(); o.inc(); o.inc(); o.v",
     2.0},
    {15,
     "function f(){ function fib(n){ return n < 2 ? n : fib(n - 1) + fib(n - 2) } return fib(15) } f()",
     610.0},
    {16, "function f(){ return g(); function g(){ return h() } function h(){ return 'h' } } f()",
     "h"},
    {17, "function f(x){ return (function(){ return x * 2 })() + (() => x)() } f(5)", 15.0},
    {18,
     "function f(){ var r = []; [1,2,3].forEach(function (v) { r.push(v * this.k) }, {k: 10}); return r.join() } f()",
     "10,20,30"},
    {19,
     "function f(){ class A { constructor(v){ this.v = v } get d(){ return this.v * 2 } static make(){ return new A(4) } } return A.make().d } f()",
     8.0},
    {20,
     "function f(){ let base = 3; class A { x = base; m(){ return this.x + base } } base = 5; return new A().m() } f()",
     10.0},
    {21,
     "var o = { k: 9, m(){ var self = this; return [1].map(() => [2].map(() => this.k + self.k)[0])[0] } }; o.m()",
     18.0},
    {22, "function f(a, g = () => a){ var a = 2; return [a, g()].join() } f(1)", "2,1"},
    {23, "function f(a = 1, b = () => a){ function a(){} return [typeof a, b()].join() } f()",
     "function,1"},
    {"23b",
     "function f(a, g = () => a){ var a; function a(){} return [typeof a, typeof g()].join() } f(1)",
     "function,number"},
    {24,
     "function f(){ let x = 1; var g = () => x; try { x = 2; throw g } catch (h) { return h() } } f()",
     2.0},
    {25, "function f(){ let x = 'kept'; var g = () => x; throw g } try { f() } catch (h) { h() }",
     "kept"},
    {26,
     "function f(){ let x = 1; function* g(){ yield x; x++; yield x } return [...g()].join() + ',' + x } f()",
     "1,2,2"},
    {28, "function f(){ let x = 4; function g(){ return eval('x + 1') } return g() } f()", 5.0},
    {29, "function f(){ let x = 4; function g(){ eval('x = 9') } g(); return x } f()", 9.0},
    {30, "function f(){ { let x = 1; (function(){ eval('x = 2') })(); return x } } f()", 2.0},
    {31, "function f(){ return (() => eval('this.k'))() } f.call({k: 5})", 5.0},
    {32, ~S|"use strict"; function f(){ let x = 5; function g(){ return x } return g() } f()|,
     5.0},
    {33,
     ~S|"use strict"; function f(n){ let s = n; function g(m){ return m == 0 ? s : g(m - 1) } return g(2000) } f(7)|,
     7.0},
    {34, "function f(){ var g = function h(n){ return n ? h(n - 1) + 1 : 0 }; return g(5) } f()",
     5.0},
    {35,
     "function f(){ const c = 1; var g = () => { c = 2 }; try { g() } catch (e) { return e.constructor.name } } f()",
     "TypeError"},
    {36, "function f(){ var g = () => x; let x = 3; return g() } f()", 3.0},
    {37,
     "function f(){ var g = () => x; try { g() } catch (e) { return e.message } let x = 3 } f()",
     "Cannot access 'x' before initialization"},
    {38,
     "function outer(){ var fs = []; for (let i = 0; i < 3; i++) setTimeout(() => fs.push(i), 0); return fs } outer().length",
     0.0},
    {39,
     @pre <> "for (var i = 0; i < 3; i++) { let j = i; fs.push(function(){ return j }) }" <> @post,
     "0,1,2"},
    {40,
     "function f(){ var s = 0; var add = function(a){ return function(b){ return a + b } }; for (var i = 0; i < 100; i++) s = add(i)(s); return s } f()",
     4950.0},
    {41, "function f(){ { function g(){ return 1 } } return typeof g } f()", "undefined"},
    {42, "function f(o){ with (o) { return function(){ return x } } } f({x: 3})()", 3.0},
    {43, "function f(){ let v = 1; var g = new Function('return typeof v'); return g() } f()",
     "undefined"},
    {44, @pre <> "for (let i of [1, 2]) { fs.push(() => i); i = i * 10 }" <> @post, "10,20"},
    {45,
     "function f(){ var x = 'f'; function g(){ var x = 'g'; return () => x } return g()() + x } f()",
     "gf"},
    {46, @pre <> "let i = 0; while (i < 3) { let j = i; fs.push(() => j); i++ }" <> @post,
     "0,1,2"},
    {47, @pre <> "var i = 0; do { let j = i; fs.push(() => j) } while (++i < 2)" <> @post, "0,1"},
    {48, "function P(x){ this.x = x; this.get = () => this.x } new P(6).get()", 6.0},
    {49,
     @pre <>
       "for (let i = 0; i < 2; i++) { try { throw i } catch (e) { fs.push(() => e + i) } }" <>
       @post, "0,2"},
    {50, "function f(a){ return (() => eval('arguments[0]'))() } f(4)", 4.0},
    {51, "function f(){ var x = 1; return (function(){ return eval('delete x') })() } f()",
     false},
    {52, "function f(a = 1, b = function(){ return eval('a') }){ var a = 2; return b() } f()",
     1.0},
    {53,
     "function f(){ switch (1) { case 0: function h(){ return 'h' } case 1: return h() } } f()",
     "h"},
    {54, "function f(){ var x = 1; (function(){ eval('x = 5') })(); return x } f()", 5.0},
    {55, "function f(){ { let y = 3; var e = function(){ return eval('y') } } return e() } f()",
     3.0},
    {56,
     "function f(){ { let x = 1; var h = function(){ x = arguments[0] }; h(4); return x } } f()",
     4.0},
    {58,
     "function f(){ class A extends Object { [k()] = 1 } function k(){ return 'p' } return new A().p } f()",
     1.0},
    {59,
     "function f(){ function even(n){ return n == 0 ? true : odd(n - 1) } function odd(n){ return n == 0 ? false : even(n - 1) } return even(10) + ',' + odd(7) } f()",
     "true,true"},
    {60, "function f(){ function g(){ return 1 } function g(){ return 2 } return g() } f()", 2.0},
    {61, "function f(){ var g = 1; function g(){} return typeof g } f()", "number"},
    {62,
     "function f(){ var a = 1; return function(){ var b = 2; return function(){ var c = 3; return () => a + b + c } } } f()()()()",
     6.0},
    {63,
     "function outer(){ var x = 0; function m(){ function k(){ return ++x } return k } return m } var k = outer()(); k(); k()",
     2.0},
    {64, "var g = function h(){ var k = () => 1; h = 5; return typeof h }; g()", "function"},
    {65,
     "function f(){ var x = 2; function g(){ return arguments.length + x } return g(1, 2) } f()",
     4.0},
    {66,
     "function f(){ var x = 1; function g(o){ with (o) { return x } } return g({}) + g({x: 2}) } f()",
     3.0},
    {67,
     ~S|function f(){ "use strict"; var x = 1; var g = () => { x = 2; return this }; return [g(), x].join() } f()|,
     ",2"},
    {68,
     "class A { x = () => { let q = 1; return () => eval('arguments') } } try { new A().x()() } catch (e) { e.constructor.name }",
     "SyntaxError"},
    # (found in review) a closure in a parameter default does not see a body name
    {69, "var x = 'glob'; function f(g = () => x) { let x = 1; return g() } f()", "glob"},
    {70, "var x = 'glob'; function f(g = () => x) { var x = 1; return g() } f()", "glob"},
    {71, "var x = 'glob'; function f(g = () => x) { function x(){} return g() } f()", "glob"},
    # (found in review) the parameters still see the self name that a body declaration hides
    {72, "(function g(x = () => typeof g) { var g = 1; return x() })()", "function"},
    {73, "(function g(x = () => typeof g) { function g(){} return x() })()", "function"},
    {74,
     "(function g(x = class { m() { return g } }) { var g = 1; return typeof new x().m() })()",
     "function"}
  ]

  # Rows 27 and 57 log from a microtask; their value is `undefined`.
  @log_rows_2c [
    {27,
     "function f(){ let x = 21; const g = async () => { await 0; return x * 2 }; g().then(v => console.log(v)) } f()",
     "42"},
    {57,
     "function f(){ { let x = 1; var a = async () => { await 0; x = 2; console.log(x) } } a() } f()",
     "2"}
  ]

  describe "the semantic table of step 2c" do
    test "every row gives the design's value at :off and at levels 1, 2 and 3" do
      for {n, src, value} <- @rows_2c, level <- @levels do
        assert JS.eval(src, resolve: level) == {:ok, value, []}, "row #{n} at #{level}: #{src}"
      end

      for {n, src, line} <- @log_rows_2c, level <- @levels do
        assert JS.eval(src, resolve: level) == {:ok, :undefined, [{:log, line}]},
               "row #{n} at #{level}: #{src}"
      end
    end

    test "the functions that the rows test are level 2 and rewritten at level 2" do
      # A row proves nothing at level 2 if its function took the old path.
      for {n, src, name} <- [
            {1, @pre <> "for (let i = 0; i < 3; i++) fs.push(() => i)" <> @post, "f"},
            {13, "function f(){ var n = 0; function inc(){ return ++n } inc(); return n }", "f"},
            {22, "function f(a, g = () => a){ var a = 2; return [a, g()].join() }", "f"},
            {48, "function P(x){ this.x = x; this.get = () => this.x }", "P"},
            {58,
             "function f(){ class A extends Object { [k()] = 1 } function k(){ return 'p' } return new A().p }",
             "f"},
            {62, "function f(){ var a = 1; return function(){ return () => a } }", "f"}
          ] do
        {:ok, tree} = Parser.parse(src, resolve: 2)
        node = find(tree, &match?({:fn, ^name, _, _, _, %Info{}}, &1))
        assert %Info{level: 2, rewritten: true} = info(node), "row #{n}"
      end
    end

    # The nine programs of bench/js_runtime.exs, wrapped as that script wraps them. The
    # expected values are the ones of that script.
    @bench_big "function big(x) { var t = 0;" <>
                 String.duplicate(" if (x < 0) { t += 1 }", 300) <>
                 " return t + x } var r = 0; for (var i = 0; i < 20000; i++) r += big(i); return r"

    @bench [
      {"fib25", "function fib(n){ return n < 2 ? n : fib(n-1) + fib(n-2) } return fib(25)",
       75025.0},
      {"closures60k",
       "var s = 0; var add = function(a){ return function(b){ return a + b } }; for (var i = 0; i < 60000; i++) { s = add(i)(s) % 1000003 } return s",
       964_603.0},
      {"propaccess60k",
       "var o = {a:1,b:2,c:3}; var t = 0; for (let i = 0; i < 60000; i++) { o.a = i; t += o.a + o.b + o.c } return t",
       1_800_270_000.0},
      {"array20k",
       "var a = []; for (var i = 0; i < 20000; i++) a.push(i); return a.map(x => x * 2).filter(x => x % 3 == 0).reduce((p, c) => p + c, 0)",
       133_326_666.0},
      {"strbuild20k",
       "var s = ''; for (var i = 0; i < 20000; i++) { s += String(i % 10) } return s.length",
       20000.0},
      {"bigfn20k", @bench_big, 199_990_000.0},
      {"classcalls30k",
       "class P { constructor(x){ this.x = x } inc(){ this.x++; return this } } var p = new P(0); for (var i = 0; i < 30000; i++) p.inc(); return p.x",
       30000.0},
      {"treewalk",
       "function mk(d){ if(d==0) return {w:10,h:5,kids:[]}; var k=[]; for(var i=0;i<4;i++) k.push(mk(d-1)); return {w:0,h:0,kids:k}; } " <>
         "function lay(n,x,y){ if(n.kids.length==0){ n.x=x;n.y=y; return n.h; } var cy=y; for(var i=0;i<n.kids.length;i++){ cy+=lay(n.kids[i],x+2,cy) } n.x=x;n.y=y;n.h=cy-y; return n.h } " <>
         "var t=mk(6); var s=0; for(var r=0;r<3;r++) s+=lay(t,0,0); return s", 61440.0},
      {"domlike",
       "var els=[]; for(var i=0;i<3000;i++){ els.push({tag:'div',attrs:{id:'e'+i,class:'c'+(i%7)},children:[],parent:null}) } " <>
         "for(var i=1;i<els.length;i++){ var p=els[(i-1)>>1]; p.children.push(els[i]); els[i].parent=p } " <>
         "var cnt=0; function q(n,c){ if(n.attrs['class']===c) cnt++; for(var i=0;i<n.children.length;i++) q(n.children[i],c) } " <>
         "for(var k=0;k<7;k++) q(els[0],'c'+k); return cnt", 3000.0}
    ]

    @tag timeout: 300_000
    test "the nine bench programs give their values at level 2" do
      for {name, body, expected} <- @bench do
        src = "(function(){ function f(){ #{body} } return f() })()"
        opts = [resolve: 2, max_steps: 1_000_000_000, timeout: 120_000]
        assert JS.eval(src, opts) == {:ok, expected, []}, name
      end
    end
  end

  # ── step 2d: level 3 functions ──────────────────────────────

  # The tests below follow section 6.1 of notes/js-frames-2d-design.md. A level 3 function
  # has hidden slots for `this`, the argument list, the arguments object, `new.target`,
  # the home object of `super` and the constructor that runs. The arguments object is
  # built on its first read. A mapped object and the parameter slots follow each other
  # through the `{:mapped, aid}` value in the `:args` slot.

  # The first function node named `name` in `src`, resolved at level 3. A method node
  # carries `{:method, name}`.
  defp fn3(src, name) do
    assert {:ok, tree} = Parser.parse(src, resolve: 3), src

    node =
      find(tree, fn
        {:fn, ^name, _, _, _, %Info{}} -> true
        {:fn, {:method, ^name}, _, _, _, %Info{}} -> true
        _ -> false
      end)

    assert node != nil, "no function #{name} in #{inspect(tree)}"
    node
  end

  # The value of a global binding that a script made.
  defp global!(gid, name) do
    assert {:ok, v} = Interp.lookup_scoped(gid, name), name
    v
  end

  # A native `peekall()`: it records every live frame of the heap, newest first. A test
  # uses it when the frame it wants to see is not the newest one, for example the frame of
  # a default constructor while the parent constructor runs.
  defp install_peek_all(gid) do
    peek =
      Interp.native("peekall", fn _this, _args ->
        last = :erlang.get(:js_next) - 1

        found =
          for id <- last..0//-1,
              t = :erlang.get(id),
              is_tuple(t) and tuple_size(t) >= 5 and match?(%Info{}, elem(t, 1)),
              do: {id, t}

        Process.put(:peeked_all, found)
        :undefined
      end)

    Interp.declare(gid, "peekall", peek)
  end

  # The slot `i` of a frame tuple that a peek recorded.
  defp at(t, i), do: elem(t, i - 1)

  # The heap entry of an object.
  defp entry({:obj, id}), do: Interp.deref(id)

  # `a` is slot 6, `b` 7, the argument list 8 and the arguments object 9.
  @args2 "function f(a, b){ return arguments }"

  # A hand-built frame of `@args2` for the call `f(args...)`, with the hidden slots as the
  # frame builder fills them at entry: the argument list and `{:unbuilt, id}`. `params`
  # overrides the parameter slots, so that a test can see that the build reads the slots
  # and not the list. Returns the frame and the function object.
  defp args_frame(gid, args, params \\ nil) do
    node = fn3(@args2, "f")
    i = info(node)

    assert %Info{
             level: 3,
             slots: %{"a" => 6, "b" => 7, :args => 8, "arguments" => 9},
             hidden: [:args, :arguments],
             argmap: %{"a" => 0, "b" => 1}
           } = i

    {:obj, id} = f = Interp.make_function(node, gid, false)
    [p0, p1] = params || Enum.take(args ++ [:undefined, :undefined], 2)
    {frame(gid, i, [p0, p1, args, {:unbuilt, id}]), f}
  end

  # The arguments object of a hand-built `args_frame`, built by the first read.
  defp build(fid), do: Interp.ev({:aslot, 0, 9}, fid)

  describe "level 3: the hidden slots at call entry (hidden_slots)" do
    @hidden_src "function F(){ peek(); this.v = [new.target, arguments] }"

    defp hidden_fn(gid, src) do
      node = fn3(src, "F")

      assert %Info{
               level: 3,
               hidden: [:this, :args, :arguments, :new_target],
               slots: %{:this => 6, :args => 7, "arguments" => 8, :new_target => 9}
             } = info(node)

      Interp.make_function(node, gid, false)
    end

    test "a call: `this` boxed or the global `this` when sloppy, raw when strict, nt undefined" do
      gid = heap()
      install_peek(gid)
      {:obj, id} = f = hidden_fn(gid, @hidden_src)

      Interp.call(f, 5.0, [1.0, 2.0])
      {_, t} = peeked()
      assert tuple_size(t) == info(fn3(@hidden_src, "F")).size
      assert Interp.typeof(at(t, 6)) == "object"
      assert at(t, 7) == [1.0, 2.0]
      # The object is built on the first read, and the marker names the function.
      assert at(t, 8) == {:unbuilt, id}
      assert at(t, 9) == :undefined

      global_this =
        case Interp.lookup_scoped(gid, :this) do
          {:ok, w} -> w
          :error -> :undefined
        end

      Interp.call(f, :undefined, [])
      {_, t} = peeked()
      assert at(t, 6) == global_this
      assert at(t, 7) == []

      strict =
        hidden_fn(gid, "function F(){ 'use strict'; peek(); this.v = [new.target, arguments] }")

      obj = Interp.new_object([])
      Interp.call(strict, obj, [])
      {_, t} = peeked()
      assert at(t, 6) == obj
      assert at(t, 9) == :undefined
    end

    test "`new`: the new object and the new target; Reflect.construct gives its own target" do
      gid = heap()
      install_peek(gid)
      f = hidden_fn(gid, @hidden_src)

      o = Interp.construct(f, [1.0])
      {fid, t} = peeked()
      assert at(t, 6) == o
      assert at(t, 7) == [1.0]
      assert at(t, 9) == f
      assert Interp.get(o, "v") |> Interp.array_list() |> hd() == f
      # Nothing holds the frame after the construction: no closure was made.
      assert freed?(fid)

      run_script("function G(){}")
      g = global!(gid, "G")
      o = Interp.construct(f, [], g)
      {_, t} = peeked()
      assert at(t, 9) == g
      assert entry(o).proto == Interp.get(g, "prototype")
    end

    test "`:home` comes from the closure; a method without a home gets undefined" do
      gid = heap()
      install_peek(gid)

      run_script(
        "var o = { m(){ peek(); return super.toString === Object.prototype.toString } }",
        3
      )

      o = global!(gid, "o")
      m = Interp.get(o, "m")
      %Info{slots: %{home: home_slot}} = closure(m).info

      assert Interp.call(m, o, []) == true
      {_, t} = peeked()
      assert at(t, home_slot) == closure(m).home
      assert at(t, home_slot) == o

      # `set_home` never ran for this closure, so the slot holds `undefined`, and `super`
      # finds no home, as at `:off`.
      bare = Interp.make_function(fn3("({ m(){ peek(); return super.x } })", "m"), gid, false)
      %Info{slots: %{home: bare_slot}} = closure(bare).info
      refute Map.has_key?(closure(bare), :home)

      assert caught(fn -> Interp.call(bare, o, []) end) ==
               {"SyntaxError", "'super' keyword unexpected here"}

      {_, t} = peeked()
      assert at(t, bare_slot) == :undefined
    end

    test "a derived constructor: `:uninit_this`, the new target and `:ctor_fn` == the class" do
      gid = heap()
      install_peek(gid)

      run_script(
        "var A = class A { constructor(){ this.a = 1 } }; " <>
          "var B = class B extends A { constructor(x){ peek(); super(); this.x = x } }; " <>
          "var C = class C { constructor(){ peek(); this.t = new.target } }; function G(){}",
        3
      )

      [b, c, g] = Enum.map(~w(B C G), &global!(gid, &1))
      %Info{kind: :derived_ctor, slots: slots} = closure(b).info
      assert %{"x" => 6, :this => ti, :new_target => ni, :ctor_fn => ci} = slots

      o = Interp.construct(b, [3.0])
      {fid, t} = peeked()
      assert at(t, ti) == :uninit_this
      assert at(t, ni) == b
      assert at(t, ci) == b
      assert Interp.get(o, "a") == 1.0 and Interp.get(o, "x") == 3.0
      assert entry(o).proto == Interp.get(b, "prototype")
      assert freed?(fid)

      # `Reflect.construct(B, [], G)`: the frame holds `G`, and `super()` passes it on.
      o = Interp.construct(b, [], g)
      {_, t} = peeked()
      assert at(t, ni) == g
      assert entry(o).proto == Interp.get(g, "prototype")

      # A base constructor runs in `:new` mode: `this` is the new object.
      %Info{kind: :ctor, slots: %{:this => cti, :new_target => cni}} = closure(c).info
      o = Interp.construct(c, [])
      {_, t} = peeked()
      assert at(t, cti) == o
      assert at(t, cni) == c
      assert Interp.get(o, "t") == c
    end

    test "the frames of both default constructor records have the size of the record" do
      gid = heap()
      install_peek(gid)
      install_peek_all(gid)

      # The base record, on a node as `Classes` builds it from the record (design 1.5),
      # with a call of `peek` as its body so that the frame can be seen.
      base = %{Resolve.default_ctor_info(false, nil) | rewritten: true}
      peek_call = [{:expr, {:call, {:gref, "peek"}, [], false}}]
      f = Interp.make_function({:fn, "A", [], peek_call, false, base}, gid, false)
      o = Interp.construct(f, [])
      {_, t} = peeked()
      assert tuple_size(t) == base.size
      assert at(t, 6) == o

      # The derived record: its frame is live while the parent constructor runs.
      run_script(
        "var P = class P { constructor(){ peekall() } }; var D = class D extends P {}",
        3
      )

      d = global!(gid, "D")
      derived = %{Resolve.default_ctor_info(true, nil) | rewritten: true}
      Interp.construct(d, [1.0, 2.0])

      assert [{_, t}] =
               for(
                 {_, t} = e <- Process.get(:peeked_all),
                 match?(%Info{kind: :derived_ctor}, elem(t, 1)),
                 do: e
               )

      assert tuple_size(t) == derived.size
      assert %Info{slots: %{"args" => 6, this: 7, new_target: 8, ctor_fn: 9}} = elem(t, 1)
      assert Interp.array_list(at(t, 6)) == [1.0, 2.0]
      assert at(t, 7) == :uninit_this
      assert at(t, 8) == d
      assert at(t, 9) == d
    end
  end

  describe "level 3: the arguments object (build_arguments)" do
    test "a mapped object: the indices below the argument count, `{:mapped, aid}` in `:args`" do
      gid = heap()
      {fid, f} = args_frame(gid, [1.0])
      {:obj, aid} = ao = build(fid)

      # Only `a` has an argument, so only index 0 maps (design 2.2, step 2).
      assert %{arguments: true, mapped: %{0 => "a"}, map_scope: ^fid} = Interp.deref(aid)
      assert slot(fid, 8) == {:mapped, aid}
      assert slot(fid, 9) == ao
      assert Interp.get(ao, "length") == 1.0
      assert Interp.get(ao, "0") == 1.0
      assert Interp.get(ao, "callee") == f

      assert Interp.get(ao, {:symbol, :iterator, "Symbol.iterator"}) ==
               Interp.get(Interp.proto(:array), "values")

      assert entry(ao).proto == Interp.proto(:object)
    end

    test "the items come from the current slots, not from the argument list" do
      gid = heap()
      # The body wrote `a = 5` before the first read of `arguments` (row 1).
      {fid, _} = args_frame(gid, [1.0, 2.0], [5.0, 2.0])
      ao = build(fid)
      assert Interp.get(ao, "0") == 5.0
      assert Interp.get(ao, "1") == 2.0
      assert %{mapped: %{0 => "a", 1 => "b"}} = entry(ao)
    end

    test "duplicate names: the last position owns the name" do
      gid = heap()
      node = fn3("function f(a, a){ return arguments }", "f")

      assert %Info{slots: %{"a" => 7, :args => 8, "arguments" => 9}, argmap: %{"a" => 1}} =
               i = info(node)

      {:obj, id} = Interp.make_function(node, gid, false)
      fid = frame(gid, i, [1.0, 2.0, [1.0, 2.0], {:unbuilt, id}])
      ao = Interp.ev({:aslot, 0, 9}, fid)
      assert %{mapped: %{1 => "a"}} = entry(ao)
      assert Interp.get(ao, "0") == 1.0
      assert Interp.get(ao, "1") == 2.0

      # The first `a` is not mapped: a write to index 0 does not reach slot 7.
      Interp.put(ao, "0", 9.0)
      assert slot(fid, 7) == 2.0
      Interp.put(ao, "1", 8.0)
      assert slot(fid, 7) == 8.0
    end

    # Each source returns the object and a closure, so the frame stays and the object is
    # not detached: a mapped object would keep its `:mapped` key.
    test "unmapped for strict code, patterns, initializers and no parameters" do
      gid = heap()

      for {src, callee} <- [
            {"function f(a){ 'use strict'; return [arguments, () => a] }", :thrower},
            {"function f({a}){ return [arguments, () => a] }", :thrower},
            {"function f(a = 1){ return [arguments, () => a] }", :thrower},
            {"function f(){ return [arguments, () => 1] }", :function}
          ] do
        f = Interp.make_function(fn3(src, "f"), gid, false)
        [ao, g] = Interp.array_list(Interp.call(f, :undefined, [Interp.new_object([]), 2.0]))
        refute Map.has_key?(entry(ao), :mapped), src
        refute Map.has_key?(entry(ao), :map_scope), src
        assert Interp.get(ao, "length") == 2.0, src

        # The argument list stays a list in the frame that the closure keeps.
        %Info{slots: %{args: args_slot}} = closure(f).info
        assert is_list(slot(closure(g).scope, args_slot)), src

        case callee do
          :thrower -> assert {"TypeError", _} = caught(fn -> Interp.get(ao, "callee") end), src
          :function -> assert Interp.get(ao, "callee") == f
        end
      end
    end
  end

  describe "level 3: the {:aslot} form" do
    test "the build runs once, and the object keeps its identity" do
      gid = heap()
      {fid, _} = args_frame(gid, [1.0, 2.0])
      ao = build(fid)
      n = :erlang.get(:js_next)
      assert build(fid) == ao
      assert Interp.ev({:member, {:aslot, 0, 9}, {:num, 1.0}, false}, fid) == 2.0
      assert :erlang.get(:js_next) == n
    end

    test "a write replaces the binding; the mapping stays with the first object (row 20)" do
      gid = heap()
      {fid, _} = args_frame(gid, [1.0, 2.0])
      {:obj, aid} = ao = build(fid)

      assert Interp.ev({:assign, "=", {:aslot, 0, 9}, {:num, 5.0}}, fid) == 5.0
      assert slot(fid, 9) == 5.0
      assert slot(fid, 8) == {:mapped, aid}
      assert Interp.ev({:aslot, 0, 9}, fid) == 5.0

      # The sync goes through the object in `:args`, not through the binding.
      Interp.ev({:assign, "=", {:mslot, 0, 6, "a", 0}, {:num, 2.0}}, fid)
      assert Interp.get(ao, "0") == 2.0
    end

    test "a write before the first read: no object is built and nothing is mapped (D1)" do
      gid = heap()
      {fid, _} = args_frame(gid, [1.0, 2.0])
      n = :erlang.get(:js_next)
      Interp.ev({:assign, "=", {:aslot, 0, 9}, {:num, 5.0}}, fid)
      assert :erlang.get(:js_next) == n
      Interp.ev({:assign, "=", {:mslot, 0, 6, "a", 0}, {:num, 9.0}}, fid)
      assert slot(fid, 6) == 9.0
      assert slot(fid, 8) == [1.0, 2.0]
      assert slot(fid, 9) == 5.0
    end

    test "typeof and delete" do
      gid = heap()
      {fid, _} = args_frame(gid, [1.0])
      assert Interp.ev({:unary, "typeof", {:aslot, 0, 9}}, fid) == "object"
      assert Interp.ev({:unary, "delete", {:aslot, 0, 9}}, fid) == false
      build(fid)
      assert Interp.ev({:unary, "typeof", {:aslot, 0, 9}}, fid) == "object"
      Interp.ev({:assign, "=", {:aslot, 0, 9}, {:num, 5.0}}, fid)
      assert Interp.ev({:unary, "typeof", {:aslot, 0, 9}}, fid) == "number"
      assert Interp.ev({:unary, "delete", {:aslot, 0, 9}}, fid) == false
    end

    test "the build at depth 1 after the owner returned (row 32)" do
      gid = heap()
      node = fn3("function f(){ return () => arguments.length }", "f")
      assert %Info{slots: %{:args => 6, "arguments" => 7}} = info(node)
      {:obj, id} = f = Interp.make_function(node, gid, false)

      g = Interp.call(f, :undefined, [1.0, 2.0, 3.0])
      fid = closure(g).scope
      refute freed?(fid)
      assert slot(fid, 7) == {:unbuilt, id}

      assert Interp.call(g, :undefined, []) == 3.0
      assert {:obj, _} = ao = slot(fid, 7)
      assert Interp.get(ao, "callee") == f
      assert Interp.call(g, :undefined, []) == 3.0
      assert slot(fid, 7) == ao
    end

    test "ev_named gives a function the name of a mapped parameter" do
      gid = heap()
      {fid, _} = args_frame(gid, [1.0])
      build(fid)
      g = Interp.ev_named({:fn, nil, [], [], false, nil}, fid, {:mslot, 0, 6, "a", 0})
      assert Interp.get(g, "name") == "a"
    end
  end

  describe "level 3: the sync of a mapped parameter" do
    # Each write role of the parameter `a`, as the resolver gives it at level 3, with the
    # value that `arguments[0]` must show after it. The parameter starts at 1.
    @roles [
      {"a = 1", 1.0},
      {"a += 2", 3.0},
      {"a ||= 3", 1.0},
      {"a &&= 4", 4.0},
      {"a++", 2.0},
      {"--a", 0.0},
      {"[a] = [4]", 4.0},
      {"({a} = {a: 5})", 5.0},
      {"var a = 6", 6.0},
      {"var [a] = [7]", 7.0},
      {"for (a in {k: 1});", "k"},
      {"for (var a of [8]);", 8.0}
    ]

    test "{:mslot} in each write role writes the slot and the item" do
      gid = heap()

      for {stmt, value} <- @roles do
        src = "function f(a, b){ #{stmt}; return arguments }"
        {[s | _], i} = body_of(fn3(src, "f"))
        assert %Info{slots: %{"a" => 6, :args => 8, "arguments" => 9}} = i
        assert {:mslot, 0, 6, "a", 0} = find(s, &match?({:mslot, _, _, _, _}, &1)), src
        {:obj, id} = Interp.make_function(fn3(src, "f"), gid, false)
        fid = frame(gid, i, [1.0, 2.0, [1.0, 2.0], {:unbuilt, id}])
        ao = Interp.ev({:aslot, 0, 9}, fid)

        Interp.exec_stmt(s, fid)
        assert slot(fid, 6) == value, src
        assert Interp.get(ao, "0") == value, src
        assert Interp.get(ao, "1") == 2.0, src
      end
    end

    test "a strict inner function writes through {:sassign} and {:supdate} at depth 1 (row 16)" do
      gid = heap()
      {fid, _} = args_frame(gid, [1.0])
      ao = build(fid)
      inner = frame(fid, info(fn3("function g(){ 'use strict'; return 1 }", "g")), [])

      Interp.ev({:sassign, "=", {:mslot, 1, 6, "a", 0}, {:num, 5.0}}, inner)
      assert Interp.get(ao, "0") == 5.0
      Interp.ev({:supdate, "++", false, {:mslot, 1, 6, "a", 0}}, inner)
      assert slot(fid, 6) == 6.0
      assert Interp.get(ao, "0") == 6.0
      Interp.bind_pattern({:mslot, 1, 6, "a", 0}, 7.0, inner, :assign)
      assert Interp.get(ao, "0") == 7.0
    end

    test "no sync after unmap_argument, and none into a foreign object" do
      gid = heap()
      {fid, _} = args_frame(gid, [1.0, 2.0])
      {:obj, aid} = ao = build(fid)

      Interp.unmap_argument(aid, 0)
      Interp.ev({:assign, "=", {:mslot, 0, 6, "a", 0}, {:num, 9.0}}, fid)
      assert slot(fid, 6) == 9.0
      assert Interp.get(ao, "0") == 1.0
      Interp.put(ao, "0", 4.0)
      assert slot(fid, 6) == 9.0

      # `arguments = other` then `b = 3`: the other object does not change.
      other = Interp.new_array([0.0, 0.0])
      Interp.ev({:assign, "=", {:aslot, 0, 9}, {:val, other}}, fid)
      Interp.ev({:assign, "=", {:mslot, 0, 7, "b", 1}, {:num, 3.0}}, fid)
      assert Interp.array_list(other) == [0.0, 0.0]
      assert Interp.get(ao, "1") == 3.0
    end

    test "sync_param on a frame: a write to the object reaches the slot" do
      gid = heap()
      {fid, _} = args_frame(gid, [1.0])
      {:obj, aid} = ao = build(fid)

      Interp.put(ao, "0", 7.0)
      assert slot(fid, 6) == 7.0

      # The direct call, after the item write, as `put` makes it. The alias check of check
      # mode reads the item, so the item is written first.
      o = Interp.deref(aid)
      Interp.store(aid, %{o | items: Map.put(o.items, 0, 8.0)})
      Interp.sync_param(Interp.deref(aid), 0, 8.0)
      assert slot(fid, 6) == 8.0

      # Index 1 has no argument, so `b` is not mapped.
      Interp.put(ao, "1", 9.0)
      assert slot(fid, 7) == :undefined
      assert Interp.get(ao, "length") == 1.0
    end

    test "assign_frame: a write by name syncs the item, also from a map scope (eval code)" do
      gid = heap()
      {fid, _} = args_frame(gid, [1.0, 2.0])
      ao = build(fid)

      Interp.assign_scoped(fid, "a", 4.0)
      assert slot(fid, 6) == 4.0
      assert Interp.get(ao, "0") == 4.0

      m = Interp.new_scope(fid)
      Interp.assign_scoped(m, "b", 5.0)
      assert slot(fid, 7) == 5.0
      assert Interp.get(ao, "1") == 5.0
    end
  end

  describe "level 3: the frame free and the detach (free_frame)" do
    test "a plain return detaches the object and frees the frame (row 23)" do
      gid = heap()
      install_peek(gid)
      f = Interp.make_function(fn3("function f(a){ peek(); return arguments }", "f"), gid, false)

      {:obj, aid} = ao = Interp.call(f, :undefined, [1.0])
      {fid, _} = peeked()
      assert freed?(fid)
      o = Interp.deref(aid)
      refute Map.has_key?(o, :mapped)
      refute Map.has_key?(o, :map_scope)
      assert o.arguments

      # The detached object is an ordinary arguments object.
      Interp.put(ao, "0", 5.0)
      assert Interp.get(ao, "0") == 5.0
      assert Interp.get(ao, "length") == 1.0
    end

    test "a closure keeps the frame and the mapping, also after a throw" do
      gid = heap()

      f =
        Interp.make_function(
          fn3("function f(a){ throw [arguments, (v) => { a = v }, () => a] }", "f"),
          gid,
          false
        )

      assert {:js_error, arr} = catch_throw(Interp.call(f, :undefined, [1.0]))
      [ao, set, get] = Interp.array_list(arr)
      fid = closure(set).scope
      refute freed?(fid)
      assert %{mapped: %{0 => "a"}, map_scope: ^fid} = entry(ao)

      Interp.call(set, :undefined, [9.0])
      assert Interp.get(ao, "0") == 9.0
      Interp.put(ao, "0", 3.0)
      assert Interp.call(get, :undefined, []) == 3.0
    end

    test "the GC keeps a frame that an escaped mapped object holds, and sweeps both later" do
      gid = heap()
      install_peek(gid)

      f =
        Interp.make_function(
          fn3("function f(a){ peek(); return [arguments, () => a] }", "f"),
          gid,
          false
        )

      [{:obj, aid} = ao, _g] = Interp.array_list(Interp.call(f, :undefined, [1.0]))
      {fid, _} = peeked()
      # Only the object is a root: the array and the closure are garbage. The object's
      # `map_scope` keeps the frame (design 2.5). The copy of the frame that `peek` keeps
      # in the process would be a root too, so it goes first.
      Process.delete(:peeked)
      Process.put(:frames_test_hold, ao)
      GC.collect()
      refute freed?(fid)
      Interp.put(ao, "0", 7.0)
      assert slot(fid, 6) == 7.0

      Process.delete(:frames_test_hold)
      GC.collect()
      assert freed?(fid)
      assert :erlang.get(aid) == :undefined
    end

    test "1000 calls that read `arguments` leave no frame; the GC takes back the objects" do
      gid = heap()
      run_script("function f(a){ return arguments[0] }", 3)
      f = global!(gid, "f")
      assert %{info: %Info{level: 3, rewritten: true, argmap: %{"a" => 0}}} = closure(f)

      GC.collect()
      base = Interp.heap_size()
      for _ <- 1..1000, do: assert(Interp.call(f, :undefined, [1.0]) == 1.0)
      # Each call leaves its arguments object, as `:off` does, and no frame.
      assert Interp.heap_size() == base + 1000
      GC.collect()
      assert Interp.heap_size() == base
    end

    test "the dangling scan follows `map_scope`" do
      gid = heap()
      {fid, _} = args_frame(gid, [1.0])
      ao = build(fid)
      assert GC.dangling(ao) == []

      # A free without the detach leaves the object pointing at a tombstone. The scan must
      # find it through the `map_scope` edge (design 2.5, the gc.ex change).
      :erlang.put(fid, {:js_freed, ~s("f")})
      assert GC.dangling(ao) == [~s("f")]
    end
  end

  describe "level 3: the by-name walk and the body entry" do
    test "lookup_frame builds the object on a by-name hit" do
      gid = heap()
      {fid, f} = args_frame(gid, [1.0, 2.0])

      assert {:ok, {:obj, aid} = ao} = Interp.lookup_scoped(fid, "arguments")
      assert slot(fid, 9) == ao
      assert slot(fid, 8) == {:mapped, aid}
      assert Interp.get(ao, "callee") == f

      # Eval code in a map scope over the frame reads the same object.
      m = Interp.new_scope(fid)
      assert Interp.ev({:id, "arguments"}, m) == ao

      {fid, _} = args_frame(gid, [1.0])
      assert {:obj, _} = Interp.ev({:id, "arguments"}, Interp.new_scope(fid))
      assert {:obj, _} = slot(fid, 9)
    end

    test "enter_body with `var arguments`: after the hoist with plain parameters (row 10)" do
      gid = heap()
      install_peek(gid)
      node = fn3("function f(a){ var arguments; function a(){} peek(); return arguments }", "f")
      assert %Info{args_var: true, slots: %{"a" => 6, :args => 7, "arguments" => 8}} = info(node)
      f = Interp.make_function(node, gid, false)

      ao = Interp.call(f, :undefined, [1.0, 2.0])
      # The object exists before any read, and it maps the hoisted function.
      {_, t} = peeked()
      assert at(t, 8) == ao
      assert Interp.typeof(Interp.get(ao, "0")) == "function"
      assert Interp.get(ao, "0") == at(t, 6)
      assert Interp.get(ao, "1") == 2.0
    end

    test "enter_body with `var arguments`: before the copies with parameter expressions" do
      gid = heap()
      install_peek(gid)
      node = fn3("function f(a = 1){ var arguments; peek(); return arguments }", "f")

      assert %Info{
               args_var: true,
               copies: [{8, 9}],
               slots: %{:args => 7, :arguments => 8, "arguments" => 9}
             } = info(node)

      f = Interp.make_function(node, gid, false)
      ao = Interp.call(f, :undefined, [5.0, 6.0])
      {_, t} = peeked()
      assert at(t, 8) == ao
      assert at(t, 9) == ao
      refute Map.has_key?(entry(ao), :mapped)
      assert Interp.array_list(ao) == [5.0, 6.0]
    end
  end

  describe "level 3: constructors" do
    test ":ctor mode returns the value and `this`, and frees the frame after the read" do
      gid = heap()
      install_peek(gid)

      run_script(
        "var A = class A { constructor(){ this.a = 1 } }; " <>
          "var B = class B extends A { constructor(r){ peek(); super(); this.b = 2; if (r) return r } }",
        3
      )

      {:obj, id} = b = global!(gid, "B")

      assert {:undefined, {:obj, _} = this} =
               Interp.run_class_frame(id, closure(b), :uninit_this, [:undefined], b, :ctor)

      {fid, _} = peeked()
      assert freed?(fid)
      assert Interp.get(this, "a") == 1.0 and Interp.get(this, "b") == 2.0
      assert entry(this).proto == Interp.get(b, "prototype")

      r = Interp.new_object([])
      assert {^r, {:obj, _}} = Interp.run_class_frame(id, closure(b), :uninit_this, [r], b, :ctor)
    end

    test "super() from an arrow writes the frame slot; a second super() throws" do
      gid = heap()
      install_peek(gid)

      run_script(
        "var A = class A { constructor(){ this.s = 'A' } }; " <>
          "var B = class B extends A { constructor(){ peek(); const f = () => super(); f(); this.t = this.s + 'B' } }; " <>
          "var C = class C extends A { constructor(){ super(); super() } }",
        3
      )

      b = global!(gid, "B")
      %Info{slots: %{this: ti}} = closure(b).info
      o = Interp.construct(b, [])
      assert Interp.get(o, "t") == "AB"
      {fid, t} = peeked()
      assert at(t, ti) == :uninit_this
      # The arrow moved the closure count, so the frame stays, and its slot holds `this`.
      refute freed?(fid)
      assert slot(fid, ti) == o

      assert caught(fn -> Interp.construct(global!(gid, "C"), []) end) ==
               {"ReferenceError", "Super constructor may only be called once"}
    end

    test "a derived constructor that does not call super() throws the ReferenceError" do
      gid = heap()
      run_script("var A = class A {}; var B = class B extends A { constructor(){ } }", 3)

      assert caught(fn -> Interp.construct(global!(gid, "B"), []) end) ==
               {"ReferenceError",
                "Must call super constructor in derived class before accessing 'this' or returning from derived constructor"}
    end

    test "default constructors run on a frame from the Info of the class node" do
      gid = heap()

      run_script(
        "var A = class A { constructor(...a){ this.a = a.join() } }; var B = class B extends A {}; var E = class E {}",
        3
      )

      b = global!(gid, "B")
      e = global!(gid, "E")

      # The nodes of design 1.5: the records of `default_ctor_info` with `rewritten` set.
      derived = Resolve.default_ctor_info(true, nil)
      base = Resolve.default_ctor_info(false, nil)

      assert %{
               info: %Info{kind: :derived_ctor, rewritten: true} = di,
               params: [{:rest, {:slot, 0, 6, "args"}}],
               body: [{:expr, {:call, {:super}, [{:spread, {:slot, 0, 6, "args"}}], false}}]
             } = closure(b)

      assert %{di | src: nil, rewritten: false} == derived

      assert %{info: %Info{kind: :ctor, rewritten: true} = bi, params: [], body: []} = closure(e)
      assert %{bi | src: nil, rewritten: false} == base

      assert Interp.get(Interp.construct(b, [1.0, 2.0, 3.0]), "a") == "1,2,3"
      assert entry(Interp.construct(e, [])).proto == Interp.get(e, "prototype")
    end
  end

  if @check do
    describe "level 3: check mode" do
      test "a forced desync fails the alias check" do
        gid = heap()
        {fid, _} = args_frame(gid, [1.0, 2.0])
        {:obj, aid} = build(fid)
        # The item of `a` changes behind the sync; the next mapped write checks all pairs.
        o = Interp.deref(aid)
        Interp.store(aid, %{o | items: Map.put(o.items, 0, 99.0)})

        e =
          assert_raise(ArgumentError, fn ->
            Interp.ev({:assign, "=", {:mslot, 0, 7, "b", 1}, {:num, 3.0}}, fid)
          end)

        assert Exception.message(e) =~ "resolve check"
      end

      test "a {:slot} write to a mapped parameter fails" do
        gid = heap()
        {fid, _} = args_frame(gid, [1.0, 2.0])

        e =
          assert_raise(ArgumentError, fn ->
            Interp.ev({:assign, "=", {:slot, 0, 6, "a"}, {:num, 3.0}}, fid)
          end)

        assert Exception.message(e) =~ "resolve check"

        assert_raise(ArgumentError, fn ->
          Interp.bind_pattern({:slot, 0, 6, "a"}, 3.0, fid, :assign)
        end)
      end

      test "an escaped {:unbuilt} marker fails" do
        gid = heap()
        {fid, _} = args_frame(gid, [1.0])

        e =
          assert_raise(ArgumentError, fn -> Interp.ev({:slot, 0, 9, "arguments"}, fid) end)

        assert Exception.message(e) =~ "resolve check"
      end

      test "a free without the detach fails in sync_param and in the dangling scan" do
        gid = heap()
        {fid, _} = args_frame(gid, [1.0])
        ao = build(fid)
        Interp.free(fid)
        assert freed?(fid)

        e = assert_raise(ArgumentError, fn -> Interp.put(ao, "0", 5.0) end)
        assert Exception.message(e) =~ "resolve check"
        assert GC.dangling(ao) == [~s("f")]
        assert_raise(ArgumentError, fn -> Interp.check_dangling(ao) end)
      end
    end
  else
    @tag skip: "set JS_RESOLVE_CHECK=1 to run the check-mode tests"
    test "level 3: check mode" do
      :ok
    end
  end

  # ── the semantic table of step 2d (2d design 6.2) ──────────

  # Each value was checked at `:off`, at level 1 and at level 2 on 75a8328, and each one
  # is the value of the design table. Row 28 is row 27 with `delete r[0][0]` before the
  # call, and row 74 is row 73 with `var arguments`. Row 60 defines the getter on
  # `Number.prototype` twice, sloppy and then strict. Row "69b" is not in the design: it
  # reads `Error.stack` in the parent of a default constructor (design 6.1, item 9).
  @rows_2d [
    {1, ~S|function f(a, b){ a = 5; return arguments[0] + ',' + arguments.length } f(1, 2)|,
     "5,2"},
    {2, ~S|function f(a){ arguments[0] = 7; return a } f(1)|, 7.0},
    {3, ~S|function f(a){ "use strict"; a = 5; return arguments[0] } f(1)|, 1.0},
    {4, ~S|function f(a){ "use strict"; arguments[0] = 7; return a } f(1)|, 1.0},
    {5, ~S|function f(a, b = 2){ a = 9; return arguments[0] + ',' + arguments.length } f(1)|,
     "1,1"},
    {6, ~S|function f(a, b){ b = 3; return arguments[1] + ',' + arguments.length } String(f(1))|,
     "undefined,1"},
    {7, ~S|function f(a){ delete arguments[0]; arguments[0] = 4; return a } f(1)|, 1.0},
    {8,
     ~S|function f(a){ Object.defineProperty(arguments, '0', {value: 3}); var x = a; Object.defineProperty(arguments, '0', {writable: false}); a = 9; return x + ',' + arguments[0] } f(1)|,
     "3,3"},
    {9, ~S|function f(a, a){ a = 3; return arguments[0] + ',' + arguments[1] } f(1, 2)|, "1,3"},
    {10, ~S|function f(a){ function a(){ return 'fn' } return typeof arguments[0] } f(1)|,
     "function"},
    {11, ~S|function f(a){ var arguments; return typeof arguments + arguments.length } f(1, 2)|,
     "object2"},
    {12, ~S|function f(a){ var a = 2; return arguments[0] } f(1)|, 2.0},
    {13, ~S|function f(a){ for (var a of [3]); return arguments[0] } f(1)|, 3.0},
    {14, ~S|function f(a){ [a] = [8]; return arguments[0] } f(1)|, 8.0},
    {15, ~S|function f(a){ a++; a += 10; return arguments[0] } f(1)|, 12.0},
    {16,
     ~S|function f(a){ function g(){ "use strict"; a = 5; a++ } g(); return arguments[0] } f(1)|,
     6.0},
    {17, ~S|function f(a){ function g(){ a = 3 } g(); return arguments[0] } f(1)|, 3.0},
    {18, ~S|function f(a){ var h = async () => { a = 4 }; h(); return arguments[0] } f(1)|, 4.0},
    {19, ~S|function f(a){ return (() => eval('arguments[0] = 4; a'))() } f(1)|, 4.0},
    {20,
     ~S|function f(a){ var o = arguments; arguments = 5; a = 2; return o[0] + ',' + arguments } f(1)|,
     "2,5"},
    {21, ~S|function f(a){ arguments[1] = 5; return arguments.length + ',' + arguments[1] } f(1)|,
     "1,5"},
    {22,
     ~S|function f(a){ a = 2; var d = Object.getOwnPropertyDescriptor(arguments, '0'); return d.value + ',' + d.writable } f(1)|,
     "2,true"},
    {23, ~S|function f(a){ return arguments } var o = f(1); o[0] = 5; o[0]|, 5.0},
    {24,
     ~S|function f(a){ return arguments } var o = f(1, 2, 3); o[0] = 9; [o.length, o[0], Array.prototype.slice.call(o).join()].join()|,
     "3,9,9,2,3"},
    {25,
     ~S|function f(){ var a = arguments; return function(){ return a[0] + arguments[0] } } f(1)(2)|,
     3.0},
    {26, ~S|function f(a){ return [arguments, () => a] } var r = f(1); r[0][0] = 7; r[1]()|, 7.0},
    {27, ~S|function f(a){ return [arguments, (v) => { a = v }] } var r = f(1); r[1](9); r[0][0]|,
     9.0},
    {28,
     ~S|function f(a){ return [arguments, (v) => { a = v }] } var r = f(1); delete r[0][0]; r[1](9); String(r[0][0])|,
     "undefined"},
    {29, ~S|function f(){ return [...arguments].join() } f(1, 2, 3)|, "1,2,3"},
    {30, ~S|function f(){ return arguments.callee === f } f()|, true},
    {31,
     ~S|function f(){ "use strict"; try { return arguments.callee } catch (e) { return e.constructor.name } } f()|,
     "TypeError"},
    {32, ~S|function f(){ return (() => () => arguments.length)()() } f(1, 2, 3)|, 3.0},
    {33,
     ~S|function f(a = arguments.length, b = arguments[0]){ return a + ',' + b } f(undefined, undefined, 3)|,
     "3,undefined"},
    {34, ~S|function f(...r){ r[0] = 9; return arguments[0] + ',' + arguments.length } f(1, 2)|,
     "1,2"},
    {35, ~S|function f(){ return typeof arguments + (delete arguments) } f()|, "objectfalse"},
    {36,
     ~S|function f(a, b){ var r = []; for (var k in arguments) r.push(k); return r.join() } f(1, 2)|,
     "0,1"},
    {37, ~S|function F(){ return new.target === F } [F(), new F() instanceof F].join()|,
     "false,true"},
    {38,
     ~S|function F(){ this.t = new.target } function G(){} var o = Reflect.construct(F, [], G); [o.t === G, Object.getPrototypeOf(o) === G.prototype].join()|,
     "true,true"},
    {39,
     ~S|function F(){ return (() => () => new.target)()() } [F() === undefined, new F() === F].join()|,
     "true,true"},
    {40,
     ~S|class A { constructor(){ this.t = new.target.name } } class B extends A {} function G(){} G.prototype = B.prototype; var o = Reflect.construct(B, [], G); o.t + (o instanceof B)|,
     "Gtrue"},
    {41,
     ~S|class A {} class B extends A { constructor(){ var g = () => this; super(); return g() === this ? {ok: 1} : undefined } } new B().ok|,
     1.0},
    {42,
     ~S|class A { constructor(x){ this.x = x } } class B extends A { constructor(){ try { this.y = 1 } catch (e) { var m = e.constructor.name } super(5); this.m = m } } var b = new B(); b.x + b.m|,
     "5ReferenceError"},
    {43,
     ~S|class A {} class B extends A { constructor(){ } } try { new B() } catch (e) { e.constructor.name }|,
     "ReferenceError"},
    {44,
     ~S|class A {} class B extends A { constructor(){ super(); try { super() } catch (e) { this.e = e.constructor.name } } } new B().e|,
     "ReferenceError"},
    {45, ~S|class A {} class B extends A { constructor(){ return {k: 1} } } new B().k|, 1.0},
    {46,
     ~S|class A { constructor(){ this.s = 'A' } } class B extends A { constructor(){ const f = () => super(); f(); this.t = this.s + 'B' } } new B().t|,
     "AB"},
    {47,
     ~S|class A { constructor(...a){ this.a = a.join() } } class B extends A {} new B(1, 2, 3).a|,
     "1,2,3"},
    {48,
     ~S|class B extends Object { constructor(){ (() => eval('super()'))(); this.k = 1 } } new B().k|,
     1.0},
    {49,
     ~S|var base = { hi(){ return 'b' + this.n } }; var o = { __proto__: base, n: 1, hi(){ return super.hi() + '!' } }; o.hi()|,
     "b1!"},
    {50,
     ~S|class A { m(){ return 'A' } } class B extends A { m(){ return () => super.m() + 'B' } } new B().m()()|,
     "AB"},
    {51,
     ~S|class A { static f(){ return this.name } } class B extends A { static g(){ return super.f() } } B.g()|,
     "B"},
    {52,
     ~S|class A { get v(){ return 1 } } class B extends A { get v(){ return super.v + 1 } } new B().v|,
     2.0},
    {53,
     ~S|class C { #x = 1; #m(){ return this.#x + 1 } get #g(){ return this.#m() * 10 } static #s = 5; t(){ return this.#g + C.#s } static has(o){ return #x in o } } [new C().t(), C.has(new C()), C.has({})].join()|,
     "25,true,false"},
    {54,
     ~S|class A { #x = 1; static g(o){ return o.#x } } class B extends A { #x = 2; static h(o){ return o.#x } } var b = new B(); A.g(b) + B.h(b)|,
     3.0},
    {55,
     ~S|class C { #p(){ return 1 } q(o){ try { return o.#p() } catch (e) { return e.constructor.name } } } new C().q({})|,
     "TypeError"},
    {56, ~S|class C { a = 1; b = this.a + 1; c = () => this.b } new C().c()|, 2.0},
    {57,
     ~S|class A { x = 1 } class B extends A { y = this.x + 1; constructor(){ super(); this.z = this.y + 1 } } new B().z|,
     3.0},
    {58, ~S|class C { static x = 1; static { this.y = this.x + 1 } static z = this.y * 10 } C.z|,
     20.0},
    {59,
     ~S|var o = { _v: 1, get v(){ return this._v }, set v(x){ this._v = x * 2 } }; o.v = 5; o.v|,
     10.0},
    {60,
     ~S|Object.defineProperty(Number.prototype, 'ty', {get(){ return typeof this }, configurable: true}); var s = (5).ty; Object.defineProperty(Number.prototype, 'ty', {get(){ "use strict"; return typeof this }}); s + ',' + (5).ty|,
     "object,number"},
    {61,
     ~S|function P(x){ this.x = x; this.nt = new.target === P } var B = P.bind(null, 7); var o = new B(); [o.x, o.nt, o instanceof P].join()|,
     "7,true,true"},
    {62,
     ~S|function F(a){ this.a = a; this.n = arguments.length } var B = F.bind(null, 1, 2); var o = new B(3); o.a + ',' + o.n|,
     "1,3"},
    {63, ~S|class A { constructor(x){ this.x = x } } var B = A.bind(null, 3); new B().x|, 3.0},
    {64,
     ~S|class A { constructor(){ this.c = 0 } inc(){ this.c++; return this } } class B extends A { inc(){ super.inc(); this.c += 10; return this } } var b = new B(); for (var i = 0; i < 3; i++) b.inc(); b.c|,
     33.0},
    {65,
     ~S|function f(){ class A { constructor(){ this.a = arguments.length } } return new A(1, 2).a } f()|,
     2.0},
    {66, ~S|class A { m(){ return this } } var m = new A().m; m() === undefined|, true},
    {67,
     ~S|function outer(){ var fs = []; for (let i = 0; i < 2; i++) fs.push(() => arguments[i]); return fs.map(g => g()).join() } outer(7, 8)|,
     "7,8"},
    {68, ~S|function f(a){ (function(){ eval('a = 3') })(); return arguments[0] } f(1)|, 3.0},
    {69,
     ~S|class A { constructor(){ this.s = new Error('y').stack } } new A().s.split('\n')[1].trim()|,
     "at A"},
    {70,
     ~S|function f(a){ function* g(){ yield arguments.length; yield a } return [...g(1, 2, 3)].join() } f(7)|,
     "3,7"},
    {71,
     ~S|function f(x){ class K extends (arguments[1]) { m(){ return x } } return new K().m() } f(4, Object)|,
     4.0},
    {73,
     ~S|var r; function f(a = async () => { r = arguments.length }){ let arguments = 1; return a } f(undefined, 2)(); r|,
     2.0},
    {74,
     ~S|var r; function f(a = async () => { r = arguments.length }){ var arguments = 1; return a } f(undefined, 2)(); r|,
     2.0},
    {75,
     ~S|var r; function f(a = async () => { r = typeof arguments }){ function arguments(){} return a } f(undefined, 2)(); r|,
     "object"},
    {"69b",
     ~S|class A { constructor(){ this.s = new Error('x').stack } } class B extends A {} new B().s|,
     "Error: x\n    at A\n    at B"}
  ]

  # The two rows of design 5.3 that change at level 3. Each one keeps the `:off` value at
  # levels 1 and 2, where the function is not rewritten, and gives the value of the spec
  # at level 3.
  @diffs_2d [
    # D1: at `:off` the write goes to a global, so the object that the read builds maps `a`.
    {"D1", ~S|function f(a){ arguments = {0: 5}; a = 9; return arguments[0] } f(1)|, 9.0, 5.0},
    # D2: `var arguments` under parameter expressions starts as the arguments object.
    {"D2",
     ~S|function f(a = () => arguments.length){ var arguments; return a() + ',' + typeof arguments } f(undefined, 2)|,
     "2,undefined", "2,object"},
    # D3 and D4 have the cause of D1: a write to `arguments` before the first read goes to a
    # global at `:off`. Here the write is a pattern target and a for-in head.
    {"D3", ~S|function f(a, b){ [arguments] = [7]; return String(arguments) } f(1)|,
     "[object Arguments]", "7"},
    {"D4", ~S|function f(a){ for (arguments in {x: 1}); return String(arguments) } f(1)|,
     "[object Arguments]", "x"}
  ]

  # The four programs that show the gain of step 2d (design 8). They are copies of the
  # programs in bench/js_runtime.exs, in the same wrapper, so that the test checks what the
  # bench measures. Their expected values are the results at `:off`.
  @bench_2d [
    {"classnew30k",
     "class P { y = 1; constructor(x){ this.x = x } } var s = 0; for (var i = 0; i < 30000; i++) s += new P(i).x; return s",
     449_985_000.0},
    {"subclass30k",
     "class B { constructor(x){ this.x = x } } class D extends B {} var s = 0; for (var i = 0; i < 30000; i++) s += new D(i).x; return s",
     449_985_000.0},
    {"supercalls30k",
     "class A { m(x){ return x + 1 } } class B extends A { #x = 2; m(x){ return super.m(x) + this.#x } } var b = new B(); var s = 0; for (var i = 0; i < 30000; i++) s = (s + b.m(i)) % 1000003; return s",
     73650.0},
    {"args30k",
     "function g(a, b){ return arguments.length + arguments[1] } var s = 0; for (var i = 0; i < 30000; i++) s += g(i, i % 7); return s",
     149_995.0}
  ]

  describe "the semantic table of step 2d" do
    test "every row gives the design's value at :off and at levels 1, 2 and 3" do
      for {n, src, value} <- @rows_2d, level <- @levels do
        assert JS.eval(src, resolve: level) == {:ok, value, []}, "row #{n} at #{level}: #{src}"
      end
    end

    # Row 72 is apart because it fails at level 2 on 75a8328 already: the method `m` is a
    # level 2 frame without a `:home` slot, so the by-name walk of the eval code finds no
    # home and throws a SyntaxError. At `:off` the scope of `m` holds `:home`. Rule R1 does
    # not change level 2, and level 2 behaviour must not change in step 2d, so the test
    # records the level 2 result of the base. The design's claim of parity at level 2 is
    # wrong.
    test "row 72: eval('super.m()') in an arrow in a plain function inside a method" do
      src =
        ~S|class A { m(){ return 1 } } class B extends A { m(){ function g(){ return (() => eval('super.m()'))() } return g.call(this) } } new B().m()|

      for level <- [:off, 1, 3] do
        assert JS.eval(src, resolve: level) == {:ok, 1.0, []}, "row 72 at #{level}"
      end

      assert JS.eval(src, resolve: 2) ==
               {:error, {:uncaught, "SyntaxError: 'super' keyword unexpected here"}, []}
    end

    test "D1 and D2: the value of :off at levels 1 and 2, the value of the spec at level 3" do
      for {n, src, off, spec} <- @diffs_2d do
        for level <- [:off, 1, 2] do
          assert JS.eval(src, resolve: level) == {:ok, off, []}, "#{n} at #{level}"
        end

        assert JS.eval(src, resolve: 3) == {:ok, spec, []}, "#{n} at 3"
      end
    end

    test "the functions that the rows test are level 3 and rewritten at level 3" do
      # A row proves nothing at level 3 if its function took the old path.
      for {n, src, name} <- [
            {1, "function f(a, b){ a = 5; return arguments[0] + ',' + arguments.length }", "f"},
            {20, "function f(a){ var o = arguments; arguments = 5; a = 2; return o }", "f"},
            {32, "function f(){ return (() => () => arguments.length)()() }", "f"},
            {37, "function F(){ return new.target === F }", "F"},
            {41,
             "class B extends A { constructor(){ var g = () => this; super(); return g() === this ? {ok: 1} : undefined } }",
             "constructor"},
            {49, "var o = { __proto__: base, n: 1, hi(){ return super.hi() + '!' } }", "hi"},
            {53, "class C { #x = 1; t(){ return this.#x } }", "t"},
            {"D2", "function f(a = () => arguments.length){ var arguments; return a() }", "f"}
          ] do
        assert %Info{level: 3, rewritten: true} = info(fn3(src, name)), "row #{n}"
      end

      # Row 47: the default constructor is level 3 and rewritten through the class node.
      assert {:ok, tree} = Parser.parse("class B extends A {}", resolve: 3)

      assert find(tree, &match?({:class, "B", _, [], %Info{level: 3, rewritten: true}}, &1)),
             "row 47"
    end

    @tag timeout: 300_000
    test "the nine bench programs and the four programs of step 2d give their values at level 3" do
      for {name, body, expected} <- @bench ++ @bench_2d do
        src = "(function(){ function f(){ #{body} } return f() })()"
        opts = [resolve: 3, max_steps: 1_000_000_000, timeout: 120_000]
        assert JS.eval(src, opts) == {:ok, expected, []}, name
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

  @levels [:off, 1, 2, 3]

  # The suite-wide level (`JS_RESOLVE=1`) lives in the same key, so the test restores it
  # instead of deleting it; a delete would run every later sync module at `:off`.
  defp set_level(level) do
    previous = Application.get_env(:browser, :js_resolve)
    Application.put_env(:browser, :js_resolve, level)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:browser, :js_resolve)
        v -> Application.put_env(:browser, :js_resolve, v)
      end
    end)
  end

  # Runs `fun` with the env at `level` and puts the previous level back.
  defp with_level(level, fun) do
    previous = Application.get_env(:browser, :js_resolve)
    Application.put_env(:browser, :js_resolve, level)

    try do
      fun.()
    after
      Application.put_env(:browser, :js_resolve, previous || :off)
    end
  end

  # Runs the page's scripts at `level`; `files` maps urls to what fetching them returns.
  # Returns the console lines, the ones logged by timers and loads included, and the errors.
  defp page(html, level, files \\ %{}) do
    set_level(level)

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

  # `JS.eval(src, resolve: 1)` sets the level of the first parse only; the code that eval
  # and the Function constructor parse reads the env, so these rows set the env.
  test "eval and new Function code runs at the level of the env" do
    for level <- @levels do
      with_level(level, fn ->
        assert Browser.JS.eval(~S|eval("let q = 5; function leaf(a){ return q + a } leaf(1)")|) ==
                 {:ok, 6.0, []}

        assert Browser.JS.eval(
                 ~S|new Function("a", "function leaf(b){ return a + b } return leaf(2)")(1)|
               ) ==
                 {:ok, 3.0, []}

        assert Browser.JS.eval(~S|(0, eval)("var g9 = 4; function leaf(){ return g9 } leaf()")|) ==
                 {:ok, 4.0, []}
      end)
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
