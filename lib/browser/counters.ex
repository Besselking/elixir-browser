defmodule Browser.Counters do
  @moduledoc """
  CSS counters (`counter-reset`, `counter-increment`, `counter-set`, and `counter()` and
  `counters()` in `content`).

  `Browser.Style` cannot know the value of a counter when it styles one element: the value
  depends on the elements that come before it. So it writes each use in a `content` value as a
  marker in the text (see `marker/3` and `marker/4`), and `resolve/1` goes over the styled tree
  in document order, keeps the counters, and puts the text of each marker in its place.

  A counter belongs to the element that resets it, to the descendants of that element and to
  its following siblings and their descendants. A reset on a sibling of the element that made
  the counter replaces it; a reset below that makes a new counter that hides it (`counters()`
  lists them all).
  """

  @open ""
  @close ""

  @doc "The text in `content` that stands for `counter(name, style)`."
  def marker(name, style), do: @open <> "c:" <> name <> ":" <> style <> @close

  @doc "The text in `content` that stands for `counters(name, separator, style)`."
  def marker(name, separator, style),
    do: @open <> "s:" <> name <> ":" <> style <> ":" <> separator <> @close

  @doc "Resolves the counters of a styled tree (a list of nodes)."
  def resolve(nodes) do
    {nodes, _state} = walk(nodes, make_ref(), %{})
    nodes
  end

  # state: name -> [{level, value}, ...], the innermost counter first; `level` tells which list of
  # siblings made the counter
  defp walk(nodes, level, state), do: Enum.map_reduce(nodes, state, &node(&1, level, &2))

  defp node({:text, text} = t, _level, state) do
    if String.contains?(text, @open),
      do: {{:text, substitute(text, state)}, state},
      else: {t, state}
  end

  defp node({:element, tag, attrs, kids}, level, state) do
    state = props(computed(attrs), level, state)
    inner = make_ref()
    {kids, state} = walk(kids, inner, state)
    {{:element, tag, attrs, kids}, leave(state, inner)}
  end

  defp node(other, _level, state), do: {other, state}

  defp computed(attrs) do
    case List.keyfind(attrs, "@computed", 0) do
      {_, %{} = c} -> c
      _ -> %{}
    end
  end

  # what leaving the children of an element does: the counters that its children made are gone
  defp leave(state, level) do
    state
    |> Enum.map(fn {name, list} -> {name, Enum.reject(list, fn {l, _} -> l == level end)} end)
    |> Enum.reject(fn {_, list} -> list == [] end)
    |> Map.new()
  end

  defp props(c, level, state) do
    state
    |> reset(pairs(c["counter-reset"], 0), level)
    |> increment(pairs(c["counter-increment"], 1), level)
    |> set(pairs(c["counter-set"], 0), level)
  end

  # `a 2 b` -> [{"a", 2}, {"b", default}]
  defp pairs(v, default) when is_binary(v) do
    v
    |> String.split(~r/\s+/, trim: true)
    |> collect(default, [])
  end

  defp pairs(_v, _default), do: []

  defp collect([], _default, acc), do: Enum.reverse(acc)

  defp collect([name, n | rest], default, acc) when name != "none" do
    case Integer.parse(n) do
      {i, ""} -> collect(rest, default, [{name, i} | acc])
      _ -> collect([n | rest], default, [{name, default} | acc])
    end
  end

  defp collect(["none" | rest], default, acc), do: collect(rest, default, acc)
  defp collect([name | rest], default, acc), do: collect(rest, default, [{name, default} | acc])

  defp reset(state, pairs, level) do
    Enum.reduce(pairs, state, fn {name, n}, st ->
      case st do
        # (a counter that a sibling made is replaced)
        %{^name => [{^level, _} | rest]} -> Map.put(st, name, [{level, n} | rest])
        _ -> Map.update(st, name, [{level, n}], &[{level, n} | &1])
      end
    end)
  end

  defp increment(state, pairs, level) do
    Enum.reduce(pairs, state, fn {name, n}, st ->
      case st do
        %{^name => [{l, v} | rest]} -> Map.put(st, name, [{l, v + n} | rest])
        _ -> Map.put(st, name, [{level, n}])
      end
    end)
  end

  defp set(state, pairs, level) do
    Enum.reduce(pairs, state, fn {name, n}, st ->
      case st do
        %{^name => [{l, _} | rest]} -> Map.put(st, name, [{l, n} | rest])
        _ -> Map.put(st, name, [{level, n}])
      end
    end)
  end

  defp substitute(text, state) do
    Regex.replace(~r/\x{E000}([^\x{E001}]*)\x{E001}/u, text, fn _, body -> value(body, state) end)
  end

  defp value("c:" <> rest, state) do
    [name, style] = String.split(rest, ":", parts: 2)

    case state do
      %{^name => [{_, v} | _]} -> format(v, style)
      _ -> format(0, style)
    end
  end

  defp value("s:" <> rest, state) do
    [name, style, sep] = String.split(rest, ":", parts: 3)

    case state do
      %{^name => list} ->
        list |> Enum.reverse() |> Enum.map_join(sep, fn {_, v} -> format(v, style) end)

      _ ->
        format(0, style)
    end
  end

  defp value(_, _state), do: ""

  @doc false
  def format(n, "decimal-leading-zero") when n >= 0 and n < 10, do: "0" <> Integer.to_string(n)
  def format(n, style) when style in ["lower-alpha", "lower-latin"] and n > 0, do: alpha(n, ?a)
  def format(n, style) when style in ["upper-alpha", "upper-latin"] and n > 0, do: alpha(n, ?A)
  def format(n, "lower-roman") when n > 0 and n < 4000, do: n |> roman() |> String.downcase()
  def format(n, "upper-roman") when n > 0 and n < 4000, do: roman(n)
  def format(_n, "none"), do: ""
  def format(_n, "disc"), do: "•"
  def format(_n, "circle"), do: "◦"
  def format(_n, "square"), do: "▪"
  def format(n, _style), do: Integer.to_string(n)

  defp alpha(n, base), do: alpha(n - 1, base, [])
  defp alpha(n, base, acc) when n < 26, do: List.to_string([base + n | acc])
  defp alpha(n, base, acc), do: alpha(div(n, 26) - 1, base, [base + rem(n, 26) | acc])

  @roman [
    {1000, "M"},
    {900, "CM"},
    {500, "D"},
    {400, "CD"},
    {100, "C"},
    {90, "XC"},
    {50, "L"},
    {40, "XL"},
    {10, "X"},
    {9, "IX"},
    {5, "V"},
    {4, "IV"},
    {1, "I"}
  ]

  defp roman(0), do: ""

  defp roman(n) do
    {v, s} = Enum.find(@roman, fn {v, _} -> v <= n end)
    s <> roman(n - v)
  end
end
