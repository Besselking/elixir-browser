defmodule Browser.Wasm.Gc do
  @moduledoc """
  The values of the garbage collection proposal: structures, arrays and `i31` values.

  A structure or an array is a reference with an identity. The struct holds its `id` and the
  key of its defined type; the fields or elements live in the process dictionary as a tuple,
  like the pages of a memory. An `i31` value is `{:i31, n}`. A host value that was converted
  with `any.convert_extern` is `{:ext, value}`. The null reference is `:null`.
  """

  import Bitwise
  alias Browser.Wasm.{Func, Num, Types}

  defmodule Struct do
    @moduledoc false
    defstruct [:id, :key]
  end

  defmodule Array do
    @moduledoc false
    defstruct [:id, :key]
  end

  @max_array 1 <<< 26

  defp trap(msg), do: Num.trap(msg)

  # ── structures ─────────────────────────────────────────────

  def new_struct(key, fields) do
    id = make_ref()
    Process.put({__MODULE__, id}, List.to_tuple(fields))
    %Struct{id: id, key: key}
  end

  def struct_get(:null, _), do: trap("null structure reference")
  def struct_get(%Struct{id: id}, i), do: elem(Process.get({__MODULE__, id}), i)

  def struct_set(:null, _, _), do: trap("null structure reference")

  def struct_set(%Struct{id: id}, i, v),
    do: Process.put({__MODULE__, id}, put_elem(Process.get({__MODULE__, id}), i, v))

  # ── arrays ─────────────────────────────────────────────────

  def new_array(key, list) do
    id = make_ref()
    Process.put({__MODULE__, id}, List.to_tuple(list))
    %Array{id: id, key: key}
  end

  def new_array_of(key, n, v) do
    if n > @max_array, do: trap("out of memory")
    id = make_ref()
    Process.put({__MODULE__, id}, Tuple.duplicate(v, n))
    %Array{id: id, key: key}
  end

  def array_len(:null), do: trap("null array reference")
  def array_len(%Array{id: id}), do: tuple_size(Process.get({__MODULE__, id}))

  def array_get(:null, _), do: trap("null array reference")

  def array_get(%Array{id: id}, i) do
    t = Process.get({__MODULE__, id})
    if i >= tuple_size(t), do: trap("out of bounds array access")
    elem(t, i)
  end

  def array_set(:null, _, _), do: trap("null array reference")

  def array_set(%Array{id: id}, i, v) do
    t = Process.get({__MODULE__, id})
    if i >= tuple_size(t), do: trap("out of bounds array access")
    Process.put({__MODULE__, id}, put_elem(t, i, v))
  end

  def array_fill(:null, _, _, _), do: trap("null array reference")

  def array_fill(%Array{id: id}, i, v, n) do
    t = Process.get({__MODULE__, id})
    if i + n > tuple_size(t), do: trap("out of bounds array access")
    list = Tuple.to_list(t)
    {a, rest} = Enum.split(list, i)
    Process.put({__MODULE__, id}, List.to_tuple(a ++ List.duplicate(v, n) ++ Enum.drop(rest, n)))
  end

  @doc "The elements `[i, i + n)` of an array, as a list."
  def array_slice(:null, _, _), do: trap("null array reference")

  def array_slice(%Array{id: id}, i, n) do
    t = Process.get({__MODULE__, id})
    if i + n > tuple_size(t), do: trap("out of bounds array access")
    t |> Tuple.to_list() |> Enum.slice(i, n)
  end

  @doc "Writes `values` into an array from index `i`."
  def array_write(:null, _, _), do: trap("null array reference")

  def array_write(%Array{id: id}, i, values) do
    t = Process.get({__MODULE__, id})
    n = length(values)
    if i + n > tuple_size(t), do: trap("out of bounds array access")
    list = Tuple.to_list(t)
    {a, rest} = Enum.split(list, i)
    Process.put({__MODULE__, id}, List.to_tuple(a ++ values ++ Enum.drop(rest, n)))
  end

  # ── packed fields ──────────────────────────────────────────

  def pack(v, :i8), do: v &&& 0xFF
  def pack(v, :i16), do: v &&& 0xFFFF
  def pack(v, nil), do: v

  def extend(v, nil), do: v
  def extend(v, {:u, _}), do: v
  def extend(v, {:s, 8}), do: if(v >= 0x80, do: v - 0x100, else: v) &&& 0xFFFFFFFF
  def extend(v, {:s, 16}), do: if(v >= 0x8000, do: v - 0x10000, else: v) &&& 0xFFFFFFFF

  @doc "The size in bytes of an array element stored in a data segment."
  def size(:i8), do: 1
  def size(:i16), do: 2
  def size(t) when t in [:i32, :f32], do: 4
  def size(t) when t in [:i64, :f64], do: 8
  def size(:v128), do: 16

  @doc "Reads one element of the type `st` from the bytes of a data segment."
  def decode(:i8, <<v::8>>), do: v
  def decode(:i16, <<v::little-16>>), do: v
  def decode(:i32, <<v::little-32>>), do: v
  def decode(:i64, <<v::little-64>>), do: v
  def decode(:f32, <<v::little-32>>), do: Num.f32_from_bits(v)
  def decode(:f64, <<v::little-64>>), do: Num.f64_from_bits(v)
  def decode(:v128, <<v::little-128>>), do: v

  # ── i31 ────────────────────────────────────────────────────

  def i31(v), do: {:i31, v &&& 0x7FFFFFFF}
  def i31_get_u(:null), do: trap("null i31 reference")
  def i31_get_u({:i31, v}), do: v

  def i31_get_s(:null), do: trap("null i31 reference")
  def i31_get_s({:i31, v}), do: if(v >= 0x40000000, do: v - 0x80000000, else: v) &&& 0xFFFFFFFF

  # ── instructions that need no instance ─────────────────────

  @doc "Runs a GC instruction on the stack (top first). Returns the new stack."
  def exec({:struct_new, key, packs}, stack) do
    {vals, st} = Enum.split(stack, tuple_size(packs))

    fields =
      vals
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.map(fn {v, i} -> pack(v, elem(packs, i)) end)

    [new_struct(key, fields) | st]
  end

  def exec({:struct_new_default, key, zeros}, st),
    do: [new_struct(key, Tuple.to_list(zeros)) | st]

  def exec({:struct_get, f, ext}, [o | st]), do: [extend(struct_get(o, f), ext) | st]

  def exec({:struct_set, f, pk}, [v, o | st]) do
    struct_set(o, f, pack(v, pk))
    st
  end

  def exec({:array_new, key, pk}, [n, v | st]), do: [new_array_of(key, n, pack(v, pk)) | st]
  def exec({:array_new_default, key, z}, [n | st]), do: [new_array_of(key, n, z) | st]

  def exec({:array_new_fixed, key, pk, n}, stack) do
    {vals, st} = Enum.split(stack, n)
    [new_array(key, vals |> Enum.reverse() |> Enum.map(&pack(&1, pk))) | st]
  end

  def exec({:array_get, ext}, [i, a | st]), do: [extend(array_get(a, i), ext) | st]

  def exec({:array_set, pk}, [v, i, a | st]) do
    array_set(a, i, pack(v, pk))
    st
  end

  def exec(:array_len, [a | st]), do: [array_len(a) | st]

  def exec({:array_fill, pk}, [n, v, i, a | st]) do
    array_fill(a, i, pack(v, pk), n)
    st
  end

  def exec({:array_copy, _}, [n, si, src, di, dst | st]) do
    values = array_slice(src, si, n)
    array_write(dst, di, values)
    st
  end

  def exec(:ref_i31, [v | st]), do: [i31(v) | st]
  def exec(:i31_get_s, [v | st]), do: [i31_get_s(v) | st]
  def exec(:i31_get_u, [v | st]), do: [i31_get_u(v) | st]

  def exec({:ref_test, nullable, ht}, [v | st]),
    do: [if(matches?(v, nullable, ht), do: 1, else: 0) | st]

  def exec({:ref_cast, nullable, ht}, [v | st]) do
    unless matches?(v, nullable, ht), do: trap("cast failure")
    [v | st]
  end

  def exec(:ref_eq, [b, a | st]), do: [if(a == b, do: 1, else: 0) | st]

  def exec(:ref_as_non_null, [v | st]) do
    if v == :null, do: trap("null reference")
    [v | st]
  end

  def exec(:any_convert_extern, [v | st]), do: [internalize(v) | st]
  def exec(:extern_convert_any, [v | st]), do: [externalize(v) | st]

  # a host value in the world of `anyref` is wrapped; an internal value stays as it is
  defp internalize(:null), do: :null
  defp internalize({:i31, _} = v), do: v
  defp internalize(%Struct{} = v), do: v
  defp internalize(%Array{} = v), do: v
  defp internalize({:ext, _} = v), do: v
  defp internalize(v), do: {:ext, v}

  defp externalize({:ext, v}), do: v
  defp externalize(v), do: v

  # ── casts ──────────────────────────────────────────────────

  @doc "Does the reference `v` have the reference type with this nullability and heap type?"
  def matches?(:null, nullable, _), do: nullable
  def matches?(v, _, ht), do: matches_heap?(v, ht)

  defp matches_heap?(_, ht) when ht in [:any, :extern, :exn], do: true
  defp matches_heap?({:i31, _}, ht) when is_atom(ht), do: ht in [:eq, :i31]
  defp matches_heap?(%Struct{}, ht) when is_atom(ht), do: ht in [:eq, :struct]
  defp matches_heap?(%Array{}, ht) when is_atom(ht), do: ht in [:eq, :array]
  defp matches_heap?(%Func{}, :func), do: true
  defp matches_heap?(%Struct{key: k}, {:ct, key}), do: Types.key_sub?(k, key)
  defp matches_heap?(%Array{key: k}, {:ct, key}), do: Types.key_sub?(k, key)
  defp matches_heap?(%Func{ct: k}, {:ct, key}) when k != nil, do: Types.key_sub?(k, key)
  defp matches_heap?(%Func{type: {p, r}}, {:ct, key}), do: Types.comp(key) == {:func, p, r}
  defp matches_heap?(_, _), do: false
end
