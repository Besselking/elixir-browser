defmodule Browser.JS.CompileNamedTest do
  # Step 5, the class test of design 5.4: a read and a write with a constant key through
  # `Interp.get_named/2` and `Interp.put_named/3` (the paths of compiled code) give the same
  # results as through `Interp.get/2` and `Interp.put/3` (the paths of the tree walker), for
  # one object of each class. The two pairs share the class dispatch (`get_obj/4` and
  # `put_obj/5`), so this test fails when a change gives one path a different key. The
  # inline caches of step A2 (`Interp.get_ic/3`, `put_ic/4` and `strict_put_ic/4`) give the
  # same results too: each operation runs two times on one site, so the first run is a miss
  # that writes the cell and the second run can hit it.
  #
  # Each mode runs in a fresh process with its own heap. The script that makes the objects
  # is the same, so both heaps give the same ids, and the results of the two modes are
  # equal terms, also when they hold objects.
  use ExUnit.Case, async: true

  alias Browser.JS.{Builtins, Interp, Parser, Shape}

  # One object of each class: plain (with an accessor), array, arguments object, function,
  # class, bound function, proxy, proxy of a function, host (the global object), typed
  # array, String wrapper, and a frozen object, on which writes fail.
  @objects """
  (function () {
    var plain = { a: 1, get g() { return 2 }, set s(v) { this.a = v } };
    var arr = [1, 2, 3]; arr.a = 4;
    var args = (function (x, y) { return arguments })(1, 2);
    function fn(p, q) { return p } fn.a = 5;
    class C { static m() { return 1 } }
    var bound = fn.bind(null, 1);
    var proxy = new Proxy({ a: 1 }, { get(t, k) { return k === 'x' ? 9 : t[k] } });
    var fproxy = new Proxy(function () {}, {});
    var typed = new Uint8Array(4);
    var str = new String('abc');
    var frozen = Object.freeze({ a: 1 });
    return [plain, arr, args, fn, C, bound, proxy, fproxy, globalThis, typed, str, frozen];
  })()
  """

  # Keys that are strings and not array indices, so the compiler gives them to the named
  # paths. They hit the special keys of each class: `length` of arrays and typed arrays,
  # `name` and `prototype` of functions, the accessors of typed arrays, and inherited keys.
  @keys ~w(a x g s length name prototype toString byteLength constructor m Infinity)

  test "get_named and put_named give the results of get and put for each class" do
    named = in_heap(:named)
    plain = in_heap(:plain)
    assert length(named) == length(plain)

    for {n, p} <- Enum.zip(named, plain) do
      assert n == p
    end
  end

  test "the inline caches give the results of get and put for each class" do
    ic = in_heap(:ic)
    plain = in_heap(:plain)
    assert length(ic) == length(plain)

    for {i, p} <- Enum.zip(ic, plain) do
      assert i == p
    end
  end

  test "get_named and get read the same value in one heap" do
    reads =
      run_in_heap(fn objs ->
        for o <- objs,
            k <- @keys,
            do: {safe(fn -> Interp.get_named(o, k) end), safe(fn -> Interp.get(o, k) end)}
      end)

    for {n, p} <- reads, do: assert(n == p)
  end

  test "a string primitive reads the same with get_named and get" do
    # A number or a boolean goes to `get/2` in a clause of its own, so only the string path
    # (`get_str/3`) is tested here. The compiler sends only keys that are not array indexes
    # to `get_named/2`. The writes on primitives, with a setter on the prototype, are a row
    # of the compile oracle ("class primitive receivers" in js_compile_test.exs).
    reads =
      run_in_heap(fn _objs ->
        for k <- ["length", "toString", "x", "charAt"],
            do: {Interp.get_named("abc", k), Interp.get("abc", k)}
      end)

    for {gn, g} <- reads, do: assert(gn == g)
  end

  # The record of each key of each object: the two reads, the two sloppy writes of 7, the
  # flag of a failed write, the two strict writes of 8 (or their errors), and the value
  # after the writes.
  defp in_heap(mode) do
    run_in_heap(fn objs ->
      rows =
        for o <- objs, k <- @keys do
          {get, put, strict_put} = ops(mode)
          read = {safe(fn -> get.(o, k) end), safe(fn -> get.(o, k) end)}
          :erlang.put(:js_put_failed, false)
          write = {safe(fn -> put.(o, k, 7.0) end), safe(fn -> put.(o, k, 7.0) end)}
          failed = :erlang.get(:js_put_failed)

          strict =
            {safe(fn -> strict_put.(o, k, 8.0) end), safe(fn -> strict_put.(o, k, 8.0) end)}

          {k, read, write, failed, strict, safe(fn -> Interp.get(o, k) end)}
        end

      rows ++ [{:js_next, :erlang.get(:js_next)}]
    end)
  end

  # The read, the write and the strict write of a mode. The inline caches get new sites for
  # each object and key.
  defp ops(:plain), do: {&Interp.get/2, &Interp.put/3, &Interp.strict_put/3}
  defp ops(:named), do: {&Interp.get_named/2, &Interp.put_named/3, &Interp.strict_put_named/3}

  defp ops(:ic) do
    {r, w, s} = {Shape.new_site(), Shape.new_site(), Shape.new_site()}

    {&Interp.get_ic(&1, &2, r), &Interp.put_ic(&1, &2, &3, w),
     &Interp.strict_put_ic(&1, &2, &3, s)}
  end

  # Runs `fun` on the list of objects of `@objects` in a fresh heap, in a process of its own,
  # as `Browser.JS.eval/2` runs a script.
  defp run_in_heap(fun) do
    task =
      Task.async(fn ->
        Interp.init(1_000_000)
        Builtins.install()
        {:ok, program} = Parser.parse(@objects, resolve: 4)
        arr = Interp.run_program(program, true)
        n = trunc(Interp.get(arr, "length"))
        fun.(for i <- 0..(n - 1), do: Interp.get(arr, i * 1.0))
      end)

    Task.await(task, 30_000)
  end

  # The value of `fun`, or the text of the JS error that it throws.
  defp safe(fun) do
    fun.()
  catch
    {:js_error, v} -> {:error, Interp.to_str(Interp.get(v, "message"))}
  end
end
