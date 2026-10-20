defmodule Browser.JS.CompileCoverageTest do
  # Step 5, the coverage test of design 5.4: every rewritten sync function of a corpus
  # compiles, and the nodes that stay on the tree are only the kinds that the design keeps
  # there (design 2.2 and 2.5). A node on that list is a kind that the heap keeps, a kind
  # that needs a name hint, or a rare kind. A new kind in the result is a hot path that the
  # compiler sends to the tree walker by mistake, which costs time but gives no wrong
  # value. The differential oracle (js_compile_test.exs) tests the values.
  #
  # The test does not run the programs. It finds each function node of the parsed program
  # and compiles its body with the process key `:jsc_trace`, which makes the compiler list
  # the nodes that it gives to the tree walker.
  #
  # Two parts of design 5.4 are not here. The corpus is the snippets below and the bench
  # programs; the four Speedometer bundles are left out, because they are not in the
  # repository. And the test checks that the kinds on the tree are a subset of the allowed
  # list, not that they are the full list: a kind that compiles now is not a fault.
  use ExUnit.Case, async: true

  alias Browser.JS.{Compile, Parser, Resolve}
  alias Browser.JS.Resolve.Info

  # The kinds that stay on the tree: the functions and classes that the heap keeps, the
  # reads and writes of a name that the resolver did not put in a slot, the special forms
  # of `typeof` and `delete`, `super`, private names, `import`, the template strings that
  # are kept for each place, the regular expressions, and the shapes of the old path.
  @allowed_ev MapSet.new([
                :fn,
                :class,
                :gen,
                :async,
                :regex,
                :tagged_strings,
                :val,
                :id,
                :aslot,
                :super_member,
                :new_target,
                :this,
                :import_call,
                :import_meta,
                :import_phase,
                :tdz_names,
                {:unary, "typeof"},
                {:unary, "delete"},
                {:unary, "sdelete"},
                {:assign, :name},
                {:sassign, :name},
                {:assign, :nameable},
                {:sassign, :nameable},
                {:update, :name},
                {:supdate, :name}
              ])

  # Statements on the tree: the declarations that make a class or bind a resource, a
  # `return` of the old path, and a `for` with a head that has no known shape.
  @allowed_fstmt MapSet.new([:classdecl, :using, :return])

  # Tail sites on the tree: a call whose callee `call_target/2` reads by name, through
  # `super` or through an optional chain.
  @allowed_tail MapSet.new([{:call, :id}, {:call, :super}, {:call, :chain}])

  # The shells that stay on the tree (design r16 8.3): a statement with a block frame, a
  # call whose callee the tree reads by name, through `super` or through an optional chain,
  # a private name, a literal with a spread or a method, a logical assignment, and the rare
  # targets of an assignment. The kinds of the second list compile in a later part of
  # round 16.
  @allowed_shell MapSet.new(
                   [
                     {:switch, :framed},
                     {:block, :framed},
                     {:for, :framed},
                     {:forin, :framed},
                     {:forof, :framed},
                     {:try, :framed},
                     {:call, :id},
                     {:call, :chain},
                     {:call, :super},
                     {:call, :super_member},
                     {:member, :priv},
                     {:binary, :priv},
                     :object,
                     :array
                   ] ++
                     for(
                       kind <- [:assign, :sassign, :update, :supdate],
                       t <- [:logical, :priv, :cslot, :fname, :mslot, :super_member],
                       do: {kind, t}
                     ) ++
                     [
                       :try,
                       :forin,
                       :forof,
                       :dowhile,
                       :var,
                       :destructure,
                       {:unary, "delete"},
                       {:unary, "sdelete"}
                     ]
                 )

  # One snippet for each compiled kind and for each kind with compiled children.
  @snippets [
    "function f(a, b) { var x = a + b * 2 - 1, y; let z = x < 3 ? x : -x; return z }",
    "function f(o) { o.a = o.b + o['c']; o.d += 1; o['e'] -= 2; o.f++; --o[1]; return o.a }",
    "function f(n) { var s = 0; for (var i = 0; i < n; i++) { if (i % 2) continue; s += i } return s }",
    "function f(n) { var s = 0; while (n > 0) { n--; if (n == 3) break } return s }",
    "function f(n) { do { n-- } while (n > 0); return n }",
    "function f(x) { switch (x) { case 1: return 'a'; case 2: { break } default: x = 3 } return x }",
    "function f(x) { try { g(x) } catch (e) { return e } finally { x = 1 } return x }",
    "function f(o) { for (var k in o) { o[k] = 1 } for (const v of [1, 2]) { o.v = v } return o }",
    "function f(a) { return [a, ...a, , 1].length + g(...a) + new G(...a) + [1, 2].length }",
    "function f(o) { return { a: 1, b: o, ...o, [o.k]: 2, get c() { return 1 }, m() {} } }",
    "function f(o) { return o?.a?.b ?? o?.c?.() ?? typeof o + typeof q + !o + ~o + +o + void 0 }",
    "function f(a, b) { return `x${a}y${b}` + (a, b) + (a && b) + (a || b) }",
    "function f(o) { var {a, b: [c = 1]} = o; [a, c] = [c, a]; return a + c }",
    "function f(o) { o.a ||= 1; o.b &&= 2; o.c ??= 3; return o }",
    "function f(o) { delete o.a; delete o[o.k]; return 'a' in o && o instanceof Object }",
    "function f(x) { l: for (;;) { for (;;) { if (x) break l; continue l } } return x }",
    "function f(x) { if (x) throw new Error('x'); return f(x - 1) }",
    "function f(x) { var g = function () { return x }; var h = () => x; return g() + h() }",
    "function f(x) { class C { m() { return x } } return new C().m() }",
    "function f(x) { return /a/.test(x) }",
    "function f(x) { 'use strict'; x.a = 1; x.b += 1; x.c++; return x }",
    "function f(x) { return x ? g(x) : (x, h(x)) }",
    "function f(x) { return x && g(x) }",
    "function f(x) { return x || (x = 1, g(x)) }",
    "function f(x) { return x ?? (g(x), x.h(x)) }",
    "function f() { return arguments.length }",
    "function f() { return this.a }",
    "function f() { return new.target }",
    # (r16) the statement kinds that compiled in round 16, and their framed twins
    "function f(x) { switch (x) { case 'a': let y = 1; return y; case g(x): function h() {} return h } }",
    "function f(x) { switch (x) { case 1: let y = x; return () => y; default: return 0 } }"
  ]

  # The programs of bench/js_runtime.exs. The script binds its program lists to variables,
  # so the test evaluates those assignments in their order.
  @bench_names [:big_body, :programs, :extra_programs, :programs_2e, :programs_3]

  defp bench do
    {:ok, {:__block__, _, exprs}} =
      "bench/js_runtime.exs" |> File.read!() |> Code.string_to_quoted()

    binding =
      Enum.reduce(exprs, [], fn
        {:=, _, [{name, _, ctx}, _]} = e, b when is_atom(ctx) ->
          if name in @bench_names, do: elem(Code.eval_quoted(e, b), 1), else: b

        _, b ->
          b
      end)

    for name <- tl(@bench_names),
        {_, _, _, _, body} <- Keyword.fetch!(binding, name),
        do: "(function(){ function f(){ #{body} } return f() })()"
  end

  # The function nodes of `node` whose `Info` says that the resolver rewrote them.
  defp functions(node, acc) do
    acc =
      case node do
        {:fn, _, _, body, mode, src} ->
          case Resolve.unpack(src) do
            {_, %Info{rewritten: true} = info} -> [%{info: info, mode: mode, body: body} | acc]
            _ -> acc
          end

        _ ->
          acc
      end

    cond do
      is_tuple(node) -> node |> Tuple.to_list() |> functions(acc)
      is_list(node) -> Enum.reduce(node, acc, &functions/2)
      true -> acc
    end
  end

  # The key of a node on the tree: its kind, with the detail that the lists above need.
  defp key(:ev, {:unary, op, _}), do: {:unary, op}

  # A shell: a statement with a block frame is `{kind, :framed}`. A call names the kind of
  # its callee, and a node with a private name says so.
  defp key(:shell, node) do
    case node do
      {k, _, _, _, _, sc} when k in [:forin, :forof, :try, :for] ->
        scoped(k, sc)

      {:switch, _, _, sc} ->
        scoped(:switch, sc)

      {:block, _, sc} ->
        scoped(:block, sc)

      {:call, callee, _, _} ->
        {:call, elem(callee, 0)}

      {:member, _, {:priv, _}, _} ->
        {:member, :priv}

      {:binary, "in", {:priv_ref, _}, _} ->
        {:binary, :priv}

      {:unary, op, _} ->
        {:unary, op}

      {kind, op, _, _} when kind in [:assign, :sassign] and op in ["&&=", "||=", "??="] ->
        {kind, :logical}

      {kind, _, target, _} when kind in [:assign, :sassign] ->
        {kind, target_key(target)}

      {kind, _, _, target} when kind in [:update, :supdate] ->
        {kind, target_key(target)}

      _ ->
        elem(node, 0)
    end
  end

  defp key(:ev, {kind, _, target, _value}) when kind in [:assign, :sassign] do
    if elem(target, 0) in [:id, :gref, :mref], do: {kind, :name}, else: {kind, :nameable}
  end

  defp key(:ev, {kind, _, _, _}) when kind in [:update, :supdate], do: {kind, :name}
  defp key(:tail, {:call, callee, _, _}), do: {:call, elem(callee, 0)}
  defp key(_, node), do: elem(node, 0)

  defp scoped(k, %{frame: true}), do: {k, :framed}
  defp scoped(k, _sc), do: k

  defp target_key({:member, _, {:priv, _}, _}), do: :priv
  defp target_key(target), do: elem(target, 0)

  # The nodes that stay on the tree when each rewritten sync function of `src` compiles,
  # as `{how, key}`, and the number of bodies that compiled.
  defp tree_nodes(src) do
    {:ok, program} = Parser.parse(src, resolve: 4)

    Process.put(:js_compile, true)
    Process.put(:jsc_trace, [])

    compiled =
      for c <- functions(program, []), Compile.code(c) != nil, reduce: 0, do: (n -> n + 1)

    traced = Process.delete(:jsc_trace)
    Process.delete(:js_compile)
    for {:jsc, _} = k <- Process.get_keys(), do: Process.delete(k)

    nodes = for {how, node} <- traced, do: {how, key(how, node)}
    {nodes, compiled}
  end

  defp allowed?({:shell, k}), do: MapSet.member?(@allowed_shell, k)
  defp allowed?({:ev, k}), do: MapSet.member?(@allowed_ev, k)
  defp allowed?({:fstmt, k}), do: MapSet.member?(@allowed_fstmt, k)
  defp allowed?({:tail, k}), do: MapSet.member?(@allowed_tail, k)

  test "every rewritten sync function compiles, and only the listed kinds stay on the tree" do
    results = for src <- @snippets ++ bench(), do: {src, tree_nodes(src)}

    assert Enum.sum(for {_, {_, n}} <- results, do: n) >= length(@snippets) + length(bench())

    bad =
      for {src, {nodes, _}} <- results,
          node <- nodes,
          not allowed?(node),
          uniq: true,
          do: {node, String.slice(src, 0, 80)}

    assert bad == []
  end

  test "the bench programs keep no hot kind on the tree" do
    # The nine programs, the async programs and the step 3 programs use only kinds that
    # compile: the functions that they make and the arguments object (`{:aslot}`, which
    # the first read builds) are the only nodes on the tree.
    nodes =
      for src <- bench(),
          {how, _} = n <- elem(tree_nodes(src), 0),
          how != :shell,
          uniq: true,
          do: n

    assert Enum.sort(nodes) --
             [{:ev, :aslot}, {:ev, :class}, {:ev, :fn}, {:ev, :gen}, {:ev, :async}] == []
  end
end
