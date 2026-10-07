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

  defp new_buffer(bytes, max \\ nil) do
    {:obj, id} = buf = new_object([], proto(:arraybuffer))
    o = Map.put(deref(id), :bytes, bytes)
    store(id, if(max, do: Map.put(o, :max, max), else: o))
    buf
  end

  defp resizable?(bid), do: Map.has_key?(deref(bid), :max)

  @doc "A `Uint8Array` over an immutable ArrayBuffer of `bytes` (the value of a bytes module)."
  def bytes_view(bytes) do
    buf = new_buffer(bytes)
    store(buffer_id(buf), Map.put(deref(buffer_id(buf)), :immutable, true))
    view(:u8, buffer_id(buf), 0, byte_size(bytes))
  end

  defp immutable?(bid), do: Map.get(deref(bid), :immutable, false)

  # a typed array whose buffer can be written to
  defp mut!({:ta, _, bid, _, _} = d) do
    if immutable?(bid), do: throw_error("TypeError", "the typed array's buffer is immutable")
    d
  end

  @doc "Detaches an ArrayBuffer (`$262.detachArrayBuffer`): it loses its bytes and its views read as empty."
  def detach({:obj, id} = buf) do
    unless ab?(buf), do: throw_error("TypeError", "not an ArrayBuffer")
    store(id, deref(id) |> Map.put(:bytes, <<>>) |> Map.put(:detached, true))
    :undefined
  end

  defp detached?(bid), do: Map.get(deref(bid), :detached, false)

  defp buffer?({:obj, id}), do: Map.has_key?(deref(id), :bytes)
  defp buffer?(_), do: false

  # an ArrayBuffer (not a SharedArrayBuffer)
  defp ab?({:obj, id}) do
    o = deref(id)
    Map.has_key?(o, :bytes) and not Map.has_key?(o, :shared)
  end

  defp ab?(_), do: false

  defp sab?({:obj, id}) do
    o = deref(id)
    Map.has_key?(o, :bytes) and Map.has_key?(o, :shared)
  end

  defp sab?(_), do: false

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

  # the offset and length a view has now (`:oob` when a detached or shrunk buffer leaves it
  # out of bounds); a length-tracking view (`:auto`) follows the buffer's size
  defp eff({:ta, kind, bid, off, len}) do
    o = deref(bid)
    total = byte_size(o.bytes)

    cond do
      Map.get(o, :detached, false) -> :oob
      len == :auto -> if off > total, do: :oob, else: {off, div(total - off, size_of(kind))}
      off + len * size_of(kind) > total -> :oob
      true -> {off, len}
    end
  end

  defp data!({:obj, id}) do
    case deref(id) do
      %{host: {__MODULE__, {:ta, kind, bid, _, _} = d}} ->
        case eff(d) do
          :oob ->
            throw_error(
              "TypeError",
              "cannot perform this operation on a detached or out of bounds typed array"
            )

          {off, len} ->
            {:ta, kind, bid, off, len}
        end

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

  # the elements of a typed array read one at a time, as late as possible: a callback that
  # resizes the buffer shows up as `undefined` for the elements that are gone
  defp live_values(this) do
    {:ta, kind, bid, _, n} = data!(this)
    {:obj, id} = this
    %{host: {__MODULE__, d0}} = deref(id)
    size = size_of(kind)

    Stream.map(0..(n - 1)//1, fn i ->
      case eff(d0) do
        {off, len} when i < len ->
          read(kind, binary_part(deref(bid).bytes, off + i * size, size))

        _ ->
          :undefined
      end
    end)
  end

  # element `i` as the typed array is now, or `:undefined` past its current length
  defp ta_at(this, i) do
    {:obj, id} = this
    %{host: {__MODULE__, {:ta, kind, bid, _, _} = d0}} = deref(id)
    size = size_of(kind)

    case eff(d0) do
      {off, len} when i >= 0 and i < len ->
        read(kind, binary_part(deref(bid).bytes, off + i * size, size))

      _ ->
        :undefined
    end
  end

  # ToIntegerOrInfinity: an integer, or :infinity / :neg_infinity
  defp int_or_inf(v) do
    case to_num(v) do
      n when n in [:infinity, :neg_infinity] -> n
      :nan -> 0
      n -> trunc(n)
    end
  end

  defp present?(this, i) do
    {:obj, id} = this
    %{host: {__MODULE__, d0}} = deref(id)

    case eff(d0) do
      {_, len} -> i < len
      :oob -> false
    end
  end

  # `{value, index}` pairs, ascending or descending, read one at a time
  defp live_pairs(this, dir \\ :asc) do
    {:ta, kind, bid, _, n} = data!(this)
    {:obj, id} = this
    %{host: {__MODULE__, d0}} = deref(id)
    size = size_of(kind)
    range = if dir == :asc, do: 0..(n - 1)//1, else: (n - 1)..0//-1

    Stream.map(range, fn i ->
      v =
        case eff(d0) do
          {off, len} when i < len ->
            read(kind, binary_part(deref(bid).bytes, off + i * size, size))

          _ ->
            :undefined
        end

      {v, i}
    end)
  end

  defp put_elem_at({:ta, kind, bid, off, _}, i, value) do
    size = size_of(kind)
    o = deref(bid)
    pos = off + i * size
    <<pre::binary-size(^pos), _::binary-size(^size), post::binary>> = o.bytes
    store(bid, %{o | bytes: pre <> write(kind, value) <> post})
    :ok
  end

  defp put_bytes_at({:ta, kind, bid, _, _} = d, i, bytes) do
    {off, _} = eff(d)
    size = size_of(kind)
    o = deref(bid)
    pos = off + i * size
    <<pre::binary-size(^pos), _::binary-size(^size), post::binary>> = o.bytes
    store(bid, %{o | bytes: pre <> bytes <> post})
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

  # the integer indices of the elements there are now
  def host_keys({:ta, _, _, _, _} = d) do
    case eff(d),
      do: (
        :oob -> []
        {_, len} -> for(i <- 0..(len - 1)//1, do: Integer.to_string(i))
      )
  end

  def host_keys(_), do: []

  @doc false
  def host_get({:ta, kind, bid, _, _} = d0, key, _self) when is_binary(key) do
    {off, len} =
      case eff(d0),
        do: (
          :oob -> {0, 0}
          r -> r
        )

    d = {:ta, kind, bid, off, len}

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
        case canonical(key) do
          {:index, i} when i < len -> {:ok, elem_at(d, i)}
          :none -> :miss
          _ -> {:ok, :undefined}
        end
    end
  end

  def host_get(_, _, _), do: :miss

  # CanonicalNumericIndexString: `{:index, i}` for a non-negative integer key, `:invalid` for any
  # other canonical number ("-0", "1.5", "-1", "Infinity", "NaN"), `:none` for every other key
  defp canonical("-0"), do: :invalid

  defp canonical(key) do
    case Integer.parse(key) do
      {i, ""} when i >= 0 and i <= 9_007_199_254_740_991 ->
        if Integer.to_string(i) == key, do: {:index, i}, else: other_canonical(key)

      _ ->
        other_canonical(key)
    end
  end

  defp other_canonical(key) do
    if key in ["Infinity", "-Infinity", "NaN"] or
         (Regex.match?(~r/\A-?[0-9.e+-]+\z/, key) and to_str(to_num(key)) == key),
       do: :invalid,
       else: :none
  end

  @doc false
  def host_put({:ta, kind, bid, _, _} = d0, key, v, _self) when is_binary(key) do
    case canonical(key) do
      :none ->
        :miss

      c ->
        # the value is converted first, whatever the index
        bytes = write(kind, v)

        case {c, eff(d0)} do
          {{:index, i}, {off, len}} when i < len ->
            if immutable?(bid) do
              :readonly
            else
              size = size_of(kind)
              o = deref(bid)
              pos = off + i * size
              <<pre::binary-size(^pos), _::binary-size(^size), post::binary>> = o.bytes
              store(bid, %{o | bytes: pre <> bytes <> post})
              :ok
            end

          _ ->
            :ok
        end
    end
  end

  def host_put(_, _, _, _), do: :miss

  @doc false
  # a canonical numeric key that is no index of this typed array (nothing can be set there)
  def invalid_index?({:obj, id}, key) when is_binary(key) do
    case deref(id) do
      %{host: {__MODULE__, {:ta, _, _, _, _} = d}} ->
        case {canonical(key), eff(d)} do
          {:none, _} -> false
          {{:index, i}, {_, len}} -> i >= len
          _ -> true
        end

      _ ->
        false
    end
  end

  def invalid_index?(_, _), do: false

  @doc false
  def typed_array?(v), do: ta?(v)

  @doc false
  # a typed array that a detached or shrunk buffer has left out of bounds
  def out_of_bounds?({:obj, id} = v) do
    ta?(v) and
      (
        %{host: {_, d}} = deref(id)
        eff(d) == :oob
      )
  end

  def out_of_bounds?(_), do: false

  @doc false
  def numeric_key?(key), do: is_binary(key) and canonical(key) != :none

  @doc false
  def host_has({:ta, _, _, _, _} = d, key) when is_binary(key) do
    case {canonical(key), eff(d)} do
      {{:index, i}, {_, len}} -> i < len
      _ -> false
    end
  end

  def host_has(d, key), do: match?({:ok, v} when v != :undefined, host_get(d, key, nil))

  @doc false
  def host_delete({:ta, _, _, _, _} = d, key) when is_binary(key) do
    case canonical(key) do
      :none ->
        :default

      {:index, i} ->
        case eff(d) do
          {_, len} when i < len -> false
          _ -> true
        end

      :invalid ->
        true
    end
  end

  def host_delete(_, _), do: :default

  @doc false
  # an element as an own property: writable, enumerable and configurable
  def property({:ta, kind, bid, _, _} = d, key) when is_binary(key) do
    case {canonical(key), eff(d)} do
      {{:index, i}, {off, len}} when i < len ->
        {:data, elem_at({:ta, kind, bid, off, len}, i), true, true, true}

      _ ->
        nil
    end
  end

  def property(_, _), do: nil

  @doc false
  # `Object.defineProperty` on an element: it can only be given as a plain value
  def define_own({:ta, kind, _, _, _} = d, key, desc) when is_binary(key) do
    case canonical(key) do
      :none ->
        :ordinary

      c ->
        valid? =
          match?({:index, _}, c) and
            case {c, eff(d)} do
              {{:index, i}, {_, len}} -> i < len
              _ -> false
            end

        ok? =
          valid? and Map.get(desc, :configurable) != false and Map.get(desc, :enumerable) != false and
            not (Map.has_key?(desc, :get) or Map.has_key?(desc, :set)) and
            Map.get(desc, :writable) != false

        unless ok?, do: throw_error("TypeError", "Cannot redefine property: #{key}")

        if Map.has_key?(desc, :value) do
          bytes = write(kind, desc.value)

          with {:index, i} <- c,
               {off, len} when i < len <- eff(d) do
            {:ta, _, bid, _, _} = d

            if immutable?(bid),
              do: throw_error("TypeError", "the typed array's buffer is immutable")

            size = size_of(kind)
            o = deref(bid)
            pos = off + i * size
            <<pre::binary-size(^pos), _::binary-size(^size), post::binary>> = o.bytes
            store(bid, %{o | bytes: pre <> bytes <> post})
          end
        end

        :ok
    end
  end

  def define_own(_, _, _), do: :ordinary

  # the ArrayBuffer object a view was made on (each view of one buffer shares it)
  defp buffer_object(bid), do: {:obj, bid}

  # ── install ────────────────────────────────────────────────

  def install(scope) do
    install_buffer(scope)
    install_shared_buffer(scope)
    install_atomics(scope)
    install_typed_arrays(scope)
    install_data_view(scope)
    install_text(scope)
    :ok
  end

  defp install_buffer(scope) do
    p = new_object()
    put_proto(:arraybuffer, p)

    ctor =
      native("ArrayBuffer", fn this, args ->
        unless match?({:obj, _}, this),
          do: throw_error("TypeError", "Constructor ArrayBuffer requires 'new'")

        n = to_index(arg(args, 0))

        max =
          case arg(args, 1) do
            {:obj, _} = opts ->
              case Interp.get(opts, "maxByteLength") do
                :undefined -> nil
                v -> to_index(v)
              end

            _ ->
              nil
          end

        if max && n > max, do: throw_error("RangeError", "Invalid array buffer max length")

        if max && max > 1_000_000_000_000,
          do: throw_error("RangeError", "Array buffer allocation failed")

        if n > 1_000_000_000, do: throw_error("RangeError", "Array buffer allocation failed")
        new_buffer(:binary.copy(<<0>>, n), max)
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
        native("get byteLength", fn this, _ ->
          unless ab?(this), do: throw_error("TypeError", "not an ArrayBuffer")
          byte_size(bytes_of(this)) * 1.0
        end),
      enumerable: false
    )

    Props.define_accessor(p, "resizable",
      get:
        native("get resizable", fn this, _ ->
          unless ab?(this), do: throw_error("TypeError", "not an ArrayBuffer")
          resizable?(buffer_id(this))
        end),
      enumerable: false
    )

    Props.define_accessor(p, "maxByteLength",
      get:
        native("get maxByteLength", fn this, _ ->
          unless ab?(this), do: throw_error("TypeError", "not an ArrayBuffer")
          bid = buffer_id(this)
          o = deref(bid)

          cond do
            Map.get(o, :detached, false) -> 0.0
            true -> Map.get(o, :max, byte_size(o.bytes)) * 1.0
          end
        end),
      enumerable: false
    )

    resize =
      native("resize", fn this, args ->
        unless ab?(this), do: throw_error("TypeError", "not an ArrayBuffer")
        bid = buffer_id(this)
        unless resizable?(bid), do: throw_error("TypeError", "ArrayBuffer is not resizable")
        n = to_index(arg(args, 0))
        o = deref(bid)

        if Map.get(o, :detached, false),
          do: throw_error("TypeError", "cannot resize a detached ArrayBuffer")

        if n > o.max, do: throw_error("RangeError", "Invalid array buffer length")
        bytes = o.bytes

        bytes =
          if n <= byte_size(bytes),
            do: binary_part(bytes, 0, n),
            else: bytes <> :binary.copy(<<0>>, n - byte_size(bytes))

        store(bid, %{o | bytes: bytes})
        :undefined
      end)

    {:obj, rid} = resize
    store(rid, Map.put(deref(rid), :arity, 1.0))
    put_hidden(p, "resize", resize)

    Props.define_accessor(p, "immutable",
      get:
        native("get immutable", fn this, _ ->
          unless ab?(this), do: throw_error("TypeError", "not an ArrayBuffer")
          immutable?(buffer_id(this))
        end),
      enumerable: false
    )

    Props.define_accessor(p, "detached",
      get:
        native("get detached", fn this, _ ->
          unless ab?(this), do: throw_error("TypeError", "not an ArrayBuffer")
          detached?(buffer_id(this))
        end),
      enumerable: false
    )

    # transfer(newLength) / transferToFixedLength(newLength): the bytes move to a new buffer
    # (cut or zero-padded to the length) and this one is detached
    for name <- ["transfer", "transferToFixedLength", "transferToImmutable"] do
      f =
        native(name, fn this, args ->
          unless ab?(this), do: throw_error("TypeError", "not an ArrayBuffer")

          len =
            case arg(args, 0) do
              :undefined -> byte_size(bytes_of(this))
              v -> to_index(v)
            end

          if detached?(buffer_id(this)),
            do: throw_error("TypeError", "cannot transfer a detached ArrayBuffer")

          if immutable?(buffer_id(this)),
            do: throw_error("TypeError", "cannot transfer an immutable ArrayBuffer")

          bytes = bytes_of(this)

          moved =
            if len <= byte_size(bytes),
              do: binary_part(bytes, 0, len),
              else: bytes <> :binary.copy(<<0>>, len - byte_size(bytes))

          max = if name == "transfer", do: Map.get(deref(buffer_id(this)), :max)

          if max && len > max, do: throw_error("RangeError", "Invalid array buffer length")
          buf = new_buffer(moved, max)

          if name == "transferToImmutable",
            do: store(buffer_id(buf), Map.put(deref(buffer_id(buf)), :immutable, true))

          detach(this)
          buf
        end)

      {:obj, fid} = f
      store(fid, Map.put(deref(fid), :arity, 0.0))
      put_hidden(p, name, f)
    end

    def_fn(p, "slice", 2, fn this, args ->
      unless ab?(this), do: throw_error("TypeError", "not an ArrayBuffer")

      if detached?(buffer_id(this)),
        do: throw_error("TypeError", "cannot slice a detached ArrayBuffer")

      slice_buffer(this, args, :arraybuffer, &ab?/1, &new_buffer(&1, nil))
    end)

    def_fn(p, "sliceToImmutable", 2, fn this, args ->
      unless ab?(this), do: throw_error("TypeError", "not an ArrayBuffer")

      if detached?(buffer_id(this)),
        do: throw_error("TypeError", "cannot slice a detached ArrayBuffer")

      len = byte_size(bytes_of(this))
      from = rel_index(arg(args, 0), len, 0)
      to = rel_index(arg(args, 1), len, len)

      if detached?(buffer_id(this)),
        do: throw_error("TypeError", "cannot slice a detached ArrayBuffer")

      n = max(to - from, 0)
      bytes = bytes_of(this)

      if byte_size(bytes) < from + n, do: throw_error("RangeError", "slice is out of bounds")

      buf = new_buffer(binary_part(bytes, from, n))
      store(buffer_id(buf), Map.put(deref(buffer_id(buf)), :immutable, true))
      buf
    end)

    put_tag(p, "ArrayBuffer")
  end

  # TypedArraySpeciesCreate: a typed array from `this.constructor[@@species]` (or the
  # intrinsic constructor), checked to be a typed array of the same content type, and at least
  # as long as the length asked for
  defp species_create(this, kind, args) do
    default = proto({:ta_ctor, kind})
    c = Interp.get(this, "constructor")

    ctor =
      case c do
        :undefined ->
          default

        {:obj, _} ->
          case Interp.get(c, {:symbol, :species, "Symbol.species"}) do
            s when s in [:undefined, :null] -> default
            s -> s
          end

        _ ->
          throw_error("TypeError", "object.constructor is not an object")
      end

    unless Interp.constructor?(ctor), do: throw_error("TypeError", "species is not a constructor")

    result = typed_array_create(ctor, args)
    {:ta, rkind, _, _, _} = data!(result)

    if kind in [:i64, :u64] != rkind in [:i64, :u64],
      do: throw_error("TypeError", "species created a typed array of another content type")

    result
  end

  # TypedArrayCreateFromConstructor: `new ctor(...args)` must be a typed array (in bounds), and
  # at least as long as the length asked for
  defp typed_array_create(ctor, args) do
    result = construct(ctor, args)
    {:ta, _, _, _, rlen} = d = data!(result)
    # (a result that is written to must not sit on an immutable buffer; `subarray` just shares)
    if match?([_], args), do: mut!(d)

    case args do
      [n] when is_float(n) ->
        if rlen < n, do: throw_error("TypeError", "created a typed array that is too short")

      _ ->
        :ok
    end

    result
  end

  # ── SharedArrayBuffer and Atomics ──────────────────────────

  defp new_shared(bytes, max) do
    {:obj, id} = buf = new_object([], proto(:sharedarraybuffer))
    o = deref(id) |> Map.put(:bytes, bytes) |> Map.put(:shared, true)
    store(id, if(max, do: Map.put(o, :max, max), else: o))
    buf
  end

  defp install_shared_buffer(scope) do
    p = new_object()
    put_proto(:sharedarraybuffer, p)

    ctor =
      native("SharedArrayBuffer", fn this, args ->
        unless match?({:obj, _}, this),
          do: throw_error("TypeError", "Constructor SharedArrayBuffer requires 'new'")

        n = to_index(arg(args, 0))

        max =
          case arg(args, 1) do
            {:obj, _} = opts ->
              case Interp.get(opts, "maxByteLength") do
                :undefined -> nil
                v -> to_index(v)
              end

            _ ->
              nil
          end

        if max && n > max, do: throw_error("RangeError", "Invalid array buffer max length")

        if max && max > 1_000_000_000_000,
          do: throw_error("RangeError", "Array buffer allocation failed")

        if n > 1_000_000_000, do: throw_error("RangeError", "Array buffer allocation failed")
        new_shared(:binary.copy(<<0>>, n), max)
      end)

    put_const(ctor, "prototype", p)
    put_hidden(p, "constructor", ctor)
    declare(scope, "SharedArrayBuffer", ctor)
    def_species(ctor)

    shared! = fn this ->
      unless sab?(this), do: throw_error("TypeError", "not a SharedArrayBuffer")
      deref(buffer_id(this))
    end

    getter = fn name, fun ->
      Props.define_accessor(p, name,
        get: native("get " <> name, fn this, _ -> fun.(shared!.(this)) end),
        enumerable: false
      )
    end

    getter.("byteLength", fn o -> byte_size(o.bytes) * 1.0 end)
    getter.("growable", fn o -> Map.has_key?(o, :max) end)
    getter.("maxByteLength", fn o -> Map.get(o, :max, byte_size(o.bytes)) * 1.0 end)

    def_fn(p, "grow", 1, fn this, args ->
      o = shared!.(this)

      unless Map.has_key?(o, :max),
        do: throw_error("TypeError", "SharedArrayBuffer is not growable")

      n = to_index(arg(args, 0))

      if n > o.max or n < byte_size(o.bytes),
        do: throw_error("RangeError", "Invalid array buffer length")

      store(buffer_id(this), %{o | bytes: o.bytes <> :binary.copy(<<0>>, n - byte_size(o.bytes))})
      :undefined
    end)

    def_fn(p, "slice", 2, fn this, args ->
      shared!.(this)
      slice_buffer(this, args, :sharedarraybuffer, &sab?/1, &new_shared(&1, nil))
    end)

    put_tag(p, "SharedArrayBuffer")
  end

  # `slice` of either buffer: a new buffer from the species constructor (`new`: the plain one)
  defp slice_buffer(this, args, kind, kind?, plain) do
    len = byte_size(bytes_of(this))
    from = rel_index(arg(args, 0), len, 0)
    to = rel_index(arg(args, 1), len, len)
    n = max(to - from, 0)
    default = Interp.get(proto(kind), "constructor")
    c = Interp.get(this, "constructor")

    species =
      case c do
        :undefined ->
          default

        {:obj, _} ->
          case Interp.get(c, {:symbol, :species, "Symbol.species"}) do
            s when s in [:undefined, :null] -> default
            s -> s
          end

        _ ->
          throw_error("TypeError", "object.constructor is not an object")
      end

    unless Interp.constructor?(species),
      do: throw_error("TypeError", "species is not a constructor")

    result =
      if species == default do
        plain.(binary_part(bytes_of(this), from, n))
      else
        r = construct(species, [n * 1.0])
        unless kind?.(r), do: throw_error("TypeError", "species did not create a buffer")

        if detached?(buffer_id(r)),
          do: throw_error("TypeError", "species created a detached buffer")

        if r == this, do: throw_error("TypeError", "species returned the same buffer")

        if immutable?(buffer_id(r)),
          do: throw_error("TypeError", "species created an immutable buffer")

        if byte_size(bytes_of(r)) < n,
          do: throw_error("TypeError", "species created a buffer that is too small")

        # (the source may have shrunk or detached meanwhile)
        src = bytes_of(this)
        from = min(from, byte_size(src))
        chunk = binary_part(src, from, min(n, byte_size(src) - from))
        o = deref(buffer_id(r))
        size = byte_size(chunk)
        <<_::binary-size(^size), rest::binary>> = o.bytes
        store(buffer_id(r), %{o | bytes: chunk <> rest})
        r
      end

    result
  end

  defp waiters, do: Process.get(:js_waiters) || []

  @atomic_kinds [:i8, :u8, :i16, :u16, :i32, :u32, :i64, :u64]

  defp install_atomics(scope) do
    atomics = new_object()
    declare(scope, "Atomics", atomics)
    put_tag(atomics, "Atomics")

    # the typed array (an integer one; for wait and notify an Int32Array or BigInt64Array)
    validate = fn ta, waitable? ->
      d = data!(ta)
      {:ta, kind, _, _, _} = d
      kinds = if waitable?, do: [:i32, :i64], else: @atomic_kinds

      unless kind in kinds,
        do: throw_error("TypeError", "invalid typed array type for this Atomics operation")

      d
    end

    index = fn {:ta, _, _, _, len}, idx ->
      i = to_index(idx)
      if i >= len, do: throw_error("RangeError", "Atomics index out of range"), else: i
    end

    # the value as the element type holds it: an integer (a BigInt for the 64-bit kinds)
    operand = fn kind, v ->
      if kind in [:i64, :u64] do
        {:bigint, n} = Browser.JS.BigInt.to_bigint(v)
        n
      else
        int_or_inf(v)
      end
    end

    num = fn
      {:bigint, n} -> n
      n -> trunc(n)
    end

    modify = fn name, fun ->
      def_fn(atomics, name, 3, fn _, args ->
        ta = arg(args, 0)
        d = validate.(ta, false) |> mut!()
        i = index.(d, arg(args, 1))
        {:ta, kind, _, _, _} = d
        v = operand.(kind, arg(args, 2))
        d = data!(ta)
        i = index.(d, i * 1.0)
        old = elem_at(d, i)
        v = if is_integer(v), do: v, else: 0
        new = fun.(num.(old), v)
        put_elem_at(d, i, if(kind in [:i64, :u64], do: {:bigint, new}, else: new * 1.0))
        old
      end)
    end

    modify.("add", &(&1 + &2))
    modify.("sub", &(&1 - &2))
    modify.("and", &Bitwise.band/2)
    modify.("or", &Bitwise.bor/2)
    modify.("xor", &Bitwise.bxor/2)
    modify.("exchange", fn _, v -> v end)

    def_fn(atomics, "compareExchange", 4, fn _, args ->
      ta = arg(args, 0)
      d = validate.(ta, false) |> mut!()
      i = index.(d, arg(args, 1))
      {:ta, kind, _, _, _} = d
      expected = operand.(kind, arg(args, 2))
      replacement = operand.(kind, arg(args, 3))
      d = data!(ta)
      i = index.(d, i * 1.0)
      old = elem_at(d, i)
      expected = if is_integer(expected), do: expected, else: 0
      replacement = if is_integer(replacement), do: replacement, else: 0

      as_kind = fn n ->
        read(kind, write(kind, if(kind in [:i64, :u64], do: {:bigint, n}, else: n * 1.0)))
      end

      if as_kind.(expected) == old,
        do:
          put_elem_at(
            d,
            i,
            if(kind in [:i64, :u64], do: {:bigint, replacement}, else: replacement * 1.0)
          )

      old
    end)

    def_fn(atomics, "pause", 0, fn _, args ->
      n = arg(args, 0)

      unless n == :undefined or (is_number(n) and n == trunc(n)),
        do: throw_error("TypeError", "Atomics.pause: argument must be an integral number")

      :undefined
    end)

    def_fn(atomics, "load", 2, fn _, args ->
      ta = arg(args, 0)
      d = validate.(ta, false)
      i = index.(d, arg(args, 1))
      d = data!(ta)
      elem_at(d, index.(d, i * 1.0))
    end)

    def_fn(atomics, "store", 3, fn _, args ->
      ta = arg(args, 0)
      d = validate.(ta, false) |> mut!()
      i = index.(d, arg(args, 1))
      {:ta, kind, _, _, _} = d
      v = operand.(kind, arg(args, 2))
      d = data!(ta)
      i = index.(d, i * 1.0)

      case v do
        n when kind in [:i64, :u64] ->
          put_elem_at(d, i, {:bigint, n})
          {:bigint, n}

        n when is_integer(n) ->
          put_elem_at(d, i, n * 1.0)
          n * 1.0

        inf ->
          put_elem_at(d, i, 0.0)
          if inf == :infinity, do: :infinity, else: :neg_infinity
      end
    end)

    def_fn(atomics, "isLockFree", 1, fn _, args ->
      int_or_inf(arg(args, 0)) in [1, 2, 4, 8]
    end)

    # the shared part of `wait` and `waitAsync`: the element's byte position and whether the
    # value the caller expects is still there
    wait_args = fn args ->
      ta = arg(args, 0)
      d = validate.(ta, true)
      {:ta, kind, bid, off, _} = d

      unless Map.has_key?(deref(bid), :shared),
        do: throw_error("TypeError", "not a shared typed array")

      i = index.(d, arg(args, 1))

      v =
        if kind == :i64,
          do: elem(Browser.JS.BigInt.to_bigint(arg(args, 2)), 1),
          else: to_integer(arg(args, 2))

      timeout =
        case to_num(arg(args, 3)) do
          :nan -> :infinity
          :neg_infinity -> 0
          :infinity -> :infinity
          n -> max(n, 0)
        end

      cur = num.(elem_at(d, i))
      as_kind = read(kind, write(kind, if(kind == :i64, do: {:bigint, v}, else: v * 1.0)))
      {bid, off + i * size_of(kind), timeout, num.(as_kind) == cur}
    end

    def_fn(atomics, "wait", 4, fn _, args ->
      {_, _, _, equal?} = wait_args.(args)

      if Process.get(:js_cannot_block, false),
        do: throw_error("TypeError", "Atomics.wait cannot block this thread")

      # (nothing can notify: a wait that finds its value just times out)
      if equal?, do: "timed-out", else: "not-equal"
    end)

    def_fn(atomics, "waitAsync", 4, fn _, args ->
      {bid, pos, timeout, equal?} = wait_args.(args)
      res = new_object()

      cond do
        not equal? ->
          Interp.put(res, "async", false)
          Interp.put(res, "value", "not-equal")

        timeout == 0 ->
          Interp.put(res, "async", false)
          Interp.put(res, "value", "timed-out")

        true ->
          p = Browser.JS.Promise.new()
          seq = (Process.get(:js_waiter_seq) || 0) + 1
          Process.put(:js_waiter_seq, seq)

          timer =
            if timeout != :infinity do
              Browser.JS.Builtins.add_timer(
                native("", fn _, _ ->
                  if Enum.any?(waiters(), &(&1.seq == seq)) do
                    Process.put(:js_waiters, Enum.reject(waiters(), &(&1.seq == seq)))
                    Browser.JS.Promise.resolve(p, "timed-out")
                  end

                  :undefined
                end),
                timeout * 1.0
              )
            end

          Process.put(
            :js_waiters,
            waiters() ++ [%{seq: seq, key: {bid, pos}, p: p, timer: timer}]
          )

          Interp.put(res, "async", true)
          Interp.put(res, "value", p)
      end

      res
    end)

    def_fn(atomics, "notify", 3, fn _, args ->
      d = validate.(arg(args, 0), true)
      i = index.(d, arg(args, 1))
      {:ta, kind, bid, off, _} = d

      count =
        case arg(args, 2) do
          :undefined ->
            :infinity

          c ->
            with n when is_integer(n) <- int_or_inf(c),
                 do: max(n, 0),
                 else: (_ -> if c == :neg_infinity, do: 0, else: :infinity)
        end

      key = {bid, off + i * size_of(kind)}
      {here, rest} = Enum.split_with(waiters(), &(&1.key == key))
      woken = if count == :infinity, do: here, else: Enum.take(here, count)
      keep = Enum.reject(here, &(&1 in woken))
      Process.put(:js_waiters, Enum.filter(waiters(), &(&1 in rest or &1 in keep)))

      for w <- woken do
        if w.timer, do: Browser.JS.Builtins.clear_timer(w.timer)
        Browser.JS.Promise.enqueue(fn -> Browser.JS.Promise.resolve(w.p, "ok") end)
      end

      length(woken) * 1.0
    end)

    :ok
  end

  # length, byteLength, byteOffset, buffer and @@toStringTag are getters on %TypedArray%.prototype
  defp install_ta_accessors(base) do
    getter = fn name, f ->
      Props.define_accessor(base, name,
        get:
          native("get " <> to_string(name), fn this, _ ->
            unless ta?(this), do: throw_error("TypeError", "this is not a typed array")
            {:obj, id} = this
            %{host: {__MODULE__, {:ta, _, bid, _, _} = d}} = deref(id)
            f.(d, detached?(bid))
          end),
        enumerable: false
      )
    end

    getter.("length", fn d, _ ->
      case eff(d),
        do: (
          :oob -> 0.0
          {_, len} -> len * 1.0
        )
    end)

    getter.("byteLength", fn {:ta, kind, _, _, _} = d, _ ->
      case eff(d),
        do: (
          :oob -> 0.0
          {_, len} -> len * size_of(kind) * 1.0
        )
    end)

    getter.("byteOffset", fn d, _ ->
      case eff(d),
        do: (
          :oob -> 0.0
          {off, _} -> off * 1.0
        )
    end)

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

  # relative index with infinities
  defp rel_index_inf(:undefined, _len, default), do: default

  defp rel_index_inf(v, len, _default) do
    case int_or_inf(v) do
      :neg_infinity -> 0
      :infinity -> len
      n when n < 0 -> max(len + n, 0)
      n -> min(n, len)
    end
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
        native(name, fn this, args ->
          unless match?({:obj, _}, this),
            do: throw_error("TypeError", "Constructor #{name} requires 'new'")

          build(kind, args)
        end)

      {:obj, cid} = ctor
      store(cid, Map.merge(deref(cid), %{proto: base_ctor, arity: 3.0}))
      put_proto({:ta_ctor, kind}, ctor)
      put_const(ctor, "prototype", p)
      put_hidden(p, "constructor", ctor)
      put_const(ctor, "BYTES_PER_ELEMENT", size * 1.0)
      put_const(p, "BYTES_PER_ELEMENT", size * 1.0)
      declare(scope, name, ctor)
    end

    install_u8_encoding()

    # %TypedArray%.from and .of build an instance of whatever constructor they are called on
    def_fn(base_ctor, "from", 1, fn this, args ->
      unless Interp.constructor?(this), do: throw_error("TypeError", "this is not a constructor")
      f = arg(args, 1)
      if f != :undefined, do: callable!(f)
      src = arg(args, 0)

      iterator =
        if nullish?(src),
          do: throw_error("TypeError", "Cannot convert undefined or null to object"),
          else: Interp.get(src, {:symbol, :iterator, "Symbol.iterator"})

      cond do
        nullish?(iterator) ->
          # the result is constructed before any element of an array-like source is read
          n = if match?({:obj, _}, src), do: to_int(Interp.get(src, "length")), else: 0
          if n > 100_000_000, do: throw_error("RangeError", "Invalid typed array length: #{n}")
          target = typed_array_create(this, [n * 1.0])

          for k <- 0..(n - 1)//1 do
            v = Interp.get(src, Integer.to_string(k))
            mapped = if f == :undefined, do: v, else: call(f, arg(args, 2), [v, k * 1.0])
            Interp.put(target, k, mapped)
          end

          target

        function?(iterator) ->
          list = Interp.iterate_with(src, iterator)
          target = typed_array_create(this, [length(list) * 1.0])

          for {v, k} <- Enum.with_index(list) do
            mapped = if f == :undefined, do: v, else: call(f, arg(args, 2), [v, k * 1.0])
            Interp.put(target, k, mapped)
          end

          target

        true ->
          throw_error("TypeError", "Symbol.iterator is not a function")
      end
    end)

    def_fn(base_ctor, "of", 0, fn this, args ->
      unless Interp.constructor?(this), do: throw_error("TypeError", "this is not a constructor")
      target = typed_array_create(this, [length(args) * 1.0])
      for {v, k} <- Enum.with_index(args), do: Interp.put(target, k, v)
      target
    end)
  end

  # Uint8Array.fromBase64/fromHex and the prototype's toBase64/toHex/setFromBase64/setFromHex
  defp install_u8_encoding do
    ctor = proto({:ta_ctor, :u8})
    p = proto({:ta, :u8})
    max = 9_007_199_254_740_991

    str! = fn s ->
      unless is_binary(s), do: throw_error("TypeError", "argument must be a string")
      s
    end

    options! = fn o ->
      cond do
        o == :undefined -> nil
        match?({:obj, _}, o) -> o
        true -> throw_error("TypeError", "options must be an object")
      end
    end

    option = fn o, key, default, allowed ->
      v = if o == nil, do: :undefined, else: Interp.get(o, key)

      cond do
        v == :undefined -> default
        is_binary(v) and v in allowed -> v
        true -> throw_error("TypeError", "invalid #{key} option")
      end
    end

    decode_opts = fn o ->
      o = options!.(o)
      alphabet = option.(o, "alphabet", "base64", ["base64", "base64url"])
      last = option.(o, "lastChunkHandling", "loose", ["loose", "strict", "stop-before-partial"])
      {alphabet, last}
    end

    u8! = fn this ->
      case this do
        {:obj, id} ->
          case deref(id) do
            %{host: {__MODULE__, {:ta, :u8, _, _, _}}} -> this
            _ -> throw_error("TypeError", "this is not a Uint8Array")
          end

        _ ->
          throw_error("TypeError", "this is not a Uint8Array")
      end
    end

    from_bytes = fn bytes -> make(:u8, for(<<b <- bytes>>, do: b * 1.0)) end

    set_bytes = fn this, status, read, bytes ->
      {:ta, _, bid, off, _} = data!(this)
      o = deref(bid)
      n = byte_size(bytes)
      <<pre::binary-size(^off), _::binary-size(^n), post::binary>> = o.bytes
      store(bid, %{o | bytes: pre <> bytes <> post})
      if status == :error, do: throw_error("SyntaxError", "invalid input")
      res = new_object()
      Interp.put(res, "read", read * 1.0)
      Interp.put(res, "written", n * 1.0)
      res
    end

    def_fn(ctor, "fromBase64", 1, fn _, args ->
      s = str!.(arg(args, 0))
      {alphabet, last} = decode_opts.(arg(args, 1))

      case Browser.JS.BinaryEncoding.decode_base64(s, alphabet, last, max) do
        {:ok, _, bytes} -> from_bytes.(bytes)
        {:error, _, _} -> throw_error("SyntaxError", "invalid base64 string")
      end
    end)

    def_fn(ctor, "fromHex", 1, fn _, args ->
      s = str!.(arg(args, 0))

      case Browser.JS.BinaryEncoding.decode_hex(s, max) do
        {:ok, _, bytes} -> from_bytes.(bytes)
        {:error, _, _} -> throw_error("SyntaxError", "invalid hex string")
      end
    end)

    def_fn(p, "toBase64", 0, fn this, args ->
      u8!.(this)
      o = options!.(arg(args, 0))
      alphabet = option.(o, "alphabet", "base64", ["base64", "base64url"])
      omit = if o == nil, do: false, else: truthy(Interp.get(o, "omitPadding"))
      {:ta, _, _, _, _} = d = data!(this)
      Browser.JS.BinaryEncoding.encode_base64(u8_bytes(d), alphabet, omit)
    end)

    def_fn(p, "toHex", 0, fn this, _ ->
      u8!.(this)
      {:ta, _, _, _, _} = d = data!(this)
      Browser.JS.BinaryEncoding.encode_hex(u8_bytes(d))
    end)

    def_fn(p, "setFromBase64", 1, fn this, args ->
      u8!.(this)
      mut!(data!(this))
      s = str!.(arg(args, 0))
      {alphabet, last} = decode_opts.(arg(args, 1))
      {:ta, _, _, _, len} = data!(this)
      {status, read, bytes} = Browser.JS.BinaryEncoding.decode_base64(s, alphabet, last, len)
      set_bytes.(this, status, read, bytes)
    end)

    def_fn(p, "setFromHex", 1, fn this, args ->
      u8!.(this)
      mut!(data!(this))
      s = str!.(arg(args, 0))
      {:ta, _, _, _, len} = data!(this)
      {status, read, bytes} = Browser.JS.BinaryEncoding.decode_hex(s, len)
      set_bytes.(this, status, read, bytes)
    end)
  end

  defp u8_bytes({:ta, _, bid, off, len}), do: binary_part(deref(bid).bytes, off, len)

  # `new Int8Array(length | buffer, byteOffset, length | typedArray | iterable | array-like)`
  defp build(kind, args) do
    size = size_of(kind)

    case arg(args, 0) do
      {:obj, _} = src ->
        if buffer?(src),
          do: build_view(kind, size, src, args),
          else: make(kind, source_values(src))

      n ->
        len = to_index(n)
        if len > 100_000_000, do: throw_error("RangeError", "Invalid typed array length: #{len}")
        buf = new_buffer(:binary.copy(<<0>>, len * size))
        view(kind, buffer_id(buf), 0, len)
    end
  end

  defp build_view(kind, size, src, args) do
    off = to_index(arg(args, 1))

    if rem(off, size) != 0,
      do: throw_error("RangeError", "start offset of #{kind} should be a multiple of #{size}")

    new_len = if arg(args, 2) == :undefined, do: :undefined, else: to_index(arg(args, 2))
    if detached?(buffer_id(src)), do: throw_error("TypeError", "ArrayBuffer is detached")
    total = byte_size(bytes_of(src))

    len =
      cond do
        new_len == :undefined and resizable?(buffer_id(src)) ->
          if off > total, do: throw_error("RangeError", "Start offset is outside the bounds")
          :auto

        new_len == :undefined ->
          if rem(total, size) != 0,
            do:
              throw_error(
                "RangeError",
                "byte length of #{kind} should be a multiple of #{size}"
              )

          if off > total, do: throw_error("RangeError", "Start offset is outside the bounds")
          div(total - off, size)

        true ->
          new_len
      end

    if len != :auto and off + len * size > total,
      do: throw_error("RangeError", "Invalid typed array length")

    view(kind, buffer_id(src), off, len)
  end

  # the values of a typed array, iterable or array-like
  defp source_values(src) do
    cond do
      ta?(src) ->
        values(data!(src))

      match?({:obj, _}, src) ->
        case Interp.get(src, {:symbol, :iterator, "Symbol.iterator"}) do
          f when f in [:undefined, :null] ->
            array_like(src)

          f ->
            if function?(f),
              do:
                if(Interp.array_iteration_pristine?(src),
                  do: iterate(src),
                  else: Interp.iterate_protocol_list(src)
                ),
              else: throw_error("TypeError", "Symbol.iterator is not a function")
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
      {:ta, _, _, _, len} = data!(this)

      case int_or_inf(arg(args, 0)) do
        :infinity -> :undefined
        :neg_infinity -> :undefined
        i -> ta_at(this, if(i < 0, do: len + i, else: i))
      end
    end)

    def_fn(p, "fill", fn this, args ->
      {:ta, kind, _, _, len} = data!(this) |> mut!()

      value =
        if kind in [:i64, :u64],
          do: Browser.JS.BigInt.to_bigint(arg(args, 0)),
          else: to_num(arg(args, 0))

      from = rel_index_inf(arg(args, 1), len, 0)
      to = rel_index_inf(arg(args, 2), len, len)
      {:ta, _, _, _, len2} = d = data!(this)
      to = min(to, len2)
      if to > from, do: put_all(d, from, List.duplicate(value, to - from))
      this
    end)

    def_fn(p, "set", 1, fn this, args ->
      unless ta?(this), do: throw_error("TypeError", "this is not a typed array")
      {:obj, tid} = this
      %{host: {__MODULE__, {:ta, kind, _, _, _} = d0}} = deref(tid)
      mut!(d0)
      src = arg(args, 0)

      off =
        case int_or_inf(arg(args, 1)) do
          :infinity -> :infinity
          :neg_infinity -> -1
          n -> n
        end

      if off != :infinity and off < 0, do: throw_error("RangeError", "offset is out of bounds")

      target_len =
        case eff(d0) do
          :oob ->
            throw_error(
              "TypeError",
              "cannot perform this operation on a detached or out of bounds typed array"
            )

          {_, n} ->
            n
        end

      if ta?(src) do
        {:ta, skind, _, _, slen} = sd = data!(src)

        if off == :infinity or off + slen > target_len,
          do: throw_error("RangeError", "offset is out of bounds")

        if kind in [:i64, :u64] != skind in [:i64, :u64],
          do: throw_error("TypeError", "Cannot mix BigInt and other types")

        {:ta, _, _, _, _} = td = data!(this)
        if slen > 0, do: put_all(td, off, values(sd))
      else
        if nullish?(src),
          do: throw_error("TypeError", "Cannot convert undefined or null to object")

        n = to_int(Interp.get(src, "length"))

        if off == :infinity or off + n > target_len,
          do: throw_error("RangeError", "offset is out of bounds")

        for i <- 0..(n - 1)//1 do
          bytes = write(kind, Interp.get(src, Integer.to_string(i)))

          case eff(d0) do
            {_, len} when off + i < len -> put_bytes_at(d0, off + i, bytes)
            _ -> :ok
          end
        end
      end

      :undefined
    end)

    def_fn(p, "subarray", 2, fn this, args ->
      unless ta?(this), do: throw_error("TypeError", "this is not a typed array")
      {:obj, id} = this
      %{host: {__MODULE__, {:ta, kind, bid, off0, len0} = d0}} = deref(id)

      src_len =
        case eff(d0),
          do: (
            :oob -> 0
            {_, n} -> n
          )

      from = rel_index_inf(arg(args, 0), src_len, 0)
      size = size_of(kind)
      begin = (off0 + from * size) * 1.0

      if len0 == :auto and arg(args, 1) == :undefined do
        species_create(this, kind, [buffer_object(bid), begin])
      else
        to = rel_index_inf(arg(args, 1), src_len, src_len)
        species_create(this, kind, [buffer_object(bid), begin, max(to - from, 0) * 1.0])
      end
    end)

    def_fn(p, "slice", 2, fn this, args ->
      {:ta, kind, _, _, len} = data!(this)
      from = rel_index_inf(arg(args, 0), len, 0)
      to = rel_index_inf(arg(args, 1), len, len)
      count = max(to - from, 0)
      zero = if kind in [:i64, :u64], do: {:bigint, 0}, else: 0.0
      result = species_create(this, kind, [count * 1.0])

      if count > 0 do
        data!(this)

        for {i, n} <- Enum.with_index(from..(from + count - 1)//1) do
          Interp.put(result, n, if(present?(this, i), do: ta_at(this, i), else: zero))
        end
      end

      result
    end)

    def_fn(p, "map", 1, fn this, args ->
      {:ta, kind, _, _, len} = data!(this)
      f = callable!(arg(args, 0))
      result = species_create(this, kind, [len * 1.0])

      for {{v, i}, n} <- Stream.with_index(live_pairs(this)) do
        Interp.put(result, n, call(f, arg(args, 1), [v, i * 1.0, this]))
      end

      result
    end)

    def_fn(p, "filter", 1, fn this, args ->
      {:ta, kind, _, _, _} = data!(this)
      f = callable!(arg(args, 0))

      kept =
        live_pairs(this)
        |> Enum.filter(fn {v, i} -> truthy(call(f, arg(args, 1), [v, i * 1.0, this])) end)
        |> Enum.map(&elem(&1, 0))

      result = species_create(this, kind, [length(kept) * 1.0])
      for {v, n} <- Enum.with_index(kept), do: Interp.put(result, n, v)
      result
    end)

    def_fn(p, "forEach", fn this, args ->
      f = callable!(arg(args, 0))

      for {v, i} <- live_pairs(this),
          do: call(f, arg(args, 1), [v, i * 1.0, this])

      :undefined
    end)

    def_fn(p, "reduce", fn this, args -> reduce(this, args, false) end)
    def_fn(p, "reduceRight", fn this, args -> reduce(this, args, true) end)

    def_fn(p, "join", fn this, args ->
      {:ta, _, _, _, len} = data!(this)
      sep = if arg(args, 0) == :undefined, do: ",", else: to_str(arg(args, 0))
      join_elems(this, len, sep, &to_str/1)
    end)

    put_hidden(p, "toString", Interp.get(proto(:array), "toString"))

    def_fn(p, "toLocaleString", fn this, _ ->
      {:ta, _, _, _, len} = data!(this)

      join_elems(this, len, ",", fn
        v when v in [:undefined, :null] -> ""
        v -> to_str(call(Interp.get(v, "toLocaleString"), v, []))
      end)
    end)

    def_fn(p, "indexOf", fn this, args ->
      {:ta, _, _, _, len} = data!(this)
      v = arg(args, 0)

      if len == 0 do
        -1.0
      else
        case int_or_inf(arg(args, 1)) do
          :infinity ->
            -1.0

          n ->
            k = if n == :neg_infinity, do: 0, else: if(n >= 0, do: n, else: max(len + n, 0))

            found =
              Enum.find(k..(len - 1)//1, fn i ->
                present?(this, i) and strict_eq(ta_at(this, i), v)
              end)

            (found || -1) * 1.0
        end
      end
    end)

    def_fn(p, "lastIndexOf", fn this, args ->
      {:ta, _, _, _, len} = data!(this)
      v = arg(args, 0)

      if len == 0 do
        -1.0
      else
        n = if length(args) > 1, do: int_or_inf(arg(args, 1)), else: len - 1

        k =
          case n do
            :neg_infinity -> -1
            :infinity -> len - 1
            n when n >= 0 -> min(n, len - 1)
            n -> len + n
          end

        found =
          Enum.find(k..0//-1, fn i -> present?(this, i) and strict_eq(ta_at(this, i), v) end)

        (found || -1) * 1.0
      end
    end)

    def_fn(p, "includes", fn this, args ->
      {:ta, _, _, _, len} = data!(this)
      v = arg(args, 0)

      if len == 0 do
        false
      else
        case int_or_inf(arg(args, 1)) do
          :infinity ->
            false

          n ->
            k = if n == :neg_infinity, do: 0, else: if(n >= 0, do: n, else: max(len + n, 0))

            Enum.any?(k..(len - 1)//1, fn i ->
              x = ta_at(this, i)
              strict_eq(x, v) or (x == :nan and v == :nan)
            end)
        end
      end
    end)

    for {name, from_end?, want} <- [
          {"find", false, :value},
          {"findIndex", false, :index},
          {"findLast", true, :value},
          {"findLastIndex", true, :index}
        ] do
      def_fn(p, name, fn this, args ->
        f = callable!(arg(args, 0))
        items = live_pairs(this, if(from_end?, do: :desc, else: :asc))

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

      live_pairs(this)
      |> Enum.all?(fn {v, i} -> truthy(call(f, arg(args, 1), [v, i * 1.0, this])) end)
    end)

    def_fn(p, "some", fn this, args ->
      f = callable!(arg(args, 0))

      live_pairs(this)
      |> Enum.any?(fn {v, i} -> truthy(call(f, arg(args, 1), [v, i * 1.0, this])) end)
    end)

    def_fn(p, "reverse", fn this, _ ->
      d = data!(this) |> mut!()
      items = live_values(this) |> Enum.reverse()
      if items != [], do: put_all(d, 0, items)
      this
    end)

    def_fn(p, "toReversed", fn this, _ ->
      {:ta, kind, _, _, _} = data!(this)
      make(kind, live_values(this) |> Enum.reverse())
    end)

    def_fn(p, "sort", fn this, args ->
      d = data!(this) |> mut!()
      sorted = sorted_values(d, arg(args, 0))
      {:obj, tid} = this
      %{host: {__MODULE__, d0}} = deref(tid)

      # the comparator may have detached or shrunk the buffer: write back what still exists
      case eff(d0) do
        {off, len} when sorted != [] and len > 0 ->
          {:ta, kind, bid, _, _} = d0
          put_all({:ta, kind, bid, off, len}, 0, Enum.take(sorted, len))

        _ ->
          :ok
      end

      this
    end)

    def_fn(p, "toSorted", 1, fn this, args ->
      {:ta, kind, _, _, _} = d = data!(this)
      make(kind, sorted_values(d, arg(args, 0)))
    end)

    def_fn(p, "with", fn this, args ->
      {:ta, kind, _, _, len} = data!(this)

      k =
        case int_or_inf(arg(args, 0)) do
          n when n in [:infinity, :neg_infinity] -> -1
          n when n < 0 -> len + n
          n -> n
        end

      value =
        if kind in [:i64, :u64],
          do: Browser.JS.BigInt.to_bigint(arg(args, 1)),
          else: to_num(arg(args, 1))

      unless present?(this, k) and k >= 0,
        do: throw_error("RangeError", "Invalid typed array index")

      make(kind, for(i <- 0..(len - 1)//1, do: if(i == k, do: value, else: ta_at(this, i))))
    end)

    def_fn(p, "copyWithin", fn this, args ->
      {:ta, _, _, _, len} = data!(this) |> mut!()
      target = rel_index_inf(arg(args, 0), len, 0)
      from = rel_index_inf(arg(args, 1), len, 0)
      to = rel_index_inf(arg(args, 2), len, len)
      {:ta, _, _, _, len2} = d = data!(this)
      count = min(to - from, len - target) |> min(len2 - from) |> min(len2 - target)

      if count > 0 do
        chunk = d |> values() |> Enum.slice(from, count)
        put_all(d, target, chunk)
      end

      this
    end)

    values_fn = native("values", fn this, _ -> ta_iterator(this, :values) end)

    put_hidden(p, "values", values_fn)
    put_hidden(p, {:symbol, :iterator, "Symbol.iterator"}, values_fn)
    def_fn(p, "keys", fn this, _ -> ta_iterator(this, :keys) end)
    def_fn(p, "entries", fn this, _ -> ta_iterator(this, :entries) end)
  end

  # an iterator that looks at the typed array each time: an array that shrank out of bounds is a
  # TypeError, one that grew yields the new elements, and one that ended stays ended
  defp ta_iterator(this, what) do
    {:ta, kind, bid, _, _} = data!(this)
    {:obj, id} = this
    %{host: {__MODULE__, d0}} = deref(id)
    size = size_of(kind)
    pos = make_ref()
    Process.put(pos, 0)

    step = fn ->
      i = Process.get(pos)

      result =
        if i == :done do
          :done
        else
          case eff(d0) do
            :oob ->
              throw_error(
                "TypeError",
                "cannot perform this operation on a detached or out of bounds typed array"
              )

            {off, len} when i < len ->
              Process.put(pos, i + 1)

              case what do
                :keys ->
                  {:ok, i * 1.0}

                :values ->
                  {:ok, read(kind, binary_part(deref(bid).bytes, off + i * size, size))}

                :entries ->
                  v = read(kind, binary_part(deref(bid).bytes, off + i * size, size))
                  {:ok, new_array([i * 1.0, v])}
              end

            _ ->
              Process.put(pos, :done)
              :done
          end
        end

      case result do
        {:ok, v} -> new_object([{"value", v}, {"done", false}])
        :done -> new_object([{"value", :undefined}, {"done", true}])
      end
    end

    Browser.JS.Collections.array_iterator(step)
  end

  defp join_elems(this, len, sep, to_s) do
    Enum.map_join(0..(len - 1)//1, sep, fn i ->
      case ta_at(this, i) do
        :undefined -> to_s.(:undefined) |> then(&if(&1 == "undefined", do: "", else: &1))
        v -> to_s.(v)
      end
    end)
  end

  defp reduce(this, args, from_right?) do
    f = callable!(arg(args, 0))
    items = live_pairs(this, if(from_right?, do: :desc, else: :asc))

    {acc, rest} =
      case {Enum.take(items, 1), length(args)} do
        {_, n} when n >= 2 ->
          {arg(args, 1), items}

        {[{v, _}], _} ->
          {v, Stream.drop(items, 1)}

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
      native("DataView", fn this, args ->
        unless match?({:obj, _}, this),
          do: throw_error("TypeError", "Constructor DataView requires 'new'")

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

        len =
          cond do
            arg(args, 2) != :undefined -> to_index(arg(args, 2))
            resizable?(buffer_id(buf)) -> :auto
            true -> total - off
          end

        if off < 0 or off > total or (len != :auto and (len < 0 or off + len > total)),
          do: throw_error("RangeError", "Start offset #{off} is outside the bounds of the buffer")

        new_host(__MODULE__, {:dv, buffer_id(buf), off, len}, p)
      end)

    put_const(ctor, "prototype", p)
    put_hidden(p, "constructor", ctor)
    put_tag(p, "DataView")
    declare(scope, "DataView", ctor)

    dv! = fn this ->
      case this do
        {:obj, id} ->
          case deref(id) do
            %{host: {__MODULE__, {:dv, _, _, _} = d}} -> d
            _ -> throw_error("TypeError", "this is not a DataView")
          end

        _ ->
          throw_error("TypeError", "this is not a DataView")
      end
    end

    Props.define_accessor(p, "buffer",
      get: native("get buffer", fn this, _ -> buffer_object(elem(dv!.(this), 1)) end),
      enumerable: false
    )

    Props.define_accessor(p, "byteLength",
      get:
        native("get byteLength", fn this, _ ->
          {_, _, _, len} = dv_eff!(dv!.(this))
          len * 1.0
        end),
      enumerable: false
    )

    Props.define_accessor(p, "byteOffset",
      get:
        native("get byteOffset", fn this, _ ->
          {_, _, off, _} = dv_eff!(dv!.(this))
          off * 1.0
        end),
      enumerable: false
    )

    for {name, kind} <- @dv_types do
      size = size_of(kind)

      def_fn(p, "get" <> name, 1, fn this, args ->
        d = dv!(this)
        i = dv_toindex(arg(args, 0))
        {:dv, bid, off, len} = dv_eff!(d)
        i = dv_check(i, size, len, bid)
        bin = binary_part(deref(bid).bytes, off + i, size)
        read(kind, if(truthy(arg(args, 1)), do: bin, else: swap(bin)))
      end)

      def_fn(p, "set" <> name, 2, fn this, args ->
        d = dv!(this)

        if immutable?(elem(d, 1)),
          do: throw_error("TypeError", "the DataView's buffer is immutable")

        i = dv_toindex(arg(args, 0))
        enc = write(kind, arg(args, 1))
        {:dv, bid, off, len} = dv_eff!(d)
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

  # the view's offset and length now; a detached buffer or one that shrank under it is a TypeError
  defp dv_eff!({:dv, bid, off, len}) do
    o = deref(bid)
    total = byte_size(o.bytes)

    cond do
      Map.get(o, :detached, false) ->
        throw_error("TypeError", "cannot perform this operation on a detached ArrayBuffer")

      len == :auto and off > total ->
        throw_error("TypeError", "DataView is out of bounds")

      len == :auto ->
        {:dv, bid, off, total - off}

      off + len > total ->
        throw_error("TypeError", "DataView is out of bounds")

      true ->
        {:dv, bid, off, len}
    end
  end

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
