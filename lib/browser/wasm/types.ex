defmodule Browser.Wasm.Types do
  @moduledoc """
  The type system of WebAssembly: value types, reference types, heap types and subtyping.

  A value type is `:i32`, `:i64`, `:f32`, `:f64`, `:v128`, or a reference type. The three most
  common reference types keep their short names: `:funcref`, `:externref` and `:exnref`. Any
  other reference type is `{:ref, nullable?, heap_type}`. A heap type is an abstract atom
  (`:func`, `:extern`, `:exn`, `:any`, `:eq`, `:i31`, `:struct`, `:array`, `:none`, `:nofunc`,
  `:noextern`, `:noexn`) or `{:ct, key}`, a defined type.

  A defined type is canonical: its `key` is `{group, index}`, where `group` is a tuple with the
  definitions of the whole recursive group (a reference into the group is `{:rel, index}`) and
  `index` is the position in it. Two types are the same type when the keys are equal. This is
  the iso-recursive equality of the specification, and it works across modules.

  A definition is `{final?, supertypes, composite}` and a composite type is `{:func, params,
  results}`, `{:struct, fields}` or `{:array, field}` (a field is `{storage, mutability}`;
  the storage is a value type, `:i8` or `:i16`; the mutability is `:const` or `:var`).
  """

  @abstract ~w(func extern exn any eq i31 struct array none nofunc noextern noexn)a

  # ── building and taking apart reference types ──────────────

  @doc "The reference type with this nullability and heap type, in its short form if it has one."
  def ref(true, :func), do: :funcref
  def ref(true, :extern), do: :externref
  def ref(true, :exn), do: :exnref
  def ref(nullable, ht), do: {:ref, nullable, ht}

  @doc "`{nullable?, heap_type}` of a reference type."
  def split(:funcref), do: {true, :func}
  def split(:externref), do: {true, :extern}
  def split(:exnref), do: {true, :exn}
  def split({:ref, nullable, ht}), do: {nullable, ht}

  def ref_type?(t) when t in [:funcref, :externref, :exnref], do: true
  def ref_type?({:ref, _, _}), do: true
  def ref_type?(_), do: false

  def nullable?(t), do: elem(split(t), 0)
  def heap(t), do: elem(split(t), 1)

  @doc "The reference type `t` made nullable (or not)."
  def with_null(t, nullable), do: ref(nullable, heap(t))

  def abstract?(ht), do: ht in @abstract

  @doc "Does the type have a default value (everything but a non-nullable reference)?"
  def defaultable?({:ref, false, _}), do: false
  def defaultable?(_), do: true

  # ── definitions ────────────────────────────────────────────

  @doc "The key of the type at `index` of `group`."
  def key(group, index), do: {group, index}

  @doc "The expanded definition `%{final:, supers:, comp:}` of a defined type."
  def definition({:ct, key}), do: definition(key)

  def definition({group, i}) do
    {final, supers, comp} = elem(group, i)
    %{final: final, supers: subst(group, supers), comp: subst(group, comp)}
  end

  @doc "The composite type of a defined type, with its references resolved."
  def comp(ct), do: definition(ct).comp

  # a reference into the group becomes a defined type
  defp subst(group, {:rel, j}), do: {:ct, {group, j}}
  defp subst(_, {:ct, _} = ct), do: ct

  defp subst(group, t) when is_tuple(t),
    do: group |> subst(Tuple.to_list(t)) |> List.to_tuple()

  defp subst(group, l) when is_list(l), do: Enum.map(l, &subst(group, &1))
  defp subst(_, other), do: other

  # ── subtyping ──────────────────────────────────────────────

  @doc "Is value type `a` a subtype of `b`?"
  def sub?(a, a), do: true

  def sub?(a, b) do
    if ref_type?(a) and ref_type?(b) do
      {na, ha} = split(a)
      {nb, hb} = split(b)
      (nb or not na) and heap_sub?(ha, hb)
    else
      false
    end
  end

  @doc "Is heap type `a` a subtype of heap type `b`?"
  def heap_sub?(a, a), do: true

  def heap_sub?({:ct, ka} = a, {:ct, _} = b), do: b in supers_closure(ka) or a == b
  def heap_sub?({:ct, k}, b) when is_atom(b), do: b in abstract_supers(comp(k))
  def heap_sub?(a, {:ct, _} = b) when is_atom(a), do: bottom_of?(a, comp_kind(b))
  def heap_sub?(a, b), do: b in abstract_supers(a)

  # the abstract heap types above a defined or abstract type
  defp abstract_supers({:func, _, _}), do: [:func]
  defp abstract_supers({:struct, _}), do: [:struct, :eq, :any]
  defp abstract_supers({:array, _}), do: [:array, :eq, :any]
  defp abstract_supers(:i31), do: [:eq, :any]
  defp abstract_supers(:struct), do: [:eq, :any]
  defp abstract_supers(:array), do: [:eq, :any]
  defp abstract_supers(:eq), do: [:any]
  defp abstract_supers(:none), do: [:any, :eq, :i31, :struct, :array]
  defp abstract_supers(:nofunc), do: [:func]
  defp abstract_supers(:noextern), do: [:extern]
  defp abstract_supers(:noexn), do: [:exn]
  defp abstract_supers(_), do: []

  defp comp_kind({:ct, k}) do
    case comp(k) do
      {:func, _, _} -> :func
      {:struct, _} -> :struct
      {:array, _} -> :array
    end
  end

  defp bottom_of?(:none, kind), do: kind in [:struct, :array]
  defp bottom_of?(:nofunc, kind), do: kind == :func
  defp bottom_of?(_, _), do: false

  @doc "The defined types a defined type is declared a subtype of, directly or not."
  def supers_closure(key) do
    for {:ct, k} <- definition(key).supers, s <- [{:ct, k} | supers_closure(k)], do: s
  end

  @doc "Do two defined types (keys) match, i.e. is the first a subtype of the second?"
  def key_sub?(a, b), do: a == b or {:ct, b} in supers_closure(a)

  @doc "The top heap type of the hierarchy `ht` is in."
  def top(ht) when ht in [:func, :nofunc], do: :func
  def top(ht) when ht in [:extern, :noextern], do: :extern
  def top(ht) when ht in [:exn, :noexn], do: :exn
  def top(ht) when ht in [:any, :eq, :i31, :struct, :array, :none], do: :any

  def top({:ct, k}) do
    case comp(k) do
      {:func, _, _} -> :func
      _ -> :any
    end
  end

  @doc "The bottom heap type of the hierarchy `ht` is in."
  def bottom(ht) do
    case top(ht) do
      :func -> :nofunc
      :extern -> :noextern
      :exn -> :noexn
      :any -> :none
    end
  end

  @doc "Do the two reference types share a hierarchy (a cast between them is valid)?"
  def same_hierarchy?(a, b), do: top(heap(a)) == top(heap(b))

  # ── subtype declarations ───────────────────────────────────

  @doc """
  Does the field list / composite type `sub` match the composite type `super`, for a declared
  subtype? (Function parameters are contravariant, results and immutable fields covariant,
  mutable fields invariant.)
  """
  def comp_match?({:func, p1, r1}, {:func, p2, r2}) do
    length(p1) == length(p2) and length(r1) == length(r2) and
      Enum.all?(Enum.zip(p2, p1), fn {a, b} -> sub?(a, b) end) and
      Enum.all?(Enum.zip(r1, r2), fn {a, b} -> sub?(a, b) end)
  end

  def comp_match?({:struct, f1}, {:struct, f2}) do
    length(f1) >= length(f2) and
      Enum.all?(Enum.zip(Enum.take(f1, length(f2)), f2), fn {a, b} -> field_match?(a, b) end)
  end

  def comp_match?({:array, a}, {:array, b}), do: field_match?(a, b)
  def comp_match?(_, _), do: false

  defp field_match?({s1, :const}, {s2, :const}), do: storage_sub?(s1, s2)
  defp field_match?({s1, :var}, {s2, :var}), do: storage_eq?(s1, s2)
  defp field_match?(_, _), do: false

  defp storage_sub?(a, b) when a in [:i8, :i16] or b in [:i8, :i16], do: a == b
  defp storage_sub?(a, b), do: sub?(a, b)

  defp storage_eq?(a, b), do: a == b or (a not in [:i8, :i16] and sub?(a, b) and sub?(b, a))
end
