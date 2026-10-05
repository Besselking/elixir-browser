defmodule Browser.JS.Json do
  @moduledoc """
  `JSON.parse` (with revivers) and `JSON.stringify` (with replacer functions and arrays, gaps,
  `toJSON`, wrapper objects, BigInt and proxy support), following the specification's
  operations step by step.
  """

  import Browser.JS.Interp, except: [get: 2, put: 3]
  alias Browser.JS.{Interp, Num, Props, Proxy}

  defp get(o, k), do: Interp.get(o, k)
  defp arg(args, i), do: Enum.at(args, i, :undefined)
  defp object?({:obj, _}), do: true
  defp object?(_), do: false

  def install(scope) do
    json = new_object()
    declare(scope, "JSON", json)
    put_tag(json, "JSON")

    for {name, arity, fun} <- [
          {"parse", 2, fn _, args -> parse(to_str(arg(args, 0)), arg(args, 1)) end},
          {"stringify", 3, fn _, args -> stringify(arg(args, 0), arg(args, 1), arg(args, 2)) end}
        ] do
      f = native(name, fun)
      set_arity(f, arity)
      put_hidden(json, name, f)
    end

    :ok
  end

  defp to_length(v) do
    case to_num(v) do
      n when is_number(n) -> n |> trunc() |> max(0) |> min(9_007_199_254_740_991)
      :infinity -> 9_007_199_254_740_991
      _ -> 0
    end
  end

  # ── parse ──────────────────────────────────────────────────

  def parse(text, reviver) do
    {value, rest} = value(skip_ws(text))

    unless skip_ws(rest) == "", do: syntax_error(rest)

    if function?(reviver) do
      root = new_object()
      define_data(root, "", value)
      internalize(root, "", reviver)
    else
      value
    end
  end

  defp syntax_error(""), do: throw_error("SyntaxError", "Unexpected end of JSON input")

  defp syntax_error(rest) do
    <<c::utf8, _::binary>> = rest
    throw_error("SyntaxError", "Unexpected token #{<<c::utf8>>} in JSON")
  end

  defp skip_ws(<<c, rest::binary>>) when c in [?\s, ?\t, ?\n, ?\r], do: skip_ws(rest)
  defp skip_ws(s), do: s

  defp value("null" <> r), do: {:null, r}
  defp value("true" <> r), do: {true, r}
  defp value("false" <> r), do: {false, r}
  defp value("\"" <> r), do: string(r, [])

  defp value("[" <> r) do
    r = skip_ws(r)

    case r do
      "]" <> r -> {new_array([]), r}
      _ -> array_items(r, [])
    end
  end

  defp value("{" <> r) do
    r = skip_ws(r)
    obj = new_object()

    case r do
      "}" <> r -> {obj, r}
      _ -> object_members(r, obj)
    end
  end

  defp value(<<c, _::binary>> = s) when c == ?- or c in ?0..?9, do: number(s)
  defp value(s), do: syntax_error(s)

  defp array_items(r, acc) do
    {v, r} = value(skip_ws(r))

    case skip_ws(r) do
      "," <> r -> array_items(r, [v | acc])
      "]" <> r -> {new_array(Enum.reverse([v | acc])), r}
      other -> syntax_error(other)
    end
  end

  defp object_members(r, obj) do
    case skip_ws(r) do
      "\"" <> r ->
        {key, r} = string(r, [])

        case skip_ws(r) do
          ":" <> r ->
            {v, r} = value(skip_ws(r))
            define_data(obj, key, v)

            case skip_ws(r) do
              "," <> r -> object_members(r, obj)
              "}" <> r -> {obj, r}
              other -> syntax_error(other)
            end

          other ->
            syntax_error(other)
        end

      other ->
        syntax_error(other)
    end
  end

  defp string("\"" <> r, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), r}

  defp string("\\" <> r, acc) do
    case r do
      "\"" <> r -> string(r, ["\"" | acc])
      "\\" <> r -> string(r, ["\\" | acc])
      "/" <> r -> string(r, ["/" | acc])
      "b" <> r -> string(r, ["\b" | acc])
      "f" <> r -> string(r, ["\f" | acc])
      "n" <> r -> string(r, ["\n" | acc])
      "r" <> r -> string(r, ["\r" | acc])
      "t" <> r -> string(r, ["\t" | acc])
      "u" <> r -> unicode_escape(r, acc)
      other -> syntax_error(other)
    end
  end

  defp string(<<c, _::binary>> = s, _) when c < 0x20, do: syntax_error(s)
  defp string(<<c::utf8, r::binary>>, acc), do: string(r, [<<c::utf8>> | acc])
  defp string(<<_, r::binary>>, acc), do: string(r, ["�" | acc])
  defp string("", _), do: syntax_error("")

  defp unicode_escape(r, acc) do
    {hi, r} = hex4(r)

    cond do
      hi in 0xD800..0xDBFF ->
        case r do
          "\\u" <> r2 ->
            {lo, r3} = hex4(r2)

            if lo in 0xDC00..0xDFFF do
              cp = 0x10000 + (hi - 0xD800) * 0x400 + (lo - 0xDC00)
              string(r3, [<<cp::utf8>> | acc])
            else
              string("\\u" <> r2, ["�" | acc])
            end

          _ ->
            string(r, ["�" | acc])
        end

      hi in 0xDC00..0xDFFF ->
        string(r, ["�" | acc])

      true ->
        string(r, [<<hi::utf8>> | acc])
    end
  end

  defp hex4(<<a, b, c, d, r::binary>> = s) do
    case Integer.parse(<<a, b, c, d>>, 16) do
      {n, ""} when a != ?+ and a != ?- -> {n, r}
      _ -> syntax_error(s)
    end
  end

  defp hex4(s), do: syntax_error(s)

  defp number(s) do
    case Regex.run(~r/\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/, s) do
      [m] ->
        rest = binary_part(s, byte_size(m), byte_size(s) - byte_size(m))
        {Num.parse(m), rest}

      nil ->
        syntax_error(s)
    end
  end

  defp internalize(holder, name, reviver) do
    val = get(holder, name)

    if object?(val) do
      keys =
        if Proxy.is_array(val) do
          len = to_length(get(val, "length"))
          for i <- 0..(len - 1)//1, do: Integer.to_string(i)
        else
          Props.enumerable_own_keys(val) |> Enum.filter(&is_binary/1)
        end

      for k <- keys do
        new = internalize(val, k, reviver)

        if new == :undefined do
          Interp.delete(val, k)
        else
          Props.try_define(
            val,
            k,
            new_object([
              {"value", new},
              {"writable", true},
              {"enumerable", true},
              {"configurable", true}
            ])
          )
        end
      end
    end

    Interp.call(reviver, holder, [name, val])
  end

  # ── stringify ──────────────────────────────────────────────

  def stringify(value, replacer, space) do
    {fun, list} = replacer_parts(replacer)
    gap = gap(space)
    state = %{fun: fun, list: list, gap: gap}
    wrapper = new_object()
    define_data(wrapper, "", value)

    case serialize("", wrapper, state, [], "") do
      :undefined -> :undefined
      s -> s
    end
  end

  defp replacer_parts({:obj, _} = r) do
    cond do
      function?(r) ->
        {r, nil}

      Proxy.is_array(r) ->
        len = to_length(get(r, "length"))

        list =
          Enum.reduce(0..(len - 1)//1, [], fn i, acc ->
            v = get(r, Integer.to_string(i))

            item =
              cond do
                is_binary(v) -> v
                is_number(v) or v in [:nan, :infinity, :neg_infinity] -> to_str(v)
                object?(v) and wrapper_kind(v) in [:string, :number] -> to_str(v)
                true -> nil
              end

            if item == nil or item in acc, do: acc, else: [item | acc]
          end)

        {nil, Enum.reverse(list)}

      true ->
        {nil, nil}
    end
  end

  defp replacer_parts(_), do: {nil, nil}

  defp wrapper_kind({:obj, id}) do
    case deref(id) do
      %{prim: p} when is_binary(p) -> :string
      %{prim: p} when is_boolean(p) -> :boolean
      %{prim: {:bigint, _}} -> :bigint
      %{prim: {:symbol, _, _}} -> nil
      %{prim: _} -> :number
      _ -> nil
    end
  end

  defp gap(space) do
    space =
      case space do
        {:obj, _} ->
          case wrapper_kind(space) do
            :number -> to_num(space)
            :string -> to_str(space)
            _ -> space
          end

        _ ->
          space
      end

    cond do
      is_number(space) -> String.duplicate(" ", space |> trunc() |> max(0) |> min(10))
      space == :infinity -> String.duplicate(" ", 10)
      is_binary(space) -> String.slice(space, 0, 10)
      true -> ""
    end
  end

  defp serialize(key, holder, state, stack, indent) do
    value = get(holder, key)

    value =
      if object?(value) or big?(value) do
        case get(value, "toJSON") do
          f when is_tuple(f) -> if function?(f), do: Interp.call(f, value, [key]), else: value
          _ -> value
        end
      else
        value
      end

    value = if state.fun, do: Interp.call(state.fun, holder, [key, value]), else: value

    value =
      case value do
        {:obj, id} ->
          case wrapper_kind(value) do
            :number -> to_num(value)
            :string -> to_str(value)
            :boolean -> deref(id).prim
            :bigint -> deref(id).prim
            nil -> value
          end

        _ ->
          value
      end

    cond do
      value == :null -> "null"
      value == true -> "true"
      value == false -> "false"
      is_binary(value) -> quote_string(value)
      is_number(value) -> Num.to_string(value)
      value in [:nan, :infinity, :neg_infinity] -> "null"
      big?(value) -> throw_error("TypeError", "Do not know how to serialize a BigInt")
      object?(value) and not function?(value) -> structure(value, state, stack, indent)
      true -> :undefined
    end
  end

  defp structure({:obj, id} = value, state, stack, indent) do
    if id in stack, do: throw_error("TypeError", "Converting circular structure to JSON")

    stack = [id | stack]
    stepback = indent
    indent = indent <> state.gap

    if Proxy.is_array(value) do
      len = to_length(get(value, "length"))

      parts =
        for i <- 0..(len - 1)//1 do
          case serialize(Integer.to_string(i), value, state, stack, indent) do
            :undefined -> "null"
            s -> s
          end
        end

      wrap("[", "]", parts, state.gap, indent, stepback)
    else
      keys = state.list || Props.enumerable_own_keys(value) |> Enum.filter(&is_binary/1)
      colon = if state.gap == "", do: ":", else: ": "

      parts =
        Enum.flat_map(keys, fn k ->
          case serialize(k, value, state, stack, indent) do
            :undefined -> []
            s -> [quote_string(k) <> colon <> s]
          end
        end)

      wrap("{", "}", parts, state.gap, indent, stepback)
    end
  end

  defp wrap(open, close, [], _, _, _), do: open <> close
  defp wrap(open, close, parts, "", _, _), do: open <> Enum.join(parts, ",") <> close

  defp wrap(open, close, parts, _gap, indent, stepback) do
    open <> "\n" <> indent <> Enum.join(parts, ",\n" <> indent) <> "\n" <> stepback <> close
  end

  defp quote_string(s), do: "\"" <> escape(s, []) <> "\""

  defp escape("", acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()
  defp escape("\"" <> r, acc), do: escape(r, ["\\\"" | acc])
  defp escape("\\" <> r, acc), do: escape(r, ["\\\\" | acc])
  defp escape("\b" <> r, acc), do: escape(r, ["\\b" | acc])
  defp escape("\f" <> r, acc), do: escape(r, ["\\f" | acc])
  defp escape("\n" <> r, acc), do: escape(r, ["\\n" | acc])
  defp escape("\r" <> r, acc), do: escape(r, ["\\r" | acc])
  defp escape("\t" <> r, acc), do: escape(r, ["\\t" | acc])

  defp escape(<<c, r::binary>>, acc) when c < 0x20 do
    hex = c |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0")
    escape(r, ["\\u" <> hex | acc])
  end

  defp escape(<<c, r::binary>>, acc) when c < 0x80, do: escape(r, [<<c>> | acc])
  defp escape(<<c::utf8, r::binary>>, acc), do: escape(r, [<<c::utf8>> | acc])
  defp escape(<<_, r::binary>>, acc), do: escape(r, ["�" | acc])
end
