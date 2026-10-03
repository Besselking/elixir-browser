defmodule Browser.JS.Builtins do
  @moduledoc """
  The global environment: `console`, `Math`, `JSON`, `Object`, `Array`, `String`, `Number`,
  the error types, timers, and the methods on strings, numbers and arrays.

  Natives are `fn this, args -> value end`. Strings count code points, not UTF-16 units.
  """

  import Browser.JS.Interp, except: [get: 2, put: 3]
  alias Browser.JS.Interp
  alias Browser.JS.Num

  @timer_horizon 60_000.0
  @error_types ~w(Error TypeError ReferenceError RangeError SyntaxError EvalError URIError)

  @doc "Creates the prototypes and the global scope. Call after `Interp.init/1`."
  def install do
    object_proto = {:obj, alloc(%{class: :object, props: %{}, keys: [], proto: nil})}
    put_proto(:object, object_proto)

    function_proto =
      {:obj,
       alloc(%{
         class: :function,
         fun: {:native, "", fn _, _ -> :undefined end},
         props: %{},
         keys: [],
         proto: object_proto
       })}

    put_proto(:function, function_proto)

    for name <- [:array, :string, :number, :boolean], do: put_proto(name, new_object())
    error_proto = new_object()
    put_proto({:error, "Error"}, error_proto)

    for t <- @error_types, t != "Error" do
      put_proto({:error, t}, new_object([], error_proto))
    end

    scope = new_global_scope()
    declare(scope, "undefined", :undefined)
    declare(scope, "NaN", :nan)
    declare(scope, "Infinity", :infinity)

    object_methods(object_proto)
    function_methods(function_proto)
    array_methods(proto(:array))
    string_methods(proto(:string))
    number_methods(proto(:number))
    install_errors(scope, error_proto)
    install_object(scope, object_proto)
    install_array(scope, proto(:array))
    install_primitives(scope)
    install_math(scope)
    install_json(scope)
    install_console(scope)
    install_timers(scope)
    install_misc(scope)
    Browser.JS.RegExp.install(scope)
    Browser.JS.Promise.install(scope)

    scope
  end

  defp def_fn(obj, name, fun), do: put_hidden(obj, name, native(name, fun))
  defp arg(args, i), do: Enum.at(args, i, :undefined)
  defp float(n), do: n * 1.0

  defp constructor(scope, name, proto, fun) do
    f = native(name, fun)
    put_hidden(f, "prototype", proto)
    put_hidden(proto, "constructor", f)
    declare(scope, name, f)
    f
  end

  # ── Object.prototype / Function.prototype ──────────────────

  defp object_methods(p) do
    def_fn(p, "hasOwnProperty", fn this, args ->
      key = to_key(arg(args, 0))
      key in own_keys(this) or (array?(this) and key == "length")
    end)

    def_fn(p, "toString", fn _, _ -> "[object Object]" end)
    def_fn(p, "valueOf", fn this, _ -> this end)
  end

  defp function_methods(p) do
    def_fn(p, "call", fn this, args -> call(this, arg(args, 0), Enum.drop(args, 1)) end)

    def_fn(p, "apply", fn this, args ->
      list = if nullish?(arg(args, 1)), do: [], else: array_list(arg(args, 1))
      call(this, arg(args, 0), list)
    end)

    def_fn(p, "bind", fn this, args ->
      bound_this = arg(args, 0)
      bound_args = Enum.drop(args, 1)
      native("bound", fn _, more -> call(this, bound_this, bound_args ++ more) end)
    end)

    def_fn(p, "toString", fn this, _ ->
      "function #{to_str(Interp.get(this, "name"))}() { [native code] }"
    end)
  end

  # ── errors ─────────────────────────────────────────────────

  defp install_errors(scope, error_proto) do
    for t <- @error_types do
      proto = proto({:error, t})
      put_hidden(proto, "name", t)
      put_hidden(proto, "message", "")

      constructor(scope, t, proto, fn this, args ->
        err = if match?({:obj, _}, this), do: this, else: new_object([], proto)
        msg = arg(args, 0)
        if msg != :undefined, do: put_hidden(err, "message", to_str(msg))
        err
      end)
    end

    def_fn(error_proto, "toString", fn this, _ ->
      name = to_str(Interp.get(this, "name"))
      msg = to_str(Interp.get(this, "message"))
      if msg == "", do: name, else: name <> ": " <> msg
    end)
  end

  # ── Object ─────────────────────────────────────────────────

  defp install_object(scope, object_proto) do
    obj =
      constructor(scope, "Object", object_proto, fn _, args ->
        case arg(args, 0) do
          {:obj, _} = o -> o
          _ -> new_object()
        end
      end)

    def_fn(obj, "keys", fn _, [o | _] -> new_array(own_keys(o)) end)

    def_fn(obj, "hasOwn", fn _, args ->
      o = arg(args, 0)
      key = to_key(arg(args, 1))
      match?({:obj, _}, o) and (key in own_keys(o) or (array?(o) and key == "length"))
    end)

    def_fn(obj, "values", fn _, [o | _] ->
      new_array(Enum.map(own_keys(o), &Interp.get(o, &1)))
    end)

    def_fn(obj, "entries", fn _, [o | _] ->
      new_array(Enum.map(own_keys(o), &new_array([&1, Interp.get(o, &1)])))
    end)

    def_fn(obj, "assign", fn _, [target | sources] ->
      for s <- sources,
          not nullish?(s),
          k <- own_keys(s),
          do: Interp.put(target, k, Interp.get(s, k))

      target
    end)

    def_fn(obj, "fromEntries", fn _, [list | _] ->
      o = new_object()
      for e <- iterate(list), do: Interp.put(o, to_key(Interp.get(e, 0.0)), Interp.get(e, 1.0))
      o
    end)

    def_fn(obj, "create", fn _, [proto | _] -> new_object([], proto) end)
    def_fn(obj, "freeze", fn _, [o | _] -> o end)
    def_fn(obj, "getPrototypeOf", fn _, [{:obj, id} | _] -> deref(id).proto || :null end)
  end

  # ── Array ──────────────────────────────────────────────────

  defp install_array(scope, array_proto) do
    arr =
      constructor(scope, "Array", array_proto, fn _, args ->
        case args do
          [n] when is_number(n) -> new_array(List.duplicate(:undefined, trunc(n)))
          list -> new_array(list)
        end
      end)

    def_fn(arr, "isArray", fn _, args -> array?(arg(args, 0)) end)
    def_fn(arr, "of", fn _, args -> new_array(args) end)

    def_fn(arr, "from", fn _, args ->
      src = arg(args, 0)
      f = arg(args, 1)

      list =
        cond do
          is_binary(src) or array?(src) ->
            iterate(src)

          match?({:obj, _}, src) ->
            for i <- 0..(to_int(Interp.get(src, "length")) - 1)//1, do: Interp.get(src, float(i))

          true ->
            []
        end

      new_array(
        if function?(f),
          do:
            list
            |> Enum.with_index()
            |> Enum.map(fn {v, i} -> call(f, :undefined, [v, float(i)]) end),
          else: list
      )
    end)
  end

  # start / end arguments of slice-like methods
  defp rel(v, len, default) do
    if v == :undefined do
      default
    else
      n = to_int(v)
      if n < 0, do: max(len + n, 0), else: min(n, len)
    end
  end

  defp array_methods(p) do
    def_fn(p, "push", fn this, args ->
      list = array_list(this) ++ args
      set_array_list(this, list)
      float(length(list))
    end)

    def_fn(p, "pop", fn this, _ ->
      case Enum.reverse(array_list(this)) do
        [] ->
          :undefined

        [last | rest] ->
          set_array_list(this, Enum.reverse(rest))
          last
      end
    end)

    def_fn(p, "shift", fn this, _ ->
      case array_list(this) do
        [] ->
          :undefined

        [first | rest] ->
          set_array_list(this, rest)
          first
      end
    end)

    def_fn(p, "unshift", fn this, args ->
      list = args ++ array_list(this)
      set_array_list(this, list)
      float(length(list))
    end)

    def_fn(p, "slice", fn this, args ->
      list = array_list(this)
      len = length(list)
      from = rel(arg(args, 0), len, 0)
      to = rel(arg(args, 1), len, len)
      new_array(Enum.slice(list, from, max(to - from, 0)))
    end)

    def_fn(p, "splice", fn this, args ->
      list = array_list(this)
      len = length(list)
      from = rel(arg(args, 0), len, 0)

      count =
        case args do
          [_] -> len - from
          [] -> 0
          [_, c | _] -> c |> to_int() |> max(0) |> min(len - from)
        end

      {head, rest} = Enum.split(list, from)
      {removed, tail} = Enum.split(rest, count)
      set_array_list(this, head ++ Enum.drop(args, 2) ++ tail)
      new_array(removed)
    end)

    def_fn(p, "concat", fn this, args ->
      new_array(
        array_list(this) ++
          Enum.flat_map(args, fn a -> if array?(a), do: array_list(a), else: [a] end)
      )
    end)

    def_fn(p, "join", fn this, args ->
      join(this, if(arg(args, 0) == :undefined, do: ",", else: to_str(arg(args, 0))))
    end)

    def_fn(p, "toString", fn this, _ -> join(this, ",") end)

    def_fn(p, "reverse", fn this, _ ->
      set_array_list(this, Enum.reverse(array_list(this)))
      this
    end)

    def_fn(p, "indexOf", fn this, args ->
      v = arg(args, 0)
      float(Enum.find_index(array_list(this), &strict_eq(&1, v)) || -1)
    end)

    def_fn(p, "lastIndexOf", fn this, args ->
      v = arg(args, 0)
      list = array_list(this)
      idx = list |> Enum.reverse() |> Enum.find_index(&strict_eq(&1, v))
      float(if idx, do: length(list) - 1 - idx, else: -1)
    end)

    def_fn(p, "includes", fn this, args ->
      v = arg(args, 0)
      Enum.any?(array_list(this), &same_value_zero(&1, v))
    end)

    def_fn(p, "at", fn this, args ->
      list = array_list(this)
      n = to_int(arg(args, 0))
      Enum.at(list, if(n < 0, do: length(list) + n, else: n), :undefined)
    end)

    def_fn(p, "fill", fn this, args ->
      list = array_list(this)
      len = length(list)
      from = rel(arg(args, 1), len, 0)
      to = rel(arg(args, 2), len, len)
      v = arg(args, 0)

      set_array_list(
        this,
        list
        |> Enum.with_index()
        |> Enum.map(fn {x, i} -> if i >= from and i < to, do: v, else: x end)
      )

      this
    end)

    def_fn(p, "flat", fn this, args ->
      depth = if arg(args, 0) == :undefined, do: 1, else: to_int(arg(args, 0))
      new_array(flatten(array_list(this), depth))
    end)

    def_fn(p, "forEach", fn this, [f | _] = args ->
      each_with_index(this, f, args)
      :undefined
    end)

    def_fn(p, "map", fn this, [f | _] = args ->
      new_array(
        for {v, i} <- Enum.with_index(array_list(this)),
            do: call(f, arg(args, 1), [v, float(i), this])
      )
    end)

    def_fn(p, "filter", fn this, [f | _] = args ->
      new_array(
        for {v, i} <- Enum.with_index(array_list(this)),
            truthy(call(f, arg(args, 1), [v, float(i), this])),
            do: v
      )
    end)

    def_fn(p, "find", fn this, [f | _] = args ->
      Enum.find_value(Enum.with_index(array_list(this)), :undefined, fn {v, i} ->
        if truthy(call(f, arg(args, 1), [v, float(i), this])), do: v
      end)
    end)

    def_fn(p, "findIndex", fn this, [f | _] = args ->
      idx =
        Enum.find_index(Enum.with_index(array_list(this)), fn {v, i} ->
          truthy(call(f, arg(args, 1), [v, float(i), this]))
        end)

      float(idx || -1)
    end)

    def_fn(p, "some", fn this, [f | _] = args ->
      Enum.any?(Enum.with_index(array_list(this)), fn {v, i} ->
        truthy(call(f, arg(args, 1), [v, float(i), this]))
      end)
    end)

    def_fn(p, "every", fn this, [f | _] = args ->
      Enum.all?(Enum.with_index(array_list(this)), fn {v, i} ->
        truthy(call(f, arg(args, 1), [v, float(i), this]))
      end)
    end)

    def_fn(p, "reduce", fn this, [f | rest] -> reduce(this, f, rest, false) end)
    def_fn(p, "reduceRight", fn this, [f | rest] -> reduce(this, f, rest, true) end)

    def_fn(p, "sort", fn this, args ->
      f = arg(args, 0)
      {undefs, list} = this |> array_list() |> Enum.split_with(&(&1 == :undefined))

      cmp =
        if function?(f),
          do: fn a, b ->
            case to_num(call(f, :undefined, [a, b])) do
              :nan -> true
              n -> Num.compare(n, 0.0) != :gt
            end
          end,
          else: fn a, b -> to_str(a) <= to_str(b) end

      set_array_list(this, Enum.sort(list, cmp) ++ undefs)
      this
    end)
  end

  defp each_with_index(this, f, args) do
    for {v, i} <- Enum.with_index(array_list(this)),
        do: call(f, arg(args, 1), [v, float(i), this])
  end

  defp reduce(this, f, rest, right?) do
    list = this |> array_list() |> Enum.with_index()
    list = if right?, do: Enum.reverse(list), else: list

    {acc, list} =
      case {rest, list} do
        {[init | _], l} -> {init, l}
        {[], [{v, _} | l]} -> {v, l}
        {[], []} -> throw_error("TypeError", "Reduce of empty array with no initial value")
      end

    Enum.reduce(list, acc, fn {v, i}, acc -> call(f, :undefined, [acc, v, float(i), this]) end)
  end

  defp flatten(list, depth) do
    Enum.flat_map(list, fn v ->
      if array?(v) and depth > 0, do: flatten(array_list(v), depth - 1), else: [v]
    end)
  end

  defp join(arr, sep) do
    arr |> array_list() |> Enum.map_join(sep, fn v -> if nullish?(v), do: "", else: to_str(v) end)
  end

  # ── String / Number / Boolean ──────────────────────────────

  defp install_primitives(scope) do
    str =
      constructor(scope, "String", proto(:string), fn _, args ->
        if args == [], do: "", else: to_str(hd(args))
      end)

    def_fn(str, "fromCharCode", fn _, args ->
      args |> Enum.map(&<<trunc(to_num(&1))::utf8>>) |> Enum.join()
    end)

    num =
      constructor(scope, "Number", proto(:number), fn _, args ->
        if args == [], do: 0.0, else: to_num(hd(args))
      end)

    constructor(scope, "Boolean", proto(:boolean), fn _, args -> truthy(arg(args, 0)) end)

    def_fn(num, "isInteger", fn _, [v | _] -> is_number(v) and v == trunc(v) end)

    def_fn(num, "isSafeInteger", fn _, [v | _] ->
      is_number(v) and v == trunc(v) and abs(v) <= 9_007_199_254_740_991
    end)

    def_fn(num, "isFinite", fn _, [v | _] -> is_number(v) end)
    def_fn(num, "isNaN", fn _, [v | _] -> v == :nan end)

    for {k, v} <- [
          {"MAX_SAFE_INTEGER", 9_007_199_254_740_991.0},
          {"MIN_SAFE_INTEGER", -9_007_199_254_740_991.0},
          {"EPSILON", 2.220446049250313e-16},
          {"MAX_VALUE", 1.7976931348623157e308},
          {"MIN_VALUE", 5.0e-324},
          {"POSITIVE_INFINITY", :infinity},
          {"NEGATIVE_INFINITY", :neg_infinity},
          {"NaN", :nan}
        ],
        do: put_hidden(num, k, v)

    parse_float = native("parseFloat", fn _, args -> Num.parse_prefix(to_str(arg(args, 0))) end)

    parse_int =
      native("parseInt", fn _, args -> parse_int(to_str(arg(args, 0)), arg(args, 1)) end)

    put_hidden(num, "parseFloat", parse_float)
    put_hidden(num, "parseInt", parse_int)
    declare(scope, "parseFloat", parse_float)
    declare(scope, "parseInt", parse_int)
    declare(scope, "isNaN", native("isNaN", fn _, args -> to_num(arg(args, 0)) == :nan end))

    declare(
      scope,
      "isFinite",
      native("isFinite", fn _, args -> is_number(to_num(arg(args, 0))) end)
    )
  end

  defp parse_int(s, radix_arg) do
    s = String.trim(s)

    {sign, s} =
      case s do
        "-" <> r -> {-1, r}
        "+" <> r -> {1, r}
        _ -> {1, s}
      end

    radix = if radix_arg == :undefined, do: 0, else: to_int(radix_arg)

    {radix, s} =
      case {radix, s} do
        {r, "0x" <> rest} when r in [0, 16] -> {16, rest}
        {r, "0X" <> rest} when r in [0, 16] -> {16, rest}
        {0, s} -> {10, s}
        {r, s} -> {r, s}
      end

    if radix < 2 or radix > 36 do
      :nan
    else
      digits = s |> String.upcase() |> String.to_charlist() |> Enum.take_while(&digit?(&1, radix))

      case digits do
        [] -> :nan
        _ -> sign * String.to_integer(List.to_string(digits), radix) * 1.0
      end
    end
  end

  defp digit?(c, radix) do
    v =
      cond do
        c in ?0..?9 -> c - ?0
        c in ?A..?Z -> c - ?A + 10
        true -> 99
      end

    v < radix
  end

  defp number_methods(p) do
    def_fn(p, "toString", fn this, args ->
      case arg(args, 0) do
        :undefined ->
          Num.to_string(this)

        r when is_number(this) and this == trunc(this) ->
          trunc(this) |> Integer.to_string(to_int(r)) |> String.downcase()

        _ ->
          Num.to_string(this)
      end
    end)

    def_fn(p, "toFixed", fn this, args ->
      d = to_int(arg(args, 0))

      if is_number(this) and abs(this) < 1.0e21,
        do: :erlang.float_to_binary(this * 1.0, decimals: d),
        else: Num.to_string(this)
    end)

    def_fn(p, "valueOf", fn this, _ -> this end)
    def_fn(proto(:boolean), "toString", fn this, _ -> to_str(this) end)
  end

  defp string_methods(p) do
    def_fn(p, "toString", fn this, _ -> this end)
    def_fn(p, "valueOf", fn this, _ -> this end)
    def_fn(p, "toUpperCase", fn this, _ -> String.upcase(this) end)
    def_fn(p, "toLowerCase", fn this, _ -> String.downcase(this) end)
    def_fn(p, "trim", fn this, _ -> String.trim(this) end)
    def_fn(p, "trimStart", fn this, _ -> String.trim_leading(this) end)
    def_fn(p, "trimEnd", fn this, _ -> String.trim_trailing(this) end)
    def_fn(p, "charAt", fn this, args -> String.at(this, to_int(arg(args, 0))) || "" end)

    def_fn(p, "at", fn this, args ->
      n = to_int(arg(args, 0))
      String.at(this, n) || :undefined
    end)

    def_fn(p, "charCodeAt", fn this, args ->
      case String.at(this, to_int(arg(args, 0))) do
        nil -> :nan
        <<c::utf8, _::binary>> -> float(c)
      end
    end)

    def_fn(p, "codePointAt", fn this, args ->
      case String.at(this, to_int(arg(args, 0))) do
        nil -> :undefined
        <<c::utf8, _::binary>> -> float(c)
      end
    end)

    def_fn(p, "indexOf", fn this, args ->
      from = max(to_int(arg(args, 1)), 0)
      float(index_of(this, to_str(arg(args, 0)), from))
    end)

    def_fn(p, "lastIndexOf", fn this, args ->
      needle = to_str(arg(args, 0))

      positions =
        for i <- 0..max(String.length(this) - String.length(needle), 0)//1,
            cp_slice(this, i, String.length(needle)) == needle,
            do: i

      float(List.last(positions) || -1)
    end)

    def_fn(p, "includes", fn this, args -> index_of(this, to_str(arg(args, 0)), 0) >= 0 end)

    def_fn(p, "startsWith", fn this, args ->
      String.starts_with?(cp_slice(this, max(to_int(arg(args, 1)), 0), nil), to_str(arg(args, 0)))
    end)

    def_fn(p, "endsWith", fn this, args -> String.ends_with?(this, to_str(arg(args, 0))) end)
    def_fn(p, "concat", fn this, args -> this <> Enum.map_join(args, &to_str/1) end)
    def_fn(p, "repeat", fn this, args -> String.duplicate(this, max(to_int(arg(args, 0)), 0)) end)

    def_fn(p, "slice", fn this, args ->
      len = String.length(this)
      from = rel(arg(args, 0), len, 0)
      to = rel(arg(args, 1), len, len)
      cp_slice(this, from, max(to - from, 0))
    end)

    def_fn(p, "substring", fn this, args ->
      len = String.length(this)

      clamp = fn v, default ->
        if v == :undefined, do: default, else: v |> to_int() |> max(0) |> min(len)
      end

      a = clamp.(arg(args, 0), 0)
      b = clamp.(arg(args, 1), len)
      cp_slice(this, min(a, b), abs(b - a))
    end)

    def_fn(p, "match", fn this, args ->
      Browser.JS.RegExp.string_match(this, to_regexp(arg(args, 0)))
    end)

    def_fn(p, "matchAll", fn this, args ->
      Browser.JS.RegExp.string_match_all(this, to_regexp(arg(args, 0), "g"))
    end)

    def_fn(p, "search", fn this, args ->
      Browser.JS.RegExp.string_search(this, to_regexp(arg(args, 0)))
    end)

    def_fn(p, "split", fn this, args ->
      sep = arg(args, 0)

      if Browser.JS.RegExp.regexp?(sep),
        do: Browser.JS.RegExp.string_split(this, sep, arg(args, 1)),
        else: split_string(this, sep, arg(args, 1))
    end)

    def_fn(p, "replace", fn this, args -> replace(this, args, false) end)
    def_fn(p, "replaceAll", fn this, args -> replace(this, args, true) end)
    def_fn(p, "padStart", fn this, args -> pad(this, args, :leading) end)
    def_fn(p, "padEnd", fn this, args -> pad(this, args, :trailing) end)

    def_fn(p, "localeCompare", fn this, args ->
      other = to_str(arg(args, 0))

      cond do
        this < other -> -1.0
        this > other -> 1.0
        true -> 0.0
      end
    end)
  end

  defp cp_slice(s, from, nil), do: s |> String.codepoints() |> Enum.drop(from) |> Enum.join()

  defp cp_slice(s, from, count),
    do: s |> String.codepoints() |> Enum.slice(from, count) |> Enum.join()

  defp index_of(s, needle, from) do
    rest = cp_slice(s, from, nil)

    case :binary.match(rest, needle) do
      {pos, _} -> from + String.length(binary_part(rest, 0, pos))
      :nomatch -> -1
    end
  end

  defp split_string(this, sep, limit) do
    parts =
      cond do
        sep == :undefined -> [this]
        to_str(sep) == "" -> String.codepoints(this)
        true -> String.split(this, to_str(sep))
      end

    new_array(if limit == :undefined, do: parts, else: Enum.take(parts, to_int(limit)))
  end

  defp to_regexp(v, flags \\ "") do
    if Browser.JS.RegExp.regexp?(v), do: v, else: Browser.JS.RegExp.new(to_str(v), flags)
  end

  defp replace(s, args, all?) do
    if Browser.JS.RegExp.regexp?(arg(args, 0)),
      do: Browser.JS.RegExp.string_replace(s, arg(args, 0), arg(args, 1), all?),
      else: replace_string(s, args, all?)
  end

  defp replace_string(s, args, all?) do
    pattern = to_str(arg(args, 0))
    repl = arg(args, 1)

    fun = fn matched, pos ->
      if function?(repl),
        do: to_str(call(repl, :undefined, [matched, float(pos), s])),
        else: to_str(repl)
    end

    case :binary.matches(s, pattern) do
      [] ->
        s

      matches ->
        matches = if all?, do: matches, else: Enum.take(matches, 1)

        {out, last} =
          Enum.reduce(matches, {[], 0}, fn {pos, len}, {acc, from} ->
            piece = binary_part(s, from, pos - from)
            {[fun.(pattern, String.length(binary_part(s, 0, pos))), piece | acc], pos + len}
          end)

        IO.iodata_to_binary(Enum.reverse([binary_part(s, last, byte_size(s) - last) | out]))
    end
  end

  defp pad(s, args, side) do
    target = to_int(arg(args, 0))
    filler = if arg(args, 1) == :undefined, do: " ", else: to_str(arg(args, 1))
    need = target - String.length(s)

    if need <= 0 or filler == "" do
      s
    else
      padding =
        filler |> String.duplicate(div(need, String.length(filler)) + 1) |> cp_slice(0, need)

      if side == :leading, do: padding <> s, else: s <> padding
    end
  end

  # ── Math ───────────────────────────────────────────────────

  defp install_math(scope) do
    math = new_object()
    declare(scope, "Math", math)
    put_hidden(math, "PI", :math.pi())
    put_hidden(math, "E", :math.exp(1))
    put_hidden(math, "LN2", :math.log(2))
    put_hidden(math, "SQRT2", :math.sqrt(2))

    unary = fn name, fun ->
      def_fn(math, name, fn _, args ->
        case to_num(arg(args, 0)) do
          n when is_atom(n) -> fun.(n)
          n -> fun.(n * 1.0)
        end
      end)
    end

    keep_special = fn f -> fn n -> if is_atom(n), do: n, else: f.(n) end end

    unary.("floor", keep_special.(&:math.floor/1))
    unary.("ceil", keep_special.(&:math.ceil/1))
    unary.("trunc", keep_special.(&(&1 |> trunc() |> float())))
    unary.("round", keep_special.(&:math.floor(&1 + 0.5)))

    unary.("abs", fn n ->
      if n == :neg_infinity, do: :infinity, else: if(is_atom(n), do: n, else: abs(n))
    end)

    unary.("sign", fn n ->
      cond do
        is_atom(n) and n != :nan -> if(n == :infinity, do: 1.0, else: -1.0)
        n == :nan -> :nan
        n > 0 -> 1.0
        n < 0 -> -1.0
        true -> 0.0
      end
    end)

    unary.("sqrt", fn n ->
      cond do
        n == :infinity -> n
        is_atom(n) -> :nan
        n < 0 -> :nan
        true -> :math.sqrt(n)
      end
    end)

    unary.(
      "cbrt",
      keep_special.(&if &1 < 0, do: -:math.pow(-&1, 1 / 3), else: :math.pow(&1, 1 / 3))
    )

    unary.("sin", keep_special.(&:math.sin/1))
    unary.("cos", keep_special.(&:math.cos/1))
    unary.("tan", keep_special.(&:math.tan/1))
    unary.("atan", keep_special.(&:math.atan/1))

    unary.("exp", fn n ->
      cond do
        is_atom(n) -> if n == :neg_infinity, do: 0.0, else: n
        n > 709 -> :infinity
        true -> :math.exp(n)
      end
    end)

    unary.("log", fn n ->
      cond do
        n == :infinity -> n
        is_atom(n) -> :nan
        n < 0 -> :nan
        n == 0 -> :neg_infinity
        true -> :math.log(n)
      end
    end)

    unary.("log2", fn n ->
      cond do
        n == :infinity -> n
        is_atom(n) -> :nan
        n < 0 -> :nan
        n == 0 -> :neg_infinity
        true -> :math.log2(n)
      end
    end)

    unary.("log10", fn n ->
      cond do
        n == :infinity -> n
        is_atom(n) -> :nan
        n < 0 -> :nan
        n == 0 -> :neg_infinity
        true -> :math.log10(n)
      end
    end)

    def_fn(math, "atan2", fn _, args ->
      with y when is_number(y) <- to_num(arg(args, 0)),
           x when is_number(x) <- to_num(arg(args, 1)),
           do: :math.atan2(y * 1.0, x * 1.0),
           else: (_ -> :nan)
    end)

    def_fn(math, "pow", fn _, args -> Num.pow(to_num(arg(args, 0)), to_num(arg(args, 1))) end)
    def_fn(math, "random", fn _, _ -> :rand.uniform() end)
    def_fn(math, "max", fn _, args -> extreme(args, :neg_infinity, :gt) end)
    def_fn(math, "min", fn _, args -> extreme(args, :infinity, :lt) end)

    def_fn(math, "hypot", fn _, args ->
      args
      |> Enum.map(&to_num/1)
      |> Enum.reduce(0.0, fn n, acc -> Num.add(acc, Num.mul(n, n)) end)
      |> then(&if(is_number(&1), do: :math.sqrt(&1), else: &1))
    end)
  end

  defp extreme(args, start, want) do
    Enum.reduce(args, start, fn v, acc ->
      n = to_num(v)

      cond do
        acc == :nan or n == :nan -> :nan
        Num.compare(n, acc) == want -> n
        true -> acc
      end
    end)
  end

  # ── JSON ───────────────────────────────────────────────────

  defp install_json(scope) do
    json = new_object()
    declare(scope, "JSON", json)

    def_fn(json, "stringify", fn _, args ->
      indent =
        case arg(args, 2) do
          n when is_number(n) -> String.duplicate(" ", n |> trunc() |> max(0) |> min(10))
          s when is_binary(s) -> String.slice(s, 0, 10)
          _ -> ""
        end

      case stringify(arg(args, 0), indent, "", []) do
        :skip -> :undefined
        s -> s
      end
    end)

    def_fn(json, "parse", fn _, args ->
      try do
        {value, _, _} = :json.decode(to_str(arg(args, 0)), :ok, json_decoders())
        value
      catch
        :error, _ -> throw_error("SyntaxError", "Unexpected token in JSON")
      end
    end)
  end

  defp json_decoders do
    %{
      array_start: fn _ -> [] end,
      array_push: fn v, acc -> [v | acc] end,
      array_finish: fn acc, old -> {new_array(Enum.reverse(acc)), old} end,
      object_start: fn _ -> [] end,
      object_push: fn k, v, acc -> [{k, v} | acc] end,
      object_finish: fn acc, old ->
        {new_object(acc |> Enum.reverse() |> Enum.uniq_by(&elem(&1, 0))), old}
      end,
      float: fn s -> String.to_float(s) end,
      integer: fn s -> String.to_integer(s) * 1.0 end,
      null: :null
    }
  end

  defp stringify(v, indent, cur, seen) do
    cond do
      v == :null -> "null"
      v in [true, false] -> to_str(v)
      is_binary(v) -> :json.encode(v) |> IO.iodata_to_binary()
      is_number(v) -> Num.to_string(v)
      v in [:nan, :infinity, :neg_infinity] -> "null"
      v == :undefined -> :skip
      function?(v) -> :skip
      v in seen -> throw_error("TypeError", "Converting circular structure to JSON")
      array?(v) -> stringify_array(v, indent, cur, [v | seen])
      true -> stringify_object(v, indent, cur, [v | seen])
    end
  end

  defp stringify_array(v, indent, cur, seen) do
    items =
      for x <- array_list(v),
          do:
            (case stringify(x, indent, cur <> indent, seen) do
               :skip -> "null"
               s -> s
             end)

    wrap("[", "]", items, indent, cur)
  end

  defp stringify_object(v, indent, cur, seen) do
    sep = if indent == "", do: ":", else: ": "

    items =
      Enum.flat_map(own_keys(v), fn k ->
        case stringify(Interp.get(v, k), indent, cur <> indent, seen) do
          :skip -> []
          s -> [IO.iodata_to_binary(:json.encode(k)) <> sep <> s]
        end
      end)

    wrap("{", "}", items, indent, cur)
  end

  defp wrap(open, close, [], _, _), do: open <> close
  defp wrap(open, close, items, "", _), do: open <> Enum.join(items, ",") <> close

  defp wrap(open, close, items, indent, cur) do
    inner = cur <> indent
    open <> "\n" <> inner <> Enum.join(items, ",\n" <> inner) <> "\n" <> cur <> close
  end

  # ── console ────────────────────────────────────────────────

  defp install_console(scope) do
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
        line = args |> Enum.map(&inspect_arg/1) |> Enum.join(" ")
        Process.put(:js_console, [{level, line} | Process.get(:js_console, [])])
        :undefined
      end)
    end
  end

  defp inspect_arg(v) when is_binary(v), do: v
  defp inspect_arg(v), do: inspect_js(v, 0, [])

  @doc "Node-style one-line rendering of a value, as `console.log` prints it."
  def inspect_js(v, depth, seen) do
    cond do
      is_binary(v) ->
        "'" <> String.replace(v, "'", "\\'") <> "'"

      v == :undefined ->
        "undefined"

      v == :null ->
        "null"

      is_boolean(v) ->
        to_str(v)

      num?(v) ->
        Num.to_string(v)

      function?(v) ->
        function_label(v)

      v in seen ->
        "[Circular]"

      error?(v) ->
        to_str(call(Interp.get(v, "toString"), v, []))

      array?(v) and depth > 2 ->
        "[Array]"

      array?(v) ->
        list_label("[", "]", Enum.map(array_list(v), &inspect_js(&1, depth + 1, [v | seen])))

      depth > 2 ->
        "[Object]"

      true ->
        pairs =
          for k <- own_keys(v),
              do: key_label(k) <> ": " <> inspect_js(Interp.get(v, k), depth + 1, [v | seen])

        list_label("{", "}", pairs)
    end
  end

  defp list_label(open, close, []), do: open <> close
  defp list_label(open, close, items), do: open <> " " <> Enum.join(items, ", ") <> " " <> close

  defp key_label(k),
    do: if(Regex.match?(~r/\A[A-Za-z_$][\w$]*\z/, k), do: k, else: "'" <> k <> "'")

  defp function_label(f) do
    case to_str(Interp.get(f, "name")) do
      "" -> "[Function (anonymous)]"
      name -> "[Function: #{name}]"
    end
  end

  defp error?({:obj, _} = v),
    do: Interp.instance_of?(v, Interp.ev({:id, "Error"}, Interp.global()))

  defp error?(_), do: false

  # ── timers ─────────────────────────────────────────────────

  defp install_timers(scope) do
    Process.put(:js_timers, [])
    Process.put(:js_timer_seq, 0)
    Process.put(:js_now, 0.0)

    add = fn interval? ->
      fn _, args ->
        f = arg(args, 0)

        delay =
          case to_num(arg(args, 1)) do
            n when is_number(n) -> max(n, 0.0)
            _ -> 0.0
          end

        seq = Process.get(:js_timer_seq) + 1
        Process.put(:js_timer_seq, seq)

        timer = %{
          id: seq,
          at: Process.get(:js_now) + delay,
          seq: seq,
          fun: f,
          args: Enum.drop(args, 2),
          interval: if(interval?, do: max(delay, 1.0))
        }

        Process.put(:js_timers, [timer | Process.get(:js_timers)])
        float(seq)
      end
    end

    clear = fn _, args ->
      id = to_num(arg(args, 0))
      Process.put(:js_timers, Enum.reject(Process.get(:js_timers), &(float(&1.id) == id)))
      :undefined
    end

    declare(scope, "setTimeout", native("setTimeout", add.(false)))
    declare(scope, "setInterval", native("setInterval", add.(true)))
    declare(scope, "clearTimeout", native("clearTimeout", clear))
    declare(scope, "clearInterval", native("clearInterval", clear))
  end

  @doc """
  Runs pending timers in virtual time (no real waiting), earliest first, until none are left
  or the next one is more than a virtual minute away (so a `setInterval` can't run forever).
  `on_error` receives the thrown value of a callback that raised; the others still run.
  """
  def run_timers(on_error) do
    if run_next_timer(on_error), do: run_timers(on_error), else: :ok
  end

  @doc """
  Runs the earliest pending timer; false when there is none (or the next one lies beyond the
  virtual minute).
  """
  def run_next_timer(on_error) do
    case Enum.min_by(Process.get(:js_timers), &{&1.at, &1.seq}, fn -> nil end) do
      nil ->
        false

      %{at: at} when at > @timer_horizon ->
        false

      t ->
        Process.put(:js_timers, List.delete(Process.get(:js_timers), t))
        Process.put(:js_now, t.at)

        if t.interval do
          seq = Process.get(:js_timer_seq)
          Process.put(:js_timer_seq, seq + 1)

          Process.put(:js_timers, [
            %{t | at: t.at + t.interval, seq: seq + 1} | Process.get(:js_timers)
          ])
        end

        try do
          call(t.fun, :undefined, t.args)
          Browser.JS.Promise.run_microtasks()
        catch
          {:js_error, v} -> on_error.(v)
        end

        true
    end
  end

  defp install_misc(scope) do
    date = new_object()
    declare(scope, "Date", date)
    def_fn(date, "now", fn _, _ -> float(System.system_time(:millisecond)) end)

    perf = new_object()
    declare(scope, "performance", perf)
    def_fn(perf, "now", fn _, _ -> float(System.monotonic_time(:microsecond)) / 1000 end)
  end
end
