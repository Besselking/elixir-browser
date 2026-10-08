defmodule Browser.JS.ArrayGeneric do
  @moduledoc """
  `Array.prototype` methods on any object, following the specification step by step: lengths up
  to 2^53 - 1, only the indices the algorithm touches, and every read and write observable.
  `Browser.JS.Builtins` keeps list-based fast paths for ordinary arrays and calls in here for
  everything else (array-likes, proxies, frozen arrays, arrays with very large lengths).
  """

  import Browser.JS.Interp, except: [get: 2, put: 3, delete: 2, to_int: 1]
  alias Browser.JS.{Builtins, Interp, Props, Proxy}

  @max 9_007_199_254_740_991
  @max_array 4_294_967_295
  @huge 18_014_398_509_481_984

  defp arg(args, i), do: Enum.at(args, i, :undefined)

  # ── plumbing ───────────────────────────────────────────────

  @doc "ToLength(Get(o, \"length\"))."
  def len(o) do
    case to_num(Interp.get(o, "length")) do
      :nan -> 0
      :neg_infinity -> 0
      :infinity -> @max
      n -> n |> trunc() |> max(0) |> min(@max)
    end
  end

  @doc "ToIntegerOrInfinity, with the infinities as very large integers."
  def to_integer(v) do
    case to_num(v) do
      :nan -> 0
      :infinity -> @huge
      :neg_infinity -> -@huge
      n -> trunc(n)
    end
  end

  # a relative index (negative: from the end) clamped to 0..len
  def rel(v, len, default) do
    if v == :undefined do
      default
    else
      n = to_integer(v)
      if n < 0, do: max(len + n, 0), else: min(n, len)
    end
  end

  defp key(i) when i < @max_array, do: i * 1.0
  defp key(i), do: Integer.to_string(i)

  defp get(o, i), do: Interp.get(o, key(i))
  defp has?(o, i), do: Interp.has_property?(o, key(i))

  # an element stored directly in an ordinary array: `{:ok, v}`, else `:other` (a hole, an
  # accessor, or not an array at all) and the caller goes through the property protocol
  defp stored({:obj, id}, k) do
    case deref(id) do
      %{class: :array, items: items} = o when not is_map_key(o, :proxy) ->
        case items do
          %{^k => {:accessor, _, _}} -> :other
          %{^k => v} -> {:ok, v}
          _ -> :other
        end

      _ ->
        :other
    end
  end

  defp stored(_, _), do: :other

  defp read(o, k) do
    case stored(o, k) do
      {:ok, v} -> v
      :other -> get(o, k)
    end
  end

  defp present_value(o, k) do
    case stored(o, k) do
      {:ok, v} -> {:ok, v}
      :other -> if has?(o, k), do: {:ok, get(o, k)}, else: :absent
    end
  end

  defp set!(o, i, v), do: set_key!(o, key(i), v)

  defp set_key!(o, k, v) do
    unless Props.ordinary_set(o, to_key(k), v, o),
      do: throw_error("TypeError", "Cannot assign to read only property '#{to_str(k)}' of object")

    :ok
  end

  defp set_length!(o, n), do: set_key!(o, "length", n * 1.0)

  defp delete!(o, i) do
    unless Interp.delete(o, key(i)),
      do: throw_error("TypeError", "Cannot delete property '#{to_str(key(i))}' of object")

    :ok
  end

  defp create!(a, i, v) do
    Props.define(
      a,
      key(i),
      new_object([{"value", v}, {"writable", true}, {"enumerable", true}, {"configurable", true}])
    )

    :ok
  end

  # a new array of `n` empty slots
  defp array_create(n) do
    if n > @max_array, do: throw_error("RangeError", "Invalid array length")
    Builtins.array_of(n, %{})
  end

  # ArraySpeciesCreate
  defp species_create(o, n) do
    if Proxy.is_array(o) do
      c = Interp.get(o, "constructor")

      c =
        case c do
          {:obj, _} ->
            case Interp.get(c, {:symbol, :species, "Symbol.species"}) do
              :null -> :undefined
              sp -> sp
            end

          other ->
            other
        end

      cond do
        c == :undefined or c == Interp.get(proto(:array), "constructor") ->
          array_create(n)

        not function?(c) ->
          throw_error("TypeError", "object.constructor[Symbol.species] is not a constructor")

        true ->
          construct(c, [n * 1.0])
      end
    else
      array_create(n)
    end
  end

  defp check_length!(n) do
    if n > @max, do: throw_error("TypeError", "Invalid array length")
  end

  # ── mutators ───────────────────────────────────────────────

  def push(o, args) do
    len = len(o)
    check_length!(len + length(args))
    args |> Enum.with_index(len) |> Enum.each(fn {v, i} -> set!(o, i, v) end)
    n = len + length(args)
    set_length!(o, n)
    n * 1.0
  end

  def pop(o) do
    len = len(o)

    if len == 0 do
      set_length!(o, 0)
      :undefined
    else
      last = get(o, len - 1)
      delete!(o, len - 1)
      set_length!(o, len - 1)
      last
    end
  end

  def shift(o) do
    len = len(o)

    if len == 0 do
      set_length!(o, 0)
      :undefined
    else
      first = get(o, 0)
      move_down(o, 1, len, 1)
      delete!(o, len - 1)
      set_length!(o, len - 1)
      first
    end
  end

  # indices `from..stop-1` move `by` places down
  defp move_down(o, from, stop, by) do
    for k <- from..(stop - 1)//1 do
      if has?(o, k), do: set!(o, k - by, get(o, k)), else: delete!(o, k - by)
    end

    :ok
  end

  def unshift(o, args) do
    len = len(o)
    argc = length(args)

    if argc > 0 do
      check_length!(len + argc)

      for k <- len..1//-1 do
        if has?(o, k - 1),
          do: set!(o, k + argc - 1, get(o, k - 1)),
          else: delete!(o, k + argc - 1)
      end

      args |> Enum.with_index() |> Enum.each(fn {v, j} -> set!(o, j, v) end)
    end

    set_length!(o, len + argc)
    (len + argc) * 1.0
  end

  def splice(o, args) do
    len = len(o)
    start = rel(arg(args, 0), len, 0)

    {items, del} =
      case args do
        [] -> {[], 0}
        [_] -> {[], len - start}
        [_, dc | rest] -> {rest, dc |> to_integer() |> max(0) |> min(len - start)}
      end

    count = length(items)
    check_length!(len + count - del)
    a = species_create(o, del)

    for k <- 0..(del - 1)//1, has?(o, start + k), do: create!(a, k, get(o, start + k))
    set_length!(a, del)

    cond do
      count < del ->
        for k <- start..(len - del - 1)//1 do
          from = k + del
          to = k + count
          if has?(o, from), do: set!(o, to, get(o, from)), else: delete!(o, to)
        end

        for k <- len..(len - del + count + 1)//-1, do: delete!(o, k - 1)

      count > del ->
        for k <- (len - del)..(start + 1)//-1 do
          from = k + del - 1
          to = k + count - 1
          if has?(o, from), do: set!(o, to, get(o, from)), else: delete!(o, to)
        end

      true ->
        :ok
    end

    items |> Enum.with_index(start) |> Enum.each(fn {v, i} -> set!(o, i, v) end)
    set_length!(o, len - del + count)
    a
  end

  def fill(o, args) do
    len = len(o)
    v = arg(args, 0)
    from = rel(arg(args, 1), len, 0)
    to = rel(arg(args, 2), len, len)
    for k <- from..(to - 1)//1, do: set!(o, k, v)
    o
  end

  def copy_within(o, args) do
    len = len(o)
    to = rel(arg(args, 0), len, 0)
    from = rel(arg(args, 1), len, 0)
    final = rel(arg(args, 2), len, len)
    count = min(final - from, len - to)

    {dir, from, to} =
      if from < to and to < from + count,
        do: {-1, from + count - 1, to + count - 1},
        else: {1, from, to}

    for k <- 0..(count - 1)//1 do
      f = from + dir * k
      t = to + dir * k
      if has?(o, f), do: set!(o, t, get(o, f)), else: delete!(o, t)
    end

    o
  end

  def reverse(o) do
    len = len(o)
    middle = div(len, 2)

    for lower <- 0..(middle - 1)//1 do
      upper = len - lower - 1
      lower_exists = has?(o, lower)
      lower_v = if lower_exists, do: get(o, lower)
      upper_exists = has?(o, upper)
      upper_v = if upper_exists, do: get(o, upper)

      cond do
        lower_exists and upper_exists ->
          set!(o, lower, upper_v)
          set!(o, upper, lower_v)

        upper_exists ->
          set!(o, lower, upper_v)
          delete!(o, upper)

        lower_exists ->
          delete!(o, lower)
          set!(o, upper, lower_v)

        true ->
          :ok
      end
    end

    o
  end

  # ── queries ────────────────────────────────────────────────

  def slice(o, args) do
    len = len(o)
    k = rel(arg(args, 0), len, 0)
    final = rel(arg(args, 1), len, len)
    count = max(final - k, 0)
    a = species_create(o, count)

    n =
      Enum.reduce(k..(final - 1)//1, 0, fn i, n ->
        if has?(o, i), do: create!(a, n, get(o, i))
        n + 1
      end)

    set_length!(a, n)
    a
  end

  def index_of(o, args) do
    len = len(o)

    if len == 0 do
      -1.0
    else
      n = to_integer(arg(args, 1))
      start = if n < 0, do: max(len + n, 0), else: n
      v = arg(args, 0)

      found =
        Enum.find(candidates(o, start, len - 1, :asc), fn k -> match_at?(o, k, v) end)

      (found || -1) * 1.0
    end
  end

  def last_index_of(o, args) do
    len = len(o)

    if len == 0 do
      -1.0
    else
      n = if length(args) > 1, do: to_integer(arg(args, 1)), else: len - 1
      start = if n < 0, do: len + n, else: min(n, len - 1)
      v = arg(args, 0)

      found =
        if start < 0,
          do: nil,
          else: Enum.find(candidates(o, 0, start, :desc), fn k -> match_at?(o, k, v) end)

      (found || -1) * 1.0
    end
  end

  def includes(o, args) do
    len = len(o)

    if len == 0 do
      false
    else
      n = to_integer(arg(args, 1))
      start = if n < 0, do: max(len + n, 0), else: n
      v = arg(args, 0)

      cond do
        start >= len -> false
        very_sparse?(o, start, len - 1) and v != :undefined -> sparse_includes?(o, start, v)
        true -> Enum.any?(start..(len - 1)//1, fn k -> same_value_zero(read(o, k), v) end)
      end
    end
  end

  defp match_at?(o, k, v) do
    case present_value(o, k) do
      {:ok, x} -> strict_eq(x, v)
      :absent -> false
    end
  end

  defp sparse_includes?(o, start, v) do
    {:obj, id} = o

    Enum.any?(Map.keys(deref(id).items), fn k ->
      k >= start and same_value_zero(get(o, k), v)
    end)
  end

  # the indices to visit: all of them, or only those present in a huge, nearly empty array
  defp candidates(o, from, to, dir) do
    range = if dir == :asc, do: from..to//1, else: to..from//-1

    if very_sparse?(o, from, to) do
      {:obj, id} = o
      keys = for k <- Map.keys(deref(id).items), k >= from and k <= to, do: k
      if dir == :asc, do: Enum.sort(keys), else: Enum.sort(keys, :desc)
    else
      range
    end
  end

  defp very_sparse?({:obj, id}, from, to) do
    case deref(id) do
      %{class: :array, items: items} ->
        to - from > 100_000 and to - from - map_size(items) > 100_000

      _ ->
        false
    end
  end

  defp very_sparse?(_, _, _), do: false

  def find_last(o, args, index?) do
    len = len(o)
    f = callable!(arg(args, 0))
    this_arg = arg(args, 1)

    result =
      Enum.find_value((len - 1)..0//-1, fn k ->
        v = get(o, k)
        if truthy(call(f, this_arg, [v, k * 1.0, o])), do: {k, v}
      end)

    case {result, index?} do
      {nil, true} -> -1.0
      {nil, false} -> :undefined
      {{k, _}, true} -> k * 1.0
      {{_, v}, false} -> v
    end
  end

  defp callable!(f) do
    unless function?(f), do: throw_error("TypeError", "callback is not a function")
    f
  end

  def at(o, args) do
    len = len(o)
    n = to_integer(arg(args, 0))
    k = if n >= 0, do: n, else: len + n
    if k < 0 or k >= len, do: :undefined, else: get(o, k)
  end

  # ── copying methods ────────────────────────────────────────

  def join(o, separator) do
    len = len(o)
    sep = if separator == :undefined, do: ",", else: to_str(separator)

    0..(len - 1)//1
    |> Enum.map(fn k ->
      case read(o, k) do
        v when v in [:undefined, :null] -> ""
        v -> to_str(v)
      end
    end)
    |> Browser.JS.Str.join(sep)
  end

  def to_sorted(o, args) do
    f = arg(args, 0)

    unless f == :undefined or function?(f),
      do:
        throw_error("TypeError", "The comparison function must be either a function or undefined")

    len = len(o)
    a = array_create(len)
    sorted = sort_list(read_all(o, len), f)
    sorted |> Enum.with_index() |> Enum.each(fn {v, k} -> Interp.put(a, key(k), v) end)
    a
  end

  # the values in order, undefined last
  defp sort_list(items, f) do
    {undefs, list} = Enum.split_with(items, &(&1 == :undefined))

    cmp =
      if function?(f),
        do: fn a, b ->
          case to_num(call(f, :undefined, [a, b])) do
            :nan -> true
            n -> n <= 0
          end
        end,
        else: fn a, b -> to_str(a) <= to_str(b) end

    Enum.sort(list, cmp) ++ undefs
  end

  def to_reversed(o) do
    len = len(o)
    a = array_create(len)
    for k <- 0..(len - 1)//1, do: Interp.put(a, key(k), get(o, len - k - 1))
    a
  end

  def with_index(o, args) do
    len = len(o)
    rel = to_integer(arg(args, 0))
    actual = if rel >= 0, do: rel, else: len + rel
    if actual >= len or actual < 0, do: throw_error("RangeError", "Invalid index")
    a = array_create(len)

    for k <- 0..(len - 1)//1 do
      Interp.put(a, key(k), if(k == actual, do: arg(args, 1), else: get(o, k)))
    end

    a
  end

  def to_spliced(o, args) do
    len = len(o)
    start = rel(arg(args, 0), len, 0)

    {items, skip} =
      case args do
        [] -> {[], 0}
        [_] -> {[], len - start}
        [_, sc | rest] -> {rest, sc |> to_integer() |> max(0) |> min(len - start)}
      end

    new_len = len + length(items) - skip
    check_length!(new_len)
    a = array_create(new_len)

    for i <- 0..(start - 1)//1, do: Interp.put(a, key(i), get(o, i))
    items |> Enum.with_index(start) |> Enum.each(fn {v, i} -> Interp.put(a, key(i), v) end)

    for i <- (start + length(items))..(new_len - 1)//1 do
      Interp.put(a, key(i), get(o, i - length(items) + skip))
    end

    a
  end

  # ── Array.from and Array.of ────────────────────────────────

  @iterator {:symbol, :iterator, "Symbol.iterator"}

  # the intrinsic Array constructor builds plain arrays, which the loops fill directly
  defp array_ctor?({:obj, id}), do: match?(%{fun: {:native, "Array", _}}, deref(id))
  defp array_ctor?(_), do: false

  def of(c, args) do
    n = length(args)

    a =
      cond do
        array_ctor?(c) -> array_create(n)
        constructor?(c) -> construct(c, [n * 1.0])
        true -> array_create(n)
      end

    args |> Enum.with_index() |> Enum.each(fn {v, k} -> create!(a, k, v) end)
    set_length!(a, n)
    a
  end

  def from(c, args) do
    items = arg(args, 0)
    mapfn = arg(args, 1)
    this_arg = arg(args, 2)
    mapping? = mapfn != :undefined
    if mapping? and not function?(mapfn), do: throw_error("TypeError", "mapper is not a function")

    if nullish?(items),
      do: throw_error("TypeError", "Cannot convert undefined or null to object")

    using = Interp.get(items, @iterator)

    unless using in [:undefined, :null] or function?(using),
      do: throw_error("TypeError", "Symbol.iterator is not a function")

    map = fn v, k -> if mapping?, do: call(mapfn, this_arg, [v, k * 1.0]), else: v end

    if using in [:undefined, :null],
      do: from_array_like(c, items, map),
      else: from_iterable(c, items, map)
  end

  defp from_iterable(c, items, map) do
    plain? = array_ctor?(c)

    a =
      cond do
        plain? -> nil
        constructor?(c) -> construct(c, [])
        true -> array_create(0)
      end

    sink = fn k, v -> if a, do: create!(a, k, v) end

    {list, count} =
      case Interp.for_of_source(items) do
        {:list, list} ->
          {mapped, n} =
            Enum.reduce(list, {[], 0}, fn v, {acc, k} ->
              m = map.(v, k)
              sink.(k, m)
              {[m | acc], k + 1}
            end)

          {Enum.reverse(mapped), n}

        {:proto, it, next} ->
          drain(it, next, map, sink, 0, [])
      end

    if plain? do
      new_array(list)
    else
      set_length!(a, count)
      a
    end
  end

  defp drain(it, next, map, sink, k, acc) do
    case Interp.iter_step(it, next) do
      :done ->
        {Enum.reverse(acc), k}

      {:ok, v} ->
        m =
          try do
            m = map.(v, k)
            sink.(k, m)
            m
          catch
            kind, e ->
              Interp.iter_close(it, true)
              :erlang.raise(kind, e, __STACKTRACE__)
          end

        drain(it, next, map, sink, k + 1, [m | acc])
    end
  end

  defp from_array_like(c, items, map) do
    o = if match?({:obj, _}, items), do: items, else: Builtins.box(items)
    len = len(o)

    a =
      cond do
        array_ctor?(c) -> if len > @max_array, do: array_create(len)
        constructor?(c) -> construct(c, [len * 1.0])
        true -> array_create(len)
      end

    if array_ctor?(c) do
      # nothing else can see the new array: build it in one go
      new_array(for k <- 0..(len - 1)//1, do: map.(get(o, k), k))
    else
      for k <- 0..(len - 1)//1, do: create!(a, k, map.(get(o, k), k))
      set_length!(a, len)
      a
    end
  end

  # ── concat ─────────────────────────────────────────────────

  @spreadable {:symbol, :isConcatSpreadable, "Symbol.isConcatSpreadable"}

  def concat(o, args) do
    a = species_create(o, 0)
    plain? = fresh_array?(a)

    {n, acc} =
      Enum.reduce([o | args], {0, %{}}, fn e, {n, acc} ->
        if spreadable?(e),
          do: spread(e, a, plain?, n, acc),
          else: {n + 1, add(a, plain?, acc, n, e)}
      end)

    if plain? do
      if n > @max_array, do: throw_error("RangeError", "Invalid array length")
      {:obj, id} = a
      store(id, %{deref(id) | items: acc, len: n})
    else
      set_length!(a, n)
    end

    a
  end

  # a result array that nothing else could have observed: elements may be stored directly
  defp fresh_array?({:obj, id}) do
    case deref(id) do
      %{class: :array, len: 0, proto: pr} ->
        pr == proto(:array) and not Map.has_key?(deref(id), :proxy)

      _ ->
        false
    end
  end

  defp add(_a, true, acc, n, v), do: Map.put(acc, n, v)

  defp add(a, false, acc, n, v) do
    if n >= @max, do: throw_error("TypeError", "Invalid array length")
    create!(a, n, v)
    acc
  end

  defp spreadable?({:obj, _} = e) do
    case Interp.get(e, @spreadable) do
      :undefined -> Proxy.is_array(e)
      v -> truthy(v)
    end
  end

  defp spreadable?(_), do: false

  defp spread(e, a, plain?, n, acc) do
    len = len(e)
    if n + len > @max, do: throw_error("TypeError", "Invalid array length")

    case dense_items(e, len) do
      {:ok, items} when plain? ->
        {n + len, Enum.reduce(items, acc, fn {i, v}, acc -> Map.put(acc, n + i, v) end)}

      _ ->
        Enum.reduce(0..(len - 1)//1, {n, acc}, fn k, {m, acc} ->
          acc = if has?(e, k), do: add(a, plain?, acc, m, get(e, k)), else: acc
          {m + 1, acc}
        end)
    end
  end

  # the elements of an ordinary array without accessors or holes, as they are stored
  defp dense_items({:obj, id}, len) do
    case deref(id) do
      %{class: :array, items: items, len: ^len} = o when map_size(items) == len ->
        if Map.has_key?(o, :proxy) or
             Enum.any?(items, fn {_, v} -> match?({:accessor, _, _}, v) end),
           do: :slow,
           else: {:ok, items}

      _ ->
        :slow
    end
  end

  @doc "Every element 0..len-1 read through Get (holes read as undefined)."
  def read_all(o, len), do: for(k <- 0..(len - 1)//1, do: get(o, k))
end
