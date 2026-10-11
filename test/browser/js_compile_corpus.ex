# The data-model corpus is part of the programs of the oracles (`programs/1`).
Code.require_file("js_datamodel_corpus.ex", __DIR__)

defmodule Browser.JS.CompileTest.Corpus do
  # The corpus of the differential oracle comes from the tables of other test files and from
  # bench/js_runtime.exs. This module reads those tables when the test module compiles, so
  # that a row added there is also a row of the oracle. It is a module of its own because a
  # module body can call only functions that are already compiled.
  @moduledoc false

  @doc """
  Gives the module attributes of the test file `path`, as a map from name to value. Each
  attribute is evaluated in the order of the file. A reference to an earlier attribute
  takes that attribute's value. An attribute that cannot be evaluated outside its module
  is not in the map.
  """
  def attrs(path) do
    {:ok, ast} = path |> File.read!() |> Code.string_to_quoted()

    {_, found} =
      Macro.prewalk(ast, %{}, fn
        {:@, _, [{name, _, [value]}]} = node, acc when is_atom(name) ->
          {node, eval_attr(name, value, acc)}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp eval_attr(name, value, acc) do
    value =
      Macro.prewalk(value, fn
        {:@, _, [{ref, _, ctx}]} = node when is_atom(ref) and is_atom(ctx) ->
          if Map.has_key?(acc, ref), do: Macro.escape(Map.fetch!(acc, ref)), else: node

        node ->
          node
      end)

    # The diagnostics of an attribute that cannot be evaluated here are not of interest,
    # so they are kept from the output of the test run.
    {acc, _diagnostics} =
      Code.with_diagnostics(fn ->
        try do
          {v, _} = Code.eval_quoted(value)
          Map.put(acc, name, v)
        rescue
          _ -> acc
        end
      end)

    acc
  end

  @doc """
  Gives the sources of the rows of the attributes `specs` of the test file `path`. Each
  spec is `{attribute, shape}`, and the shape tells where the source is in a row:

    * `:src` - the second element of the row;
    * `:first` - the row itself when it is a string, else its first element;
    * `:r` - the third element of a step 2e row, in the `r` wrapper when its kind is `:r`;
    * `:snip` - the second element, in the `r` wrapper;
    * `:body` - the second element, which is a function body;
    * `:wrap` - the row as `:first`, which is a function body.

  The bodies go into the wrapper of bench/js_runtime.exs, with small loop counts.
  """
  def table(path, specs) do
    attrs = attrs(path)

    for {name, shape} <- specs,
        rows = Map.get(attrs, name) || raise("no table @#{name} in #{path}"),
        {row, i} <- Enum.with_index(rows) do
      {"#{Path.basename(path, ".exs")} @#{name} #{label(row, i)}", source(row, shape)}
    end
  end

  defp label(row, _i) when is_tuple(row) and not is_binary(elem(row, 0)),
    do: "#{inspect(elem(row, 0))}"

  defp label(row, _i) when is_tuple(row) and is_binary(elem(row, 0)) and tuple_size(row) > 2,
    do: elem(row, 0)

  defp label(_row, i), do: "##{i}"

  defp source(row, :src), do: elem(row, 1)
  defp source(row, :first) when is_binary(row), do: row
  defp source(row, :first), do: elem(row, 0)
  defp source({_, :r, src, _}, :r), do: r_wrap(src)
  defp source({_, _, src, _}, :r), do: src
  defp source(row, :snip), do: r_wrap(elem(row, 1))
  defp source(row, :body), do: bench_wrap(elem(row, 1))
  defp source(row, :wrap), do: bench_wrap(source(row, :first))

  defp r_wrap(src), do: "var r=[]; " <> src <> "; r"

  @doc """
  Puts a function body into the wrapper of bench/js_runtime.exs. The loop counts become
  smaller, so that the oracle stays fast. A count changes no kind of node, and the oracle
  compares two runs of the same source, so the values of the bench do not apply.
  """
  def bench_wrap(body) do
    body =
      body
      |> String.replace("fib(25)", "fib(12)")
      |> String.replace("mk(6)", "mk(3)")
      |> then(&Regex.replace(~r/\b\d{4,}\b/, &1, fn n -> "#{div(String.to_integer(n), 100)}" end))

    "(function(){ function f(){ #{body} } return f() })()"
  end

  # The files that the tables come from, by their names in the test directory.
  @bench_rel "../../bench/js_runtime.exs"
  @table_files ~w(js_completion_test.exs js_awaits_test.exs js_frames_test.exs
                  js_stack_test.exs js_resolve_test.exs)

  @doc "Gives the files that `tables/1` reads, for `@external_resource`."
  def sources(dir),
    do: [Path.expand(@bench_rel, dir) | Enum.map(@table_files, &Path.join(dir, &1))]

  @doc """
  Gives the snippets of steps 2 to 4, read from their test files in `dir`, and the programs
  of bench/js_runtime.exs, as `{name, source}`. The shapes are those of `table/2`.
  """
  def tables(dir) do
    bench(Path.expand(@bench_rel, dir)) ++
      table(Path.join(dir, "js_completion_test.exs"),
        rows: :src,
        b1: :src,
        d2: :src,
        d1: :src,
        nested_global: :first,
        rows_u1: :src,
        rows_u6: :src,
        rows_u7: :src,
        bench_3: :body
      ) ++
      table(Path.join(dir, "js_awaits_test.exs"), snippets: :snip, bench: :body) ++
      table(Path.join(dir, "js_frames_test.exs"),
        rows: :src,
        rows_2c: :src,
        log_rows_2c: :src,
        rows_2d: :src,
        diffs_2d: :src,
        rows_2e: :r,
        diffs_2e: :snip
      ) ++
      table(Path.join(dir, "js_stack_test.exs"),
        file_rows_2f: :src,
        uncaught_rows_2f: :src,
        rows_2f: :src
      ) ++
      table(Path.join(dir, "js_resolve_test.exs"), bench_bodies: :wrap)
  end

  @doc """
  Gives every program of the compile oracle, as `{name, source, options}`, in the order of
  `@corpus` of js_compile_test.exs in `dir`. The new snippets come from the attributes of
  that file and get the step limits that it gives them. Another oracle (the fast-path
  oracle of js_fast_test.exs) runs the same programs with this function.
  """
  def programs(dir) do
    a = attrs(Path.join(dir, "js_compile_test.exs"))

    judges =
      for {src, i} <- Enum.with_index(Map.fetch!(a, :judges)),
          do: {"judge #{i}", bench_wrap(src), [max_steps: 200_000]}

    hot_kinds =
      for {src, i} <- Enum.with_index(Map.fetch!(a, :hot_kinds)),
          do: {"hot-kinds #{i}", src, [max_steps: 50_000]}

    snippets = Enum.flat_map([:edges, :kinds, :classes], &Map.fetch!(a, &1))
    small = judges ++ hot_kinds ++ Enum.map(snippets, &row/1)

    Enum.uniq_by(
      small ++ Browser.JS.DatamodelCorpus.rows() ++ for({n, s} <- tables(dir), do: {n, s, []}),
      &elem(&1, 1)
    )
  end

  @doc "Gives a row of the new snippets as `{name, source, options}`."
  def row({name, src}), do: {name, src, []}
  def row({_, _, opts} = row) when is_list(opts), do: row

  @doc """
  Gives the programs of bench/js_runtime.exs. The script binds its program lists to
  variables, so this function evaluates those assignments in their order.
  """
  @bench_names [:big_body, :programs, :extra_programs, :programs_2e, :programs_3]

  def bench(path) do
    {:ok, {:__block__, _, exprs}} = path |> File.read!() |> Code.string_to_quoted()

    binding =
      Enum.reduce(exprs, [], fn
        {:=, _, [{name, _, ctx}, _]} = expr, binding when name in @bench_names and is_atom(ctx) ->
          {_, binding} = Code.eval_quoted(expr, binding)
          binding

        _, binding ->
          binding
      end)

    lists = for name <- tl(@bench_names), do: Keyword.get(binding, name) || raise("no #{name}")

    for list <- lists, {id, _, _, _, body} <- list, do: {"bench #{id}", bench_wrap(body)}
  end
end
