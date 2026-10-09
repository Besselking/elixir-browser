defmodule Browser.JS.ConsoleApi do
  @moduledoc """
  The page's `console` object: the logging methods (`log`, `warn`, `error`, `info`, `debug`,
  `dir`, `trace`, `assert`) with `%s %d %i %f %o %O %c` formats, `group` / `groupEnd` (the lines
  inside a group are indented), `time` / `timeLog` / `timeEnd`, `count` / `countReset`,
  `table` and `clear`.

  Every method adds `{level, text}` lines to the runtime's console buffer (`:js_console` in the
  process dictionary), which `Browser.JS.Runtime` hands to `Browser.Console`.
  """

  import Browser.JS.Interp, except: [get: 2, put: 3]
  alias Browser.JS.{Builtins, Interp}

  defp arg(args, i), do: Enum.at(args, i, :undefined)
  defp def_fn(obj, name, fun), do: put_hidden(obj, name, native(name, fun))

  def install(scope) do
    console = new_object()
    declare(scope, "console", console)

    for {name, level} <- [
          {"log", :log},
          {"info", :log},
          {"debug", :log},
          {"warn", :warn},
          {"error", :error}
        ] do
      def_fn(console, name, fn _, args ->
        emit(level, format(args))
        :undefined
      end)
    end

    for name <- ~w(dir dirxml) do
      def_fn(console, name, fn _, args ->
        emit(:log, Builtins.inspect_js(arg(args, 0), 0, []))
        :undefined
      end)
    end

    def_fn(console, "trace", fn _, args ->
      header = if args == [], do: "Trace", else: "Trace: " <> format(args)
      emit(:log, Interp.stack_string(header))
      :undefined
    end)

    def_fn(console, "assert", fn _, args ->
      if !truthy(arg(args, 0)) do
        rest = args |> Enum.drop(1) |> format()

        emit(
          :error,
          Interp.stack_string("Assertion failed" <> if(rest == "", do: "", else: ": " <> rest))
        )
      end

      :undefined
    end)

    for name <- ~w(group groupCollapsed) do
      def_fn(console, name, fn _, args ->
        if args != [], do: emit(:log, format(args))
        Process.put(:js_console_group, Process.get(:js_console_group, 0) + 1)
        :undefined
      end)
    end

    def_fn(console, "groupEnd", fn _, _ ->
      Process.put(:js_console_group, max(Process.get(:js_console_group, 0) - 1, 0))
      :undefined
    end)

    def_fn(console, "time", fn _, args ->
      label = label(args)
      timers = Process.get(:js_console_timers, %{})

      if Map.has_key?(timers, label) do
        emit(:warn, "Timer '#{label}' already exists")
      else
        Process.put(
          :js_console_timers,
          Map.put(timers, label, System.monotonic_time(:microsecond))
        )
      end

      :undefined
    end)

    def_fn(console, "timeLog", fn _, args ->
      with_timer(args, fn label, ms ->
        extra = args |> Enum.drop(1) |> format()
        emit(:log, "#{label}: #{ms}" <> if(extra == "", do: "", else: " " <> extra))
      end)
    end)

    def_fn(console, "timeEnd", fn _, args ->
      with_timer(args, fn label, ms ->
        Process.put(:js_console_timers, Map.delete(Process.get(:js_console_timers, %{}), label))
        emit(:log, "#{label}: #{ms}")
      end)
    end)

    def_fn(console, "count", fn _, args ->
      label = label(args)
      counts = Process.get(:js_console_counts, %{})
      n = Map.get(counts, label, 0) + 1
      Process.put(:js_console_counts, Map.put(counts, label, n))
      emit(:log, "#{label}: #{n}")
      :undefined
    end)

    def_fn(console, "countReset", fn _, args ->
      label = label(args)
      counts = Process.get(:js_console_counts, %{})

      if Map.has_key?(counts, label),
        do: Process.put(:js_console_counts, Map.put(counts, label, 0)),
        else: emit(:warn, "Count for '#{label}' does not exist")

      :undefined
    end)

    def_fn(console, "table", fn _, args ->
      emit(:log, table(arg(args, 0), arg(args, 1)) || format(args))
      :undefined
    end)

    def_fn(console, "clear", fn _, _ ->
      Process.put(:js_console_group, 0)
      Process.put(:js_console, [{:clear, ""} | Process.get(:js_console, [])])
      :undefined
    end)

    for name <- ~w(profile profileEnd timeStamp) do
      def_fn(console, name, fn _, _ -> :undefined end)
    end
  end

  # one line (or several) in the log, indented by the groups that are open
  defp emit(level, text) do
    indent = String.duplicate("  ", Process.get(:js_console_group, 0))
    text = if indent == "", do: text, else: indent <> String.replace(text, "\n", "\n" <> indent)
    Process.put(:js_console, [{level, text} | Process.get(:js_console, [])])
  end

  defp label(args) do
    case arg(args, 0) do
      :undefined -> "default"
      v -> to_str(v)
    end
  end

  defp with_timer(args, fun) do
    label = label(args)

    case Map.fetch(Process.get(:js_console_timers, %{}), label) do
      {:ok, t0} ->
        fun.(label, duration(System.monotonic_time(:microsecond) - t0))

      :error ->
        emit(:warn, "Timer '#{label}' does not exist")
    end

    :undefined
  end

  # "1.234 ms", "56.78 ms", "1.5 s" as Chrome writes a timer
  defp duration(us) when us < 1_000_000,
    do: "#{:erlang.float_to_binary(us / 1000, decimals: 3)} ms"

  defp duration(us), do: "#{:erlang.float_to_binary(us / 1_000_000, decimals: 3)} s"

  # ── formatting ─────────────────────────────────────────────

  @doc "The text `console.log(...args)` writes: format specifiers of the first argument, then the rest."
  def format([first | rest]) when is_binary(first) do
    if String.contains?(first, "%") do
      {text, rest} = substitute(first, rest, [])
      Enum.join([text | Enum.map(rest, &plain/1)], " ")
    else
      Enum.join([first | Enum.map(rest, &plain/1)], " ")
    end
  end

  def format(args), do: args |> Enum.map(&plain/1) |> Enum.join(" ")

  defp plain(v) when is_binary(v), do: v
  defp plain(v), do: Builtins.inspect_js(v, 0, [])

  defp substitute("%%" <> s, rest, acc), do: substitute(s, rest, ["%" | acc])

  defp substitute(<<"%", c, s::binary>> = all, rest, acc) when c in ~c"sdifoOc" do
    case rest do
      [] ->
        substitute(s, [], [binary_part(all, 0, 2) | acc])

      [v | rest] ->
        substitute(s, rest, [spec(c, v) | acc])
    end
  end

  defp substitute(<<c::utf8, s::binary>>, rest, acc), do: substitute(s, rest, [<<c::utf8>> | acc])
  defp substitute("", rest, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp spec(?s, v) when is_binary(v), do: v

  defp spec(?s, {:obj, _} = v),
    do: if(function?(v), do: Builtins.inspect_js(v, 0, []), else: plain(v))

  defp spec(?s, v), do: to_str(v)
  defp spec(c, v) when c in ~c"di", do: number(v, true)
  defp spec(?f, v), do: number(v, false)
  defp spec(c, v) when c in ~c"oO", do: Builtins.inspect_js(v, 0, [])
  defp spec(?c, _), do: ""

  defp number({:obj, _}, _), do: "NaN"

  defp number(v, int?) do
    n = to_num(v)

    cond do
      int? and is_number(n) -> Integer.to_string(trunc(n))
      true -> to_str(n)
    end
  end

  # ── console.table ──────────────────────────────────────────

  # the text of a table, or nil when `data` is not an object with rows to show
  defp table({:obj, _} = data, columns) do
    if function?(data) do
      nil
    else
      rows =
        if array?(data),
          do:
            data
            |> array_list()
            |> Enum.with_index()
            |> Enum.map(fn {v, i} -> {to_string(i), v} end),
          else: for(k <- own_keys(data), do: {k, Interp.get(data, k)})

      build_table(rows, only_columns(columns))
    end
  end

  defp table(_, _), do: nil

  defp only_columns(cols) do
    if array?(cols), do: Enum.map(array_list(cols), &to_str/1), else: nil
  end

  defp build_table([], _), do: nil

  defp build_table(rows, only) do
    object_row? = fn v -> match?({:obj, _}, v) and not function?(v) end

    cells =
      for {index, v} <- rows do
        if object_row?.(v) do
          keys =
            if array?(v),
              do: Enum.map(0..(length(array_list(v)) - 1)//1, &to_string/1),
              else: own_keys(v)

          {index, for(k <- keys, do: {k, Builtins.inspect_js(Interp.get(v, k), 1, [])}), nil}
        else
          {index, [], Builtins.inspect_js(v, 1, [])}
        end
      end

    keys =
      cells
      |> Enum.flat_map(fn {_, pairs, _} -> Enum.map(pairs, &elem(&1, 0)) end)
      |> Enum.uniq()
      |> then(fn keys -> if only, do: only, else: keys end)

    values? = Enum.any?(cells, fn {_, _, value} -> value != nil end)
    header = ["(index)"] ++ keys ++ if(values?, do: ["Values"], else: [])

    body =
      for {index, pairs, value} <- cells do
        map = Map.new(pairs)

        [index] ++
          Enum.map(keys, &Map.get(map, &1, "")) ++
          if(values?, do: [value || ""], else: [])
      end

    draw([header | body])
  end

  # a grid with the cells centred, in box-drawing characters
  defp draw([header | _] = grid) do
    widths =
      for i <- 0..(length(header) - 1) do
        grid |> Enum.map(&(&1 |> Enum.at(i) |> String.length())) |> Enum.max() |> Kernel.+(2)
      end

    rule = fn l, m, r -> l <> Enum.map_join(widths, m, &String.duplicate("─", &1)) <> r end

    line = fn row ->
      "│" <>
        (row |> Enum.zip(widths) |> Enum.map_join("│", fn {cell, w} -> center(cell, w) end)) <>
        "│"
    end

    [h | body] = grid

    Enum.join(
      [rule.("┌", "┬", "┐"), line.(h), rule.("├", "┼", "┤")] ++
        Enum.map(body, line) ++ [rule.("└", "┴", "┘")],
      "\n"
    )
  end

  defp center(text, width) do
    pad = width - String.length(text)
    left = div(pad, 2)
    String.duplicate(" ", left) <> text <> String.duplicate(" ", pad - left)
  end
end
