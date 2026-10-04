defmodule Browser.JS.TypedArrays do
  @moduledoc """
  `ArrayBuffer`, the typed arrays (`Int8Array` … `Float64Array`), `DataView`, `TextEncoder` and
  `TextDecoder` for the JavaScript runtime.

  An `ArrayBuffer` is an ordinary heap object with its bytes (an Elixir binary) under `:bytes`.
  A typed array or `DataView` is a host object (see `Browser.JS.Interp.new_host/3`) holding
  `{:ta, kind, buffer_id, byte_offset, length}` or `{:dv, buffer_id, byte_offset, byte_length}`:
  reading an index decodes the bytes, writing one rebuilds the buffer's binary. Byte order is
  little-endian.
  """

  import Bitwise, only: [<<<: 2, |||: 2]
  import Browser.JS.Interp, except: [get: 2, put: 3]
  alias Browser.JS.{Interp, Num, Props}

  @kinds [
    {"Int8Array", :i8, 1},
    {"Uint8Array", :u8, 1},
    {"Uint8ClampedArray", :u8c, 1},
    {"Int16Array", :i16, 2},
    {"Uint16Array", :u16, 2},
    {"Int32Array", :i32, 4},
    {"Uint32Array", :u32, 4},
    {"Float16Array", :f16, 2},
    {"Float32Array", :f32, 4},
    {"Float64Array", :f64, 8},
    {"BigInt64Array", :i64, 8},
    {"BigUint64Array", :u64, 8}
  ]

  @max_f32 3.4028235677973366e38

  defp arg(args, i), do: Enum.at(args, i, :undefined)
  defp def_fn(obj, name, fun), do: put_hidden(obj, name, native(name, fun))

  defp def_fn(obj, name, arity, fun) do
    {:obj, id} = f = native(name, fun)
    store(id, Map.put(deref(id), :arity, arity * 1.0))
    put_hidden(obj, name, f)
  end

  defp callable!(f) do
    unless function?(f), do: throw_error("TypeError", "#{to_str(f)} is not a function")
    f
  end

  defp size_of(kind), do: Enum.find_value(@kinds, fn {_, k, s} -> if k == kind, do: s end)

  # ── element codecs ─────────────────────────────────────────

  defp read(:i8, <<v::signed-8>>), do: v * 1.0
  defp read(:u8, <<v::unsigned-8>>), do: v * 1.0
  defp read(:u8c, <<v::unsigned-8>>), do: v * 1.0
  defp read(:i16, <<v::little-signed-16>>), do: v * 1.0
  defp read(:u16, <<v::little-unsigned-16>>), do: v * 1.0
  defp read(:i32, <<v::little-signed-32>>), do: v * 1.0
  defp read(:u32, <<v::little-unsigned-32>>), do: v * 1.0
  defp read(:i64, <<v::little-signed-64>>), do: {:bigint, v}
  defp read(:u64, <<v::little-unsigned-64>>), do: {:bigint, v}
  defp read(:f16, <<bits::little-unsigned-16>>), do: decode_half(bits)
  defp read(:f32, <<bits::little-unsigned-32>>), do: decode_float(<<bits::32>>, 8)
  defp read(:f64, <<bits::little-unsigned-64>>), do: decode_float(<<bits::64>>, 11)

  # IEEE 754 binary16
  defp decode_half(bits) do
    <<sign::1, exp::5, frac::10>> = <<bits::16>>
    s = if sign == 1, do: -1.0, else: 1.0

    cond do
      exp == 31 and frac != 0 -> :nan
      exp == 31 -> if sign == 1, do: :neg_infinity, else: :infinity
      exp == 0 -> s * frac * :math.pow(2, -24)
      true -> s * (1 + frac / 1024) * :math.pow(2, exp - 15)
    end
  end

  # round to nearest, ties to even
  defp encode_half(:nan), do: 0x7E00
  defp encode_half(:infinity), do: 0x7C00
  defp encode_half(:neg_infinity), do: 0xFC00

  defp encode_half(x) do
    <<sign::1, _::63>> = <<x * 1.0::float-64>>
    a = abs(x)
    s = sign <<< 15

    cond do
      a == 0 ->
        s

      a >= 65520.0 ->
        s ||| 0x7C00

      a < :math.pow(2, -14) ->
        # subnormal (and the step up to the smallest normal): multiples of 2^-24
        s ||| round_half_even(a * 16_777_216.0)

      true ->
        {m, e} = frexp(a)
        # a = m * 2^e with m in [0.5, 1): the unbiased exponent is e - 1
        he = e - 1 + 15
        frac = round_half_even((m * 2 - 1) * 1024)

        if frac == 1024,
          do: s ||| (he + 1) <<< 10,
          else: s ||| he <<< 10 ||| frac
    end
  end

  # {m, e} with x = m * 2^e and m in [0.5, 1), for a positive finite float
  defp frexp(x) do
    <<_::1, e::11, m::52>> = <<x::float-64>>

    if e == 0 do
      {m0, e0} = frexp(x * 18_014_398_509_481_984.0)
      {m0, e0 - 54}
    else
      <<mant::float-64>> = <<0::1, 1022::11, m::52>>
      {mant, e - 1022}
    end
  end

  @doc "`Math.f16round`: the nearest binary16 value."
  def f16round(x) do
    case to_num(x) do
      n when n in [:nan, :infinity, :neg_infinity] -> n
      n -> n |> encode_half() |> decode_half()
    end
  end

  # NaN and the infinities have no Elixir float; everything else decodes as a float
  defp decode_float(bits, exp_bits) do
    total = bit_size(bits)
    man_bits = total - 1 - exp_bits
    <<sign::1, exp::size(^exp_bits), man::size(^man_bits)>> = bits

    cond do
      exp == Bitwise.bsl(1, exp_bits) - 1 and man != 0 -> :nan
      exp == Bitwise.bsl(1, exp_bits) - 1 -> if sign == 1, do: :neg_infinity, else: :infinity
      total == 32 -> (fn <<f::float-32>> -> f end).(bits)
      true -> (fn <<f::float-64>> -> f end).(bits)
    end
  end

  defp write(:f16, value) do
    <<encode_half(to_num(value))::little-unsigned-16>>
  end

  defp write(kind, value) when kind in [:f32, :f64] do
    n = to_num(value)

    case {kind, n} do
      {:f32, :nan} -> <<0, 0, 0xC0, 0x7F>>
      {:f32, :infinity} -> <<0, 0, 0x80, 0x7F>>
      {:f32, :neg_infinity} -> <<0, 0, 0x80, 0xFF>>
      {:f32, x} when x > @max_f32 -> <<0, 0, 0x80, 0x7F>>
      {:f32, x} when x < -@max_f32 -> <<0, 0, 0x80, 0xFF>>
      {:f32, x} -> <<x::little-float-32>>
      {:f64, :nan} -> <<0, 0, 0, 0, 0, 0, 0xF8, 0x7F>>
      {:f64, :infinity} -> <<0, 0, 0, 0, 0, 0, 0xF0, 0x7F>>
      {:f64, :neg_infinity} -> <<0, 0, 0, 0, 0, 0, 0xF0, 0xFF>>
      {:f64, x} -> <<x::little-float-64>>
    end
  end

  defp write(kind, value) when kind in [:i64, :u64] do
    {:bigint, n} = Browser.JS.BigInt.to_bigint(value)
    <<Bitwise.band(n, Bitwise.bsl(1, 64) - 1)::little-size(64)>>
  end

  defp write(:u8c, value) do
    case to_num(value) do
      n when n in [:nan, :neg_infinity] -> <<0>>
      :infinity -> <<255>>
      n -> <<n |> round_half_even() |> max(0) |> min(255)>>
    end
  end

  defp write(kind, value) do
    bits = size_of(kind) * 8
    i = to_integer(value)
    <<Bitwise.band(i, Bitwise.bsl(1, bits) - 1)::little-size(bits)>>
  end

  # ToInteger on the way to a modular wrap
  defp to_integer(value) do
    case to_num(value) do
      n when is_float(n) -> trunc(n)
      n when is_integer(n) -> n
      _ -> 0
    end
  end

  defp round_half_even(n) do
    f = Float.floor(n)
    diff = n - f

    cond do
      diff < 0.5 -> trunc(f)
      diff > 0.5 -> trunc(f) + 1
      rem(trunc(f), 2) == 0 -> trunc(f)
      true -> trunc(f) + 1
    end
  end

  # ── buffers and views ──────────────────────────────────────

  defp new_buffer(bytes) do
    {:obj, id} = buf = new_object([], proto(:arraybuffer))
    store(id, Map.put(deref(id), :bytes, bytes))
    buf
  end

  @doc "Detaches an ArrayBuffer (`$262.detachArrayBuffer`): it loses its bytes and its views read as empty."
  def detach({:obj, id} = buf) do
    unless buffer?(buf), do: throw_error("TypeError", "not an ArrayBuffer")
    store(id, deref(id) |> Map.put(:bytes, <<>>) |> Map.put(:detached, true))
    :undefined
  end

  defp detached?(bid), do: Map.get(deref(bid), :detached, false)

  defp buffer?({:obj, id}), do: Map.has_key?(deref(id), :bytes)
  defp buffer?(_), do: false

  defp bytes_of({:obj, id}), do: deref(id).bytes
  defp buffer_id({:obj, id}), do: id

  defp view(kind, bid, offset, length),
    do: new_host(__MODULE__, {:ta, kind, bid, offset, length}, proto({:ta, kind}))

  # a new typed array of its own buffer holding `values`
  defp make(kind, values) do
    bytes = values |> Enum.map(&write(kind, &1)) |> IO.iodata_to_binary()
    buf = new_buffer(bytes)
    view(kind, buffer_id(buf), 0, length(values))
  end

  defp data!({:obj, id}) do
    case deref(id) do
      %{host: {__MODULE__, {:ta, _, bid, _, _} = d}} ->
        if detached?(bid),
          do: throw_error("TypeError", "cannot perform this operation on a detached ArrayBuffer")

        d

      _ ->
        throw_error("TypeError", "this is not a typed array")
    end
  end

  defp data!(_), do: throw_error("TypeError", "this is not a typed array")

  defp ta?({:obj, id}), do: match?(%{host: {__MODULE__, {:ta, _, _, _, _}}}, deref(id))
  defp ta?(_), do: false

  defp elem_at({:ta, kind, bid, off, _len}, i) do
    size = size_of(kind)
    read(kind, binary_part(deref(bid).bytes, off + i * size, size))
  end

  defp values({:ta, kind, bid, off, len}) do
    size = size_of(kind)
    bytes = binary_part(deref(bid).bytes, off, len * size)
    for <<chunk::binary-size(^size) <- bytes>>, do: read(kind, chunk)
  end

  defp put_elem_at({:ta, kind, bid, off, _}, i, value) do
    size = size_of(kind)
    o = deref(bid)
    pos = off + i * size
    <<pre::binary-size(^pos), _::binary-size(^size), post::binary>> = o.bytes
    store(bid, %{o | bytes: pre <> write(kind, value) <> post})
    :ok
  end

  defp put_all({:ta, kind, bid, off, _}, start, items) do
    size = size_of(kind)
    o = deref(bid)
    pos = off + start * size
    chunk = items |> Enum.map(&write(kind, &1)) |> IO.iodata_to_binary()
    n = byte_size(chunk)
    <<pre::binary-size(^pos), _::binary-size(^n), post::binary>> = o.bytes
    store(bid, %{o | bytes: pre <> chunk <> post})
  end

  # ── host protocol ──────────────────────────────────────────

  @doc false
  def host_get({:ta, kind, bid, off, len} = d, key, _self) when is_binary(key) do
    {off, len} = if detached?(bid), do: {0, 0}, else: {off, len}

    case key do
      "length" ->
        {:ok, len * 1.0}

      "byteLength" ->
        {:ok, len * size_of(kind) * 1.0}

      "byteOffset" ->
        {:ok, off * 1.0}

      "buffer" ->
        {:ok, buffer_object(bid)}

      _ ->
        case Integer.parse(key) do
          {i, ""} when i >= 0 ->
            if i < len, do: {:ok, elem_at(d, i)}, else: {:ok, :undefined}

          _ ->
            :miss
        end
    end
  end

  def host_get({:dv, bid, off, len}, key, _self) do
    case key do
      "byteLength" -> {:ok, len * 1.0}
      "byteOffset" -> {:ok, off * 1.0}
      "buffer" -> {:ok, buffer_object(bid)}
      _ -> :miss
    end
  end

  def host_get(_, _, _), do: :miss

  @doc false
  def host_put({:ta, _, bid, _, len} = d, key, v, _self) when is_binary(key) do
    len = if detached?(bid), do: 0, else: len

    case Integer.parse(key) do
      {i, ""} when i >= 0 ->
        if i < len, do: put_elem_at(d, i, v)
        :ok

      _ ->
        :miss
    end
  end

  def host_put(_, _, _, _), do: :miss

  # the ArrayBuffer object a view was made on (each view of one buffer shares it)
  defp buffer_object(bid), do: {:obj, bid}

  # ── install ────────────────────────────────────────────────

  def install(scope) do
    install_buffer(scope)
    install_typed_arrays(scope)
    install_data_view(scope)
    install_text(scope)
    :ok
  end

  defp install_buffer(scope) do
    p = new_object()
    put_proto(:arraybuffer, p)

    ctor =
      native("ArrayBuffer", fn _, args ->
        n = to_int(arg(args, 0))

        if n < 0 or n > 1_000_000_000,
          do: throw_error("RangeError", "Invalid array buffer length")

        new_buffer(:binary.copy(<<0>>, n))
      end)

    put_const(ctor, "prototype", p)
    put_hidden(p, "constructor", ctor)
    declare(scope, "ArrayBuffer", ctor)
    def_species(ctor)

    def_fn(ctor, "isView", fn _, args ->
      case arg(args, 0) do
        {:obj, id} -> match?(%{host: {__MODULE__, _}}, deref(id))
        _ -> false
      end
    end)

    Props.define_accessor(p, "byteLength",
      get:
        native("byteLength", fn this, _ ->
          unless buffer?(this), do: throw_error("TypeError", "not an ArrayBuffer")
          byte_size(bytes_of(this)) * 1.0
        end),
      enumerable: false
    )

    Props.define_accessor(p, "detached",
      get:
        native("get detached", fn this, _ ->
          unless buffer?(this), do: throw_error("TypeError", "not an ArrayBuffer")
          detached?(buffer_id(this))
        end),
      enumerable: false
    )

    # transfer(newLength) / transferToFixedLength(newLength): the bytes move to a new buffer
    # (cut or zero-padded to the length) and this one is detached
    for name <- ["transfer", "transferToFixedLength"] do
      f =
        native(name, fn this, args ->
          unless buffer?(this), do: throw_error("TypeError", "not an ArrayBuffer")

          len =
            case arg(args, 0) do
              :undefined -> byte_size(bytes_of(this))
              v -> to_index(v)
            end

          if detached?(buffer_id(this)),
            do: throw_error("TypeError", "cannot transfer a detached ArrayBuffer")

          bytes = bytes_of(this)

          moved =
            if len <= byte_size(bytes),
              do: binary_part(bytes, 0, len),
              else: bytes <> :binary.copy(<<0>>, len - byte_size(bytes))

          buf = new_buffer(moved)
          detach(this)
          buf
        end)

      {:obj, fid} = f
      store(fid, Map.put(deref(fid), :arity, 0.0))
      put_hidden(p, name, f)
    end

    def_fn(p, "slice", fn this, args ->
      unless buffer?(this), do: throw_error("TypeError", "not an ArrayBuffer")

      if detached?(buffer_id(this)),
        do: throw_error("TypeError", "cannot slice a detached ArrayBuffer")

      bytes = bytes_of(this)
      len = byte_size(bytes)
      from = rel_index(arg(args, 0), len, 0)
      to = rel_index(arg(args, 1), len, len)
      n = max(to - from, 0)
      new_buffer(binary_part(bytes, from, n))
    end)

    put_tag(p, "ArrayBuffer")
  end

  # length, byteLength, byteOffset, buffer and @@toStringTag are getters on %TypedArray%.prototype
  defp install_ta_accessors(base) do
    getter = fn name, f ->
      Props.define_accessor(base, name,
        get:
          native(to_string(name), fn this, _ ->
            unless ta?(this), do: throw_error("TypeError", "this is not a typed array")
            {:obj, id} = this
            %{host: {__MODULE__, {:ta, _, bid, _, _} = d}} = deref(id)
            f.(d, detached?(bid))
          end),
        enumerable: false
      )
    end

    getter.("length", fn {:ta, _, _, _, len}, gone -> if(gone, do: 0, else: len) * 1.0 end)

    getter.("byteLength", fn {:ta, kind, _, _, len}, gone ->
      if(gone, do: 0, else: len * size_of(kind)) * 1.0
    end)

    getter.("byteOffset", fn {:ta, _, _, off, _}, gone -> if(gone, do: 0, else: off) * 1.0 end)
    getter.("buffer", fn {:ta, _, bid, _, _}, _ -> buffer_object(bid) end)

    Props.define_accessor(base, {:symbol, :toStringTag, "Symbol.toStringTag"},
      get:
        native("get [Symbol.toStringTag]", fn this, _ ->
          if ta?(this) do
            {:obj, id} = this
            %{host: {__MODULE__, {:ta, kind, _, _, _}}} = deref(id)
            for({n, ^kind, _} <- @kinds, do: n) |> hd()
          else
            :undefined
          end
        end),
      enumerable: false
    )
  end

  # ToIndex
  defp to_index(v) do
    n = to_int(v)

    if n < 0 or n > 9_007_199_254_740_991,
      do: throw_error("RangeError", "Invalid array buffer length"),
      else: n
  end

  defp rel_index(:undefined, _len, default), do: default

  defp rel_index(v, len, _default) do
    n = to_int(v)
    if n < 0, do: max(len + n, 0), else: min(n, len)
  end

  defp install_typed_arrays(scope) do
    base = new_object()
    put_proto(:typed_array, base)
    install_methods(base)

    # %TypedArray%, the constructor every typed array constructor inherits from
    base_ctor =
      native("TypedArray", fn _, _ ->
        throw_error("TypeError", "Abstract class TypedArray not directly constructable")
      end)

    put_const(base_ctor, "prototype", base)
    put_hidden(base, "constructor", base_ctor)
    def_species(base_ctor)
    install_ta_accessors(base)

    for {name, kind, size} <- @kinds do
      p = new_object([], base)
      put_proto({:ta, kind}, p)

      ctor =
        native(name, fn _, args -> build(kind, args) end)

      {:obj, cid} = ctor
      store(cid, %{deref(cid) | proto: base_ctor})
      put_const(ctor, "prototype", p)
      put_hidden(p, "constructor", ctor)
      put_const(ctor, "BYTES_PER_ELEMENT", size * 1.0)
      put_const(p, "BYTES_PER_ELEMENT", size * 1.0)
      declare(scope, name, ctor)

      def_fn(ctor, "from", fn _, args ->
        src = arg(args, 0)
        f = arg(args, 1)
        list = source_values(src)
        list = if f == :undefined, do: list, else: map_with(list, callable!(f), arg(args, 2))
        make(kind, list)
      end)

      def_fn(ctor, "of", fn _, args -> make(kind, args) end)
    end
  end

  defp map_with(list, f, this_arg) do
    list
    |> Enum.with_index()
    |> Enum.map(fn {v, i} -> call(f, this_arg, [v, i * 1.0]) end)
  end

  # `new Int8Array(length | buffer, byteOffset, length | typedArray | iterable | array-like)`
  defp build(kind, args) do
    size = size_of(kind)

    case arg(args, 0) do
      :undefined ->
        make(kind, [])

      n when is_number(n) ->
        len = to_int(n)

        if len < 0 or len > 100_000_000,
          do: throw_error("RangeError", "Invalid typed array length: #{to_str(n)}")

        buf = new_buffer(:binary.copy(<<0>>, len * size))
        view(kind, buffer_id(buf), 0, len)

      src ->
        if buffer?(src) do
          total = byte_size(bytes_of(src))
          off = if arg(args, 1) == :undefined, do: 0, else: to_int(arg(args, 1))

          if off < 0 or rem(off, size) != 0,
            do:
              throw_error("RangeError", "start offset of #{kind} should be a multiple of #{size}")

          len =
            if arg(args, 2) == :undefined do
              if rem(total - off, size) != 0 or total < off,
                do:
                  throw_error(
                    "RangeError",
                    "byte length of #{kind} should be a multiple of #{size}"
                  )

              div(total - off, size)
            else
              to_int(arg(args, 2))
            end

          if off + len * size > total, do: throw_error("RangeError", "Invalid typed array length")
          view(kind, buffer_id(src), off, len)
        else
          make(kind, source_values(src))
        end
    end
  end

  # the values of a typed array, iterable or array-like
  defp source_values(src) do
    cond do
      ta?(src) ->
        values(data!(src))

      match?({:obj, _}, src) ->
        case Interp.get(src, {:symbol, :iterator, "Symbol.iterator"}) do
          f when is_tuple(f) ->
            if function?(f), do: iterate(src), else: array_like(src)

          _ ->
            array_like(src)
        end

      is_binary(src) ->
        iterate(src)

      true ->
        []
    end
  end

  defp array_like(src) do
    n = to_int(Interp.get(src, "length"))

    # as large as the biggest typed array that can be made
    if n > 100_000_000, do: throw_error("RangeError", "Invalid typed array length: #{n}")

    for i <- 0..(n - 1)//1, do: Interp.get(src, Integer.to_string(i))
  end

  defp install_methods(p) do
    def_fn(p, "at", fn this, args ->
      d = data!(this)
      len = elem(d, 4)
      i = to_int(arg(args, 0))
      i = if i < 0, do: len + i, else: i
      if i >= 0 and i < len, do: elem_at(d, i), else: :undefined
    end)

    def_fn(p, "fill", fn this, args ->
      {:ta, _, _, _, len} = d = data!(this)
      from = rel_index(arg(args, 1), len, 0)
      to = rel_index(arg(args, 2), len, len)
      if to > from, do: put_all(d, from, List.duplicate(arg(args, 0), to - from))
      this
    end)

    def_fn(p, "set", fn this, args ->
      {:ta, _, _, _, len} = d = data!(this)
      items = source_values(arg(args, 0))
      off = if arg(args, 1) == :undefined, do: 0, else: to_int(arg(args, 1))

      if off < 0 or off + length(items) > len,
        do: throw_error("RangeError", "offset is out of bounds")

      if items != [], do: put_all(d, off, items)
      :undefined
    end)

    def_fn(p, "subarray", fn this, args ->
      {:ta, kind, bid, off, len} = data!(this)
      from = rel_index(arg(args, 0), len, 0)
      to = rel_index(arg(args, 1), len, len)
      view(kind, bid, off + from * size_of(kind), max(to - from, 0))
    end)

    def_fn(p, "slice", fn this, args ->
      {:ta, kind, _, _, len} = d = data!(this)
      from = rel_index(arg(args, 0), len, 0)
      to = rel_index(arg(args, 1), len, len)
      make(kind, d |> values() |> Enum.slice(from, max(to - from, 0)))
    end)

    def_fn(p, "map", fn this, args ->
      {:ta, kind, _, _, _} = d = data!(this)
      make(kind, map_with(values(d), callable!(arg(args, 0)), arg(args, 1)))
    end)

    def_fn(p, "filter", fn this, args ->
      {:ta, kind, _, _, _} = d = data!(this)
      f = callable!(arg(args, 0))

      kept =
        d
        |> values()
        |> Enum.with_index()
        |> Enum.filter(fn {v, i} -> truthy(call(f, arg(args, 1), [v, i * 1.0, this])) end)
        |> Enum.map(&elem(&1, 0))

      make(kind, kept)
    end)

    def_fn(p, "forEach", fn this, args ->
      f = callable!(arg(args, 0))

      for {v, i} <- Enum.with_index(values(data!(this))),
          do: call(f, arg(args, 1), [v, i * 1.0, this])

      :undefined
    end)

    def_fn(p, "reduce", fn this, args -> reduce(this, args, false) end)
    def_fn(p, "reduceRight", fn this, args -> reduce(this, args, true) end)

    def_fn(p, "join", fn this, args ->
      sep = if arg(args, 0) == :undefined, do: ",", else: to_str(arg(args, 0))
      this |> data!() |> values() |> Enum.map_join(sep, &to_str/1)
    end)

    def_fn(p, "toString", fn this, _ ->
      this |> data!() |> values() |> Enum.map_join(",", &to_str/1)
    end)

    def_fn(p, "indexOf", fn this, args ->
      v = arg(args, 0)

      idx =
        this |> data!() |> values() |> Enum.find_index(&strict_eq(&1, v))

      (idx || -1) * 1.0
    end)

    def_fn(p, "lastIndexOf", fn this, args ->
      v = arg(args, 0)

      idx =
        this
        |> data!()
        |> values()
        |> Enum.with_index()
        |> Enum.reverse()
        |> Enum.find_value(fn {x, i} -> if strict_eq(x, v), do: i end)

      (idx || -1) * 1.0
    end)

    def_fn(p, "includes", fn this, args ->
      v = arg(args, 0)

      this
      |> data!()
      |> values()
      |> Enum.any?(fn x -> strict_eq(x, v) or (x == :nan and v == :nan) end)
    end)

    for {name, from_end?, want} <- [
          {"find", false, :value},
          {"findIndex", false, :index},
          {"findLast", true, :value},
          {"findLastIndex", true, :index}
        ] do
      def_fn(p, name, fn this, args ->
        f = callable!(arg(args, 0))
        items = this |> data!() |> values() |> Enum.with_index()
        items = if from_end?, do: Enum.reverse(items), else: items

        found =
          Enum.find(items, fn {v, i} -> truthy(call(f, arg(args, 1), [v, i * 1.0, this])) end)

        case {found, want} do
          {nil, :value} -> :undefined
          {nil, :index} -> -1.0
          {{v, _}, :value} -> v
          {{_, i}, :index} -> i * 1.0
        end
      end)
    end

    def_fn(p, "every", fn this, args ->
      f = callable!(arg(args, 0))

      this
      |> data!()
      |> values()
      |> Enum.with_index()
      |> Enum.all?(fn {v, i} -> truthy(call(f, arg(args, 1), [v, i * 1.0, this])) end)
    end)

    def_fn(p, "some", fn this, args ->
      f = callable!(arg(args, 0))

      this
      |> data!()
      |> values()
      |> Enum.with_index()
      |> Enum.any?(fn {v, i} -> truthy(call(f, arg(args, 1), [v, i * 1.0, this])) end)
    end)

    def_fn(p, "reverse", fn this, _ ->
      d = data!(this)
      items = d |> values() |> Enum.reverse()
      if items != [], do: put_all(d, 0, items)
      this
    end)

    def_fn(p, "toReversed", fn this, _ ->
      {:ta, kind, _, _, _} = d = data!(this)
      make(kind, d |> values() |> Enum.reverse())
    end)

    def_fn(p, "sort", fn this, args ->
      d = data!(this)
      sorted = sorted_values(d, arg(args, 0))
      if sorted != [], do: put_all(d, 0, sorted)
      this
    end)

    def_fn(p, "toSorted", fn this, args ->
      {:ta, kind, _, _, _} = d = data!(this)
      make(kind, sorted_values(d, arg(args, 0)))
    end)

    def_fn(p, "with", fn this, args ->
      {:ta, kind, _, _, len} = d = data!(this)
      n = to_int(arg(args, 0))
      i = if n < 0, do: len + n, else: n
      if i < 0 or i >= len, do: throw_error("RangeError", "Invalid typed array index")
      make(kind, List.replace_at(values(d), i, arg(args, 1)))
    end)

    def_fn(p, "copyWithin", fn this, args ->
      {:ta, _, _, _, len} = d = data!(this)
      target = rel_index(arg(args, 0), len, 0)
      from = rel_index(arg(args, 1), len, 0)
      to = rel_index(arg(args, 2), len, len)
      count = min(to - from, len - target)

      if count > 0 do
        chunk = d |> values() |> Enum.slice(from, count)
        put_all(d, target, chunk)
      end

      this
    end)

    values_fn =
      native("values", fn this, _ ->
        Browser.JS.Collections.make_iterator(this |> data!() |> values())
      end)

    put_hidden(p, "values", values_fn)
    put_hidden(p, {:symbol, :iterator, "Symbol.iterator"}, values_fn)

    def_fn(p, "keys", fn this, _ ->
      n = elem(data!(this), 4)
      Browser.JS.Collections.make_iterator(for i <- 0..(n - 1)//1, do: i * 1.0)
    end)

    def_fn(p, "entries", fn this, _ ->
      items =
        this
        |> data!()
        |> values()
        |> Enum.with_index()
        |> Enum.map(fn {v, i} -> new_array([i * 1.0, v]) end)

      Browser.JS.Collections.make_iterator(items)
    end)
  end

  defp reduce(this, args, from_right?) do
    f = callable!(arg(args, 0))
    items = this |> data!() |> values() |> Enum.with_index()
    items = if from_right?, do: Enum.reverse(items), else: items

    {acc, rest} =
      case {items, length(args)} do
        {_, n} when n >= 2 ->
          {arg(args, 1), items}

        {[{v, _} | tail], _} ->
          {v, tail}

        {[], _} ->
          throw_error("TypeError", "Reduce of empty array with no initial value")
      end

    Enum.reduce(rest, acc, fn {v, i}, a -> call(f, :undefined, [a, v, i * 1.0, this]) end)
  end

  defp sort_compare({:bigint, a}, {:bigint, b}),
    do: if(a < b, do: :lt, else: if(a > b, do: :gt, else: :eq))

  defp sort_compare(a, b) when is_number(a) and a == 0 and is_number(b) and b == 0 do
    case {neg_zero?(a), neg_zero?(b)} do
      {true, false} -> :lt
      {false, true} -> :gt
      _ -> :eq
    end
  end

  defp sort_compare(a, b), do: Num.compare(a, b)

  defp neg_zero?(z), do: match?(<<1::1, _::63>>, <<z * 1.0::float-64>>)

  # the default order is numeric, NaN last
  defp sorted_values(d, cmp) do
    items = values(d)

    cond do
      cmp == :undefined ->
        {nans, nums} = Enum.split_with(items, &(&1 == :nan))
        Enum.sort(nums, fn a, b -> sort_compare(a, b) != :gt end) ++ nans

      true ->
        f = callable!(cmp)

        Enum.sort(items, fn a, b ->
          case to_num(call(f, :undefined, [a, b])) do
            :nan -> true
            n -> Num.compare(n, 0.0) != :gt
          end
        end)
    end
  end

  # ── DataView ───────────────────────────────────────────────

  @dv_types [
    {"Int8", :i8},
    {"Uint8", :u8},
    {"Int16", :i16},
    {"Uint16", :u16},
    {"Int32", :i32},
    {"Uint32", :u32},
    {"Float16", :f16},
    {"Float32", :f32},
    {"Float64", :f64},
    {"BigInt64", :i64},
    {"BigUint64", :u64}
  ]

  defp install_data_view(scope) do
    p = new_object()
    put_proto(:data_view, p)

    ctor =
      native("DataView", fn _, args ->
        buf = arg(args, 0)

        unless buffer?(buf),
          do:
            throw_error(
              "TypeError",
              "First argument to DataView constructor must be an ArrayBuffer"
            )

        off = if arg(args, 1) == :undefined, do: 0, else: to_int(arg(args, 1))

        if off < 0, do: throw_error("RangeError", "Start offset #{off} is outside the bounds")

        if detached?(buffer_id(buf)),
          do: throw_error("TypeError", "cannot construct a DataView on a detached ArrayBuffer")

        total = byte_size(bytes_of(buf))
        len = if arg(args, 2) == :undefined, do: total - off, else: to_int(arg(args, 2))

        if off < 0 or off > total or len < 0 or off + len > total,
          do: throw_error("RangeError", "Start offset #{off} is outside the bounds of the buffer")

        new_host(__MODULE__, {:dv, buffer_id(buf), off, len}, p)
      end)

    put_const(ctor, "prototype", p)
    put_hidden(p, "constructor", ctor)
    put_tag(p, "DataView")
    declare(scope, "DataView", ctor)

    for {name, kind} <- @dv_types do
      size = size_of(kind)

      def_fn(p, "get" <> name, 1, fn this, args ->
        {:dv, bid, off, len} = dv!(this)
        i = dv_toindex(arg(args, 0))
        i = dv_check(i, size, len, bid)
        bin = binary_part(deref(bid).bytes, off + i, size)
        read(kind, if(truthy(arg(args, 1)), do: bin, else: swap(bin)))
      end)

      def_fn(p, "set" <> name, 2, fn this, args ->
        {:dv, bid, off, len} = dv!(this)
        i = dv_toindex(arg(args, 0))
        enc = write(kind, arg(args, 1))
        i = dv_check(i, size, len, bid)
        enc = if truthy(arg(args, 2)), do: enc, else: swap(enc)
        o = deref(bid)
        pos = off + i
        <<pre::binary-size(^pos), _::binary-size(^size), post::binary>> = o.bytes
        store(bid, %{o | bytes: pre <> enc <> post})
        :undefined
      end)
    end
  end

  # multi-byte values are big-endian unless asked otherwise; the codecs are little-endian
  defp swap(bin), do: bin |> :binary.bin_to_list() |> Enum.reverse() |> :binary.list_to_bin()

  defp dv!({:obj, id}) do
    case deref(id) do
      %{host: {__MODULE__, {:dv, _, _, _} = d}} -> d
      _ -> throw_error("TypeError", "this is not a DataView")
    end
  end

  defp dv!(_), do: throw_error("TypeError", "this is not a DataView")

  defp dv_toindex(v) do
    n = to_num(v)
    i = to_int(v)

    if n in [:infinity, :neg_infinity] or i < 0 or i > 9_007_199_254_740_991,
      do: throw_error("RangeError", "Offset is outside the bounds of the DataView")

    i
  end

  # a detached buffer is a TypeError, checked before the range
  defp dv_check(i, size, len, bid) do
    if detached?(bid),
      do: throw_error("TypeError", "cannot perform this operation on a detached ArrayBuffer")

    if i + size > len,
      do: throw_error("RangeError", "Offset is outside the bounds of the DataView")

    i
  end

  # ── TextEncoder / TextDecoder ──────────────────────────────

  defp install_text(scope) do
    ep = new_object()

    enc =
      native("TextEncoder", fn _, _ ->
        o = new_object([], ep)
        put_hidden(o, "encoding", "utf-8")
        o
      end)

    put_const(enc, "prototype", ep)
    put_hidden(ep, "constructor", enc)
    declare(scope, "TextEncoder", enc)

    def_fn(ep, "encode", fn _, args ->
      s = if arg(args, 0) == :undefined, do: "", else: to_str(arg(args, 0))
      make(:u8, :binary.bin_to_list(s))
    end)

    dp = new_object()

    dec =
      native("TextDecoder", fn _, _ ->
        o = new_object([], dp)
        put_hidden(o, "encoding", "utf-8")
        o
      end)

    put_const(dec, "prototype", dp)
    put_hidden(dp, "constructor", dec)
    declare(scope, "TextDecoder", dec)

    def_fn(dp, "decode", fn _, args ->
      case arg(args, 0) do
        :undefined ->
          ""

        src ->
          bytes =
            cond do
              ta?(src) ->
                {:ta, kind, bid, off, len} = data!(src)
                binary_part(deref(bid).bytes, off, len * size_of(kind))

              buffer?(src) ->
                bytes_of(src)

              true ->
                throw_error(
                  "TypeError",
                  "The provided value is not of type '(ArrayBuffer or ArrayBufferView)'"
                )
            end

          bytes |> String.replace_invalid() |> String.replace_prefix("﻿", "")
      end
    end)
  end
end
