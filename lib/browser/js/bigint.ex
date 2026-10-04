defmodule Browser.JS.BigInt do
  @moduledoc """
  BigInt for the JavaScript runtime. A BigInt is `{:bigint, integer}`: the language's
  arbitrary-precision integers are Elixir's own. The operators call `arith/3`, `compare/2` and
  `loose_eq/2` from `Browser.JS.Interp`; this module also installs `BigInt` and its prototype.
  """

  import Bitwise
  import Browser.JS.Interp, except: [get: 2, put: 3, loose_eq: 2]
  alias Browser.JS.Interp

  defp arg(args, i), do: Enum.at(args, i, :undefined)

  @mix_error "Cannot mix BigInt and other types, use explicit conversions"

  @doc "A binary operator with at least one BigInt operand (both must be)."
  def arith(op, {:bigint, x}, {:bigint, y}) do
    {:bigint,
     case op do
       "+" -> x + y
       "-" -> x - y
       "*" -> x * y
       "/" -> if y == 0, do: throw_error("RangeError", "Division by zero"), else: div(x, y)
       "%" -> if y == 0, do: throw_error("RangeError", "Division by zero"), else: rem(x, y)
       "**" -> pow(x, y)
       "&" -> x &&& y
       "|" -> x ||| y
       "^" -> bxor(x, y)
       "<<" -> shift_left(x, y)
       ">>" -> shift_left(x, -y)
       ">>>" -> throw_error("TypeError", "BigInts have no unsigned right shift, use >> instead")
     end}
  end

  def arith(_, _, _), do: throw_error("TypeError", @mix_error)

  defp pow(_x, y) when y < 0, do: throw_error("RangeError", "Exponent must be non-negative")

  defp pow(x, y) when y > 10_000_000 and abs(x) > 1,
    do: throw_error("RangeError", "Maximum BigInt size exceeded")

  defp pow(x, y), do: Integer.pow(x, y)

  defp shift_left(x, n) when n >= 0 and n > 1_000_000_000,
    do: if(x == 0, do: 0, else: throw_error("RangeError", "Maximum BigInt size exceeded"))

  defp shift_left(x, n) when n >= 0, do: x <<< n
  defp shift_left(x, n), do: x >>> -n

  @doc "Abstract relational comparison where an operand is a BigInt: `:lt`, `:gt`, `:eq` or `:nan`."
  def compare({:bigint, x}, {:bigint, y}), do: cmp(x, y)

  def compare({:bigint, x}, b) when is_binary(b) do
    case parse(b) do
      {:ok, y} -> cmp(x, y)
      :error -> :nan
    end
  end

  def compare(a, {:bigint, y}) when is_binary(a) do
    case parse(a) do
      {:ok, x} -> cmp(x, y)
      :error -> :nan
    end
  end

  def compare({:bigint, x}, b), do: compare_num(x, to_num(b))

  def compare(a, {:bigint, y}) do
    case compare_num(y, to_num(a)) do
      :lt -> :gt
      :gt -> :lt
      other -> other
    end
  end

  defp compare_num(_x, :nan), do: :nan
  defp compare_num(_x, :infinity), do: :lt
  defp compare_num(_x, :neg_infinity), do: :gt
  defp compare_num(x, f), do: cmp(x, f)

  defp cmp(a, b) when a < b, do: :lt
  defp cmp(a, b) when a > b, do: :gt
  defp cmp(_, _), do: :eq

  @doc "`==` where an operand is a BigInt."
  def loose_eq({:bigint, x}, {:bigint, y}), do: x == y

  def loose_eq({:bigint, x}, b) when is_binary(b), do: match?({:ok, ^x}, parse(b))
  def loose_eq(a, {:bigint, y}) when is_binary(a), do: match?({:ok, ^y}, parse(a))
  def loose_eq({:bigint, _} = a, b) when is_boolean(b), do: loose_eq(a, to_num(b))
  def loose_eq(a, {:bigint, _} = b) when is_boolean(a), do: loose_eq(to_num(a), b)

  def loose_eq({:bigint, _} = a, b) when is_number(b) or b in [:nan, :infinity, :neg_infinity],
    do: compare(a, b) == :eq

  def loose_eq(a, {:bigint, _} = b) when is_number(a) or a in [:nan, :infinity, :neg_infinity],
    do: compare(a, b) == :eq

  def loose_eq({:bigint, _} = a, {:obj, _} = b), do: loose_eq(a, to_primitive(b, "default"))
  def loose_eq({:obj, _} = a, {:bigint, _} = b), do: loose_eq(to_primitive(a, "default"), b)
  def loose_eq(_, _), do: false

  @doc "StringToBigInt: `{:ok, integer}` or `:error`."
  def parse(s) do
    s = Interp.js_trim(s)

    case s do
      "" ->
        {:ok, 0}

      <<?0, x, digits::binary>> when x in [?x, ?X, ?o, ?O, ?b, ?B] ->
        base = %{?x => 16, ?X => 16, ?o => 8, ?O => 8, ?b => 2, ?B => 2}[x]
        radix_parse(digits, base)

      <<sign, digits::binary>> when sign in [?+, ?-] ->
        with {:ok, n} <- radix_parse(digits, 10), do: {:ok, if(sign == ?-, do: -n, else: n)}

      _ ->
        radix_parse(s, 10)
    end
  end

  defp radix_parse("", _), do: :error

  defp radix_parse(digits, base) do
    case Integer.parse(digits, base) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  @doc "`Number(value)` of a BigInt: the nearest double, infinite when out of range."
  def to_float(n) when abs(n) > 1.7976931348623157e308 * 1_000_000_000_000_000,
    do: if(n > 0, do: :infinity, else: :neg_infinity)

  def to_float(n) do
    float(n)
  rescue
    ArithmeticError -> if n > 0, do: :infinity, else: :neg_infinity
  end

  defp float(n), do: n * 1.0

  @doc "ToBigInt."
  def to_bigint(v) do
    case to_primitive(v, "number") do
      {:bigint, _} = b ->
        b

      true ->
        {:bigint, 1}

      false ->
        {:bigint, 0}

      s when is_binary(s) ->
        case parse(s) do
          {:ok, n} -> {:bigint, n}
          :error -> throw_error("SyntaxError", "Cannot convert #{s} to a BigInt")
        end

      p ->
        throw_error("TypeError", "Cannot convert #{inspect_prim(p)} to a BigInt")
    end
  end

  defp inspect_prim({:symbol, _, _}), do: "a Symbol"
  defp inspect_prim(p), do: to_str(p)

  # ToIndex
  defp to_index(:undefined), do: 0

  defp to_index(v) do
    n = to_int(v)

    if n < 0 or n > 9_007_199_254_740_991,
      do: throw_error("RangeError", "Invalid value: not (convertible to) a safe integer"),
      else: n
  end

  defp this_bigint({:bigint, _} = b), do: b

  defp this_bigint({:obj, id}) do
    case deref(id) do
      %{prim: {:bigint, _} = b} -> b
      _ -> throw_error("TypeError", "BigInt.prototype method requires that 'this' be a BigInt")
    end
  end

  defp this_bigint(_),
    do: throw_error("TypeError", "BigInt.prototype method requires that 'this' be a BigInt")

  def install(scope) do
    p = new_object()
    put_proto(:bigint, p)

    ctor =
      native("BigInt", fn this, args ->
        # `new BigInt(...)`: the fresh object has BigInt.prototype
        if match?({:obj, _}, this) and Interp.get(this, "constructor") == lookup_ctor(),
          do: throw_error("TypeError", "BigInt is not a constructor")

        v = to_primitive(arg(args, 0), "number")

        case v do
          n when is_number(n) ->
            if n == trunc(n),
              do: {:bigint, trunc(n)},
              else:
                throw_error(
                  "RangeError",
                  "The number #{to_str(n)} cannot be converted to a BigInt because it is not an integer"
                )

          n when n in [:nan, :infinity, :neg_infinity] ->
            throw_error(
              "RangeError",
              "The number #{to_str(n)} cannot be converted to a BigInt because it is not an integer"
            )

          other ->
            to_bigint(other)
        end
      end)
      |> with_length(1)

    put_const(ctor, "prototype", p)
    put_hidden(p, "constructor", ctor)
    :erlang.put(:js_bigint_ctor, ctor)
    declare(scope, "BigInt", ctor)

    put_hidden(
      ctor,
      "asIntN",
      with_length(
        native("asIntN", fn _, args ->
          bits = to_index(arg(args, 0))
          {:bigint, n} = to_bigint(arg(args, 1))
          {:bigint, as_int(n, bits)}
        end),
        2
      )
    )

    put_hidden(
      ctor,
      "asUintN",
      with_length(
        native("asUintN", fn _, args ->
          bits = to_index(arg(args, 0))
          {:bigint, n} = to_bigint(arg(args, 1))
          {:bigint, n &&& (1 <<< bits) - 1}
        end),
        2
      )
    )

    put_hidden(
      p,
      "toString",
      native("toString", fn this, args ->
        {:bigint, n} = this_bigint(this)

        radix =
          case arg(args, 0) do
            :undefined -> 10
            r -> to_int(r)
          end

        if radix < 2 or radix > 36,
          do: throw_error("RangeError", "toString() radix must be between 2 and 36")

        n |> Integer.to_string(radix) |> String.downcase()
      end)
    )

    put_hidden(
      p,
      "toLocaleString",
      native("toLocaleString", fn this, _ ->
        {:bigint, n} = this_bigint(this)
        Integer.to_string(n)
      end)
    )

    put_hidden(p, "valueOf", native("valueOf", fn this, _ -> this_bigint(this) end))
    put_tag(p, "BigInt")
    :ok
  end

  defp lookup_ctor, do: :erlang.get(:js_bigint_ctor)

  defp as_int(_n, 0), do: 0

  defp as_int(n, bits) do
    m = n &&& (1 <<< bits) - 1
    if m >= 1 <<< (bits - 1), do: m - (1 <<< bits), else: m
  end

  defp with_length({:obj, id} = f, n) do
    store(id, Map.put(deref(id), :arity, n * 1.0))
    f
  end
end
